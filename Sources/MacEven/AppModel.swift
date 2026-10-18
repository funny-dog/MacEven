import Foundation
import Combine
import AppKit
import MacEvenCore
import Darwin

/// 历史报告只用于展示；不恢复索引、选择或清理权限。
struct AnalysisReport: Codable, Equatable {
    let completedAt: Date
    let summary: String
    let details: [String]

    init(summary: String, details: [String] = [], completedAt: Date = Date()) {
        self.completedAt = completedAt; self.summary = summary; self.details = Array(details.prefix(100))
    }
    static func load(_ key: String, defaults: UserDefaults?) -> AnalysisReport? {
        guard let data = defaults?.data(forKey: "analysisReport." + key), data.count <= 262_144 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save(_ key: String, defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(self), data.count <= 262_144 else { return }
        defaults?.set(data, forKey: "analysisReport." + key)
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    case system = "系统状态", overview = "智能扫描", disk = "磁盘分析", cleanup = "缓存清理", applications = "软件", settings = "设置"
    var id: String { rawValue }
}

enum DiskBrowseMode: Hashable, Sendable { case directory, purposes, largeFiles, spaceInsights, treemap, duplicates }
/// 大文件排行范围：默认可清理；全部范围排除应用包内部文件。
enum DiskLargeFilesScope: Hashable, Sendable { case cleanable, all }

struct DiskTrashConfirmation: Identifiable, Sendable {
    let id = UUID()
    let generation: UUID
    let entries: [DiskEntry]
    var allocatedSize: Int64 { entries.reduce(0) { $0 + $1.allocatedSize } }
}

final class ProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (UUID, ScanProgress)?
    func put(_ value: ScanProgress, generation: UUID) { lock.withLock { latest = (generation, value) } }
    func take(for generation: UUID? = nil) -> ScanProgress? {
        lock.withLock {
            defer { latest = nil }
            guard let latest, generation == nil || latest.0 == generation else { return nil }
            return latest.1
        }
    }
}

/// 记住上次未取消扫描的条目数，作为下次同范围扫描的进度分母。只用于显示，不影响任何清理判断。
/// defaults 为 nil 时只保存在内存中（检查程序用，避免写入偏好）。
@MainActor final class ScanEstimates {
    private let defaults: UserDefaults?
    private var memory: [String: Int] = [:]
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    private func key(_ scope: String) -> String { "scanEstimate." + scope }
    func expected(_ scope: String) -> Int? {
        let value = defaults.map { $0.integer(forKey: key(scope)) } ?? memory[scope] ?? 0
        return value > 0 ? value : nil
    }
    func record(_ scope: String, visited: Int) {
        guard visited > 0 else { return }
        if let defaults { defaults.set(visited, forKey: key(scope)) } else { memory[scope] = visited }
    }
}

/// 扫描卷根时用卷已用的文件数（inode）估算：扫描耗时主要取决于条目数，比按字节更接近线性。
/// 启动盘根目录经 firmlink 同时包含系统卷与数据卷，两者相加。
func volumeFileCount(root: URL) -> Int? {
    guard let values = try? root.resourceValues(forKeys: [.volumeURLKey]), let volume = values.volume,
        volume.standardizedFileURL.path == root.standardizedFileURL.path else { return nil }
    func used(_ path: String) -> (count: Int, fsid: fsid_t)? {
        var info = statfs()
        guard statfs(path, &info) == 0, info.f_files > info.f_ffree else { return nil }
        return (Int(info.f_files - info.f_ffree), info.f_fsid)
    }
    guard let main = used(root.path) else { return nil }
    var total = main.count
    if root.standardizedFileURL.path == "/", let data = used("/System/Volumes/Data"),
        data.fsid.val.0 != main.fsid.val.0 || data.fsid.val.1 != main.fsid.val.1 { total += data.count }
    return total
}

extension ScanProgress {
    /// 候选列表类扫描的精确进度；没有单元信息时总数未知。
    var unitEstimate: ProgressEstimate {
        totalUnits.map { ProgressEstimate.units(completedUnits ?? 0, of: $0) } ?? .unknown
    }
    /// 进度条下方的一行说明；高级模式附带占用估算与失败路径数。
    func caption(advanced: Bool = false) -> String {
        let units = totalUnits.map { localized("\(min(completedUnits ?? 0, $0))/\($0) 项 · ") } ?? ""
        let detail = advanced ? localized(" · 占用估算 \(bytes(allocatedSize))") + (errors > 0 ? " · \(errorCountDescription)" : "") : ""
        return units + localized("已检查 \(visited.formatted()) 个文件") + detail + localized(" · \(Int(elapsed)) 秒")
    }
}

// All index/session access stays on this serial queue; the mailbox alone has its own lock.
final class DiskBackend: @unchecked Sendable {
    let queue = DispatchQueue(label: "MacEven.disk", qos: .utility)
    let mailbox = ProgressMailbox()
    var index: DiskIndex?
    /// 用途标签只用于解释；每次扫描完成后按当时的应用目录重建。
    var purpose = PurposeClassifier()
    private var session: URL?
    private var lockFD: Int32 = -1
    private let cache: URL
    init(cache: URL) { self.cache = cache }
    deinit { releaseOwnership() }

    func prepare() throws {
        guard lockFD < 0 else { return }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = cache.appendingPathComponent(".session-lock")
        let fd = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        }
        guard fd >= 0 else { throw MacEvenError(localized("无法打开 MacEven 会话锁。")) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw MacEvenError(localized("另一个 MacEven 实例正在使用扫描索引，请先退出该实例。"))
        }
        lockFD = fd
        do {
            for url in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: []) {
                let name = url.lastPathComponent
                if name.hasPrefix(".duplicate-delta-"),
                    UUID(uuidString: String(name.dropFirst(17).prefix(36))) != nil,
                    [".sqlite", ".sqlite-journal"].contains(String(name.dropFirst(53))) {
                    try FileManager.default.removeItem(at: url)
                }
                if name.hasPrefix("session-"), UUID(uuidString: String(name.dropFirst(8))) != nil,
                    (try? FileIdentity.read(url).isDirectory) == true {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch { releaseOwnership(); throw error }
    }
    private func releaseOwnership() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }

    func makeIndex() throws -> DiskIndex {
        try prepare()
        try cleanup()
        let folder = cache.appendingPathComponent("session-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        session = folder
        let value = try DiskIndex(url: folder.appendingPathComponent("index.sqlite")); index = value
        return value
    }
    /// 重复文件保留元数据与哈希；独占锁和队列仍由本 backend 管理。
    func makeDuplicateIndex() throws -> DiskIndex {
        try prepare()
        if let index { return index }
        let url = cache.appendingPathComponent("duplicate-index.sqlite")
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw MacEvenError(localized("无法安全打开重复文件缓存。")) }
        close(fd)
        let value = try DiskIndex(url: url)
        index = value
        return value
    }
    func cleanup() throws {
        index?.close(); index = nil
        if let session {
            do { try FileManager.default.removeItem(at: session) }
            catch {
                let value = error as NSError
                if value.domain != NSCocoaErrorDomain || (value.code != NSFileNoSuchFileError && value.code != NSFileReadNoSuchFileError) { throw error }
            }
            self.session = nil
        }
    }
    func finish() throws {
        defer { releaseOwnership() }
        try cleanup()
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var page = AppPage.system
    @Published var status = localized("准备扫描")
    @Published var scanning = false
    @Published var operating = false
    @Published var progress: ScanProgress?
    @Published var summary: ScanSummary?
    @Published var rootEntry: DiskEntry?
    @Published var entries: [DiskEntry] = []
    @Published var breadcrumbs: [DiskEntry] = []
    @Published var selection = Set<Int64>()
    @Published private(set) var browseMode = DiskBrowseMode.purposes
    var largeFiles: Bool { browseMode == .largeFiles }
    @Published private(set) var largeFilesScope = DiskLargeFilesScope.cleanable
    @Published private(set) var largeFilesSkippedBundleCount = 0
    @Published private(set) var largeFilesCapped = false
    @Published private(set) var categoryStats: [SpaceCategoryStat] = []
    @Published private(set) var spaceFilter = try! SpaceFilter()
    @Published private(set) var filteredCount: Int64 = 0
    @Published private(set) var filteredAllocatedSize: Int64 = 0
    @Published private(set) var treemapSnapshot: TreemapSnapshot?
    @Published private(set) var trashConfirmation: DiskTrashConfirmation?
    @Published private(set) var trashResults: [TrashResult] = []
    @Published var offset = 0
    @Published var loading = false
    @Published var canNext = false
    @Published var message: String?
    @Published var errorExamples: [String] = []
    @Published var blocked: [Int64: BlockKind] = [:]
    @Published private(set) var lastAnalysis: AnalysisReport?
    private let historyDefaults: UserDefaults?
    @Published private(set) var labels: [Int64: PurposeLabel] = [:]
    @Published private(set) var directoryLabel: PurposeLabel?
    /// 全盘按用途汇总（扫描时写入）；purposeCategory 是当前列出的用途，purposeBytes 是条目归属该用途的字节。
    @Published private(set) var purposeSummary: PurposeSummary?
    @Published private(set) var purposeCategory: PurposeCategory?
    @Published private(set) var purposeBytes: [Int64: Int64] = [:]
    private let backend: DiskBackend
    private let homeURL: URL
    private var token: CancellationToken?
    private var generation = UUID()
    private var queryGeneration = UUID()
    private var queryToken: CancellationToken?
    private var closed = false
    /// 移动结束时在后台队列同步调用；退出期间完成的移动也会写入操作日志。
    var recordOperation: (@Sendable ([TrashResult]) -> Void)?
    /// 用途标签解析应用名称用；未注入时只显示原始标识。在后台队列调用。
    var applicationCatalog: (@Sendable () -> [CacheApplication])?
    private var directoryID: Int64 = 1
    private var timer: Timer?
    private(set) var rootURL = URL(fileURLWithPath: "/")
    let estimates: ScanEstimates
    /// 本次扫描的进度分母：上次同一扫描根的条目数，或卷已用的文件数。
    private var expectedVisited: Int?
    var busy: Bool { scanning || operating || loading }
    var progressEstimate: ProgressEstimate {
        guard scanning, let progress, let expectedVisited else { return .unknown }
        return .expected(Double(progress.visited), of: Double(expectedVisited))
    }
    var selectedEntries: [DiskEntry] { entries.filter { selection.contains($0.id) } }
    @Published var expandPurposeFiles: Bool = false
    var canTrash: Bool { !busy && !selection.isEmpty && selectedEntries.count == selection.count && (treemapSnapshot?.invalidSizeCount ?? 0) == 0 && selectedEntries.allSatisfy { blocked[$0.id] == nil } }
    var selectedSize: Int64 { selectedEntries.reduce(0) { $0 + $1.allocatedSize } }
    /// 列表大小列：按用途浏览时显示归属该用途的部分，其余显示整个条目的占用。
    func listedSize(_ item: DiskEntry) -> Int64 { browseMode == .purposes ? purposeBytes[item.id] ?? item.allocatedSize : item.allocatedSize }
    var showsBreadcrumbs: Bool { browseMode != .largeFiles && browseMode != .purposes && browseMode != .duplicates }

    var hasOnlySystemProtectedIssues: Bool {
        guard let summary, summary.errors > 0, !summary.cancelled else { return false }
        return summary.issues.allSatisfy { $0.category == .systemProtected || $0.category == .excluded }
    }

    var hasAuthorizableIssues: Bool {
        guard !FullDiskAccessChecker.check(), let summary else { return false }
        return summary.issues.contains { $0.category == .permissionDenied || $0.category == .operationDenied }
    }

    var incompleteResultNotice: String? {
        guard let summary else { return nil }
        if summary.cancelled { return localized("扫描已取消，当前结果不完整") }
        if hasOnlySystemProtectedIssues {
            return nil
        }
        if summary.errors > 0 {
            return hasAuthorizableIssues ? localized("部分路径未获授权，当前结果不完整") : localized("部分路径未能完成扫描，当前结果不完整")
        }
        return nil
    }
    var treemapDirectoryNotice: String? {
        guard let directory = breadcrumbs.last, let summary else { return nil }
        let path = directory.url.standardizedFileURL.path
        let prefix = path == "/" ? "/" : path + "/"
        guard let issue = summary.issues.first(where: { issue in
            guard let issuePath = issue.path else { return false }
            return issuePath == path || issuePath.hasPrefix(prefix)
        }) else { return nil }
        return localized("此目录或其子路径存在\(issue.category.title)，未扫描内容未计入。")
    }
    var treemapEmptyNotice: String {
        if loading { return localized("正在查询空间图…") }
        guard let snapshot = treemapSnapshot else { return localized("空间图尚未取得，请重新加载目录。") }
        if incompleteResultNotice != nil && snapshot.totalCount == 0 {
            return localized("没有已扫描的子项；扫描不完整，不能确认目录为空。")
        }
        if snapshot.totalCount == 0 { return localized("此目录为空。") }
        return localized("已扫描条目的磁盘占用估算为零，无法分配面积；可在目录明细中查看条目。")
    }

    init(cacheDirectory: URL? = nil, estimates: ScanEstimates = ScanEstimates(), historyDefaults: UserDefaults? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.estimates = estimates
        self.historyDefaults = historyDefaults
        homeURL = home
        // 磁盘分析扫描结果仅在当前 app 运行轮次生效，退出后不持久化恢复，启动时重新开始。
        lastAnalysis = nil
        historyDefaults?.removeObject(forKey: "analysisReport.disk")
        backend = DiskBackend(cache: cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacEven/sessions", isDirectory: true))
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scanning, let value = self.backend.mailbox.take(for: self.generation) else { return }
                self.progress = value
            }
        }
    }

    func prepareSessions() {
        guard !closed else { return }
        let backend = backend
        backend.queue.async { [weak self] in
            do { try backend.prepare() }
            catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.message = text }
            }
        }
    }

    func start(root: URL = URL(fileURLWithPath: "/")) {
        guard !closed && !operating else { return }
        token?.cancel(); queryToken?.cancel()
        let run = UUID(); generation = run; queryGeneration = UUID()
        let cancellation = CancellationToken(); token = cancellation; rootURL = root
        let estimateKey = "disk:" + root.standardizedFileURL.path
        expectedVisited = estimates.expected(estimateKey) ?? volumeFileCount(root: root)
        scanning = true; status = localized("扫描中"); progress = nil; summary = nil; entries = []; breadcrumbs = []
        selection = []; rootEntry = nil; blocked = [:]; labels = [:]; directoryLabel = nil; errorExamples = []; offset = 0; loading = false
        largeFilesSkippedBundleCount = 0; largeFilesCapped = false
        purposeSummary = nil; purposeCategory = nil; purposeBytes = [:]
        directoryID = 1; categoryStats = []; spaceFilter = try! SpaceFilter()
        filteredCount = 0; filteredAllocatedSize = 0; trashConfirmation = nil; trashResults = []; canNext = false
        treemapSnapshot = nil
        _ = backend.mailbox.take()
        let backend = backend, catalog = applicationCatalog
        backend.queue.async { [weak self] in
            do {
                let index = try backend.makeIndex()
                // 扫描、汇总与列表标签共用同一个分类器，规则序号一致。
                let purpose = PurposeClassifier(applications: catalog?() ?? [])
                backend.purpose = purpose
                let result = try Scanner.scan(root: root, index: index, token: cancellation, purposes: purpose) { backend.mailbox.put($0, generation: run) }
                let rootEntry = try index.entry(id: 1)
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.progress = backend.mailbox.take(for: run); self.summary = result; self.errorExamples = result.errorExamples
                    self.scanning = false; self.rootEntry = rootEntry
                    if !result.cancelled && !cancellation.isCancelled, let rootEntry {
                        self.estimates.record(estimateKey, visited: result.visited)
                        let scopeName = root.path == "/" ? localized("内部磁盘") : (root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
                        let incomplete = result.errors > 0 && !self.hasOnlySystemProtectedIssues
                        let summary = localized("\(scopeName) · \(result.visited.formatted()) 项 · 占用估算 \(bytes(rootEntry.allocatedSize))") + (incomplete ? localized(" · 扫描不完整") : localized(" · 扫描完成"))
                        let details = [
                            localized("范围：\(root.path)"),
                            localized("已检查：\(result.visited.formatted()) 个条目"),
                            localized("磁盘占用估算：\(bytes(rootEntry.allocatedSize))"),
                            localized("逻辑大小：\(bytes(rootEntry.logicalSize))")
                        ] + (incomplete ? [localized("\(result.errorCountDescription)，部分路径未计入")] : (self.hasOnlySystemProtectedIssues ? [localized("已自动标记跳过系统保护路径")] : []))
                        let report = AnalysisReport(summary: summary, details: details)
                        self.lastAnalysis = report
                    }
                    self.status = result.cancelled ? localized("已取消 · 结果不完整") : (result.errors > 0 && !self.hasOnlySystemProtectedIssues) ? localized("扫描完成 · 结果不完整") : localized("扫描完成")
                    self.load(directory: 1)
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.scanning = false; self.status = localized("扫描失败"); self.message = text
                }
            }
        }
    }
    func cancel() {
        token?.cancel(); queryToken?.cancel()
        if scanning { status = localized("正在停止扫描…") }
        else if loading { status = localized("正在取消查询…") }
    }
    func showLargeFiles(_ value: Bool) { setBrowseMode(value ? .largeFiles : .directory) }
    /// 大文件范围只影响大文件视图；选择在本次运行内保持，应用重启后恢复默认「可清理」。
    func setLargeFilesScope(_ scope: DiskLargeFilesScope) {
        guard !closed && !busy, browseMode == .largeFiles, scope != largeFilesScope else { return }
        largeFilesScope = scope
        load(offset: 0)
    }
    func showSpaceInsights() { setBrowseMode(.spaceInsights) }
    func setBrowseMode(_ mode: DiskBrowseMode) {
        guard !closed && !scanning && !operating else { return }
        browseMode = mode
        // 重复文件由 DuplicateModel 持有数据与扫描状态，不查询磁盘会话索引。
        if mode != .duplicates { load(offset: 0) }
    }
    func applySpaceFilter(_ filter: SpaceFilter) {
        guard !closed && !scanning && !operating else { return }
        spaceFilter = filter; browseMode = .spaceInsights; load(offset: 0)
    }
    func clearSpaceFilter() { applySpaceFilter(try! SpaceFilter()) }
    /// nil 表示选占用最多的用途。
    func showPurpose(_ category: PurposeCategory?) {
        guard !closed && !scanning && !operating else { return }
        purposeCategory = category; browseMode = .purposes
        if category != nil { expandPurposeFiles = true }
        load(offset: 0)
    }
    /// 从用途列表进入某个文件夹的目录浏览。
    func browse(directory id: Int64) {
        guard !closed && !scanning && !operating else { return }
        browseMode = .directory; load(directory: id)
    }
    func selectTreemapEntry(_ id: Int64) {
        guard !busy, browseMode == .treemap, (treemapSnapshot?.invalidSizeCount ?? 0) == 0, entries.contains(where: { $0.id == id }) else { return }
        selection = [id]
    }
    func load(directory: Int64? = nil, offset: Int = 0) {
        guard !closed && !scanning && !operating, rootEntry != nil, browseMode != .duplicates else { return }
        let id = directory ?? directoryID
        directoryID = id
        let offset = browseMode == .treemap ? 0 : max(0, offset)
        self.offset = offset; selection = []; trashConfirmation = nil; blocked = [:]; labels = [:]; directoryLabel = nil; loading = true
        entries = []; canNext = false; categoryStats = []; filteredCount = 0; filteredAllocatedSize = 0
        largeFilesSkippedBundleCount = 0; largeFilesCapped = false
        treemapSnapshot = nil; purposeBytes = [:]
        queryToken?.cancel()
        let cancellation = CancellationToken(); queryToken = cancellation
        let query = UUID(); queryGeneration = query; let run = generation, mode = browseMode, filter = spaceFilter, wanted = purposeCategory, scope = largeFilesScope, home = homeURL
        let backend = backend
        backend.queue.async { [weak self] in
            do {
                guard !cancellation.isCancelled, let index = backend.index else { throw MacEvenError(localized("查询已取消或索引已关闭。")) }
                index.setCancelHandler(token: cancellation)
                defer { index.setCancelHandler(token: nil); withExtendedLifetime(cancellation) {} }
                let service = TrashService(index: index, home: home)
                let values: [DiskEntry], next: Bool, stats: [SpaceCategoryStat], count: Int64, allocated: Int64
                let tree: TreemapSnapshot?
                var skippedBundleCount = 0
                var cappedResult = false
                var purposeSummary: PurposeSummary?, purposeCategory: PurposeCategory?, purposeBytes: [Int64: Int64] = [:]
                switch mode {
                case .directory:
                    values = try index.children(of: id, offset: offset)
                    next = try !index.children(of: id, offset: offset + 100, limit: 1).isEmpty
                    stats = []; count = 0; allocated = 0; tree = nil
                case .purposes:
                    let summary = PurposeSummary(totals: try index.purposeTotals(), total: try index.entry(id: 1)?.allocatedSize ?? 0, rules: backend.purpose.rules)
                    let group = summary.groups.first { $0.category == wanted } ?? summary.groups.first
                    let page = try index.purposePage(tags: group?.tags ?? [], offset: group?.category == wanted ? offset : 0)
                    values = page.entries; next = page.hasNext; stats = []; count = 0; allocated = 0; tree = nil
                    purposeSummary = summary; purposeCategory = group?.category; purposeBytes = page.bytes
                case .largeFiles:
                    let pageSize = 100
                    let maxPages = 10
                    var collected: [DiskEntry] = []
                    var page = 0
                    while collected.count < pageSize && page < maxPages {
                        guard !cancellation.isCancelled else { throw MacEvenError(localized("查询已取消。")) }
                        let batch = scope == .cleanable
                            ? try index.largestCleanableFiles(homePath: service.homePath, limit: pageSize, offset: page * pageSize)
                            : try index.largestFiles(limit: pageSize, offset: page * pageSize)
                        guard !batch.isEmpty else { break }
                        for item in batch {
                            if scope == .all, BundlePath.containsBundleAncestor(item.url.path) {
                                skippedBundleCount += 1
                                continue
                            }
                            if scope == .cleanable, service.blockKind(item.url) != nil { continue }
                            collected.append(item)
                            if collected.count == pageSize { break }
                        }
                        if batch.count < pageSize { break }
                        page += 1
                        if page == maxPages && collected.count < pageSize { cappedResult = true }
                    }
                    values = collected; next = false; stats = []; count = 0; allocated = 0; tree = nil
                case .spaceInsights:
                    stats = try index.spaceStats(directoryID: id, token: cancellation)
                    let page = try index.spacePage(directoryID: id, filter: filter, offset: offset, token: cancellation)
                    values = page.entries; next = page.hasNext; count = page.totalCount; allocated = page.allocatedSize
                    tree = nil
                case .treemap:
                    let snapshot = try index.treemap(of: id)
                    tree = snapshot; values = snapshot.entries; next = false; stats = []; count = 0; allocated = 0
                case .duplicates:
                    // load 已在入口对重复文件早退；兜底不查询磁盘索引。
                    values = []; next = false; stats = []; count = 0; allocated = 0; tree = nil
                }
                let path = try index.ancestors(of: id)
                var reasons: [Int64: BlockKind] = [:]
                for item in values { if let kind = service.blockKind(item.url) { reasons[item.id] = kind } }
                let purpose = backend.purpose.labels(for: values, directory: mode == .largeFiles || mode == .purposes ? nil : path.last?.url.path)
                let root = try index.entry(id: 1)
                guard !cancellation.isCancelled else { throw MacEvenError(localized("查询已取消。")) }
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run, self.queryGeneration == query else { return }
                    guard !cancellation.isCancelled else { self.loading = false; self.status = localized("查询已取消"); self.message = localized("查询已取消。"); return }
                    self.entries = values; self.breadcrumbs = path; self.canNext = next; self.blocked = reasons
                    self.largeFilesSkippedBundleCount = skippedBundleCount; self.largeFilesCapped = cappedResult
                    self.labels = purpose.entries; self.directoryLabel = purpose.directory
                    self.categoryStats = stats; self.filteredCount = count; self.filteredAllocatedSize = allocated
                    self.treemapSnapshot = tree
                    if mode == .purposes {
                        self.purposeSummary = purposeSummary; self.purposeCategory = purposeCategory; self.purposeBytes = purposeBytes
                        if purposeCategory != wanted { self.offset = 0 }
                    }
                    self.rootEntry = root; self.loading = false
                    if self.status == localized("正在取消查询…") || self.status == localized("查询已取消") { self.status = localized("查询完成") }
                }
            } catch {
                let text = cancellation.isCancelled ? localized("查询已取消。") : error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run, self.queryGeneration == query else { return }
                    self.loading = false; self.message = text
                    if cancellation.isCancelled { self.status = localized("查询已取消") }
                }
            }
        }
    }
    func prepareTrash() {
        guard canTrash else { return }
        trashConfirmation = DiskTrashConfirmation(generation: generation, entries: selectedEntries)
    }
    func dismissTrashConfirmation() { trashConfirmation = nil }
    func trashSelected() {
        guard !closed && !busy, let frozen = trashConfirmation, frozen.generation == generation else { return }
        let ids = frozen.entries.map(\.id); let backend = backend; let run = generation, record = recordOperation
        trashConfirmation = nil
        operating = true; status = localized("正在移到废纸篓…")
        backend.queue.async { [weak self] in
            guard let index = backend.index else { return }
            let results = TrashService(index: index).move(ids: ids)
            record?(results)
            let invalid = results.contains { $0.destination != nil && $0.error != nil }
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.generation == run else { return }
                self.operating = false; self.selection = []; self.trashResults = results
                let succeeded = results.filter { $0.destination != nil }.count
                let errors = results.compactMap { item in item.error.map { "\(item.path)\n\($0)" } }
                self.message = localized("已移到废纸篓：\(succeeded) 项。空间将在清空废纸篓后释放。") + (errors.isEmpty ? "" : "\n\n" + errors.joined(separator: "\n\n"))
                self.status = invalid ? localized("索引失效 · 请重新扫描") : localized("文件操作完成")
                if invalid { self.rootEntry = nil; self.entries = []; self.labels = [:]; self.directoryLabel = nil; self.purposeSummary = nil; self.purposeBytes = [:]; self.breadcrumbs = []; self.categoryStats = []; self.filteredCount = 0; self.filteredAllocatedSize = 0; self.canNext = false; self.treemapSnapshot = nil }
                else { self.load() }
            }
        }
    }
    func shutdown(_ completion: @escaping @MainActor @Sendable (String?) -> Void) {
        closed = true; token?.cancel(); queryToken?.cancel(); generation = UUID(); queryGeneration = UUID(); timer?.invalidate(); timer = nil
        scanning = false; operating = false; loading = false; entries = []; labels = [:]; directoryLabel = nil; categoryStats = []; selection = []; trashConfirmation = nil
        purposeSummary = nil; purposeBytes = [:]
        filteredCount = 0; filteredAllocatedSize = 0; canNext = false
        treemapSnapshot = nil
        let backend = backend
        backend.queue.async {
            var errorText: String?
            do { try backend.finish() } catch { errorText = error.localizedDescription }
            let text = errorText
            Task { @MainActor in completion(text) }
        }
    }
}

// 0 显示为“0 KB”，不使用系统的英文“Zero KB”。
func bytes(_ value: Int64) -> String { value == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
