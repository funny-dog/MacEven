import Foundation

// Shared lstat-only ancestry check; never resolve a symlink into an allowed path.
func validateHomePath(_ url: URL, home: URL) throws {
    guard url.path.hasPrefix(home.path + "/"), !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw MacEvenError(localized("路径不在允许的主目录范围内。")) }
    var current = home
        let base = try FileIdentity.read(home)
        guard base.isDirectory && !base.isSymlink else { throw MacEvenError(localized("主目录已变化，请重新启动。")) }
        let parts = url.path.dropFirst(home.path.count + 1).split(separator: "/")
        for (offset, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            let info = try FileIdentity.read(current)
            if info.isSymlink { throw MacEvenError(localized("符号链接或经过符号链接的路径不可操作。")) }
            if info.device != base.device { throw MacEvenError(localized("其他挂载卷不可操作。")) }
            if offset == parts.count - 1 {
                if !info.isRegular && !info.isDirectory { throw MacEvenError(localized("特殊文件不可操作。")) }
            } else if !info.isDirectory { throw MacEvenError(localized("祖先目录已变化。")) }
        }
}
func homePathBlockReason(_ url: URL, home: URL) -> String? {
    do { try validateHomePath(url, home: home); return nil } catch { return error.localizedDescription }
}

/// 外接卷内的路径：不含隐藏组成部分，从卷根逐级 lstat 无符号链接、同一设备，卷根身份与扫描时一致。
func volumePathBlockReason(_ url: URL, root: TrashService.VolumeRoot) -> String? {
    let path = url.path
    guard path.hasPrefix(root.url.path + "/"), !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
        return localized("路径不在允许的磁盘范围内。")
    }
    let parts = path.dropFirst(root.url.path.count + 1).split(separator: "/")
    guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") }) else { return localized("隐藏路径受保护。") }
    do {
        let base = try FileIdentity.read(root.url)
        guard base.isDirectory, !base.isSymlink, base.device == root.device, base.inode == root.inode else {
            return localized("磁盘已变化，请重新扫描。")
        }
        var current = root.url
        for (offset, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            let info = try FileIdentity.read(current)
            if info.isSymlink { return localized("符号链接或经过符号链接的路径不可操作。") }
            if info.device != base.device { return localized("其他挂载卷不可操作。") }
            if offset == parts.count - 1 {
                if !info.isRegular && !info.isDirectory { return localized("特殊文件不可操作。") }
            } else if !info.isDirectory { return localized("祖先目录已变化。") }
        }
    } catch { return error.localizedDescription }
    return nil
}

func validCacheIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".." &&
    value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }
}

public struct TrashResult: Sendable {
    public let id: Int64
    public let path: String
    public let destination: URL?
    public let error: String?
    public let allocatedSize: Int64?
    public init(id: Int64, path: String, destination: URL?, error: String?, allocatedSize: Int64? = nil) {
        self.id = id; self.path = path; self.destination = destination; self.error = error; self.allocatedSize = allocatedSize
    }
}

/// 默认清理范围（磁盘分析）下条目受保护的结构化原因。
public enum BlockKind: Sendable, Equatable {
    case pathInvalid(String)
    case outsideHome
    case libraryOrHidden
    case macevenSelf
    case userProtected(String)

    /// 既有清理流程使用的文案，与本改动前的 reasonBlocked 保持一致。
    public var blockedMessage: String {
        switch self {
        case .pathInvalid(let detail): return detail
        case .outsideHome: return localized("首版仅允许操作主目录内的普通文件，主目录本身受保护。")
        case .libraryOrHidden: return localized("Library 和隐藏路径受保护。")
        case .macevenSelf: return localized("MacEven 自身及其索引受保护。")
        case .userProtected(let detail): return detail
        }
    }

    /// 大文件列表悬停与 VoiceOver 使用的用户语言说明。
    public var lockReason: String {
        switch self {
        case .pathInvalid(let detail), .userProtected(let detail): return detail
        case .outsideHome: return localized("不在主目录内，MacEven 只清理主目录中的文件")
        case .libraryOrHidden: return localized("位于资料库或隐藏路径，默认受保护")
        case .macevenSelf: return localized("属于 MacEven 自身或索引，不可清理")
        }
    }

    /// 汇总行里的分组名称。
    public var summaryLabel: String {
        switch self {
        case .pathInvalid: return localized("路径无效")
        case .outsideHome: return localized("主目录外")
        case .libraryOrHidden: return localized("资料库/隐藏")
        case .macevenSelf: return localized("MacEven 自身")
        case .userProtected: return localized("保护名单")
        }
    }
}

public final class TrashService {
    /// 重复文件扫描时校验过的外接卷根（挂载点路径与身份）。
    struct VolumeRoot: Sendable {
        let url: URL
        let device: Int64
        let inode: Int64
    }
    private let index: DiskIndex
    private let home: URL
    private let cacheApplications: [CacheApplication]
    private let cacheMode: Bool
    private let developerRoots: [URL]
    private let developerMode: Bool
    private let protection: ProtectionStore
    private let volumeRoots: [VolumeRoot]
    public convenience init(index: DiskIndex, home: URL = FileManager.default.homeDirectoryForCurrentUser, cacheBundleIdentifiers: Set<String> = [], cacheApplications: [CacheApplication] = [], protection: ProtectionStore = .shared) {
        self.init(index: index, home: home, cacheBundleIdentifiers: cacheBundleIdentifiers, cacheApplications: cacheApplications, developerAllowedRoots: [], protection: protection)
    }
    init(index: DiskIndex, home: URL, cacheBundleIdentifiers: Set<String> = [], cacheApplications: [CacheApplication] = [], developerAllowedRoots: [URL], protection: ProtectionStore = .shared,
         volumeRoots: [VolumeRoot] = []) {
        self.index = index; self.home = (try? canonicalFileURL(home)) ?? home.standardizedFileURL
        self.protection = protection
        self.volumeRoots = volumeRoots
        self.cacheMode = !cacheBundleIdentifiers.isEmpty || !cacheApplications.isEmpty
        self.cacheApplications = (cacheApplications + cacheBundleIdentifiers.map { CacheApplication(id: $0, name: $0) }).filter {
            validCacheIdentifier($0.id) && !$0.id.lowercased().hasPrefix("com.apple.") && !$0.id.lowercased().hasPrefix("local.maceven") && $0.id.lowercased() != "maceven"
        }
        // 只放行固定规则的根目录；DerivedData 只放行其中的单个项目目录。
        let home = self.home
        let filteredRoots = developerAllowedRoots.filter { root in
            DeveloperCleanupRule.allCases.contains { rule in
                let base = home.appendingPathComponent(rule.relativePath).path
                return rule == .derivedData ? root.deletingLastPathComponent().path == base : root.path == base
            }
        }
        self.developerRoots = filteredRoots
        self.developerMode = !developerAllowedRoots.isEmpty
    }

    /// 规范化后的主目录路径；索引粗筛必须与保护判定使用同一个值。
    public var homePath: String { home.path }

    /// 默认清理范围（磁盘分析）的结构化锁定原因。
    /// 缓存、开发工具与外接卷路径不属于此范围，返回 nil；这些流程继续使用 reasonBlocked 的既有文案。
    public func blockKind(_ url: URL, applyingUserProtection: Bool = true) -> BlockKind? {
        guard !cacheMode, !developerMode else { return nil }
        let path = url.path
        if volumeRoots.contains(where: { path.hasPrefix($0.url.path + "/") }) { return nil }
        // Foundation standardization may rewrite /private/var to /var. Preserve filesystem spelling.
        if url.pathComponents.contains("..") || url.pathComponents.contains(".") { return .pathInvalid(localized("路径必须是扫描得到的实际路径。")) }
        guard path.hasPrefix(home.path + "/") else { return .outsideHome }
        let parts = path.dropFirst(home.path.count + 1).split(separator: "/")
        guard parts.first != "Library", !parts.contains(where: { $0.hasPrefix(".") }) else { return .libraryOrHidden }
        if selfReason(url) != nil { return .macevenSelf }
        if applyingUserProtection, let reason = protection.reason(for: url) { return .userProtected(reason) }
        if let reason = homePathBlockReason(url, home: home) { return .pathInvalid(reason) }
        return nil
    }

    /// applyingUserProtection 仅供重复文件的保留项关闭：保护保留项不应阻止删除其他副本。
    public func reasonBlocked(_ url: URL, applyingUserProtection: Bool = true) -> String? {
        // Foundation standardization may rewrite /private/var to /var. Preserve filesystem spelling.
        let path = url.path
        if url.pathComponents.contains("..") || url.pathComponents.contains(".") { return localized("路径必须是扫描得到的实际路径。") }
        // 外接卷只对普通删除模式开放（重复文件）；缓存与开发工具清理仍限主目录白名单。
        if !developerMode && !cacheMode {
            if let root = volumeRoots.first(where: { path.hasPrefix($0.url.path + "/") }) {
                if let reason = volumePathBlockReason(url, root: root) { return reason }
                return selfOrUserReason(url, applyingUserProtection: applyingUserProtection)
            }
            // 默认范围与 blockKind 共用同一套判定，避免大文件提示与实际保护规则分叉。
            return blockKind(url, applyingUserProtection: applyingUserProtection)?.blockedMessage
        }
        guard path.hasPrefix(home.path + "/") else { return localized("首版仅允许操作主目录内的普通文件，主目录本身受保护。") }
        let parts = path.dropFirst(home.path.count + 1).split(separator: "/")
        if developerMode {
            let allowed = developerRoots.contains { root in
                path == root.path
            }
            guard allowed else { return localized("开发工具清理仅允许白名单范围内的缓存路径。") }
        } else {
            let relative = parts.joined(separator: "/")
            let owners = cacheApplications.filter { ApplicationCachePaths.contains(relative, application: $0) }
            guard Set(owners.map(\.id)).count == 1 else { return localized("缓存清理仅允许归属唯一且精确匹配的应用缓存路径。") }
            if applyingUserProtection {
                for owner in owners { if let reason = protection.reason(forBundleIdentifier: owner.id) { return reason } }
            }
        }
        if let reason = selfOrUserReason(url, applyingUserProtection: applyingUserProtection) { return reason }
        return homePathBlockReason(url, home: home)
    }

    private func selfReason(_ url: URL) -> String? {
        let path = url.path
        for protected in [index.url.path, Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path] {
            if path == protected || path.hasPrefix(protected + "/") || protected.hasPrefix(path + "/") { return localized("MacEven 自身及其索引受保护。") }
        }
        return nil
    }

    private func selfOrUserReason(_ url: URL, applyingUserProtection: Bool) -> String? {
        if let reason = selfReason(url) { return reason }
        if applyingUserProtection, let reason = protection.reason(for: url) { return reason }
        return nil
    }

    public func move(ids: [Int64]) -> [TrashResult] {
        let selected = Set(ids)
        guard selected.count <= 100 else {
            return [TrashResult(id: 0, path: "", destination: nil, error: localized("一次最多选择 100 个条目。"))]
        }
        var results: [TrashResult] = []
        // Filter ancestors before mutations, so earlier deletions cannot hide the selection relationship.
        var targets: [DiskEntry] = []
        for id in selected.sorted() {
            do {
                guard let item = try index.entry(id: id) else { throw MacEvenError(localized("条目已不存在，请重新扫描。")) }
                let parents = try index.ancestors(of: id).dropLast()
                if parents.contains(where: { selected.contains($0.id) }) { continue }
                targets.append(item)
            } catch { results.append(TrashResult(id: id, path: "", destination: nil, error: error.localizedDescription)) }
        }
        var invalidIndex = false
        for item in targets {
            var destination: NSURL?
            do {
                if invalidIndex { throw MacEvenError(localized("索引同步失败，余下操作停止；请重新扫描。")) }
                if let reason = reasonBlocked(item.url) { throw MacEvenError(reason) }
                let fresh = try FileIdentity.read(item.url)
                guard fresh == item.identity else { throw MacEvenError(localized("文件已被修改或替换，请重新扫描。")) }
                for parent in try index.ancestors(of: item.id).dropLast() {
                    let actual = try FileIdentity.read(parent.url)
                    guard actual.isDirectory && actual.device == parent.identity.device && actual.inode == parent.identity.inode else {
                        throw MacEvenError(localized("祖先目录已被替换，请重新扫描。"))
                    }
                }
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
                do { try index.removeSubtree(id: item.id) }
                catch {
                    invalidIndex = true
                    results.append(TrashResult(id: item.id, path: item.url.path, destination: destination as URL?, error: localized("已移到废纸篓，但索引同步失败：\(error.localizedDescription)。请重新扫描。"), allocatedSize: item.allocatedSize))
                    continue
                }
                results.append(TrashResult(id: item.id, path: item.url.path, destination: destination as URL?, error: nil, allocatedSize: item.allocatedSize))
            } catch { results.append(TrashResult(id: item.id, path: item.url.path, destination: destination as URL?, error: error.localizedDescription, allocatedSize: item.allocatedSize)) }
        }
        return results
    }
}
