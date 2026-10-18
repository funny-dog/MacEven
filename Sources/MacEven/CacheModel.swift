import Foundation
import AppKit
import Combine
import MacEvenCore

/// 智能扫描分类卡展示的单项：名称与占用估算，只读。
struct CleanupItemSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int64
}

struct CleanupRestrictionSummary: Identifiable, Equatable {
    var id: String { reason }
    let reason: String
    let count: Int
}

func cleanupRestrictions<Group>(_ groups: [Group], reason: (Group) -> String?, size: (Group) -> Int64?) -> [CleanupRestrictionSummary] {
    let reasons = groups.compactMap { reason($0) ?? (size($0) == nil ? localized("尚未完成占用统计，需要重新扫描。") : nil) }
    return Dictionary(grouping: reasons, by: { $0 }).map { CleanupRestrictionSummary(reason: $0.key, count: $0.value.count) }
        .sorted { $0.count == $1.count ? $0.reason < $1.reason : $0.count > $1.count }
}

/// 可清理（未阻止且已统计）项目中最大的几项，按占用从大到小。
func largestCleanupItems<Group>(_ groups: [Group], limit: Int = 3, id: (Group) -> String, name: (Group) -> String,
    size: (Group) -> Int64?, blocked: (Group) -> Bool) -> [CleanupItemSummary] {
    Array(groups.compactMap { group -> CleanupItemSummary? in
        guard !blocked(group), let value = size(group) else { return nil }
        return CleanupItemSummary(id: id(group), name: name(group), size: value)
    }.sorted { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }.prefix(limit))
}

enum CacheCatalog {
    struct Result: Sendable {
        let applications: [CacheApplication]
        let truncated: Bool
        let errors: [String]
    }
    static func discover(in roots: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/System/Applications")], token: CancellationToken = CancellationToken()) -> Result {
        var apps: [String: CacheApplication] = [:]; var errors: [String] = []; var truncated = false; var visited = 0
        for root in roots {
            guard let base = try? FileIdentity.read(root), base.isDirectory, !base.isSymlink else { continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, error in
                if errors.count < 100 { errors.append(String(error.localizedDescription.prefix(1000))) }; return !token.isCancelled
            }) else { continue }
            while !token.isCancelled, let path = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                visited += 1
                if visited > 16384 || apps.count >= 2048 { truncated = true; break }
                guard let info = try? FileIdentity.read(path), !info.isSymlink, info.device == base.device else { enumerator.skipDescendants(); continue }
                guard path.pathExtension.lowercased() == "app", info.isDirectory else { continue }
                enumerator.skipDescendants()
                guard let app = CacheApplication(bundleURL: path) else { continue }
                apps[app.id] = apps[app.id] ?? app
            }
            if truncated || token.isCancelled { break }
        }
        return Result(applications: apps.values.sorted { $0.id < $1.id }, truncated: truncated, errors: errors)
    }
    static func isRunning(_ id: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            guard !$0.isTerminated, let actual = $0.bundleIdentifier else { return false }
            return actual == id || actual.hasPrefix(id + ".")
        }
    }
}

struct CacheConfirmation: Identifiable, Equatable {
    let id = UUID()
    let generation: UUID
    let groups: [CacheGroup]
    var allocatedSize: Int64 { groups.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
}

@MainActor final class CacheModel: ObservableObject {
    let developer: DeveloperCleanupModel
    @Published var developerSelected = false
    private var developerChanges: AnyCancellable?
    private final class State: @unchecked Sendable {
        let disk: DiskBackend
        var cleaner: CacheCleanup?
        init(directory: URL) { disk = DiskBackend(cache: directory) }
    }
    @Published private(set) var groups: [CacheGroup] = []
    @Published var selection = Set<String>()
    @Published private(set) var scanning = false
    @Published private(set) var operating = false
    @Published private(set) var loading = false
    @Published private(set) var status = localized("准备扫描应用缓存")
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var incomplete = false
    private(set) var scanFailed = false
    @Published private(set) var errors: [String] = []
    @Published private(set) var results: [TrashResult] = []
    @Published private(set) var confirmation: CacheConfirmation?
    @Published private(set) var offset = 0
    @Published private(set) var canNext = false
    @Published var message: String?
    private var allGroups: [CacheGroup] = []
    private let backend: State
    private let home: URL
    private let applications: [CacheApplication]?
    private let isRunning: @Sendable (String) -> Bool
    private let quitApplication: @Sendable (String, URL?) -> String?
    private var generation = UUID()
    private var token: CancellationToken?
    private var timer: Timer?
    private var closed = false
    /// 移动结束时在后台队列同步调用；退出期间完成的移动也会写入操作日志。
    var recordOperation: (@Sendable ([TrashResult]) -> Void)?
    var busy: Bool { scanning || operating || loading || developer.busy }
    /// 扫描中按候选单元计算的进度；未开始统计或已结束时为未知。
    var progressEstimate: ProgressEstimate { scanning ? (progress?.unitEstimate ?? .unknown) : .unknown }
    var selectedGroups: [CacheGroup] { groups.filter { selection.contains($0.id) } }
    // 推荐固定使用首页快照，清理前切回首页复用既有选择与确认校验。
    var recommendationGroups: [CacheGroup] { Array(allGroups.prefix(100)) }
    // 智能扫描汇总与“选择全部可清理项”：只取当前页（按占用从大到小），每次最多 50 项。
    var selectableGroups: [CacheGroup] { groups.filter { $0.blockedReason == nil && $0.allocatedSize != nil } }
    var selectableCount: Int { allGroups.filter { $0.blockedReason == nil && $0.allocatedSize != nil }.count }
    var selectableSize: Int64 { allGroups.filter { $0.blockedReason == nil }.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    var measuredSize: Int64 { allGroups.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    var restrictions: [CleanupRestrictionSummary] { cleanupRestrictions(allGroups, reason: \.blockedReason, size: \.allocatedSize) }
    var readOnlyCount: Int { allGroups.filter { $0.blockedReason != nil || $0.allocatedSize == nil }.count }
    var largestItems: [CleanupItemSummary] {
        largestCleanupItems(allGroups, id: \.id, name: \.name, size: \.allocatedSize, blocked: { $0.blockedReason != nil })
    }
    func selectLargest(limit: Int = 50) {
        guard !closed, !busy, !scanFailed else { return }
        selection = Set(selectableGroups.prefix(limit).map(\.id))
    }
    var canClean: Bool { !closed && !busy && !scanFailed && !selection.isEmpty && selection.count <= 50 && selectedGroups.count == selection.count && selectedGroups.allSatisfy { $0.blockedReason == nil && $0.allocatedSize != nil } }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, applications: [CacheApplication]? = nil,
        cacheDirectory: URL? = nil, isRunning: @escaping @Sendable (String) -> Bool = CacheCatalog.isRunning,
        developerActivity: (@Sendable (DeveloperCleanupRule, URL) -> String?)? = nil,
        quitApplication: @escaping @Sendable (String, URL?) -> String? = { ApplicationCloser.close(identifier: $0, applicationURL: $1) }) {
        self.home = home; self.applications = applications; self.isRunning = isRunning; self.quitApplication = quitApplication
        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacEven/cleanup-sessions")
        backend = State(directory: directory)
        developer = DeveloperCleanupModel(home: home, cacheDirectory: directory.appendingPathComponent("developer"), activity: developerActivity, browserRunning: isRunning, quitApplication: quitApplication)
        developer.otherBusy = { [weak self] in self.map { $0.scanning || $0.operating || $0.loading } ?? true }
        developerChanges = developer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func discardResults() {
        guard !closed, !busy else { return }
        generation = UUID(); token?.cancel(); selection = []; confirmation = nil
        allGroups = []; groups = []; errors = []; results = []; progress = nil; message = nil
        incomplete = false; scanFailed = false; offset = 0; canNext = false; status = localized("等待本次扫描")
        let backend = backend
        backend.disk.queue.async { backend.cleaner = nil }
    }

    func start() {
        guard !closed && !operating && !developer.busy else { return }
        token?.cancel(); timer?.invalidate()
        let run = UUID(); generation = run
        let cancellation = CancellationToken(); token = cancellation
        scanning = true; loading = false; status = localized("扫描应用缓存…"); selection = []; confirmation = nil
        allGroups = []; groups = []; errors = []; results = []; progress = nil; incomplete = false; scanFailed = false; offset = 0; canNext = false
        let backend = backend, home = home, supplied = applications
        _ = backend.disk.mailbox.take()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.scanning else { return }; self.progress = self.backend.disk.mailbox.take(for: self.generation) ?? self.progress }
        }
        backend.disk.queue.async { [weak self] in
            do {
                backend.cleaner = nil
                let index = try backend.disk.makeIndex()
                let catalog = supplied.map { CacheCatalog.Result(applications: $0, truncated: $0.count > 2048, errors: []) } ?? CacheCatalog.discover(token: cancellation)
                let cleaner = CacheCleanup(index: index, home: home, applications: catalog.applications)
                backend.cleaner = cleaner
                let result = try cleaner.scan(token: cancellation) { backend.disk.mailbox.put($0, generation: run) }
                let values = try cleaner.refresh(isRunning: { _ in false })
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.timer?.invalidate(); self.timer = nil; self.scanning = false
                    self.progress = backend.disk.mailbox.take(for: run) ?? self.progress
                    self.allGroups = values; self.load(offset: 0)
                    self.incomplete = result.summary.cancelled || result.summary.errors > 0 || result.truncated || catalog.truncated || !catalog.errors.isEmpty
                    self.errors = Array(((catalog.truncated ? [localized("应用目录达到扫描上限，未列出的应用无法确认归属。")] : [])
                        + (result.truncated ? [localized("应用归属或缓存候选达到扫描上限，需要缩小范围后重试。")] : [])
                        + catalog.errors + result.summary.errorExamples).prefix(100))
                    self.status = result.summary.cancelled ? localized("扫描已取消 · 结果不完整") : self.incomplete ? localized("扫描完成 · 部分结果或应用归属不完整") : localized("扫描完成 · \(values.count) 组缓存")
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.timer?.invalidate(); self.timer = nil; self.scanning = false; self.scanFailed = true; self.incomplete = true; self.status = localized("缓存扫描失败"); self.message = text
                }
            }
        }
    }
    func cancel() { token?.cancel(); developer.cancel(); if scanning { status = localized("正在停止缓存扫描…") } }
    func load(offset: Int) {
        self.offset = max(0, min(offset, allGroups.count)); selection = []
        groups = Array(allGroups.dropFirst(self.offset).prefix(100)); canNext = self.offset + groups.count < allGroups.count
    }
    func recheck() {
        guard !closed && !busy else { return }
        loading = true; selection = []; confirmation = nil
        let run = generation, backend = backend
        backend.disk.queue.async { [weak self] in
            do {
                let values = try backend.cleaner?.refresh(isRunning: { _ in false }) ?? []
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.allGroups = values; self.load(offset: self.offset); self.status = localized("运行状态已重新检查；内容变化仍需重新扫描")
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in guard let self, !self.closed, self.generation == run else { return }; self.loading = false; self.message = text }
            }
        }
    }
    func isApplicationRunning(_ id: String) -> Bool { isRunning(id) }
    func prepareCleanup() { guard canClean else { return }; confirmation = CacheConfirmation(generation: generation, groups: selectedGroups) }
    func dismissConfirmation() { confirmation = nil }
    func executeCleanup() {
        guard !closed, !busy, let frozen = confirmation, frozen.generation == generation else { return }
        confirmation = nil; operating = true; status = localized("正在关闭运行中的应用并清理；请完成应用中的保存提示…")
        let run = generation, backend = backend, running = isRunning, quit = quitApplication, record = recordOperation
        let cancellation = CancellationToken(); token = cancellation
        backend.disk.queue.async { [weak self] in
            var results: [TrashResult] = []
            for group in frozen.groups {
                do {
                    guard !cancellation.isCancelled, let cleaner = backend.cleaner,
                        let ready = try cleaner.refresh(isRunning: { _ in false }).first(where: { $0.id == group.id }), ready.blockedReason == nil else { throw MacEvenError(localized("操作已取消或缓存不可清理，请重新扫描。")) }
                    let wasRunning = running(group.id)
                    if let reason = quit(group.id, nil) { throw MacEvenError(reason) }
                    guard !cancellation.isCancelled, !running(group.id) else { throw MacEvenError(localized("应用尚未退出或操作已取消，缓存已保留。")) }
                    if wasRunning { try cleaner.rescanAfterQuit(groupID: group.id, token: cancellation, isRunning: running) }
                    results += cleaner.move(groupIDs: [group.id], isRunning: running)
                } catch { results.append(TrashResult(id: 0, path: group.id, destination: nil, error: error.localizedDescription)) }
            }
            record?(results)
            let values = try? backend.cleaner?.refresh(isRunning: { _ in false })
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.generation == run else { return }
                self.operating = false; self.results = results; self.selection = []
                if let values { self.allGroups = values; self.load(offset: self.offset) }
                else { self.allGroups = []; self.groups = []; self.incomplete = true }
                let count = results.filter { $0.destination != nil }.count
                self.status = localized("已移到废纸篓 \(count) 个缓存路径") + (results.contains { $0.error != nil } ? localized(" · 部分操作失败或已保留") : "")
            }
        }
    }
    func shutdown(_ completion: @escaping @MainActor @Sendable (String?) -> Void) {
        closed = true; token?.cancel(); generation = UUID(); timer?.invalidate(); timer = nil; confirmation = nil; scanning = false
        let backend = backend
        developer.shutdown { developerError in
            backend.disk.queue.async {
                backend.cleaner = nil
                var error: String?
                do { try backend.disk.finish() } catch let failure { error = failure.localizedDescription }
                let result = error ?? developerError
                Task { @MainActor in completion(result) }
            }
        }
    }
}

extension DeveloperCleanupRule {
    var browserIdentifier: String? {
        switch self {
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .firefox: "org.mozilla.firefox"
        default: nil
        }
    }
}

struct DeveloperCleanupConfirmation: Identifiable, Equatable {
    let id = UUID()
    let generation: UUID
    let groups: [DeveloperCleanupGroup]
    var allocatedSize: Int64 { groups.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
}

@MainActor final class DeveloperCleanupModel: ObservableObject {
    private final class State: @unchecked Sendable {
        let disk: DiskBackend
        var cleaner: DeveloperCleanup?
        init(directory: URL) { disk = DiskBackend(cache: directory) }
    }
    @Published private(set) var groups: [DeveloperCleanupGroup] = []
    @Published private(set) var selection = Set<String>()
    @Published private(set) var scanning = false
    @Published private(set) var operating = false
    @Published private(set) var loading = false
    @Published private(set) var status = localized("准备检查固定的开发工具与浏览器缓存")
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var incomplete = false
    private(set) var scanFailed = false
    @Published private(set) var errors: [String] = []
    @Published private(set) var results: [TrashResult] = []
    @Published private(set) var confirmation: DeveloperCleanupConfirmation?
    @Published private(set) var offset = 0
    @Published private(set) var canNext = false
    @Published var message: String?
    var otherBusy: @MainActor () -> Bool = { false }
    private var allGroups: [DeveloperCleanupGroup] = []
    private let backend: State
    private let home: URL
    private let activity: (@Sendable (DeveloperCleanupRule, URL) -> String?)?
    private let browserRunning: @Sendable (String) -> Bool
    private let quitApplication: @Sendable (String, URL?) -> String?
    private var generation = UUID()
    private var token: CancellationToken?
    private var timer: Timer?
    private var closed = false
    /// 移动结束时在后台队列同步调用；退出期间完成的移动也会写入操作日志。
    var recordOperation: (@Sendable ([TrashResult]) -> Void)?
    var busy: Bool { scanning || operating || loading }
    /// 扫描中按候选单元计算的进度；未开始统计或已结束时为未知。
    var progressEstimate: ProgressEstimate { scanning ? (progress?.unitEstimate ?? .unknown) : .unknown }
    var selectedGroups: [DeveloperCleanupGroup] { groups.filter { selection.contains($0.id) } }
    var recommendationGroups: [DeveloperCleanupGroup] { Array(allGroups.prefix(100)) }
    var selectableGroups: [DeveloperCleanupGroup] { groups.filter { $0.blockedReason == nil && $0.allocatedSize != nil } }
    var selectableCount: Int { allGroups.filter { $0.blockedReason == nil && $0.allocatedSize != nil }.count }
    var selectableSize: Int64 { allGroups.filter { $0.blockedReason == nil }.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    var measuredSize: Int64 { allGroups.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    var restrictions: [CleanupRestrictionSummary] { cleanupRestrictions(allGroups, reason: \.blockedReason, size: \.allocatedSize) }
    var readOnlyCount: Int { allGroups.filter { $0.blockedReason != nil || $0.allocatedSize == nil }.count }
    // AI Agent 缓存单独聚合到「AI 清理与维护」，避免与开发、浏览器缓存重复计数；页面合计口径不变。
    var aiCacheGroups: [DeveloperCleanupGroup] { allGroups.filter { $0.rule.aiToolName != nil } }
    var otherCacheGroups: [DeveloperCleanupGroup] { allGroups.filter { $0.rule.aiToolName == nil } }
    var aiCacheRestrictions: [CleanupRestrictionSummary] { cleanupRestrictions(aiCacheGroups, reason: \.blockedReason, size: \.allocatedSize) }
    var otherCacheRestrictions: [CleanupRestrictionSummary] { cleanupRestrictions(otherCacheGroups, reason: \.blockedReason, size: \.allocatedSize) }
    var aiCacheSelectableSize: Int64 { aiCacheGroups.filter { $0.blockedReason == nil }.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    var aiCacheSelectableCount: Int { aiCacheGroups.filter { $0.blockedReason == nil && $0.allocatedSize != nil }.count }
    var aiCacheReadOnlyCount: Int { aiCacheGroups.filter { $0.blockedReason != nil || $0.allocatedSize == nil }.count }
    var aiCacheSelectedCount: Int { aiCacheGroups.filter { selection.contains($0.id) }.count }
    var aiCacheSelectedSize: Int64 { aiCacheGroups.filter { selection.contains($0.id) }.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    var otherCacheSelectableSize: Int64 { otherCacheGroups.filter { $0.blockedReason == nil }.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    var otherCacheSelectableCount: Int { otherCacheGroups.filter { $0.blockedReason == nil && $0.allocatedSize != nil }.count }
    var otherCacheReadOnlyCount: Int { otherCacheGroups.filter { $0.blockedReason != nil || $0.allocatedSize == nil }.count }
    var otherCacheSelectedCount: Int { otherCacheGroups.filter { selection.contains($0.id) }.count }
    /// 发现缓存的 AI 工具名（去重、保持规则顺序）。
    var aiToolNames: [String] {
        var seen = Set<String>()
        return aiCacheGroups.compactMap { $0.rule.aiToolName }.filter { seen.insert($0).inserted }
    }
    var largestItems: [CleanupItemSummary] {
        largestCleanupItems(allGroups, id: \.id, name: \.name, size: \.allocatedSize, blocked: { $0.blockedReason != nil })
    }
    func selectLargest(limit: Int = 50) {
        guard !closed, !busy, !otherBusy(), !scanFailed else { return }
        selection = Set(selectableGroups.prefix(limit).map(\.id))
    }
    var canClean: Bool {
        !closed && !busy && !otherBusy() && !scanFailed && !selection.isEmpty && selection.count <= 50 &&
        selectedGroups.count == selection.count && selectedGroups.allSatisfy { $0.blockedReason == nil && $0.allocatedSize != nil }
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, cacheDirectory: URL,
         activity: (@Sendable (DeveloperCleanupRule, URL) -> String?)? = nil,
         browserRunning: @escaping @Sendable (String) -> Bool = CacheCatalog.isRunning,
         quitApplication: @escaping @Sendable (String, URL?) -> String? = { ApplicationCloser.close(identifier: $0, applicationURL: $1) }) {
        self.home = home; self.activity = activity; self.browserRunning = browserRunning; self.quitApplication = quitApplication; backend = State(directory: cacheDirectory)
    }

    nonisolated private func resolveSnapshot() -> (activity: @Sendable (DeveloperCleanupRule, URL) -> String?, advisory: (@Sendable (DeveloperCleanupRule) -> String?)?) {
        if let custom = activity {
            let act: @Sendable (DeveloperCleanupRule, URL) -> String? = { [browserRunning] rule, path in
                if let id = rule.browserIdentifier, browserRunning(id) { return nil }
                return custom(rule, path)
            }
            return (act, nil)
        }
        let snapshot = DeveloperCleanupActivity.snapshot()
        let act: @Sendable (DeveloperCleanupRule, URL) -> String? = { [browserRunning] rule, path in
            if let id = rule.browserIdentifier, browserRunning(id) { return nil }
            return snapshot.blockedReason(rule, path)
        }
        let adv: @Sendable (DeveloperCleanupRule) -> String? = { rule in
            snapshot.advisoryReason(rule)
        }
        return (act, adv)
    }

    func select(_ id: String, selected: Bool) {
        guard !closed, !busy, !otherBusy(), !scanFailed, let group = groups.first(where: { $0.id == id }),
              group.blockedReason == nil, group.allocatedSize != nil else { return }
        if selected { selection.insert(id) } else { selection.remove(id) }
    }
    func discardResults() {
        guard !closed, !busy else { return }
        generation = UUID(); token?.cancel(); selection = []; confirmation = nil
        allGroups = []; groups = []; errors = []; results = []; progress = nil; message = nil
        incomplete = false; scanFailed = false; offset = 0; canNext = false; status = localized("等待本次扫描")
        let backend = backend
        backend.disk.queue.async { backend.cleaner = nil }
    }

    func start() {
        guard !closed, !operating, !loading, !otherBusy() else { return }
        token?.cancel(); timer?.invalidate()
        let run = UUID(); generation = run
        let cancellation = CancellationToken(); token = cancellation
        scanning = true; status = localized("检查开发与浏览器缓存路径…"); selection = []; confirmation = nil
        allGroups = []; groups = []; errors = []; results = []; progress = nil; incomplete = false; scanFailed = false; offset = 0; canNext = false
        let backend = backend, home = home
        _ = backend.disk.mailbox.take()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.scanning else { return }; self.progress = self.backend.disk.mailbox.take(for: self.generation) ?? self.progress }
        }
        backend.disk.queue.async { [weak self] in
            do {
                backend.cleaner = nil
                let cleaner = DeveloperCleanup(index: try backend.disk.makeIndex(), home: home)
                backend.cleaner = cleaner
                let result = try cleaner.scan(token: cancellation) { backend.disk.mailbox.put($0, generation: run) }
                let probe = self?.resolveSnapshot()
                let values = try cleaner.refresh(activity: probe?.activity, advisory: probe?.advisory)
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.timer?.invalidate(); self.timer = nil; self.scanning = false
                    self.progress = backend.disk.mailbox.take(for: run) ?? self.progress
                    self.allGroups = values; self.load(offset: 0)
                    self.incomplete = result.summary.cancelled || result.summary.errors > 0
                    self.errors = Array(result.summary.errorExamples.prefix(100))
                    self.status = result.summary.cancelled ? localized("检查已取消 · 结果不完整") : self.incomplete ? localized("检查不完整 · 可清理已核验项目") : values.isEmpty ? localized("固定缓存路径均无可展示数据") : localized("检查完成 · \(values.count) 项 · 默认未选中")
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.timer?.invalidate(); self.timer = nil; self.scanning = false
                    self.scanFailed = true; self.incomplete = true; self.status = localized("开发缓存检查失败 · 禁止清理"); self.errors = [text]; self.message = text
                }
            }
        }
    }
    func cancel() { token?.cancel(); if scanning { status = localized("正在停止开发缓存检查…") } }
    func load(offset: Int) {
        guard !closed, !busy else { return }
        self.offset = max(0, min(offset, allGroups.count)); selection = []
        groups = Array(allGroups.dropFirst(self.offset).prefix(100)); canNext = self.offset + groups.count < allGroups.count
    }
    func recheck() {
        guard !closed, !busy, !otherBusy() else { return }
        loading = true; selection = []; confirmation = nil
        let run = generation, backend = backend
        backend.disk.queue.async { [weak self] in
            do {
                let probe = self?.resolveSnapshot()
                let values = try backend.cleaner?.refresh(activity: probe?.activity, advisory: probe?.advisory) ?? []
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.allGroups = values; self.load(offset: self.offset)
                    self.status = localized("活动状态已复核；内容变化需要重新扫描")
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.selection = []; self.incomplete = true; self.scanFailed = true; self.message = text
                }
            }
        }
    }
    func prepareCleanup() { guard canClean else { return }; confirmation = DeveloperCleanupConfirmation(generation: generation, groups: selectedGroups) }
    func dismissConfirmation() { confirmation = nil }
    func executeCleanup() {
        guard !closed, !busy, !otherBusy(), !scanFailed, let frozen = confirmation, frozen.generation == generation else { return }
        confirmation = nil; operating = true; status = localized("正在移到废纸篓…")
        let run = generation, backend = backend, activity = activity, browserRunning = browserRunning, quit = quitApplication, record = recordOperation
        let cancellation = CancellationToken(); token = cancellation
        backend.disk.queue.async { [weak self] in
            var results: [TrashResult] = []
            let moveActivity: @Sendable (DeveloperCleanupRule, URL) -> String?
            if let custom = activity {
                moveActivity = { rule, path in
                    if let id = rule.browserIdentifier, browserRunning(id) { return nil }
                    return custom(rule, path)
                }
            } else {
                moveActivity = { rule, path in
                    if let id = rule.browserIdentifier, browserRunning(id) { return nil }
                    return DeveloperCleanupActivity.blockedReason(rule, path)
                }
            }
            for group in frozen.groups {
                do {
                    guard !cancellation.isCancelled, let cleaner = backend.cleaner else { throw MacEvenError(localized("操作已取消或开发缓存索引不可用。")) }
                    if let id = group.rule.browserIdentifier {
                        let wasRunning = browserRunning(id)
                        let probe = self?.resolveSnapshot()
                        guard let ready = try cleaner.refresh(activity: probe?.activity, advisory: probe?.advisory).first(where: { $0.id == group.id }), ready.blockedReason == nil else { throw MacEvenError(localized("浏览器缓存受保护或已变化，请重新检查。")) }
                        if let reason = quit(id, nil) { throw MacEvenError(reason) }
                        guard !cancellation.isCancelled, !browserRunning(id) else { throw MacEvenError(localized("浏览器尚未退出或操作已取消，缓存已保留。")) }
                        if wasRunning { try cleaner.rescanBrowserAfterQuit(groupID: group.id, token: cancellation, activity: moveActivity) }
                    }
                    guard !cancellation.isCancelled else { throw MacEvenError(localized("操作已取消，内容已保留。")) }
                    results += cleaner.move(groupIDs: [group.id], activity: moveActivity)
                } catch { results.append(TrashResult(id: 0, path: group.id, destination: nil, error: error.localizedDescription)) }
            }
            record?(results)
            let probe = self?.resolveSnapshot()
            let values = try? backend.cleaner?.refresh(activity: probe?.activity, advisory: probe?.advisory)
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.generation == run else { return }
                self.operating = false; self.results = results; self.selection = []
                if let values { self.allGroups = values; self.load(offset: self.offset) }
                else { self.allGroups = []; self.groups = []; self.incomplete = true }
                self.status = localized("已移到废纸篓 \(results.filter { $0.destination != nil }.count) 个开发缓存路径") + (results.contains { $0.error != nil } ? localized(" · 部分已保留或操作失败") : "")
            }
        }
    }
    func shutdown(_ completion: @escaping @MainActor @Sendable (String?) -> Void) {
        closed = true; token?.cancel(); generation = UUID(); timer?.invalidate(); timer = nil
        confirmation = nil; selection = []; scanning = false
        let backend = backend
        backend.disk.queue.async {
            backend.cleaner = nil
            var error: String?
            do { try backend.disk.finish() } catch let failure { error = failure.localizedDescription }
            let result = error
            Task { @MainActor in completion(result) }
        }
    }
}
