import Foundation
import AppKit
import Combine
import MacEvenCore

enum ApplicationRemovalMode: String, CaseIterable {
    case appOnly = "仅删除 App"
    case includingData = "彻底卸载（含关联数据）"
}

/// 应用列表排序方式：默认按应用本体大小，检测过关联数据后可改按「本体 + 数据」合计。
enum ApplicationSortMode: String, CaseIterable {
    case bundleSize = "本体大小"
    case totalSize = "本体 + 数据"
}

struct ApplicationConfirmation: Identifiable, Equatable {
    let id = UUID()
    let generation: UUID
    let applications: [InstalledApplication]
    /// 彻底卸载时每个应用一份冻结计划；仅删除 App 时为空。
    let dataPlans: [ApplicationDataPlan]
    let relatedData: ApplicationDataPreview?
    let includingData: Bool
    /// 确认时 Dock 中指向这些应用的图标；执行时只移除成功移走的应用的图标。
    let dockMatches: [DockTileMatch]
    var application: InstalledApplication { applications[0] }
    var allocatedSize: Int64 { applications.reduce(0) { $0 + ($1.allocatedSize ?? 0) } + dataPlans.reduce(0) { $0 + $1.allocatedSize } }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor final class ApplicationRemovalModel: ObservableObject {
    private final class State: @unchecked Sendable {
        let disk: DiskBackend
        var remover: ApplicationRemoval?
        init(directory: URL) { disk = DiskBackend(cache: directory) }
    }
    @Published private(set) var applications: [InstalledApplication] = []
    @Published var selection: String? {
        didSet {
            if selection != oldValue { relatedData = nil; if inspectingData { token?.cancel() } }
        }
    }
    @Published var removalMode: ApplicationRemovalMode = .appOnly
    /// 批量卸载的勾选（跨页保留，最多 20 个）；为空时对当前选中的单个应用操作。
    @Published private(set) var checked = Set<String>()
    @Published var removeFromDock = true
    @Published private(set) var dockMessage: String?
    let leftovers: LeftoverModel
    private var leftoverChanges: AnyCancellable?
    private let dock: DockCleaner?
    static let batchLimit = 20
    @Published private(set) var scanning = false
    @Published private(set) var operating = false
    @Published private(set) var loading = false
    @Published private(set) var preparingData = false
    @Published private(set) var inspectingData = false
    /// 一次性检测全部应用数据；只读，可取消。
    @Published private(set) var inspectingAll = false
    @Published private(set) var inspectingAllProgress: (done: Int, total: Int)?
    @Published private(set) var inspectingAllName = ""
    /// 未检测关联数据的应用及原因：受保护、标识无法识别、大小未统计或该应用检测失败。
    @Published private(set) var dataSkips: [String: String] = [:]
    @Published private(set) var dataWarnings: [String] = []
    @Published private(set) var relatedData: ApplicationDataPreview?
    /// 已检查过的每个应用的关联数据；展开或确认后保留，供列表与操作栏显示统计。
    @Published private(set) var previews: [String: ApplicationDataPreview] = [:]
    /// 应用列表排序方式；检测完成后自动切到「本体 + 数据」。
    @Published var sortMode: ApplicationSortMode = .bundleSize
    @Published private(set) var status = localized("准备扫描已安装应用")
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var incomplete = false
    @Published private(set) var errors: [String] = []
    @Published private(set) var results: [TrashResult] = []
    @Published private(set) var lastOperation: InstalledApplication?
    @Published private(set) var confirmation: ApplicationConfirmation?
    /// 按名称、标识或路径过滤已扫描的应用；只作用于内存中的有界列表，不触发重新扫描。
    @Published var search = "" { didSet { if search != oldValue { load(offset: 0) } } }
    @Published private(set) var offset = 0
    @Published private(set) var canNext = false
    @Published var message: String?
    private var allApplications: [InstalledApplication] = []
    private let backend: State
    private let home: URL
    private let roots: [URL]?
    private let isRunning: @Sendable (InstalledApplication) -> Bool
    private let quitApplication: @Sendable (String, URL?) -> String?
    private var generation = UUID()
    private var token: CancellationToken?
    private var timer: Timer?
    private var closed = false
    /// 移动结束时在后台队列同步调用；退出期间完成的移动也会写入操作日志。
    var recordOperation: (@Sendable ([TrashResult]) -> Void)?
    var busy: Bool { scanning || operating || loading || inspectingAll || leftovers.busy }
    /// 扫描中按候选单元计算的进度；未开始统计或已结束时为未知。
    var progressEstimate: ProgressEstimate { scanning ? (progress?.unitEstimate ?? .unknown) : .unknown }
    /// 批量检测关联数据的进度；未在检测时为未知。
    var dataProgressEstimate: ProgressEstimate {
        inspectingAll ? .units(inspectingAllProgress?.done ?? 0, of: inspectingAllProgress?.total ?? 0) : .unknown
    }
    var selected: InstalledApplication? { applications.first { $0.id == selection } }
    var targets: [InstalledApplication] { checked.isEmpty ? selected.map { [$0] } ?? [] : allApplications.filter { checked.contains($0.id) } }
    func preview(for id: String) -> ApplicationDataPreview? { previews[id] }
    /// 该应用未检测关联数据的原因；已检测或尚未检测过时为 nil。
    func dataSkipReason(for id: String) -> String? { dataSkips[id] }
    /// 未检测数据的应用与原因，按应用名排序；供高级模式展开查看。
    var dataSkipRows: [(name: String, reason: String)] {
        dataSkips.map { id, reason in (allApplications.first { $0.id == id }?.name ?? id, reason) }.sorted { $0.0 < $1.0 }
    }
    /// 可检测关联数据的应用数（受保护、标识无法识别与大小未统计的应用除外）。
    var inspectableCount: Int { allApplications.filter(canInspect).count }
    var inspectedDataCount: Int { previews.count }
    /// 「本体 + 数据」合计；未检测数据的应用按本体大小参与排序，界面上如实标明。
    func totalSize(of app: InstalledApplication) -> Int64 { (app.allocatedSize ?? 0) + (previews[app.id]?.allocatedSize ?? 0) }
    /// 所选应用的关联数据统计：将清理、保留，以及尚未检查的应用数。
    var targetDataTotals: (included: Int64, retained: Int64, unknown: Int) {
        var included: Int64 = 0, retained: Int64 = 0, unknown = 0
        for app in targets {
            guard let preview = previews[app.id] else { unknown += 1; continue }
            included += preview.includedSize; retained += preview.retainedSize
        }
        return (included, retained, unknown)
    }
    var canRemove: Bool {
        let values = targets
        return !closed && !busy && !values.isEmpty && values.count <= Self.batchLimit && (checked.isEmpty || values.count == checked.count) &&
            values.allSatisfy { $0.blockedReason == nil && $0.allocatedSize != nil }
    }
    /// 关联数据检测的准入判断：系统应用、MacEven 自身、无法识别标识与大小未统计的应用只读。
    private func canInspect(_ app: InstalledApplication) -> Bool {
        guard app.allocatedSize != nil, !app.bundleIdentifier.isEmpty else { return false }
        let identifier = app.bundleIdentifier.lowercased()
        return !identifier.hasPrefix("com.apple.") && !identifier.hasPrefix("local.maceven")
    }
    var canInspectData: Bool {
        guard !closed, !busy, let selected else { return false }
        return canInspect(selected)
    }
    /// 一键检测全部应用数据；结果只用于统计与排序，不改变任何可卸载范围。
    var canInspectAllData: Bool { !closed && !busy && !incomplete && inspectableCount > 0 }

    nonisolated static func running(_ application: InstalledApplication) -> Bool {
        NSWorkspace.shared.runningApplications.contains { running in
            guard !running.isTerminated else { return false }
            if let id = running.bundleIdentifier, id == application.bundleIdentifier || id.hasPrefix(application.bundleIdentifier + ".") { return true }
            if running.bundleURL?.resolvingSymlinksInPath().path == application.url.path { return true }
            return running.executableURL?.resolvingSymlinksInPath().path.hasPrefix(application.url.path + "/") == true
        }
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, roots: [URL]? = nil, cacheDirectory: URL? = nil,
        isRunning: @escaping @Sendable (InstalledApplication) -> Bool = ApplicationRemovalModel.running,
        quitApplication: @escaping @Sendable (String, URL?) -> String? = { ApplicationCloser.close(identifier: $0, applicationURL: $1) },
        dock: DockCleaner? = .live, leftoverSnapshot: @escaping @Sendable () -> LeftoverOwnershipSnapshot = LeftoverCatalog.live) {
        self.home = home; self.roots = roots; self.isRunning = isRunning; self.quitApplication = quitApplication; self.dock = dock
        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacEven/application-sessions")
        backend = State(directory: directory)
        leftovers = LeftoverModel(home: home, cacheDirectory: directory.appendingPathComponent("leftovers"), snapshot: leftoverSnapshot)
        leftovers.otherBusy = { [weak self] in self.map { $0.scanning || $0.operating || $0.loading } ?? true }
        leftoverChanges = leftovers.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func check(_ id: String, selected: Bool) {
        guard !closed, !busy else { return }
        if !selected { checked.remove(id); return }
        guard let app = allApplications.first(where: { $0.id == id }), app.blockedReason == nil, app.allocatedSize != nil else { return }
        guard checked.count < Self.batchLimit else { message = localized("一次最多卸载 \(Self.batchLimit) 个应用。"); return }
        checked.insert(id)
    }
    func clearChecked() { checked = [] }

    func start() {
        guard !closed && !operating && !leftovers.busy else { return }
        token?.cancel(); timer?.invalidate()
        let run = UUID(); generation = run
        let cancellation = CancellationToken(); token = cancellation
        scanning = true; loading = false; preparingData = false; inspectingData = false; relatedData = nil; selection = nil; confirmation = nil; status = localized("扫描应用包…")
        allApplications = []; applications = []; results = []; lastOperation = nil; errors = []; progress = nil; incomplete = false; offset = 0; canNext = false; checked = []; dockMessage = nil; previews = [:]
        sortMode = .bundleSize; inspectingAll = false; inspectingAllProgress = nil; inspectingAllName = ""; dataSkips = [:]; dataWarnings = []
        let backend = backend, home = home, roots = roots
        _ = backend.disk.mailbox.take()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.scanning else { return }; self.progress = self.backend.disk.mailbox.take(for: self.generation) ?? self.progress }
        }
        backend.disk.queue.async { [weak self] in
            do {
                backend.remover = nil
                let remover = ApplicationRemoval(index: try backend.disk.makeIndex(), home: home, roots: roots)
                backend.remover = remover
                let result = try remover.scan(token: cancellation) { backend.disk.mailbox.put($0, generation: run) }
                let rows = try remover.refresh(isRunning: { _ in false })
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.timer?.invalidate(); self.timer = nil; self.scanning = false
                    self.progress = backend.disk.mailbox.take(for: run) ?? self.progress
                    self.allApplications = rows; self.load(offset: 0); self.incomplete = result.incomplete; self.errors = result.errors
                    self.status = result.incomplete ? localized("扫描不完整 · 请解决访问问题后重新扫描") : localized("扫描完成 · \(rows.count) 个应用")
                }
            } catch { self?.publishFailure(error.localizedDescription, generation: run) }
        }
    }
    nonisolated private func publishFailure(_ text: String, generation: UUID) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.generation == generation else { return }
            self.timer?.invalidate(); self.timer = nil; self.scanning = false; self.loading = false; self.preparingData = false; self.inspectingData = false; self.operating = false; self.inspectingAll = false
            self.status = localized("应用操作失败"); self.message = text
        }
    }
    func cancel() { token?.cancel(); leftovers.cancel(); if scanning || preparingData { status = localized("正在停止扫描…") } else if inspectingAll { status = localized("正在停止数据检测…") } }
    /// 搜索命中数基于全部已扫描应用，与分页无关。
    var matchedCount: Int { filteredApplications.count }
    var totalCount: Int { allApplications.count }
    private var filteredApplications: [InstalledApplication] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let list = query.isEmpty ? allApplications : allApplications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
                || $0.url.path.localizedCaseInsensitiveContains(query)
        }
        guard sortMode == .totalSize else { return list }
        // 「本体 + 数据」合计从大到小；未检测数据的应用按本体大小排在后面。
        return list.sorted { lhs, rhs in
            let left = totalSize(of: lhs), right = totalSize(of: rhs)
            if left != right { return left > right }
            let leftBundle = lhs.allocatedSize ?? -1, rightBundle = rhs.allocatedSize ?? -1
            if leftBundle != rightBundle { return leftBundle > rightBundle }
            return lhs.id < rhs.id
        }
    }
    func load(offset: Int) {
        let list = filteredApplications
        self.offset = max(0, min(offset, list.count)); selection = nil
        applications = Array(list.dropFirst(self.offset).prefix(100)); canNext = self.offset + applications.count < list.count
    }
    func recheck() {
        guard !closed && !busy else { return }
        loading = true; selection = nil; confirmation = nil; checked = []
        let run = generation, backend = backend
        backend.disk.queue.async { [weak self] in
            do {
                let rows = try backend.remover?.refresh(isRunning: { _ in false }) ?? []
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.allApplications = rows; self.load(offset: self.offset); self.status = localized("运行状态已检查；内容变化仍需重新扫描")
                }
            } catch { self?.publishFailure(error.localizedDescription, generation: run) }
        }
    }
    func inspectAllData() {
        guard canInspectAllData else { return }
        loading = true; inspectingAll = true; inspectingAllProgress = (0, inspectableCount); inspectingAllName = ""
        dataSkips = [:]; dataWarnings = []
        status = localized("正在检测全部应用的数据（只读，可取消）…")
        let run = generation, backend = backend
        let cancellation = CancellationToken(); token = cancellation
        backend.disk.queue.async { [weak self] in
            // 不可变绑定：进度回调是 @Sendable，闭包里不能再引用可变的弱引用 self。
            let model = self
            do {
                guard let remover = backend.remover else { throw MacEvenError(localized("应用索引不可用。")) }
                let result = try remover.inspectAllRelatedData(token: cancellation) { progress in
                    Task { @MainActor in
                        guard let model, !model.closed, model.generation == run, model.inspectingAll else { return }
                        model.inspectingAllProgress = (progress.done, progress.total)
                        model.inspectingAllName = progress.applicationName
                        // 逐个应用填充大小，列表顺序在检测完成后才更新。
                        if let preview = progress.preview { model.previews[preview.applicationID] = preview }
                    }
                }
                Task { @MainActor in
                    guard let model, !model.closed, model.generation == run else { return }
                    model.finishDataInspection(result)
                }
            } catch {
                guard let model else { return }
                model.publishFailure(error.localizedDescription, generation: run)
            }
        }
    }
    private func finishDataInspection(_ result: ApplicationDataBulkResult) {
        inspectingAll = false; loading = false; inspectingAllName = ""
        for preview in result.previews { previews[preview.applicationID] = preview }
        dataSkips = result.skipped; dataWarnings = result.warnings
        let checked = result.previews.count
        if result.cancelled {
            status = checked == 0 ? localized("数据检测已取消") : localized("数据检测已取消 · 已检测 \(checked) 个应用")
        } else if checked == 0 {
            status = localized("没有可检测关联数据的应用")
        } else {
            sortMode = .totalSize
            status = localized("已检测 \(checked) 个应用的数据 · 按 本体 + 数据 排序")
                + (result.skipped.isEmpty ? "" : localized(" · \(result.skipped.count) 个应用仅按本体大小"))
        }
        load(offset: offset)
    }
    func inspectRelatedData() {
        guard canInspectData, let selected else { return }
        loading = true; preparingData = true; inspectingData = true; relatedData = nil; confirmation = nil
        status = localized("正在检查关联数据与大小…")
        let run = generation, backend = backend
        let cancellation = CancellationToken(); token = cancellation
        backend.disk.queue.async { [weak self] in
            do {
                guard let remover = backend.remover else { throw MacEvenError(localized("应用索引不可用。")) }
                let preview = try remover.inspectRelatedData(id: selected.id, token: cancellation)
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.preparingData = false; self.inspectingData = false
                    guard self.selection == selected.id else { self.status = localized("应用选择已变化，请重新检查关联数据"); return }
                    guard !cancellation.isCancelled else { self.status = localized("关联数据检查已取消"); return }
                    self.previews[selected.id] = preview
                    self.relatedData = preview; self.status = localized("关联数据已检查 · \(preview.items.count) 项")
                }
            } catch {
                let text = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.preparingData = false; self.inspectingData = false
                    guard self.selection == selected.id else { self.status = localized("应用选择已变化，请重新检查关联数据"); return }
                    if cancellation.isCancelled { self.status = localized("关联数据检查已取消") }
                    else { self.status = localized("关联数据检查失败"); self.message = text }
                }
            }
        }
    }
    func isApplicationRunning(_ application: InstalledApplication) -> Bool { isRunning(application) }
    func prepareRemoval() {
        guard canRemove else { return }
        let apps = targets, includingData = removalMode == .includingData, single = apps.count == 1
        let currentPreview = single && relatedData?.applicationID == apps[0].id ? relatedData : nil
        loading = true; preparingData = includingData; confirmation = nil; dockMessage = nil
        status = includingData ? localized("正在检查关联数据…") : localized("正在准备卸载确认…")
        let run = generation, backend = backend, dock = dock
        let cancellation = CancellationToken(); token = cancellation
        backend.disk.queue.async { [weak self] in
            do {
                guard let remover = backend.remover else { throw MacEvenError(localized("应用索引不可用。")) }
                var plans: [ApplicationDataPlan] = []
                var preview = currentPreview
                if includingData {
                    for app in apps {
                        guard !cancellation.isCancelled else { throw MacEvenError(localized("关联数据检查已取消。")) }
                        plans.append(try remover.prepareDataRemoval(id: app.id, token: cancellation, isRunning: { _ in false }))
                    }
                    if single { preview = try? remover.inspectRelatedData(id: apps[0].id, token: cancellation) }
                }
                let matches = dock?.matches(appPaths: apps.map(\.url.path), bundleIdentifiers: apps.map(\.bundleIdentifier)) ?? []
                let frozen = ApplicationConfirmation(generation: run, applications: apps, dataPlans: plans, relatedData: preview, includingData: includingData, dockMatches: matches)
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == run else { return }
                    self.loading = false; self.preparingData = false
                    guard !cancellation.isCancelled else { self.status = localized("关联数据检查已取消"); return }
                    self.status = includingData ? localized("关联数据已检查，请确认卸载范围") : localized("请确认卸载范围")
                    if single, let preview {
                        self.previews[apps[0].id] = preview
                        if self.selection == apps[0].id { self.relatedData = preview }
                    }
                    self.removeFromDock = true
                    self.confirmation = frozen
                }
            } catch { self?.publishFailure(error.localizedDescription, generation: run) }
        }
    }
    func dismissConfirmation() { confirmation = nil }
    func executeRemoval() {
        guard !closed, !busy, let frozen = confirmation, frozen.generation == generation else { return }
        confirmation = nil; operating = true; lastOperation = frozen.application; dockMessage = nil; status = localized("正在关闭运行中的应用并卸载；请完成应用中的保存提示…")
        let run = generation, backend = backend, running = isRunning, quit = quitApplication, record = recordOperation
        let cancellation = CancellationToken(); token = cancellation
        let dock = removeFromDock && !frozen.dockMatches.isEmpty ? self.dock : nil
        backend.disk.queue.async { [weak self] in
            var results: [TrashResult] = []
            var moved: [InstalledApplication] = []
            if let remover = backend.remover {
                // 逐个应用执行：单个失败不影响其他已确认应用，各自复核运行状态与文件身份。
                for app in frozen.applications {
                    let appResults: [TrashResult]
                    do {
                        guard !cancellation.isCancelled,
                            let ready = try remover.refresh(isRunning: { _ in false }).first(where: { $0.id == app.id }), ready.blockedReason == nil else { throw MacEvenError(localized("操作已取消或应用受保护，请重新扫描。")) }
                        let wasRunning = running(app)
                        if let reason = quit(app.bundleIdentifier, app.url) { throw MacEvenError(reason) }
                        guard !cancellation.isCancelled, !running(app) else { throw MacEvenError(localized("应用尚未退出或操作已取消，应用与数据已保留。")) }
                        if frozen.includingData {
                            guard var plan = frozen.dataPlans.first(where: { $0.applicationID == app.id }) else { throw MacEvenError(localized("缺少该应用的关联数据计划，请重新确认。")) }
                            if wasRunning { plan = try remover.rescanDataAfterQuit(plan: plan, token: cancellation, isRunning: running) }
                            appResults = remover.moveIncludingData(plan: plan, isRunning: running)
                        } else { appResults = [remover.move(id: app.id, isRunning: running)] }
                    } catch { appResults = [TrashResult(id: 0, path: app.id, destination: nil, error: error.localizedDescription)] }
                    if appResults.first.map({ $0.path == app.id && $0.destination != nil }) == true { moved.append(app) }
                    results += appResults
                }
            } else { results = [TrashResult(id: 0, path: frozen.application.id, destination: nil, error: localized("应用索引不可用，请重新扫描。"))] }
            record?(results)
            var dockText: String?
            if let dock, !moved.isEmpty {
                switch dock.remove(appPaths: moved.map(\.url.path), bundleIdentifiers: moved.map(\.bundleIdentifier)) {
                case .success(let count): dockText = count > 0 ? localized("已从 Dock 移除 \(count) 个图标") : nil
                case .failure(let error): dockText = localized("Dock 图标未移除：\(error.message)")
                }
            }
            let rows = try? backend.remover?.refresh(isRunning: { _ in false })
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.generation == run else { return }
                self.operating = false; self.results = results; self.checked = []; self.dockMessage = dockText
                for app in frozen.applications { self.previews[app.id] = nil; self.dataSkips[app.id] = nil }
                self.allApplications = rows ?? []; self.load(offset: self.offset)
                if rows == nil { self.incomplete = true }
                let suffix = dockText.map { " · \($0)" } ?? ""
                if let failure = results.first(where: { $0.error != nil }) {
                    self.status = "\(results.contains(where: { $0.destination != nil }) ? localized("部分内容已移走；其余内容保留") : localized("应用与数据已保留")) · \(failure.error!)" + suffix
                } else if frozen.applications.count > 1 {
                    self.status = localized("已将 \(moved.count) 个应用") + (frozen.includingData ? localized("及确认的关联数据") : "") + localized("移到废纸篓") + suffix
                } else {
                    self.status = (frozen.includingData ? localized("App 与已确认的关联数据已移到废纸篓；未识别及共享内容保留") : localized("应用包已移到废纸篓；应用数据与缓存保留")) + suffix
                }
            }
        }
    }
    func shutdown(_ completion: @escaping @MainActor @Sendable (String?) -> Void) {
        closed = true; token?.cancel(); generation = UUID(); timer?.invalidate(); timer = nil; confirmation = nil; relatedData = nil; scanning = false; preparingData = false; inspectingData = false
        let backend = backend
        leftovers.shutdown { leftoverError in
            backend.disk.queue.async {
                backend.remover = nil
                var error: String?
                do { try backend.disk.finish() } catch let failure { error = failure.localizedDescription }
                let result = error ?? leftoverError
                Task { @MainActor in completion(result) }
            }
        }
    }
}
