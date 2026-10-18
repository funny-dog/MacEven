import Foundation
import Darwin
import CryptoKit
import CoreServices

public struct DuplicateGroup: Sendable, Identifiable {
    public let id: String
    public let memberCount: Int
    public let logicalSize: Int64
    public let allocatedSize: Int64

    public init(id: String, memberCount: Int, logicalSize: Int64, allocatedSize: Int64) {
        self.id = id
        self.memberCount = memberCount
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
    }
}

public struct DuplicateSummary: Sendable {
    /// 遍历检查过的条目数（含门槛过滤与共享块过滤的文件）。
    public let visited: Int64
    /// 得到最终摘要的文件数。
    public let hashed: Int64
    public let readBytes: Int64
    /// 哈希阶段跳过的云文件、数据不在本地等文件。
    public let skipped: Int64
    /// 访问错误与扫描期间变化的文件；只计数展示，不使结果不可清理。
    public let errors: Int64
    public let errorExamples: [String]
    public let elapsed: TimeInterval
    public let cancelled: Bool
    /// 取消、扫描入口失效或索引故障；此时禁止清理。
    public let incomplete: Bool
    /// 只做了抽样哈希的文件数。
    public let sampled: Int64
    public let filteredSmall: Int64
    public let filteredShared: Int64
    public let cached: Int64
    public let incremental: Bool

    public init(visited: Int64, hashed: Int64, readBytes: Int64, skipped: Int64, errors: Int64,
                errorExamples: [String], elapsed: TimeInterval, cancelled: Bool, incomplete: Bool,
                sampled: Int64 = 0, filteredSmall: Int64 = 0, filteredShared: Int64 = 0,
                cached: Int64 = 0, incremental: Bool = false) {
        self.visited = visited
        self.hashed = hashed
        self.readBytes = readBytes
        self.skipped = skipped
        self.errors = errors
        self.errorExamples = errorExamples
        self.elapsed = elapsed
        self.cancelled = cancelled
        self.incomplete = incomplete
        self.sampled = sampled
        self.filteredSmall = filteredSmall
        self.filteredShared = filteredShared
        self.cached = cached
        self.incremental = incremental
    }
}

public struct DuplicateProgress: Sendable {
    /// scanning → sampling → hashing
    public let phase: String
    public let visited: Int64
    public let hashed: Int64
    public let readBytes: Int64
    public let currentPath: String
    public let elapsed: TimeInterval
    /// 本阶段已完成量与总量：抽样阶段为候选数，完整哈希阶段为字节数；遍历阶段为 nil。
    public let phaseDone: Int64?
    public let phaseTotal: Int64?

    public init(phase: String, visited: Int64, hashed: Int64, readBytes: Int64, currentPath: String, elapsed: TimeInterval,
                phaseDone: Int64? = nil, phaseTotal: Int64? = nil) {
        self.phaseDone = phaseDone
        self.phaseTotal = phaseTotal
        self.phase = phase
        self.visited = visited
        self.hashed = hashed
        self.readBytes = readBytes
        self.currentPath = currentPath
        self.elapsed = elapsed
    }
}

/// 扫描中途的候选统计：按（大小, 摘要或抽样）聚类且成员 ≥2 的候选组数、文件数与占用估算。
/// 在物化候选后与抽样剪枝后各上报一次，供界面在扫描过程中实时展示。
public struct DuplicateCandidateStats: Sendable {
    public let groups: Int64
    public let files: Int64
    public let bytes: Int64

    public init(groups: Int64, files: Int64, bytes: Int64) {
        self.groups = groups
        self.files = files
        self.bytes = bytes
    }
}

/// 可扫描的磁盘。启动盘的扫描根是主目录（排除 Library），其他卷是挂载点。
public struct DuplicateVolume: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let mountURL: URL
    public let isStartup: Bool

    public init(name: String, mountURL: URL, isStartup: Bool) {
        self.id = mountURL.path
        self.name = name
        self.mountURL = mountURL
        self.isStartup = isStartup
    }
}

public enum DuplicateScope: Sendable, Equatable {
    case folder(URL)
    case volumes([DuplicateVolume])
}

public final class DuplicateFiles {
    /// 界面默认门槛与可选门槛（十进制字节，与 ByteCountFormatter 一致）。
    public static let defaultMinimumSize: Int64 = 1_000_000
    public static let minimumSizeOptions: [Int64] = [1, 100_000, 1_000_000, 10_000_000, 100_000_000]
    /// 抽样哈希：开头、中间、结尾各读一块；不超过三块的文件直接整读得到最终摘要。
    static let sampleChunk = 16 * 1024

    private struct ScanRoot {
        let url: URL
        let excluded: [String]
    }

    private let index: DiskIndex
    private let home: URL
    public private(set) var isValid: Bool = false
    private let protection: ProtectionStore
    private var volumeRoots: [TrashService.VolumeRoot] = []

    public init(index: DiskIndex, home: URL, protection: ProtectionStore = .shared) {
        self.index = index
        self.home = (try? canonicalFileURL(home)) ?? home.standardizedFileURL
        self.protection = protection
    }

    /// 本地、可写、非系统的已挂载卷；启动盘排在第一位，扫描主目录。
    public static func availableVolumes(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DuplicateVolume] {
        let home = (try? canonicalFileURL(home)) ?? home.standardizedFileURL
        let homeDevice = (try? FileIdentity.read(home))?.device
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        func name(_ url: URL) -> String {
            (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
        }
        var result = [startupVolume(home: home)]
        for url in urls where url.path != "/" {
            guard let root = try? volumeRoot(at: url), root.device != homeDevice else { continue }
            result.append(DuplicateVolume(name: name(url), mountURL: root.url, isStartup: false))
        }
        return result
    }

    /// 启动盘卷描述：重复文件的固定扫描范围（个人文件夹，不含资源库）。
    public static func startupVolume(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DuplicateVolume {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        let name = urls.first { $0.path == "/" }
            .flatMap { try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName } ?? localized("启动磁盘")
        return DuplicateVolume(name: name, mountURL: URL(fileURLWithPath: "/"), isStartup: true)
    }

    /// 外接卷根：必须是本地、可写、非系统卷的挂载点本身，且不是符号链接。
    static func volumeRoot(at url: URL) throws -> TrashService.VolumeRoot {
        let path = url.path
        guard path != "/", !path.hasPrefix("/System/"), !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw MacEvenError(localized("系统卷不可作为扫描磁盘。"))
        }
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw MacEvenError(localized("无法读取磁盘信息：\(path)")) }
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard mountPoint == path else { throw MacEvenError(localized("扫描磁盘必须是卷的挂载点：\(path)")) }
        guard info.f_flags & UInt32(MNT_LOCAL) != 0 else { throw MacEvenError(localized("仅支持本地磁盘：\(path)")) }
        guard info.f_flags & UInt32(MNT_RDONLY) == 0 else { throw MacEvenError(localized("只读磁盘无法移到废纸篓：\(path)")) }
        let identity = try FileIdentity.read(url)
        guard identity.isDirectory, !identity.isSymlink else { throw MacEvenError(localized("磁盘挂载点无效：\(path)")) }
        return TrashService.VolumeRoot(url: url, device: identity.device, inode: identity.inode)
    }

    private static func safeOpenReadOnly(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return openat(AT_FDCWD, path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)
        }
    }

    private static func identity(_ info: stat) -> FileIdentity {
        FileIdentity(device: Int64(info.st_dev), inode: Int64(bitPattern: UInt64(info.st_ino)),
            mode: Int64(info.st_mode), size: info.st_size,
            modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
            allocated: Int64(info.st_blocks) * 512)
    }

    private func trashService() -> TrashService {
        TrashService(index: index, home: home, developerAllowedRoots: [], protection: protection, volumeRoots: volumeRoots)
    }

    // 用户保护只约束删除目标：扫描候选与保留项不受影响，保护的文件仍可作为保留项。
    private func validateEntry(_ entry: DiskEntry, applyingUserProtection: Bool = false) throws {
        if let reason = trashService().reasonBlocked(entry.url, applyingUserProtection: applyingUserProtection) { throw MacEvenError(reason) }
        guard try FileIdentity.read(entry.url) == entry.identity else { throw MacEvenError(localized("文件已变化：\(entry.url.path)")) }
        for ancestor in try index.ancestors(of: entry.id).dropLast() {
            let actual = try FileIdentity.read(ancestor.url)
            guard actual.isDirectory && actual.device == ancestor.identity.device && actual.inode == ancestor.identity.inode else {
                throw MacEvenError(localized("祖先目录已被替换：\(entry.url.path)"))
            }
        }
        var info = stat()
        guard entry.url.withUnsafeFileSystemRepresentation({ lstat($0, &info) }) == 0,
            Self.identity(info) == entry.identity, info.st_nlink == 1, (info.st_flags & UInt32(SF_DATALESS)) == 0,
            try !autoreleasepool(invoking: { try entry.url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem ?? false }) else {
            throw MacEvenError(localized("文件状态已变化或为云文件：\(entry.url.path)"))
        }
    }

    private static func validDescriptor(_ fd: Int32, entry: DiskEntry) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && identity(info) == entry.identity && entry.identity.isRegular &&
            info.st_nlink == 1 && (info.st_flags & UInt32(SF_DATALESS)) == 0
    }

    /// 主目录内的普通子目录（首版规则），或可用外接卷内的普通子目录。
    private func validateRoot(_ root: URL) throws {
        let path = root.path
        if root.pathComponents.contains("..") || root.pathComponents.contains(".") {
            throw MacEvenError(localized("路径包含非法相对组件。"))
        }
        guard path.hasPrefix(home.path + "/") else {
            try validateVolumeFolder(root)
            return
        }
        let parts = path.dropFirst(home.path.count + 1).split(separator: "/")
        guard !parts.isEmpty else {
            throw MacEvenError(localized("不能扫描主目录本身。"))
        }
        guard parts.first != "Library" else {
            throw MacEvenError(localized("Library 目录受保护，不可扫描。"))
        }
        guard !parts.contains(where: { $0.hasPrefix(".") }) else {
            throw MacEvenError(localized("隐藏路径受保护，不可扫描。"))
        }

        let homeIdentity = try FileIdentity.read(home)
        guard homeIdentity.isDirectory && !homeIdentity.isSymlink else {
            throw MacEvenError(localized("主目录无效或已被替换。"))
        }
        try validateComponents(parts, base: home, device: homeIdentity.device)
        if path == index.url.path || path.hasPrefix(index.url.path + "/") || index.url.path.hasPrefix(path + "/") {
            throw MacEvenError(localized("MacEven 索引路径受保护，不可扫描。"))
        }
    }

    private func validateVolumeFolder(_ root: URL) throws {
        var info = statfs()
        guard statfs(root.path, &info) == 0 else {
            throw MacEvenError(localized("只允许扫描主目录或本地外接磁盘内的普通目录。"))
        }
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard root.path.hasPrefix(mountPoint + "/"), let volume = try? Self.volumeRoot(at: URL(fileURLWithPath: mountPoint, isDirectory: true)),
              volume.device != (try FileIdentity.read(home)).device else {
            throw MacEvenError(localized("只允许扫描主目录或本地外接磁盘内的普通目录。"))
        }
        let parts = root.path.dropFirst(mountPoint.count + 1).split(separator: "/")
        guard !parts.contains(where: { $0.hasPrefix(".") }) else {
            throw MacEvenError(localized("隐藏路径受保护，不可扫描。"))
        }
        try validateComponents(parts, base: volume.url, device: volume.device)
        volumeRoots = [volume]
    }

    /// 逐级 lstat：无符号链接、同一设备、不在软件包内，最后一级是普通目录。
    private func validateComponents(_ parts: [Substring], base: URL, device: Int64) throws {
        var current = base
        for (offset, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            let info = try FileIdentity.read(current)
            if info.isSymlink {
                throw MacEvenError(localized("符号链接或经过符号链接的路径不可作为扫描入口。"))
            }
            if info.device != device {
                throw MacEvenError(localized("其他挂载卷不可作为扫描入口。"))
            }
            if (try? current.resourceValues(forKeys: [.isPackageKey]).isPackage) == true ||
                ["app", "bundle"].contains(current.pathExtension.lowercased()) {
                throw MacEvenError(offset == parts.count - 1 ? localized("扫描目标不能是软件包。") : localized("扫描路径不能位于软件包内。"))
            }
            guard info.isDirectory else {
                throw MacEvenError(offset == parts.count - 1 ? localized("扫描目标必须是普通目录。") : localized("祖先路径非目录。"))
            }
        }
    }

    /// 解析扫描范围；单个磁盘失效时记为错误并跳过，全部失效才抛错。
    private func resolve(_ scope: DuplicateScope, skipped: (String) -> Void) throws -> [ScanRoot] {
        volumeRoots = []
        switch scope {
        case .folder(let url):
            try validateRoot(url)
            return [ScanRoot(url: url, excluded: [])]
        case .volumes(let volumes):
            guard !volumes.isEmpty else { throw MacEvenError(localized("请选择要扫描的磁盘。")) }
            var roots: [ScanRoot] = []
            var lastError: Error?
            for volume in volumes {
                do {
                    if volume.isStartup {
                        let identity = try FileIdentity.read(home)
                        guard identity.isDirectory && !identity.isSymlink else { throw MacEvenError(localized("主目录无效或已被替换。")) }
                        roots.append(ScanRoot(url: home, excluded: [home.appendingPathComponent("Library").path]))
                    } else {
                        let root = try Self.volumeRoot(at: volume.mountURL)
                        guard root.device != (try FileIdentity.read(home)).device else { throw MacEvenError(localized("主目录所在磁盘请使用启动磁盘。")) }
                        volumeRoots.append(root)
                        roots.append(ScanRoot(url: root.url, excluded: []))
                    }
                } catch {
                    lastError = error
                    skipped(localized("磁盘「\(volume.name)」已跳过：\(error.localizedDescription)"))
                }
            }
            if roots.isEmpty { throw lastError ?? MacEvenError(localized("没有可扫描的磁盘。")) }
            var seen = Set<String>()
            return roots.filter { seen.insert($0.url.path).inserted }
        }
    }

    private func relevantEvent(_ event: DuplicateEvents.Event, roots: [ScanRoot]) -> Bool {
        if DuplicateEvents.needsFullScan([event]) { return true }
        guard let root = roots.first(where: { event.path == $0.url.path || event.path.hasPrefix($0.url.path + "/") }) else { return false }
        let parts = event.path.dropFirst(root.url.path.count).split(separator: "/")
        return !parts.contains(where: { $0.hasPrefix(".") }) &&
            !root.excluded.contains(where: { event.path == $0 || event.path.hasPrefix($0 + "/") })
    }

    private func incrementalDirectories(events: [DuplicateEvents.Event], roots: [ScanRoot], changed: [String]) throws -> [String] {
        var paths = Set(changed)
        for event in events where relevantEvent(event, roots: roots) {
            guard let root = roots.first(where: { event.path == $0.url.path || event.path.hasPrefix($0.url.path + "/") }) else { continue }
            if event.path == root.url.path { paths.insert(root.url.path); continue }
            let isDirectory = event.flags & UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs) != 0
            let structural = event.flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
            var url = URL(fileURLWithPath: event.path)
            if url.path == root.url.path { paths.insert(root.url.path); continue }
            if !isDirectory || structural { url.deleteLastPathComponent() }
            while url.path != root.url.path {
                guard url.path.hasPrefix(root.url.path + "/") else { url = root.url; break }
                if let entry = try index.duplicateNode(at: url.path), entry.identity.isDirectory { break }
                url.deleteLastPathComponent()
            }
            paths.insert(url.path)
        }
        var result: [String] = []
        for path in paths.sorted(by: { ($0.count,$0) < ($1.count,$1) }) {
            if !result.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { result.append(path) }
        }
        return result
    }

    public func scan(root: URL, minimumSize: Int64 = 1, token: CancellationToken,
                     progress: @Sendable (DuplicateProgress) -> Void = { _ in },
                     statistics: @Sendable (DuplicateCandidateStats) -> Void = { _ in }) throws -> DuplicateSummary {
        try scan(scope: .folder(root), minimumSize: minimumSize, token: token, progress: progress, statistics: statistics)
    }

    public func scan(scope: DuplicateScope, minimumSize: Int64 = 1, token: CancellationToken,
                     progress: @Sendable (DuplicateProgress) -> Void = { _ in },
                     statistics: @Sendable (DuplicateCandidateStats) -> Void = { _ in }) throws -> DuplicateSummary {
        self.isValid = false

        let startTime = Date()
        var visitedCount: Int64 = 0
        var sampledCount: Int64 = 0
        var hashedCount: Int64 = 0
        var readBytesTotal: Int64 = 0
        var skippedCount: Int64 = 0
        var errorsCount: Int64 = 0
        var filteredSmall: Int64 = 0
        var filteredShared: Int64 = 0
        var cachedCount: Int64 = 0
        var incremental = false
        var errorExamplesList: [String] = []
        var isCancelled = false
        var isFailed = false

        // 单个文件或目录的问题：计数并展示，不影响其余结果的清理。
        func addError(_ msg: String) {
            errorsCount += 1
            if errorExamplesList.count < 100 {
                errorExamplesList.append(String(msg.prefix(1000)))
            }
        }
        // 扫描入口失效或索引故障：结果不可用于清理。
        func fail(_ msg: String) {
            isFailed = true
            addError(msg)
        }
        func removeCandidate(_ id: Int64) {
            do { try index.removeDuplicateCandidate(id: id) }
            catch { fail(localized("候选索引维护失败：\(error.localizedDescription)")) }
        }
        func summary() -> DuplicateSummary {
            if token.isCancelled { isCancelled = true }
            return DuplicateSummary(visited: visitedCount, hashed: hashedCount, readBytes: readBytesTotal,
                                    skipped: skippedCount, errors: errorsCount, errorExamples: errorExamplesList,
                                    elapsed: Date().timeIntervalSince(startTime), cancelled: isCancelled,
                                    incomplete: isCancelled || isFailed, sampled: sampledCount,
                                    filteredSmall: filteredSmall, filteredShared: filteredShared, cached: cachedCount, incremental: incremental)
        }
        // 阶段进度：抽样按候选数，完整哈希按字节（已完成文件的大小 + 当前文件已读字节）。
        var sampleDone: Int64 = 0, sampleTotal: Int64 = 0
        var hashCompleted: Int64 = 0, hashTotal: Int64 = 0, fileStartRead: Int64 = 0
        func report(_ phase: String, _ path: String) {
            let done: Int64?, total: Int64?
            switch phase {
            case "sampling": done = sampleDone; total = sampleTotal
            case "hashing": done = min(hashTotal, hashCompleted + max(0, readBytesTotal - fileStartRead)); total = hashTotal
            default: done = nil; total = nil
            }
            progress(DuplicateProgress(phase: phase, visited: visitedCount,
                                       hashed: phase == "hashing" ? hashedCount : hashedCount + sampledCount,
                                       readBytes: readBytesTotal, currentPath: String(path.prefix(1000)),
                                       elapsed: Date().timeIntervalSince(startTime), phaseDone: done, phaseTotal: total))
        }

        let roots = try resolve(scope, skipped: addError)
        try index.prepareDuplicateCache()
        let baseline = try index.duplicateBaseline()
        try index.invalidateDuplicateBaseline()

        if token.isCancelled {
            isCancelled = true
            return summary()
        }

        var signature: String?
        var watchers: [DuplicateEvents] = []
        var scanRoots = roots
        var fullScanTime = startTime
        do {
            let key: [[String]] = try roots.map { root in
                let i = try FileIdentity.read(root.url)
                let volume = try root.url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString ?? ""
                return [root.url.path, volume, try DuplicateEvents.logIdentity(root: root.url),
                    String(i.device), String(i.inode), String(i.mode)] + root.excluded.sorted()
            }
            signature = String(decoding: try JSONEncoder().encode(["format-1", String(max(1,minimumSize))] + key.flatMap { $0 }), as: UTF8.self)
            let usable = baseline?.signature == signature && baseline!.fullScanTime > startTime.addingTimeInterval(-86400) &&
                roots.allSatisfy { baseline!.cursors[$0.url.path].map { $0 <= FSEventsGetCurrentEventId() } ?? false }
            var events: [DuplicateEvents.Event] = []
            for root in roots {
                let since = usable ? baseline!.cursors[root.url.path] : nil
                let watcher = try DuplicateEvents(root: root.url, since: since ?? FSEventsGetCurrentEventId())
                watchers.append(watcher)
                events += try watcher.collect(history: true, token: token)
            }
            if usable && !DuplicateEvents.needsFullScan(events) {
                let directories = try incrementalDirectories(events: events, roots: roots,
                    changed: index.duplicateDirectoryChanges(token: token))
                if !directories.contains(where: { path in roots.contains { $0.url.path == path } }) {
                    scanRoots = directories.map { path in ScanRoot(url: URL(fileURLWithPath: path), excluded: roots.flatMap(\.excluded)) }
                    incremental = true
                    fullScanTime = baseline!.fullScanTime
                }
            }
        } catch {
            // 事件日志/历史/权限检查不可靠时，全扫仍可继续；不能建立可复用基线。
            signature = nil
            watchers.forEach { $0.stop() }; watchers = []
        }
        defer { watchers.forEach { $0.stop() } }
        report(incremental ? "incremental" : "scanning", roots[0].url.path)

        // Phase 1: 批量遍历，小文件与共享块文件只计数
        for (offset, root) in scanRoots.enumerated() {
            let base = visitedCount, traversal = incremental ? "incremental" : "scanning"
            let scanSummary: ScanSummary
            let deltaURL = index.url.deletingLastPathComponent().appendingPathComponent(".duplicate-delta-\(UUID()).sqlite")
            let delta = incremental ? try DiskIndex(url: deltaURL) : nil
            defer { delta?.close(); if delta != nil { try? FileManager.default.removeItem(at: deltaURL) } }
            do {
                scanSummary = try Scanner.scan(root: root.url, index: delta ?? index, token: token,
                                               minimumFileSize: max(1, minimumSize), excludedPaths: root.excluded,
                                               resetIndex: incremental || offset == 0, requireCompleteTraversal: true,
                                               ordinaryFilesOnly: true) { sp in
                    progress(DuplicateProgress(phase: traversal, visited: base + Int64(sp.visited),
                                               hashed: 0, readBytes: 0, currentPath: sp.currentPath,
                                               elapsed: Date().timeIntervalSince(startTime)))
                }
            } catch {
                if incremental && !token.isCancelled { return try scan(scope: scope, minimumSize: minimumSize, token: token, progress: progress) }
                fail(localized("扫描失败：\(error.localizedDescription)"))
                return summary()
            }
            if incremental {
                guard !scanSummary.cancelled, scanSummary.errors == 0,
                      let old = try index.duplicateNode(at: root.url.path), let delta else {
                    if token.isCancelled { return summary() }
                    return try scan(scope: scope, minimumSize: minimumSize, token: token, progress: progress)
                }
                do { try index.replaceDuplicateSubtree(old: old, delta: delta, token: token) }
                catch { if token.isCancelled { return summary() }; fail(error.localizedDescription); return summary() }
            }
            visitedCount += Int64(scanSummary.visited + scanSummary.filteredSmall + scanSummary.filteredShared)
            filteredSmall += Int64(scanSummary.filteredSmall)
            filteredShared += Int64(scanSummary.filteredShared)
            errorsCount += Int64(scanSummary.errors)
            let remaining = 100 - errorExamplesList.count
            if remaining > 0 {
                errorExamplesList.append(contentsOf: scanSummary.errorExamples.prefix(remaining))
            }
            if scanSummary.cancelled || token.isCancelled {
                isCancelled = true
                return summary()
            }
        }

        // Phase 2: 物化重复候选（大小相同、数量 ≥ 2）
        do {
            try index.prepareDuplicateCandidates(token: token)
        } catch {
            if token.isCancelled { isCancelled = true } else { fail(localized("物化候选失败：\(error.localizedDescription)")) }
            return summary()
        }
        if token.isCancelled {
            isCancelled = true
            return summary()
        }
        // 遍历一结束即统计候选：界面在抽样与完整哈希进行期间就能展示组数与占用估算。
        do {
            let stats = try index.duplicateCandidateStats()
            statistics(DuplicateCandidateStats(groups: stats.groups, files: stats.files, bytes: stats.bytes))
        } catch {
            if token.isCancelled { isCancelled = true } else { fail(localized("统计候选失败：\(error.localizedDescription)")) }
            return summary()
        }
        if token.isCancelled {
            isCancelled = true
            return summary()
        }

        do { sampleTotal = try index.duplicateSampleCount() }
        catch { fail(localized("查询候选数量失败：\(error.localizedDescription)")); return summary() }
        report("sampling", roots[0].url.path)

        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        let chunk = Self.sampleChunk

        /// 完整校验后流式计算 SHA-256；失败时移除候选并记录原因。
        func fullDigest(_ entry: DiskEntry, phase: String) -> Data? {
            // 打开前复核
            var preStat = stat()
            guard entry.url.withUnsafeFileSystemRepresentation({ lstat($0, &preStat) }) == 0 else {
                addError(localized("打开前状态获取失败：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }
            guard Self.identity(preStat) == entry.identity else {
                addError(localized("文件在扫描后改变：\(entry.url.path)")); removeCandidate(entry.id); return nil
            }
            do {
                if try autoreleasepool(invoking: { try entry.url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem ?? false }) {
                    skippedCount += 1; removeCandidate(entry.id); return nil
                }
            } catch { addError(error.localizedDescription); removeCandidate(entry.id); return nil }

            // 硬链接、数据不在本地、非普通或空文件跳过
            guard preStat.st_nlink <= 1, (preStat.st_flags & UInt32(SF_DATALESS)) == 0,
                  (preStat.st_mode & S_IFMT) == S_IFREG, preStat.st_size > 0 else {
                skippedCount += 1
                removeCandidate(entry.id)
                return nil
            }

            // 祖先目录身份校验
            var ancestorsOk = true
            if let ancestors = try? index.ancestors(of: entry.id).dropLast() {
                for ancestor in ancestors {
                    guard let actual = try? FileIdentity.read(ancestor.url),
                          actual.isDirectory,
                          actual.device == ancestor.identity.device,
                          actual.inode == ancestor.identity.inode else {
                        ancestorsOk = false
                        break
                    }
                }
            } else {
                ancestorsOk = false
            }
            guard ancestorsOk else {
                addError(localized("祖先目录已被替换：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }

            // O_NOFOLLOW_ANY 打开并校验描述符
            let fd = Self.safeOpenReadOnly(entry.url)
            guard fd >= 0 else {
                addError(localized("无法安全打开文件：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }
            guard Self.validDescriptor(fd, entry: entry) else {
                close(fd)
                addError(localized("打开文件描述符与快照不一致：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }

            // 1 MiB 流式哈希
            var hasher = SHA256()
            var fileRead: Int64 = 0
            var readFailed = false
            while fileRead < entry.logicalSize {
                if token.isCancelled {
                    isCancelled = true
                    readFailed = true
                    break
                }
                let toRead = min(Int(entry.logicalSize - fileRead), bufferSize)
                let n = read(fd, buffer, toRead)
                if n > 0 {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
                    fileRead += Int64(n)
                    readBytesTotal += Int64(n)
                    report(phase, entry.url.path)
                } else {
                    readFailed = true
                    break
                }
            }
            if !Self.validDescriptor(fd, entry: entry) { readFailed = true }
            close(fd)
            if isCancelled { return nil }
            if readFailed {
                addError(localized("流式读取未完成：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }

            // 哈希后复核路径指向、身份与标志
            guard let postIdentity = try? FileIdentity.read(entry.url), postIdentity == entry.identity else {
                addError(localized("哈希后文件身份改变：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }
            do { try validateEntry(entry) }
            catch { addError(error.localizedDescription); removeCandidate(entry.id); return nil }
            return Data(hasher.finalize())
        }

        /// 抽样哈希只用于排除候选：确认描述符与快照一致后读开头、中间、结尾三块。
        func sampleDigest(_ entry: DiskEntry) -> Data? {
            let fd = Self.safeOpenReadOnly(entry.url)
            guard fd >= 0 else {
                addError(localized("无法安全打开文件：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }
            defer { close(fd) }
            var info = stat()
            if fstat(fd, &info) == 0, (info.st_flags & UInt32(SF_DATALESS)) != 0 {
                skippedCount += 1
                removeCandidate(entry.id)
                return nil
            }
            guard Self.validDescriptor(fd, entry: entry) else {
                addError(localized("打开文件描述符与快照不一致：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }
            var hasher = SHA256()
            let size = entry.logicalSize, block = Int64(chunk)
            for position in [0, (size - block) / 2, size - block] {
                var count = 0
                while count < chunk {
                    let n = pread(fd, buffer + count, chunk - count, off_t(position) + off_t(count))
                    if n <= 0 { break }
                    count += n
                }
                guard count == chunk else {
                    addError(localized("抽样读取未完成：\(entry.url.path)"))
                    removeCandidate(entry.id)
                    return nil
                }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
                readBytesTotal += Int64(count)
            }
            guard Self.validDescriptor(fd, entry: entry) else {
                addError(localized("抽样期间文件变化：\(entry.url.path)"))
                removeCandidate(entry.id)
                return nil
            }
            report("sampling", entry.url.path)
            return Data(hasher.finalize())
        }

        // Phase 3: 抽样哈希；小文件整读直接得到最终摘要
        var cursorID: Int64 = 0
        var samples: [(id: Int64, sample: Data, digest: Data?)] = []
        func flushSamples() {
            do { try index.storeDuplicateSamples(batch: samples) }
            catch { fail(localized("存储抽样批次失败：\(error.localizedDescription)")) }
            samples.removeAll(keepingCapacity: true)
        }
        sampling: while !isFailed {
            if token.isCancelled { isCancelled = true; break }
            let page: [DiskEntry]
            do {
                page = try index.duplicateCandidatePage(afterID: cursorID, limit: 100, needingSample: true)
            } catch {
                fail(localized("查询候选分页失败：\(error.localizedDescription)"))
                break
            }
            if page.isEmpty { break }
            cursorID = page.last!.id
            for entry in page {
                if token.isCancelled { isCancelled = true; break sampling }
                sampleDone += 1
                let small = entry.logicalSize <= Int64(3 * chunk)
                do {
                    if let cached = try index.cachedDuplicateHash(entry), !small || cached.digest != nil {
                        try autoreleasepool { try validateEntry(entry) }
                        if BulkDirectoryWalker.sharesBlocks(path: entry.url.path, allocated: entry.identity.allocated) == true {
                            filteredShared += 1; removeCandidate(entry.id); continue
                        }
                        let fd = Self.safeOpenReadOnly(entry.url)
                        guard fd >= 0 else { throw MacEvenError(localized("无法安全打开缓存候选：\(entry.url.path)")) }
                        let valid = Self.validDescriptor(fd, entry: entry)
                        close(fd)
                        guard valid else { throw MacEvenError(localized("缓存候选状态已变化：\(entry.url.path)")) }
                        samples.append((entry.id, cached.sample, cached.digest))
                        cachedCount += 1
                        if cached.digest != nil { hashedCount += 1 } else { sampledCount += 1 }
                        if samples.count >= 500 { flushSamples() }
                        report("sampling", entry.url.path)
                        continue
                    }
                } catch {
                    addError(error.localizedDescription); removeCandidate(entry.id); continue
                }
                let value = autoreleasepool { small ? fullDigest(entry, phase: "sampling") : sampleDigest(entry) }
                guard let value else {
                    if isCancelled || isFailed { break sampling }
                    continue
                }
                samples.append((id: entry.id, sample: value, digest: small ? value : nil))
                if small { hashedCount += 1 } else { sampledCount += 1 }
                if samples.count >= 500 { flushSamples() }
            }
        }
        if !samples.isEmpty && !isFailed { flushSamples() }
        if isCancelled || isFailed || token.isCancelled { return summary() }
        // 最后几个候选可能走跳过分支而没有上报，阶段结束时补报一次。
        report("sampling", roots[0].url.path)

        do {
            try index.cacheDuplicateHashes()
            try index.pruneDuplicateSamples(token: token)
            // 剪枝排除了不可能的候选，刷新一次统计再进入完整哈希。
            let stats = try index.duplicateCandidateStats()
            statistics(DuplicateCandidateStats(groups: stats.groups, files: stats.files, bytes: stats.bytes))
            hashTotal = try index.duplicatePendingBytes()
            fileStartRead = readBytesTotal
            report("hashing", roots[0].url.path)
        } catch {
            if token.isCancelled { isCancelled = true } else { fail(localized("抽样剪枝失败：\(error.localizedDescription)")) }
            return summary()
        }

        // Phase 4: 剩余候选流式完整哈希
        cursorID = 0
        var batch: [(id: Int64, digest: Data)] = []
        func flushDigests() {
            do { try index.storeDuplicateDigests(batch: batch) }
            catch { fail(localized("存储摘要批次失败：\(error.localizedDescription)")) }
            batch.removeAll(keepingCapacity: true)
        }
        hashing: while !isFailed {
            if token.isCancelled { isCancelled = true; break }
            let page: [DiskEntry]
            do {
                page = try index.duplicateCandidatePage(afterID: cursorID, limit: 100)
            } catch {
                fail(localized("查询候选分页失败：\(error.localizedDescription)"))
                break
            }
            if page.isEmpty { break }
            cursorID = page.last!.id
            for entry in page {
                if token.isCancelled { isCancelled = true; break hashing }
                fileStartRead = readBytesTotal
                let digest = autoreleasepool(invoking: { fullDigest(entry, phase: "hashing") })
                hashCompleted += entry.logicalSize; fileStartRead = readBytesTotal
                guard let digest else {
                    if isCancelled || isFailed { break hashing }
                    report("hashing", entry.url.path)
                    continue
                }
                batch.append((id: entry.id, digest: digest))
                hashedCount += 1
                sampledCount -= 1
                if batch.count >= 500 { flushDigests() }
                report("hashing", entry.url.path)
            }
        }
        if !batch.isEmpty && !isFailed { flushDigests() }

        if !isCancelled && !isFailed && !token.isCancelled {
            do {
                try index.cacheDuplicateHashes()
                if errorsCount == 0, let signature, !watchers.isEmpty {
                    var during: [DuplicateEvents.Event] = []
                    // 只保存已处理的游标。新事件意味着本轮快照不稳定，下次全扫。
                    let cursors = Dictionary(uniqueKeysWithValues: watchers.map { ($0.root.path,$0.cursor) })
                    for watcher in watchers { during += try watcher.collect(history: false, token: token) }
                    if !during.contains(where: { relevantEvent($0, roots: roots) }) {
                        try index.storeDuplicateBaseline(DuplicateBaseline(signature: signature, cursors: cursors,
                            fullScanTime: fullScanTime))
                    }
                }
            } catch {
                // 基线保存失败不会改变本轮已验证的结果；下次完整遍历。
                try? index.invalidateDuplicateBaseline()
            }
        }
        let result = summary()
        self.isValid = !result.incomplete
        return result
    }

    public func groups(offset: Int = 0, limit: Int = 100, token: CancellationToken? = nil) throws -> [DuplicateGroup] {
        try index.duplicateGroups(offset: offset, limit: limit, token: token)
    }

    public func members(groupID: String, offset: Int = 0, limit: Int = 100, token: CancellationToken? = nil) throws -> [DiskEntry] {
        try index.duplicateMembers(groupID: groupID, offset: offset, limit: limit, token: token)
    }

    public func move(groupID: String, keeperID: Int64, ids: [Int64], token: CancellationToken) -> [TrashResult] {
        guard self.isValid else {
            return ids.isEmpty ? [TrashResult(id: 0, path: "", destination: nil, error: localized("会话已失效或扫描不完整，禁止清理。"))] :
                ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("会话已失效或扫描不完整，禁止清理。")) }
        }

        guard !ids.isEmpty else {
            return [TrashResult(id: 0, path: "", destination: nil, error: localized("清理目标不能为空。"))]
        }

        let targetSet = Set(ids)
        guard ids.count <= 50, targetSet.count == ids.count else {
            return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("清理目标必须为 1 到 50 个不重复条目。")) }
        }

        guard !targetSet.contains(keeperID) else {
            return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("保留项不可包含在清理目标中。")) }
        }

        guard let keeper = try? index.duplicateGroupMember(nodeID: keeperID, groupID: groupID) else {
            return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("保留项不存在或不属于指定组。")) }
        }

        var targets: [DiskEntry] = []
        for tid in ids {
            guard let target = try? index.duplicateGroupMember(nodeID: tid, groupID: groupID) else {
                return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("清理目标不存在或不属于指定组：ID \(tid)")) }
            }
            guard target.identity.isRegular else {
                return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("清理目标非普通文件。")) }
            }
            targets.append(target)
        }

        if token.isCancelled {
            return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("操作已被取消。")) }
        }

        // 全体预查
        let trashService = trashService()
        do {
            try validateEntry(keeper)
            for target in targets { try validateEntry(target, applyingUserProtection: true) }
        } catch { return ids.map { TrashResult(id: $0, path: "", destination: nil, error: error.localizedDescription) } }
        if let reason = trashService.reasonBlocked(keeper.url, applyingUserProtection: false) {
            return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("保留项受保护不可操作：\(reason)")) }
        }
        guard let freshKeeper = try? FileIdentity.read(keeper.url), freshKeeper == keeper.identity else {
            return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("保留项已被修改或不存在。")) }
        }

        for target in targets {
            if let reason = trashService.reasonBlocked(target.url) {
                return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("清理目标受保护不可操作：\(reason)")) }
            }
            guard let freshTarget = try? FileIdentity.read(target.url), freshTarget == target.identity else {
                return ids.map { TrashResult(id: $0, path: "", destination: nil, error: localized("目标文件已被修改或不存在：\(target.url.path)")) }
            }
        }

        do { try index.invalidateDuplicateBaseline() }
        catch { return ids.map { TrashResult(id: $0, path: "", destination: nil, error: error.localizedDescription) } }

        // 顺序处理目标
        var results: [TrashResult] = []
        let bufSize = 1024 * 1024
        let kBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        let tBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer {
            kBuf.deallocate()
            tBuf.deallocate()
        }

        func readExact(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ maxCount: Int) -> Int {
            var count = 0
            while count < maxCount {
                let n = read(fd, buf + count, maxCount - count)
                if n > 0 { count += n }
                else if n == 0 { break }
                else { return -1 }
            }
            return count
        }

        for target in targets {
            if token.isCancelled {
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("操作已被取消。")))
                break
            }

            do { try validateEntry(keeper); try validateEntry(target, applyingUserProtection: true) }
            catch { results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: error.localizedDescription)); break }

            // 再次检查保留项实际路径和身份存在
            guard let currentKeeper = try? FileIdentity.read(keeper.url), currentKeeper == keeper.identity else {
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("保留项已被修改或删除，停止清理。")))
                break
            }

            // 打开两端
            let keeperFd = Self.safeOpenReadOnly(keeper.url)
            guard keeperFd >= 0 else {
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("无法打开保留项。")))
                break
            }

            let targetFd = Self.safeOpenReadOnly(target.url)
            guard targetFd >= 0 else {
                close(keeperFd)
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("无法打开目标文件。")))
                break
            }

            var kStat = stat(), tStat = stat()
            guard Self.validDescriptor(keeperFd, entry: keeper), Self.validDescriptor(targetFd, entry: target),
                  fstat(keeperFd, &kStat) == 0, fstat(targetFd, &tStat) == 0,
                  kStat.st_size == tStat.st_size,
                  kStat.st_size == keeper.logicalSize,
                  kStat.st_nlink <= 1, tStat.st_nlink <= 1,
                  (kStat.st_flags & UInt32(SF_DATALESS)) == 0, (tStat.st_flags & UInt32(SF_DATALESS)) == 0 else {
                close(keeperFd); close(targetFd)
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("文件状态与快照不符或大小不一致。")))
                break
            }

            // 完整逐字节比对
            var bytesCompared: Int64 = 0
            var matched = true
            var cancelHit = false

            while bytesCompared < keeper.logicalSize {
                if token.isCancelled {
                    cancelHit = true
                    break
                }
                let toRead = min(Int(keeper.logicalSize - bytesCompared), bufSize)
                let kRead = readExact(keeperFd, kBuf, toRead)
                let tRead = readExact(targetFd, tBuf, toRead)
                if kRead < 0 || tRead < 0 || kRead != tRead {
                    matched = false
                    break
                }
                if memcmp(kBuf, tBuf, kRead) != 0 {
                    matched = false
                    break
                }
                bytesCompared += Int64(kRead)
                if kRead < toRead {
                    matched = false
                    break
                }
            }

            if !Self.validDescriptor(keeperFd, entry: keeper) || !Self.validDescriptor(targetFd, entry: target) { matched = false }
            close(keeperFd); close(targetFd)

            if cancelHit {
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("操作已被取消。")))
                break
            }

            guard matched && bytesCompared == keeper.logicalSize else {
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("目标文件与保留项内容不一致，拒绝清理。")))
                break
            }

            // 比较结束、移到废纸篓前，复核两端路径存在与身份
            guard let postKeeper = try? FileIdentity.read(keeper.url), postKeeper == keeper.identity,
                  let postTarget = try? FileIdentity.read(target.url), postTarget == target.identity else {
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("清理前文件身份或路径发生改变。")))
                break
            }

            do { try validateEntry(keeper); try validateEntry(target, applyingUserProtection: true) }
            catch { results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: error.localizedDescription)); break }

            // 调用 TrashService
            let moveResults = trashService.move(ids: [target.id])
            guard let moveRes = moveResults.first else {
                results.append(TrashResult(id: target.id, path: target.url.path, destination: nil, error: localized("移动操作失败。")))
                break
            }
            results.append(moveRes)

            // 若系统移动成功但索引维护失败，将会话标记为失效并停止
            if moveRes.destination != nil && moveRes.error != nil {
                self.isValid = false
                break
            }

            // 其他错误立即停止余项
            if moveRes.error != nil {
                break
            }
        }

        return results
    }
}
