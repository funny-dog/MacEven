import Foundation
import Combine
import MacEvenCore

struct DuplicateConfirmation: Identifiable, Sendable {
    let id = UUID()
    let generation: UInt64
    let groupID: String
    let keeperID: Int64
    let keeperPath: String
    let targetIDs: [Int64]
    let targetPaths: [String]
    let allocatedSize: Int64
}

private final class DuplicateMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (UInt64, DuplicateProgress)?
    func put(_ value: DuplicateProgress, generation: UInt64) { lock.withLock { latest = (generation, value) } }
    func take(for generation: UInt64) -> DuplicateProgress? {
        lock.withLock {
            defer { latest = nil }
            guard latest?.0 == generation else { return nil }
            return latest?.1
        }
    }
}

@MainActor final class DuplicateModel: ObservableObject {
    private final class State: @unchecked Sendable {
        let disk: DiskBackend
        let mailbox = DuplicateMailbox()
        var service: DuplicateFiles?
        init(directory: URL) { disk = DiskBackend(cache: directory) }
    }
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var members: [DiskEntry] = []
    @Published private(set) var activeGroupID: String?
    @Published private(set) var keeperID: Int64?
    @Published private(set) var keeperPath: String?
    @Published var selectedIDs = Set<Int64>()
    @Published private(set) var confirmation: DuplicateConfirmation?
    @Published private(set) var scanning = false
    @Published private(set) var operating = false
    @Published private(set) var loading = false
    @Published private(set) var incomplete = true
    @Published private(set) var status = localized("扫描启动磁盘个人文件夹（不含资源库），查找内容相同的文件")
    @Published private(set) var progress: DuplicateProgress?
    @Published private(set) var summary: DuplicateSummary?
    @Published private(set) var results: [TrashResult] = []
    @Published private(set) var groupOffset = 0
    @Published private(set) var memberOffset = 0
    @Published private(set) var canNextGroups = false
    @Published private(set) var canNextMembers = false
    /// 扫描中途的候选统计（物化候选后、抽样剪枝后各刷新一次）；扫描结束由最终结果接替。
    @Published private(set) var liveStats: DuplicateCandidateStats?
    /// 最近一次扫描的范围，用于“重新扫描”。重复文件暂不允许选磁盘，范围固定为启动盘。
    @Published private(set) var lastScope: DuplicateScope?
    /// 只查找不小于此大小的文件；不持久化，每次启动恢复默认 1 MB。
    @Published var minimumSize: Int64 = DuplicateFiles.defaultMinimumSize
    @Published var message: String?
    @Published private(set) var lastAnalysis: AnalysisReport?
    private let historyDefaults: UserDefaults?
    private let backend: State
    private let home: URL
    private var generation: UInt64 = 0
    private var queryGeneration: UInt64 = 0
    private var token: CancellationToken?
    private var timer: Timer?
    private var closed = false
    /// 移动结束时在后台队列同步调用；退出期间完成的移动也会写入操作日志。
    var recordOperation: (@Sendable ([TrashResult]) -> Void)?
    var busy: Bool { scanning || operating || loading }
    let estimates: ScanEstimates
    /// 上次同范围、同门槛完整遍历的条目数；没有时遍历阶段总数未知。
    private var expectedVisited: Int?
    /// 遍历约占 60%，抽样与完整哈希各约 20%。增量遍历通常很快，按未知处理。
    var progressEstimate: ProgressEstimate {
        guard scanning, let progress else { return .unknown }
        let weights = [0.6, 0.2, 0.2]
        func phase(_ value: DuplicateProgress) -> ProgressEstimate {
            guard let done = value.phaseDone, let total = value.phaseTotal else { return .unknown }
            // 本阶段没有需要处理的候选：视为已完成。
            return ProgressEstimate(fraction: total > 0 ? Double(done) / Double(total) : 1, estimated: false)
        }
        switch progress.phase {
        case "scanning":
            guard let expectedVisited else { return .unknown }
            return .phases(weights, index: 0, inner: .expected(Double(progress.visited), of: Double(expectedVisited)))
        case "sampling": return .phases(weights, index: 1, inner: phase(progress))
        case "hashing": return .phases(weights, index: 2, inner: phase(progress))
        default: return .unknown
        }
    }
    var progressCaption: String {
        guard let progress else { return localized("准备中…") }
        let title = switch progress.phase {
        case "sampling": localized("抽样比对")
        case "hashing": localized("完整比对")
        case "incremental": localized("检查变化")
        default: localized("检查文件")
        }
        return localized("\(title) · 已检查 \(progress.visited.formatted()) 个文件 · \(Int(progress.elapsed)) 秒")
    }
    static func estimateKey(_ scope: DuplicateScope, minimumSize: Int64) -> String {
        let place = switch scope {
        case .folder(let url): "folder:" + url.standardizedFileURL.path
        case .volumes(let volumes): "volumes:" + volumes.map(\.id).sorted().joined(separator: ",")
        }
        return "duplicate:\(minimumSize):" + place
    }
    var selectedEntries: [DiskEntry] { members.filter { selectedIDs.contains($0.id) } }
    var canClean: Bool {
        !closed && !busy && !incomplete && activeGroupID != nil && keeperID != nil && keeperPath != nil &&
        !selectedIDs.isEmpty && selectedIDs.count <= 50 && !selectedIDs.contains(keeperID!) && selectedEntries.count == selectedIDs.count
    }
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, cacheDirectory: URL? = nil, estimates: ScanEstimates = ScanEstimates(), historyDefaults: UserDefaults? = nil) {
        self.home = home; self.estimates = estimates
        self.historyDefaults = historyDefaults
        // 重复文件扫描结果仅在当前 app 运行轮次生效，退出后不持久化恢复，启动时重新开始。
        lastAnalysis = nil
        historyDefaults?.removeObject(forKey: "analysisReport.duplicates")
        backend = State(directory: cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacEven/duplicate-sessions"))
    }
    /// 固定扫描启动盘个人文件夹（不含资源库），与磁盘分析的系统盘范围一致。
    func start() {
        start(scope: .volumes([DuplicateFiles.startupVolume(home: home)]))
    }
    /// 界面展示的固定扫描范围路径。
    var scopeSummary: String { home.path }
    /// 指定范围扫描（保留给检查程序与测试）；界面只暴露固定启动盘的 start()。
    func start(scope: DuplicateScope) {
        guard !closed && !operating else { return }
        token?.cancel(); timer?.invalidate(); generation &+= 1; queryGeneration &+= 1
        let run = generation, cancellation = CancellationToken(); token = cancellation
        lastScope = scope; scanning = true; loading = false; incomplete = true; progress = nil; summary = nil; results = []
        liveStats = nil
        groups = []; members = []; clearSelection(); groupOffset = 0; memberOffset = 0; canNextGroups = false; canNextMembers = false
        status = localized("检查目录和文件元数据…")
        let backend = backend, home = home, minimumSize = minimumSize
        let estimateKey = Self.estimateKey(scope, minimumSize: minimumSize); expectedVisited = estimates.expected(estimateKey)
        _ = backend.mailbox.take(for: run)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scanning else { return }
                self.progress = self.backend.mailbox.take(for: self.generation) ?? self.progress
            }
        }
        backend.disk.queue.async { [weak self] in
            do {
                backend.service = nil
                let service = DuplicateFiles(index: try backend.disk.makeDuplicateIndex(), home: home); backend.service = service
                let liveReporter = self
                let result = try service.scan(scope: scope, minimumSize: minimumSize, token: cancellation,
                                              progress: { backend.mailbox.put($0, generation: run) },
                                              statistics: { liveReporter?.publishLiveStats($0, generation: run) })
                let initialPage: ([DuplicateGroup], Bool)
                do {
                    let rows = cancellation.isCancelled ? [] : try service.groups(offset: 0, limit: 100, token: cancellation)
                    let next = cancellation.isCancelled ? false : try !service.groups(offset: 100, limit: 1, token: cancellation).isEmpty
                    initialPage = (rows, next)
                } catch {
                    guard cancellation.isCancelled else { throw error }
                    initialPage = ([], false)
                }
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.timer?.invalidate(); self.timer = nil; self.scanning = false; self.liveStats = nil
                    self.progress = backend.mailbox.take(for: run) ?? self.progress; self.summary = result
                    if !result.cancelled && !result.incremental { self.estimates.record(estimateKey, visited: Int(result.visited)) }
                    self.incomplete = result.incomplete || cancellation.isCancelled; self.groups = initialPage.0; self.canNextGroups = initialPage.1
                    if !result.cancelled && !cancellation.isCancelled {
                        let scopeName: String = switch scope {
                        case .folder(let url): url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
                        case .volumes(let vols): vols.count > 1 ? localized("所有磁盘") :
                            (vols.first.map { $0.isStartup ? localized("启动磁盘（个人文件）") : $0.name } ?? localized("磁盘"))
                        }
                        let scopeDetail: String = switch scope {
                        case .folder(let url): url.path
                        case .volumes(let vols): vols.map { $0.isStartup ? localized("\($0.name)（个人文件）") : $0.mountURL.path }.joined(separator: localized("、"))
                        }
                        let groupCountText = initialPage.0.isEmpty ? localized("未找到重复文件") : localized("找到 \(initialPage.0.count)\(initialPage.1 ? "+" : "") 组重复文件")
                        let totalAllocated = initialPage.0.reduce(0) { $0 + $1.allocatedSize }
                        let summary = localized("\(scopeName) · \(groupCountText) · \(initialPage.1 ? localized("前 100 组") : localized("重复文件"))占用 \(bytes(totalAllocated))") + (self.incomplete ? localized(" · 扫描不完整") : localized(" · 扫描完成"))
                        let details = [
                            localized("范围：\(scopeDetail)"),
                            localized("已检查文件：\(result.visited.formatted()) 项"),
                            localized("比对文件：\(result.hashed.formatted()) 项"),
                            initialPage.0.isEmpty ? localized("重复文件：未找到重复文件") : localized("重复组：\(initialPage.0.count)\(initialPage.1 ? "+" : "") 组 · \(initialPage.1 ? localized("前 100 组") : localized("重复文件"))占用估算 \(bytes(totalAllocated))"),
                            localized("门槛：\(minimumSize <= 1 ? localized("全部大小") : "≥ \(bytes(minimumSize))")")
                        ] + (result.errors > 0 ? [localized("已跳过 \(result.errors) 个错误或受限项目")] : [])
                        let report = AnalysisReport(summary: summary, details: details)
                        self.lastAnalysis = report
                    }
                    self.status = self.incomplete ? localized("扫描不完整 · 请重新扫描后清理")
                        : localized("扫描完成 · 大小和 SHA-256 相同的候选") + (result.errors > 0 ? localized(" · 已跳过 \(result.errors) 项") : "")
                }
            } catch { self?.publishFailure(error.localizedDescription, generation: run) }
        }
    }
    private func clearSelection() { activeGroupID = nil; keeperID = nil; keeperPath = nil; selectedIDs = []; confirmation = nil }
    func cancel() { token?.cancel(); if busy { status = localized("正在停止，请等待当前文件操作结束…") } }
    func loadGroups(offset: Int) {
        guard !closed && !scanning && !operating && summary != nil else { return }
        token?.cancel(); let cancellation = CancellationToken(); token = cancellation
        queryGeneration &+= 1; let query = queryGeneration, run = generation, backend = backend, offset = max(0, offset)
        loading = true; clearSelection(); members = []; memberOffset = 0; canNextMembers = false
        backend.disk.queue.async { [weak self] in
            do {
                guard let service = backend.service else { throw MacEvenError(localized("重复文件索引不可用")) }
                let rows = try service.groups(offset: offset, limit: 100, token: cancellation)
                let next = try !service.groups(offset: offset + 100, limit: 1, token: cancellation).isEmpty
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run, self.queryGeneration == query else { return }
                    self.groups = rows; self.groupOffset = offset; self.canNextGroups = next; self.loading = false
                }
            } catch { self?.publishFailure(error.localizedDescription, generation: run, query: query) }
        }
    }
    func loadMembers(groupID: String, offset: Int) {
        guard !closed && !scanning && !operating && summary != nil else { return }
        if activeGroupID != groupID { clearSelection() }
        activeGroupID = groupID; selectedIDs = []; confirmation = nil; loading = true
        token?.cancel(); let cancellation = CancellationToken(); token = cancellation
        queryGeneration &+= 1; let query = queryGeneration, run = generation, backend = backend, offset = max(0, offset)
        backend.disk.queue.async { [weak self] in
            do {
                guard let service = backend.service else { throw MacEvenError(localized("重复文件索引不可用")) }
                let rows = try service.members(groupID: groupID, offset: offset, limit: 100, token: cancellation)
                let next = try !service.members(groupID: groupID, offset: offset + 100, limit: 1, token: cancellation).isEmpty
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run, self.queryGeneration == query else { return }
                    self.members = rows; self.memberOffset = offset; self.canNextMembers = next; self.loading = false
                    self.applyDefaultKeeper(offset: offset)
                }
            } catch { self?.publishFailure(error.localizedDescription, generation: run, query: query) }
        }
    }
    /// 打开一个组的首页且尚未指定保留文件时：默认保留修改时间最早的一份（相同则按路径），勾选本页其余副本（最多 50 个）。
    private func applyDefaultKeeper(offset: Int) {
        guard offset == 0, keeperID == nil,
              let first = members.min(by: { ($0.identity.modified, $0.url.path) < ($1.identity.modified, $1.url.path) }) else { return }
        keeperID = first.id; keeperPath = first.url.path
        selectedIDs = Set(members.filter { $0.id != first.id }.prefix(50).map(\.id))
    }
    func keep(id: Int64) {
        guard !closed && !busy, let entry = members.first(where: { $0.id == id }) else { return }
        keeperID = id; keeperPath = entry.url.path; selectedIDs.remove(id); confirmation = nil
    }
    func prepareCleanup() {
        guard canClean, let groupID = activeGroupID, let keeperID, let keeperPath else { return }
        let targets = selectedEntries
        confirmation = DuplicateConfirmation(generation: generation, groupID: groupID, keeperID: keeperID, keeperPath: keeperPath,
            targetIDs: targets.map(\.id), targetPaths: targets.map { $0.url.path }, allocatedSize: targets.reduce(0) { $0 + $1.allocatedSize })
    }
    func dismissConfirmation() { confirmation = nil }
    func executeCleanup() {
        guard !closed && !busy && !incomplete, let frozen = confirmation, frozen.generation == generation else { return }
        confirmation = nil; operating = true; status = localized("逐字节复核并移到废纸篓…")
        let run = generation, backend = backend, cancellation = CancellationToken(), record = recordOperation; token = cancellation
        backend.disk.queue.async { [weak self] in
            guard let service = backend.service else { self?.publishFailure(localized("索引不可用，请重新扫描"), generation: run); return }
            let results = service.move(groupID: frozen.groupID, keeperID: frozen.keeperID, ids: frozen.targetIDs, token: cancellation)
            record?(results)
            do {
                let rows = try service.groups(offset: 0, limit: 100, token: cancellation)
                let next = try !service.groups(offset: 100, limit: 1, token: cancellation).isEmpty
                let valid = service.isValid
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.operating = false; self.results = results; self.clearSelection(); self.members = []; self.groups = rows
                    self.groupOffset = 0; self.memberOffset = 0; self.canNextGroups = next; self.canNextMembers = false; self.incomplete = !valid
                    self.status = localized("已移到废纸篓 \(results.filter { $0.destination != nil }.count) 项") + (results.contains { $0.error != nil } ? localized(" · 部分项目已保留，请查看结果") : "") + (!valid ? localized(" · 索引失效，请重新扫描") : "")
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.results = results; self.operating = false; self.incomplete = true; self.clearSelection()
                    self.groups = []; self.members = []; self.status = localized("操作后索引失效，请重新扫描"); self.message = text
                }
            }
        }
    }
    nonisolated private func publishLiveStats(_ stats: DuplicateCandidateStats, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.generation == generation, self.scanning else { return }
            self.liveStats = stats
        }
    }
    nonisolated private func publishFailure(_ text: String, generation: UInt64, query: UInt64? = nil) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.generation == generation, query == nil || self.queryGeneration == query else { return }
            self.timer?.invalidate(); self.timer = nil; self.scanning = false; self.operating = false; self.loading = false
            self.liveStats = nil; self.incomplete = true; self.confirmation = nil; self.status = localized("重复文件任务失败 · 请重新扫描"); self.message = text
        }
    }
    func shutdown(_ completion: @escaping @MainActor @Sendable (String?) -> Void) {
        closed = true; token?.cancel(); generation &+= 1; queryGeneration &+= 1; timer?.invalidate(); timer = nil
        confirmation = nil; scanning = false; operating = false; loading = false
        let backend = backend
        backend.disk.queue.async {
            backend.service = nil
            var failure: String?
            do { try backend.disk.finish() } catch { failure = error.localizedDescription }
            let text = failure
            Task { @MainActor in completion(text) }
        }
    }
}
