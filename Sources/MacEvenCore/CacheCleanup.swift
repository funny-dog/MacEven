import Foundation
import Darwin

public struct CacheApplication: Sendable {
    public let id: String
    public let name: String
    public let directoryNames: [String]
    public let applicationGroups: [String]
    public init(id: String, name: String, directoryNames: [String] = [], applicationGroups: [String] = []) {
        self.id = id; self.name = String(name.prefix(512))
        self.directoryNames = Array(directoryNames.prefix(16)); self.applicationGroups = Array(applicationGroups.filter(validCacheIdentifier).prefix(64))
    }

    public init?(bundleURL: URL) {
        guard let info = try? ApplicationDataDiscovery.plist(bundleURL.appendingPathComponent("Contents/Info.plist"), root: bundleURL),
              let id = info["CFBundleIdentifier"] as? String, validCacheIdentifier(id) else { return nil }
        let filename = bundleURL.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: bundleURL)
        let names = ["CFBundleName", "CFBundleDisplayName"].flatMap { key in [info[key] as? String, bundle?.object(forInfoDictionaryKey: key) as? String].compactMap { $0 } }
        self.init(id: id, name: (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? filename,
            directoryNames: names + [filename], applicationGroups: ApplicationDataDiscovery.groups(bundleURL))
    }
}

public struct CacheGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let paths: [URL]
    public let allocatedSize: Int64?
    public let logicalSize: Int64?
    public let blockedReason: String?
}

public struct CacheScanResult: Sendable {
    public let groups: [CacheGroup]
    public let summary: ScanSummary
    public let truncated: Bool
}

// Owned by the caller's serial queue. SQLite holds file records, not a tree in RAM.
public final class CacheCleanup {
    private struct Group {
        let id: String
        let app: CacheApplication?
        var paths: [URL] = []
        var roots: [Int64] = []
        var issue: String?
    }
    private let index: DiskIndex
    private let home: URL
    private let apps: [String: CacheApplication]
    private let catalogTruncated: Bool
    private var stored: [Group] = []
    private var indexInvalid = false
    private let protection: ProtectionStore

    public init(index: DiskIndex, home: URL = FileManager.default.homeDirectoryForCurrentUser, applications: [CacheApplication], protection: ProtectionStore = .shared) {
        self.index = index; self.home = (try? canonicalFileURL(home)) ?? home; self.protection = protection
        var unique: [String: CacheApplication] = [:]
        for app in applications.prefix(2048) where validCacheIdentifier(app.id) { unique[app.id] = app }
        apps = unique; catalogTruncated = applications.count > 2048
    }

    public func scan(token: CancellationToken, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> CacheScanResult {
        try index.reset(); stored = []; indexInvalid = false
        let start = Date()
        var candidates: [(URL, String)] = []; var truncated = catalogTruncated
        var owners: [String: Set<String>] = [:]
        for app in apps.values {
            for relative in ApplicationCachePaths.relativeRoots(for: app) { owners[ApplicationCachePaths.key(relative), default: []].insert(app.id) }
        }
        var errors = 0; var examples: [String] = []; var discoveryIncomplete = false
        func note(_ reason: String) { errors += 1; if examples.count < 100 { examples.append(String(reason.prefix(1000))) } }
        for (relative, sandbox) in [("Library/Caches", false), ("Library/Containers", true)] {
            if token.isCancelled { break }
            let base = home.appendingPathComponent(relative)
            do { try validateHomePath(base, home: home) }
            catch { let value = error as NSError; if value.domain != NSPOSIXErrorDomain || value.code != Int(ENOENT) { note(error.localizedDescription); discoveryIncomplete = true }; continue }
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in note(error.localizedDescription); discoveryIncomplete = true; return !token.isCancelled }) else { note(localized("无法枚举 \(base.path)")); discoveryIncomplete = true; continue }
            while !token.isCancelled, let url = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                if candidates.count >= 4096 { truncated = true; discoveryIncomplete = true; break }
                let cache = sandbox ? url.appendingPathComponent("Data/Library/Caches") : url
                if sandbox {
                    do { try validateHomePath(cache, home: home) }
                    catch { let value = error as NSError; if value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT) { continue } }
                }
                candidates.append((cache, url.lastPathComponent))
            }
        }
        for baseRelative in ["Library/Application Support", ".cache", "Library/Group Containers"] {
            if token.isCancelled { break }
            let base = home.appendingPathComponent(baseRelative)
            do { try validateHomePath(base, home: home) }
            catch { let value = error as NSError; if value.domain != NSPOSIXErrorDomain || value.code != Int(ENOENT) { note(error.localizedDescription); discoveryIncomplete = true }; continue }
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in note(error.localizedDescription); discoveryIncomplete = true; return !token.isCancelled }) else { note(localized("无法枚举 \(base.path)")); discoveryIncomplete = true; continue }
            var entries = 0
            while !token.isCancelled, let product = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                entries += 1
                if entries > 16384 || candidates.count >= 4096 { truncated = true; discoveryIncomplete = true; break }
                let suffixes = baseRelative == "Library/Application Support" ? ApplicationCachePaths.cacheDirectories : baseRelative == ".cache" ? [""] : ["Library/Caches"]
                for suffix in suffixes {
                    let cache = suffix.isEmpty ? product : product.appendingPathComponent(suffix)
                    let relative = String(cache.path.dropFirst(home.path.count + 1))
                    guard owners[ApplicationCachePaths.key(relative)] != nil else { continue }
                    if candidates.count >= 4096 { truncated = true; discoveryIncomplete = true; break }
                    do { try validateHomePath(cache, home: home) }
                    catch { let value = error as NSError; if value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT) { continue } }
                    candidates.append((cache, product.lastPathComponent))
                }
            }
        }
        var visited = 0; var logical: Int64 = 0; var allocated: Int64 = 0
        var positions: [String: Int] = [:]
        func snapshot(_ done: Int, path: String) -> ScanProgress {
            ScanProgress(visited: visited, logicalSize: logical, allocatedSize: allocated, currentPath: path,
                elapsed: Date().timeIntervalSince(start), errors: errors).units(done, of: candidates.count)
        }
        for (offset, (path, owner)) in candidates.enumerated() {
            progress(snapshot(offset, path: path.path))
            let relative = String(path.path.dropFirst(home.path.count + 1))
            let matches = owners[ApplicationCachePaths.key(relative)] ?? []
            let shared = relative.hasPrefix("Library/Group Containers/")
            let app = !shared && matches.count == 1 ? matches.first.flatMap { apps[$0] } : nil
            let id = app?.id ?? "unknown:\(path.path)"
            let position: Int
            if let known = positions[id] { position = known }
            else { position = stored.count; positions[id] = position; stored.append(Group(id: id, app: app)) }
            stored[position].paths.append(path)
            let protected = owner.lowercased().hasPrefix("com.apple.") || owner.lowercased().hasPrefix("local.maceven") || owner.lowercased() == "maceven"
            if protected { stored[position].issue = localized("系统和 MacEven 自身缓存受保护。") }
            if app == nil { stored[position].issue = stored[position].issue ?? localized("无法精确识别应用归属，仅供查看。") }
            if shared { stored[position].issue = localized("应用组缓存可能由多个应用共享，仅供查看。") }
            if ApplicationCachePaths.isDeveloperPath(relative) { stored[position].issue = localized("已归入开发与浏览器缓存，仅供查看。") }
            if token.isCancelled { stored[position].issue = localized("扫描已取消，请重新扫描。"); continue }
            // 用户保护不是扫描错误，直接只读展示。
            if let reason = app.flatMap({ protection.reason(forBundleIdentifier: $0.id) }) ?? protection.reason(for: path) { stored[position].issue = reason }
            do {
                // 归属与保护决定能否清理，不应阻止只读统计。
                try validateHomePath(path, home: home)
                guard try FileIdentity.read(path).isDirectory else { throw MacEvenError(localized("缓存入口不是目录。")) }
                let oldVisited = visited, oldLogical = logical, oldAllocated = allocated, oldErrors = errors
                let total = candidates.count
                let summary = try Scanner.scan(root: path, index: index, token: token, resetIndex: false, requireCompleteTraversal: stored[position].issue == nil) { value in
                    progress(ScanProgress(visited: oldVisited + value.visited, logicalSize: oldLogical + value.logicalSize, allocatedSize: oldAllocated + value.allocatedSize,
                        currentPath: value.currentPath, elapsed: Date().timeIntervalSince(start), errors: oldErrors + value.errors).units(offset, of: total))
                }
                stored[position].roots.append(summary.rootID); visited += summary.visited
                errors += summary.errors; examples.append(contentsOf: summary.errorExamples.prefix(max(0, 100 - examples.count)))
                if let root = try index.entry(id: summary.rootID) { logical += root.logicalSize; allocated += root.allocatedSize }
                if summary.cancelled || summary.errors > 0 { stored[position].issue = localized("缓存扫描不完整，请重新扫描。") }
            } catch { stored[position].issue = error.localizedDescription; note(error.localizedDescription) }
        }
        if !token.isCancelled { progress(snapshot(candidates.count, path: home.path)) }
        if token.isCancelled { for n in stored.indices { stored[n].issue = stored[n].issue ?? localized("扫描已取消，请重新扫描。") } }
        if discoveryIncomplete { for n in stored.indices { stored[n].issue = stored[n].issue ?? localized("缓存范围枚举不完整，请解决访问问题后重新扫描。") } }
        let groups = try refresh(isRunning: { _ in false })
        let summary = ScanSummary(rootID: 0, visited: visited, cancelled: token.isCancelled, errors: errors, errorExamples: examples, elapsed: Date().timeIntervalSince(start))
        return CacheScanResult(groups: groups, summary: summary, truncated: truncated)
    }

    public func refresh(isRunning: (String) -> Bool) throws -> [CacheGroup] {
        var values: [CacheGroup] = []
        for group in stored {
            let roots = try group.roots.compactMap { try index.entry(id: $0) }
            if !group.roots.isEmpty && roots.isEmpty { continue }
            var reason = group.issue
            if indexInvalid { reason = localized("索引失效，请重新扫描。") }
            if reason == nil, let app = group.app, isRunning(app.id) { reason = localized("应用正在运行，请退出后重新检查。") }
            if reason == nil, let app = group.app { for root in roots { if let error = TrashService(index: index, home: home, cacheApplications: [app], protection: protection).reasonBlocked(root.url) { reason = error; break } } }
            let path = group.paths[0]
            let name = path.path.hasPrefix(home.appendingPathComponent("Library/Group Containers").path + "/") ? path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent + localized(" 共享缓存") : path.lastPathComponent
            values.append(CacheGroup(id: group.id, name: group.app?.name ?? name,
                paths: roots.isEmpty || group.issue != nil ? group.paths : roots.map(\.url), allocatedSize: roots.isEmpty ? nil : roots.reduce(0) { $0 + $1.allocatedSize },
                logicalSize: roots.isEmpty ? nil : roots.reduce(0) { $0 + $1.logicalSize }, blockedReason: reason))
        }
        return values.sorted { ($0.allocatedSize ?? -1) == ($1.allocatedSize ?? -1) ? $0.id < $1.id : ($0.allocatedSize ?? -1) > ($1.allocatedSize ?? -1) }
    }

    /// 「查看构成」：从本次扫描索引读取缓存组的直接子项（按占用排序）；只读，不引入新扫描。
    /// 一个应用可对应多个缓存根，构成是各根直接子项的合并清单。
    public func composition(groupID: String, limit: Int = 20) throws -> CleanupComposition? {
        guard !indexInvalid, let group = stored.first(where: { $0.id == groupID }), !group.roots.isEmpty,
            let root = group.paths.first else { return nil }
        var entries: [CleanupCompositionEntry] = []
        var total = 0
        for rootID in group.roots {
            guard try index.entry(id: rootID) != nil else { continue }
            total += try index.childCount(of: rootID)
            entries += try index.children(of: rootID, offset: 0, limit: max(1, min(limit, 100))).map { child in
                CleanupCompositionEntry(url: child.url, allocatedSize: child.allocatedSize, isDirectory: child.isDirectory,
                    modifiedAt: Date(timeIntervalSince1970: Double(child.identity.modified) / 1_000_000_000))
            }
        }
        guard !entries.isEmpty else { return nil }
        entries.sort { $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.id < $1.id }
        return CleanupComposition(root: root, entries: Array(entries.prefix(limit)), totalChildren: total, measuredLive: false)
    }

    public func rescanAfterQuit(groupID: String, token: CancellationToken, isRunning: (String) -> Bool) throws {
        guard !indexInvalid, let position = stored.firstIndex(where: { $0.id == groupID }), stored[position].issue == nil,
            let app = stored[position].app, !stored[position].roots.isEmpty, !isRunning(app.id) else { throw MacEvenError(localized("应用尚未退出或缓存不可清理，内容已保留。")) }
        do {
            let service = TrashService(index: index, home: home, cacheApplications: [app], protection: protection)
            for offset in stored[position].roots.indices {
                guard let root = try index.entry(id: stored[position].roots[offset]) else { throw MacEvenError(localized("缓存索引已失效。")) }
                if let reason = service.reasonBlocked(root.url) { throw MacEvenError(reason) }
                stored[position].roots[offset] = try index.rescanAfterApplicationQuit(id: root.id, token: token)
            }
            guard !isRunning(app.id) else { throw MacEvenError(localized("应用重新启动，缓存已保留。")) }
        } catch { stored[position].issue = error.localizedDescription; throw error }
    }

    public func move(groupIDs: [String], isRunning: (String) -> Bool) -> [TrashResult] {
        guard Set(groupIDs).count <= 50 else { return [TrashResult(id: 0, path: "", destination: nil, error: localized("一次最多选择 50 个应用。")) ] }
        var results: [TrashResult] = []
        for id in Set(groupIDs).sorted() {
            do {
                guard !indexInvalid, let group = stored.first(where: { $0.id == id }), let app = group.app, group.issue == nil, !group.roots.isEmpty else { throw MacEvenError(localized("该缓存不可清理或索引已失效，请重新扫描。")) }
                guard !isRunning(app.id) else { throw MacEvenError(localized("应用正在运行，请退出后重新检查。")) }
                let service = TrashService(index: index, home: home, cacheApplications: [app], protection: protection)
                // Validate the whole group before the first mutation; then recheck each root.
                for rootID in group.roots {
                    guard let root = try index.entry(id: rootID) else { throw MacEvenError(localized("缓存已变化，请重新扫描。")) }
                    if let reason = service.reasonBlocked(root.url) { throw MacEvenError(reason) }
                    try index.validateSubtree(id: rootID)
                }
                for rootID in group.roots {
                    guard let root = try index.entry(id: rootID) else { continue }
                    if isRunning(app.id) { results.append(TrashResult(id: rootID, path: root.url.path, destination: nil, error: localized("应用重新启动，缓存已保留。"))); continue }
                    try index.validateSubtree(id: rootID)
                    if isRunning(app.id) { results.append(TrashResult(id: rootID, path: root.url.path, destination: nil, error: localized("应用重新启动，缓存已保留。"))); continue }
                    let moved = service.move(ids: [rootID]); results.append(contentsOf: moved)
                    if moved.contains(where: { $0.destination != nil && $0.error != nil }) { indexInvalid = true; break }
                }
            } catch { results.append(TrashResult(id: 0, path: id, destination: nil, error: error.localizedDescription)) }
        }
        return results
    }
}
