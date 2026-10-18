import Foundation
import AppKit
import Combine
import MacEvenCore

/// 某一时刻的应用归属判断；目录枚举不完整时整次结果禁止清理。
struct LeftoverOwnershipSnapshot: Sendable {
    let check: @Sendable (String) -> LeftoverOwnership
    let incomplete: Bool
    let errors: [String]
}

enum LeftoverCatalog {
    static func vendor(_ id: String) -> String { id.lowercased().split(separator: ".").prefix(2).joined(separator: ".") }

    /// 已安装（含父子标识）不列出；系统仍能找到的应用视为已安装；运行中、有启动项引用或同厂商应用仍在时只读。
    /// 启动项标签用于识别没有 .app 的命令行工具与后台服务。
    static func ownership(installedIdentifiers: [String], launchdLabels: [String] = [],
                          launchServices: @escaping @Sendable (String) -> Bool = LeftoverCatalog.launchServicesKnows,
                          running: @escaping @Sendable (String) -> Bool = LeftoverCatalog.isRunning) -> @Sendable (String) -> LeftoverOwnership {
        let installed = Set(installedIdentifiers.map { $0.lowercased() })
        let labels = Set(launchdLabels.map { $0.lowercased() })
        var vendors: [String: String] = [:]
        for id in installedIdentifiers.sorted() where vendors[vendor(id)] == nil { vendors[vendor(id)] = id }
        let samples = vendors
        return { id in
            let lower = id.lowercased()
            if installed.contains(lower) || installed.contains(where: { $0.hasPrefix(lower + ".") || lower.hasPrefix($0 + ".") }) { return .installed }
            if launchServices(id) { return .installed }
            if running(id) { return .review(localized("相关进程正在运行，残留保留。")) }
            if labels.contains(where: { $0 == lower || $0.hasPrefix(lower + ".") || lower.hasPrefix($0 + ".") }) {
                return .review(localized("有启动项（LaunchAgent / LaunchDaemon）引用该标识，可能仍在使用，保留。"))
            }
            if let sample = samples[vendor(lower)] { return .review(localized("同厂商应用 \(sample) 仍已安装，数据可能共享，仅供查看。")) }
            return .orphan
        }
    }

    static func launchServicesKnows(_ id: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path) && !url.path.contains("/.Trash/")
    }

    static func isRunning(_ id: String) -> Bool {
        let lower = id.lowercased()
        return NSWorkspace.shared.runningApplications.contains {
            guard !$0.isTerminated, let actual = $0.bundleIdentifier?.lowercased() else { return false }
            return actual == lower || actual.hasPrefix(lower + ".")
        }
    }

    /// 启动项 plist 文件名即标签；读取失败的目录跳过（只会少一个保留信号，不会扩大删除范围之外的判断）。
    static func launchdLabels(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        var labels: [String] = []
        for directory in [home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.prefix(4096) where name.hasSuffix(".plist") { labels.append(String(name.dropLast(6))) }
        }
        return labels
    }

    static func live() -> LeftoverOwnershipSnapshot {
        let catalog = CacheCatalog.discover()
        return LeftoverOwnershipSnapshot(check: ownership(installedIdentifiers: catalog.applications.map(\.id), launchdLabels: launchdLabels()),
            incomplete: catalog.truncated || !catalog.errors.isEmpty, errors: (catalog.truncated ? [localized("应用目录达到扫描上限，无法完整确认卸载残留归属。")] : []) + catalog.errors)
    }
}

struct LeftoverConfirmation: Identifiable, Equatable {
    let id = UUID()
    let generation: UUID
    let groups: [LeftoverGroup]
    var allocatedSize: Int64 { groups.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
}

@MainActor final class LeftoverModel: ObservableObject {
    private final class State: @unchecked Sendable {
        let disk: DiskBackend
        var leftovers: OrphanLeftovers?
        init(directory: URL) { disk = DiskBackend(cache: directory) }
    }
    @Published private(set) var groups: [LeftoverGroup] = []
    @Published private(set) var selection = Set<String>()
    @Published private(set) var scanning = false
    @Published private(set) var operating = false
    @Published private(set) var loading = false
    @Published private(set) var status = localized("准备扫描已卸载应用留下的数据")
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var incomplete = false
    private(set) var scanFailed = false
    @Published private(set) var errors: [String] = []
    @Published private(set) var results: [TrashResult] = []
    @Published private(set) var confirmation: LeftoverConfirmation?
    @Published private(set) var offset = 0
    @Published private(set) var canNext = false
    @Published var message: String?
    var otherBusy: @MainActor () -> Bool = { false }
    /// 移动结束时在后台队列同步调用；退出期间完成的移动也会写入操作日志。
    var recordOperation: (@Sendable ([TrashResult]) -> Void)?
    private var allGroups: [LeftoverGroup] = []
    private let backend: State
    private let home: URL
    private let snapshot: @Sendable () -> LeftoverOwnershipSnapshot
    private var generation = UUID()
    private var token: CancellationToken?
    private var timer: Timer?
    private var closed = false
    var busy: Bool { scanning || operating || loading }
    /// 扫描中按候选单元计算的进度；未开始统计或已结束时为未知。
    var progressEstimate: ProgressEstimate { scanning ? (progress?.unitEstimate ?? .unknown) : .unknown }
    var selectedGroups: [LeftoverGroup] { allGroups.filter { selection.contains($0.id) } }
    var selectableCount: Int { allGroups.filter { $0.blockedReason == nil && $0.allocatedSize != nil }.count }
    var selectableSize: Int64 { allGroups.filter { $0.blockedReason == nil }.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }
    var restrictions: [CleanupRestrictionSummary] { cleanupRestrictions(allGroups, reason: \.blockedReason, size: \.allocatedSize) }
    var readOnlyCount: Int { allGroups.filter { $0.blockedReason != nil || $0.allocatedSize == nil }.count }
    // 残留以 bundle 标识命名，与残留列表一致。
    var largestItems: [CleanupItemSummary] {
        largestCleanupItems(allGroups, id: \.id, name: \.id, size: \.allocatedSize, blocked: { $0.blockedReason != nil })
    }
    func selectLargest(limit: Int = 50) {
        guard !closed, !busy, !otherBusy(), !incomplete else { return }
        selection = Set(allGroups.filter { $0.blockedReason == nil && $0.allocatedSize != nil }.prefix(limit).map(\.id))
    }
    var canClean: Bool {
        !closed && !busy && !otherBusy() && !incomplete && !selection.isEmpty && selection.count <= 50 &&
        selectedGroups.count == selection.count && selectedGroups.allSatisfy { $0.blockedReason == nil && $0.allocatedSize != nil }
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, cacheDirectory: URL,
         snapshot: @escaping @Sendable () -> LeftoverOwnershipSnapshot = LeftoverCatalog.live) {
        self.home = home; self.snapshot = snapshot; backend = State(directory: cacheDirectory)
    }

    func select(_ id: String, selected: Bool) {
        guard !closed, !busy, !otherBusy(), !incomplete, let group = allGroups.first(where: { $0.id == id }),
              group.blockedReason == nil, group.allocatedSize != nil else { return }
        if selected { guard selection.count < 50 else { message = localized("一次最多选择 50 个标识。"); return }; selection.insert(id) } else { selection.remove(id) }
    }

    func discardResults() {
        guard !closed, !busy else { return }
        generation = UUID(); token?.cancel(); selection = []; confirmation = nil
        allGroups = []; groups = []; errors = []; results = []; progress = nil; message = nil
        incomplete = false; scanFailed = false; offset = 0; canNext = false; status = localized("等待本次扫描")
        let backend = backend
        backend.disk.queue.async { backend.leftovers = nil }
    }

    func start() {
        guard !closed, !operating, !loading, !otherBusy() else { return }
        token?.cancel(); timer?.invalidate()
        let run = UUID(); generation = run
        let cancellation = CancellationToken(); token = cancellation
        scanning = true; status = localized("扫描 ~/Library 中的应用残留…"); selection = []; confirmation = nil
        allGroups = []; groups = []; errors = []; results = []; progress = nil; incomplete = false; scanFailed = false; offset = 0; canNext = false
        let backend = backend, home = home, snapshot = snapshot
        _ = backend.disk.mailbox.take()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.scanning else { return }; self.progress = self.backend.disk.mailbox.take(for: self.generation) ?? self.progress }
        }
        backend.disk.queue.async { [weak self] in
            do {
                backend.leftovers = nil
                let owner = snapshot()
                let leftovers = OrphanLeftovers(index: try backend.disk.makeIndex(), home: home)
                backend.leftovers = leftovers
                let result = try leftovers.scan(token: cancellation, ownership: owner.check) { backend.disk.mailbox.put($0, generation: run) }
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.timer?.invalidate(); self.timer = nil; self.scanning = false
                    self.progress = backend.disk.mailbox.take(for: run) ?? self.progress
                    self.allGroups = result.groups; self.load(offset: 0)
                    self.incomplete = result.summary.cancelled || result.summary.errors > 0 || result.truncated || owner.incomplete
                    self.errors = Array(((result.truncated ? [localized("残留候选达到扫描上限，结果未覆盖全部位置。")] : []) + owner.errors + result.summary.errorExamples).prefix(100))
                    let selectable = result.groups.filter { $0.blockedReason == nil }.count
                    self.status = result.summary.cancelled ? localized("扫描已取消 · 结果不完整") : self.incomplete ? localized("扫描不完整 · 禁止清理") :
                        result.groups.isEmpty ? localized("没有发现已卸载应用留下的数据") : localized("扫描完成 · \(result.groups.count) 个标识，\(selectable) 个可选 · 默认未选中")
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.timer?.invalidate(); self.timer = nil; self.scanning = false
                    self.scanFailed = true; self.incomplete = true; self.status = localized("残留扫描失败 · 禁止清理"); self.errors = [text]; self.message = text
                }
            }
        }
    }
    func cancel() { token?.cancel(); if scanning { status = localized("正在停止残留扫描…") } }
    func load(offset: Int) {
        guard !closed else { return }
        self.offset = max(0, min(offset, allGroups.count))
        groups = Array(allGroups.dropFirst(self.offset).prefix(100)); canNext = self.offset + groups.count < allGroups.count
    }
    func recheck() {
        guard !closed, !busy, !otherBusy() else { return }
        loading = true; selection = []; confirmation = nil; status = localized("复核应用安装与运行状态…")
        let run = generation, backend = backend, snapshot = snapshot
        backend.disk.queue.async { [weak self] in
            do {
                let owner = snapshot()
                let values = try backend.leftovers?.refresh(ownership: owner.check) ?? []
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.allGroups = values; self.load(offset: self.offset)
                    if owner.incomplete { self.incomplete = true }
                    self.status = localized("安装与运行状态已复核；内容变化需要重新扫描")
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.incomplete = true; self.message = text
                }
            }
        }
    }
    func prepareCleanup() { guard canClean else { return }; confirmation = LeftoverConfirmation(generation: generation, groups: selectedGroups) }
    func dismissConfirmation() { confirmation = nil }
    func executeCleanup() {
        guard !closed, !busy, !otherBusy(), !incomplete, let frozen = confirmation, frozen.generation == generation else { return }
        confirmation = nil; operating = true; status = localized("复核归属并移到废纸篓…")
        let ids = frozen.groups.map(\.id), run = generation, backend = backend, snapshot = snapshot, record = recordOperation
        backend.disk.queue.async { [weak self] in
            // 执行前重新取得归属快照：扫描后重新安装或启动的应用会让对应残留保留。
            let owner = snapshot()
            let results: [TrashResult]
            if owner.incomplete { results = [TrashResult(id: 0, path: "", destination: nil, error: localized("应用目录枚举不完整，无法确认归属，残留全部保留。"))] }
            else { results = backend.leftovers?.move(groupIDs: ids, ownership: owner.check) ?? [TrashResult(id: 0, path: "", destination: nil, error: localized("残留索引不可用，请重新扫描。"))] }
            record?(results)
            let values = try? backend.leftovers?.refresh(ownership: owner.check)
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.generation == run else { return }
                self.operating = false; self.results = results; self.selection = []
                if let values { self.allGroups = values; self.load(offset: self.offset) }
                else { self.allGroups = []; self.groups = []; self.incomplete = true }
                self.status = localized("已移到废纸篓 \(results.filter { $0.destination != nil }.count) 个残留路径") + (results.contains { $0.error != nil } ? localized(" · 部分已保留或操作失败") : "")
            }
        }
    }
    func shutdown(_ completion: @escaping @MainActor @Sendable (String?) -> Void) {
        closed = true; token?.cancel(); generation = UUID(); timer?.invalidate(); timer = nil
        confirmation = nil; selection = []; scanning = false
        let backend = backend
        backend.disk.queue.async {
            backend.leftovers = nil
            var error: String?
            do { try backend.disk.finish() } catch let failure { error = failure.localizedDescription }
            let result = error
            Task { @MainActor in completion(result) }
        }
    }
}
