import Foundation
import Darwin

/// 由调用方判断标识的归属：已安装（不列出）、需人工核对（只读列出）或孤立（可选择）。
public enum LeftoverOwnership: Sendable, Equatable {
    case installed
    case review(String)
    case orphan
}

public struct LeftoverGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let paths: [URL]
    public let allocatedSize: Int64?
    public let logicalSize: Int64?
    public let blockedReason: String?
}

public struct LeftoverScanResult: Sendable {
    public let groups: [LeftoverGroup]
    public let summary: ScanSummary
    public let truncated: Bool
}

// 已卸载应用留在 ~/Library 的精确标识数据。只按固定位置与完整标识识别，
// 不做名称或前缀猜测；调用方的串行队列持有本会话及其 SQLite 索引。
public final class OrphanLeftovers {
    private struct Record {
        let url: URL
        let rootID: Int64
        let ancestors: [(URL, FileIdentity)]
    }
    private struct Group {
        let id: String
        var paths: [URL] = []
        var records: [Record] = []
        var issue: String?
    }
    /// ~/Library 下的固定位置：目录名、条目后缀、是否目录。ByHost 另行处理。
    static let locations: [(String, String, Bool)] = [
        ("Caches", "", true), ("Application Support", "", true), ("Preferences", ".plist", false),
        ("Containers", "", true), ("Saved Application State", ".savedState", true), ("Logs", "", true),
        ("HTTPStorages", "", true), ("HTTPStorages", ".binarycookies", false), ("WebKit", "", true),
        ("Application Scripts", "", true), ("Cookies", ".binarycookies", false)
    ]
    public static let maxGroups = 2048
    private let index: DiskIndex
    private let home: URL
    private let protection: ProtectionStore
    private var stored: [Group] = []
    private var invalid = false

    public init(index: DiskIndex, home: URL = FileManager.default.homeDirectoryForCurrentUser, protection: ProtectionStore = .shared) {
        self.index = index; self.home = (try? canonicalFileURL(home)) ?? home; self.protection = protection
    }

    /// 像应用标识的名称：至少三段、字符合法；Apple、MacEven 自身与共享应用组不在范围内。
    static func candidateIdentifier(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard ProtectionStore.validIdentifier(value), value.split(separator: ".").count >= 3,
              !lower.hasPrefix("com.apple."), !lower.hasPrefix("local.maceven"), !lower.hasPrefix("group."),
              // 开发工具规则管理的缓存（如 org.swift.swiftpm）属于命令行工具，不是已卸载应用的残留。
              !DeveloperCleanupRule.allCases.contains(where: { ($0.relativePath as NSString).lastPathComponent.lowercased() == lower }) else { return false }
        return value.split(separator: ".").allSatisfy { !$0.isEmpty }
    }

    /// 某个标识在固定位置上的精确路径（不含 ByHost）；用于移动前复核范围。
    func exactPaths(_ id: String) -> [String] {
        Self.locations.map { home.appendingPathComponent("Library/\($0.0)/\(id)\($0.1)").path }
    }

    private func byHost(_ name: String) -> String? {
        guard name.hasSuffix(".plist") else { return nil }
        let stem = name.dropLast(6)
        guard let dot = stem.lastIndex(of: "."), UUID(uuidString: String(stem[stem.index(after: dot)...])) != nil else { return nil }
        return String(stem[..<dot])
    }

    private func ancestry(_ url: URL) throws -> [(URL, FileIdentity)] {
        try validateHomePath(url, home: home)
        var current = home, values = [(home, try FileIdentity.read(home))]
        for part in url.path.dropFirst(home.path.count + 1).split(separator: "/").dropLast() {
            current.appendPathComponent(String(part)); values.append((current, try FileIdentity.read(current)))
        }
        return values
    }

    public func scan(token: CancellationToken, ownership: (String) -> LeftoverOwnership,
                     progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> LeftoverScanResult {
        try index.reset(); stored = []; invalid = false
        let start = Date()
        var errors = 0, examples: [String] = [], truncated = false, discoveryIncomplete = false
        func note(_ text: String) { errors += 1; if examples.count < 100 { examples.append(String(text.prefix(1000))) } }
        func missing(_ error: Error) -> Bool {
            let value = error as NSError
            return value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT)
        }
        // 1. 枚举固定位置的直接子项，按完整标识分组。
        var found: [String: (String, [URL])] = [:]
        var entries = 0
        let bases = Set(Self.locations.map(\.0)).sorted() + ["Preferences/ByHost"]
        for base in bases where !token.isCancelled {
            let folder = home.appendingPathComponent("Library/\(base)")
            do { try validateHomePath(folder, home: home) } catch { if !missing(error) { note(error.localizedDescription); discoveryIncomplete = true }; continue }
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in note(error.localizedDescription); discoveryIncomplete = true; return !token.isCancelled }) else {
                note(localized("无法枚举 \(folder.path)")); discoveryIncomplete = true; continue
            }
            while !token.isCancelled, let url = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                entries += 1
                if entries > 65536 { truncated = true; discoveryIncomplete = true; break }
                let name = url.lastPathComponent
                var identifier: String?
                if base == "Preferences/ByHost" { identifier = byHost(name) }
                else {
                    for (location, suffix, _) in Self.locations where location == base {
                        if suffix.isEmpty ? !name.contains(".plist") && !name.hasSuffix(".savedState") && !name.hasSuffix(".binarycookies") : name.hasSuffix(suffix) {
                            identifier = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
                        }
                    }
                }
                guard let identifier, Self.candidateIdentifier(identifier) else { continue }
                let key = identifier.lowercased()
                if found[key] == nil {
                    if found.count >= Self.maxGroups { truncated = true; discoveryIncomplete = true; continue }
                    found[key] = (identifier, [])
                }
                found[key]?.1.append(url)
            }
        }
        // 2. 已安装的标识不列出；其余统计占用，孤立项需完整统计才可选择。
        var visited = 0, logical: Int64 = 0, allocated: Int64 = 0
        let keys = found.keys.sorted(), total = keys.count
        func snapshot(_ done: Int, path: String) -> ScanProgress {
            ScanProgress(visited: visited, logicalSize: logical, allocatedSize: allocated, currentPath: path,
                elapsed: Date().timeIntervalSince(start), errors: errors).units(done, of: total)
        }
        for (offset, key) in keys.enumerated() {
            if token.isCancelled { break }
            let (id, urls) = found[key]!
            progress(snapshot(offset, path: urls.first?.path ?? id))
            let owner = ownership(id)
            if owner == .installed { continue }
            var group = Group(id: id, paths: urls.sorted { $0.path < $1.path })
            if case .review(let reason) = owner { group.issue = reason }
            if let reason = protection.reason(forBundleIdentifier: id) { group.issue = group.issue ?? reason }
            for url in group.paths {
                if token.isCancelled { group.issue = group.issue ?? localized("扫描已取消，请重新扫描。"); break }
                do {
                    if let reason = protection.reason(for: url) { group.issue = group.issue ?? reason }
                    let parents = try ancestry(url), identity = try FileIdentity.read(url)
                    guard !identity.isSymlink else { throw MacEvenError(localized("符号链接不可操作：\(url.path)")) }
                    let rootID: Int64
                    if identity.isDirectory {
                        let oldVisited = visited, oldLogical = logical, oldAllocated = allocated, oldErrors = errors
                        let summary = try Scanner.scan(root: url, index: index, token: token, resetIndex: false, requireCompleteTraversal: true) { value in
                            progress(ScanProgress(visited: oldVisited + value.visited, logicalSize: oldLogical + value.logicalSize, allocatedSize: oldAllocated + value.allocatedSize,
                                currentPath: value.currentPath, elapsed: Date().timeIntervalSince(start), errors: oldErrors + value.errors).units(offset, of: total))
                        }
                        rootID = summary.rootID; visited += summary.visited
                        if summary.cancelled || summary.errors > 0 {
                            group.issue = group.issue ?? localized("残留统计不完整，请解决访问问题后重新扫描。")
                            errors += summary.errors; examples.append(contentsOf: summary.errorExamples.prefix(max(0, 100 - examples.count)))
                        }
                    } else if identity.isRegular {
                        rootID = try index.insert(parent: 0, url: url, identity: identity).id; visited += 1
                    } else { throw MacEvenError(localized("特殊文件不可操作：\(url.path)")) }
                    if let entry = try index.entry(id: rootID) { logical += entry.logicalSize; allocated += entry.allocatedSize }
                    group.records.append(Record(url: url, rootID: rootID, ancestors: parents))
                } catch {
                    if !missing(error) { note(error.localizedDescription) }
                    group.issue = group.issue ?? localized("残留统计不完整：\(error.localizedDescription)")
                }
            }
            stored.append(group)
        }
        if !token.isCancelled { progress(snapshot(total, path: home.path)) }
        if token.isCancelled { for n in stored.indices { stored[n].issue = stored[n].issue ?? localized("扫描已取消，请重新扫描。") } }
        if discoveryIncomplete { for n in stored.indices { stored[n].issue = stored[n].issue ?? localized("残留位置枚举不完整，请解决访问问题后重新扫描。") } }
        let summary = ScanSummary(rootID: 0, visited: visited, cancelled: token.isCancelled, errors: errors, errorExamples: examples, elapsed: Date().timeIntervalSince(start))
        return LeftoverScanResult(groups: try refresh(ownership: ownership), summary: summary, truncated: truncated)
    }

    public func refresh(ownership: (String) -> LeftoverOwnership) throws -> [LeftoverGroup] {
        var values: [LeftoverGroup] = []
        for group in stored {
            let roots = try group.records.compactMap { try index.entry(id: $0.rootID) }
            if !group.records.isEmpty && roots.isEmpty { continue }
            var reason = invalid ? localized("索引失效，请重新扫描。") : group.issue
            if reason == nil {
                switch ownership(group.id) {
                case .installed: reason = localized("对应应用已重新安装或可被系统找到，保留。")
                case .review(let text): reason = text
                case .orphan: break
                }
            }
            if reason == nil { reason = protection.reason(forBundleIdentifier: group.id) }
            if reason == nil { for record in group.records { if let text = protection.reason(for: record.url) { reason = text; break } } }
            if reason == nil && group.records.count != group.paths.count { reason = localized("部分残留未能统计，保留。") }
            let measured = !group.records.isEmpty && group.records.count == group.paths.count
            values.append(LeftoverGroup(id: group.id, paths: group.paths,
                allocatedSize: measured ? roots.reduce(0) { $0 + $1.allocatedSize } : nil,
                logicalSize: measured ? roots.reduce(0) { $0 + $1.logicalSize } : nil, blockedReason: reason))
        }
        return values.sorted { ($0.allocatedSize ?? -1) == ($1.allocatedSize ?? -1) ? $0.id < $1.id : ($0.allocatedSize ?? -1) > ($1.allocatedSize ?? -1) }
    }

    private func validate(_ record: Record, id: String) throws {
        // 同一标识在不同位置的大小写可能不同（APFS 默认不区分大小写），比较时统一小写。
        let path = record.url.path
        guard exactPaths(id).contains(where: { $0.lowercased() == path.lowercased() })
            || (record.url.deletingLastPathComponent().path == home.appendingPathComponent("Library/Preferences/ByHost").path
                && byHost(record.url.lastPathComponent)?.lowercased() == id.lowercased()) else { throw MacEvenError(localized("路径不在该标识的固定残留范围内：\(path)")) }
        for protected in [index.url.path, Bundle.main.bundleURL.resolvingSymlinksInPath().path] {
            guard path != protected, !protected.hasPrefix(path + "/"), !path.hasPrefix(protected + "/") else { throw MacEvenError(localized("MacEven 自身及索引受保护。")) }
        }
        if let reason = protection.reason(for: record.url) { throw MacEvenError(reason) }
        let current = try ancestry(record.url)
        guard current.count == record.ancestors.count, zip(current, record.ancestors).allSatisfy({ a, b in
            a.0 == b.0 && a.1.device == b.1.device && a.1.inode == b.1.inode && a.1.mode == b.1.mode
        }) else { throw MacEvenError(localized("祖先目录已被替换，请重新扫描。")) }
        try index.validateSubtree(id: record.rootID)
    }

    public func move(groupIDs: [String], ownership: (String) -> LeftoverOwnership) -> [TrashResult] {
        let ids = Set(groupIDs)
        guard ids.count <= 50 else { return [TrashResult(id: 0, path: "", destination: nil, error: localized("一次最多选择 50 个标识。"))] }
        var results: [TrashResult] = []
        for id in ids.sorted() {
            do {
                guard !invalid, let group = stored.first(where: { $0.id == id }), group.issue == nil, !group.records.isEmpty,
                      group.records.count == group.paths.count else { throw MacEvenError(localized("该残留不可清理，请重新扫描。")) }
                guard ownership(id) == .orphan else { throw MacEvenError(localized("对应应用已安装、正在运行或可能共享，残留保留。")) }
                if let reason = protection.reason(forBundleIdentifier: id) { throw MacEvenError(reason) }
                // 先完整复核整组，再逐项移动；每项移动前再查一次归属。
                for record in group.records { try validate(record, id: id) }
                for record in group.records {
                    var destination: NSURL?
                    var size: Int64?
                    do {
                        guard ownership(id) == .orphan else { throw MacEvenError(localized("对应应用已重新出现，余下残留保留。")) }
                        try validate(record, id: id)
                        size = try index.entry(id: record.rootID)?.allocatedSize
                        try FileManager.default.trashItem(at: record.url, resultingItemURL: &destination)
                        do { try index.removeSubtree(id: record.rootID) }
                        catch { invalid = true; throw MacEvenError(localized("已移到废纸篓，但索引同步失败：\(error.localizedDescription)。请重新扫描。")) }
                        results.append(TrashResult(id: record.rootID, path: record.url.path, destination: destination as URL?, error: nil, allocatedSize: size))
                    } catch {
                        results.append(TrashResult(id: record.rootID, path: record.url.path, destination: destination as URL?, error: error.localizedDescription, allocatedSize: size))
                        break
                    }
                }
            } catch { results.append(TrashResult(id: 0, path: id, destination: nil, error: error.localizedDescription)) }
        }
        return results
    }
}
