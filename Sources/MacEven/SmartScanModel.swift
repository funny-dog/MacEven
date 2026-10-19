import Foundation
import Combine
import MacEvenCore

/// 智能扫描的合并确认：三类清理各自冻结的确认内容；执行时逐类调用原有的执行流程。
struct SmartCleanupConfirmation: Identifiable {
    let id = UUID()
    let cache: CacheConfirmation?
    let developer: DeveloperCleanupConfirmation?
    let leftovers: LeftoverConfirmation?
    var allocatedSize: Int64 { (cache?.allocatedSize ?? 0) + (developer?.allocatedSize ?? 0) + (leftovers?.allocatedSize ?? 0) }
    var paths: [ConfirmPath] {
        func rows<Group>(_ title: String, _ groups: [Group], paths: (Group) -> [URL], size: (Group) -> Int64?) -> [ConfirmPath] {
            groups.flatMap { group in paths(group).map { ConfirmPath(path: "\(title) · \($0.path)", size: paths(group).count == 1 ? size(group).map(bytes) : nil) } }
        }
        let devGroups = developer?.groups.filter { $0.rule.aiToolName == nil } ?? []
        let aiGroups = developer?.groups.filter { $0.rule.aiToolName != nil } ?? []
        return rows(localized("应用缓存"), cache?.groups ?? [], paths: \.paths, size: \.allocatedSize)
            + rows(localized("开发与浏览器"), devGroups, paths: \.paths, size: \.allocatedSize)
            + rows(localized("AI 缓存"), aiGroups, paths: \.paths, size: \.allocatedSize)
            + rows(localized("卸载残留"), leftovers?.groups ?? [], paths: \.paths, size: \.allocatedSize)
    }
    var count: Int { (cache?.groups.count ?? 0) + (developer?.groups.count ?? 0) + (leftovers?.groups.count ?? 0) }
}

/// AI Agent 会话与工作记录独立清理确认（绝对不混入一键缓存清理）
struct AIWorkConfirmation: Identifiable {
    let id = UUID()
    let groups: [AIWorkCleanupGroup]
    var allocatedSize: Int64 { groups.reduce(0) { $0 + $1.allocatedSize } }
    var count: Int { groups.reduce(0) { $0 + $1.count } }
    var paths: [ConfirmPath] {
        groups.flatMap { group in
            group.targets.map { target in
                ConfirmPath(path: "\(group.title) · \(target.url.path)", size: bytes(target.allocatedSize))
            }
        }
    }
    var notes: [String] {
        var list: [String] = []
        for group in groups {
            list.append(localized("\(group.title)：\(group.impact)"))
        }
        list.append(localized("长期记忆（memory/memories）、配置文件、凭据与项目源码/工作树已严格保留，不受任何影响。"))
        if groups.contains(where: \.leavesEmptyDirectories) {
            list.append(localized("会话文件移走后可能留下空的日期目录，不影响工具继续使用。"))
        }
        list.append(localized("执行前将核验相关工具进程是否已退出且无文件占用，被占用或已被修改的文件将自动保留。"))
        list.append(localized("文件仅移到废纸篓，可在 Finder 的废纸篓中恢复。MacEven 不会清空废纸篓。"))
        return list
    }
}

extension AIStorageConfirmation {
    var confirmPaths: [ConfirmPath] {
        items.map { ConfirmPath(path: "\($0.location.name) · \($0.location.url.path)", size: bytes($0.allocatedSize)) }
    }
}

// 串联已有的三类清理：依次扫描、统一选择与确认、依次执行；各自的安全复核保持不变。
@MainActor final class SmartScanModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning(String), measuring, ready, cleaning(String), done }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var storage: [StorageMeasurement] = []
    @Published private(set) var aiStorage: [StorageMeasurement] = []
    @Published private(set) var lastAnalysis: AnalysisReport?
    @Published var expandedCategories: Set<CleanupCategory> = []
    @Published var aiExpanded = false
    @Published var otherStorageExpanded = false
    private let historyDefaults: UserDefaults?
    @Published private(set) var confirmation: SmartCleanupConfirmation?
    @Published private(set) var summary: String?
    @Published var message: String?
    let cache: CacheModel
    let removal: ApplicationRemovalModel
    var developer: DeveloperCleanupModel { cache.developer }
    var leftovers: LeftoverModel { removal.leftovers }

    // AI 工作资料独立清理状态与属性
    @Published private(set) var aiWorkGroups: [AIWorkCleanupGroup] = [] { didSet { rebuildAIWorkRows() } }
    @Published private(set) var aiWorkRows: [AICleanupRow] = []
    private var aiWorkTargetsByID: [String: AIWorkCleanupTarget] = [:]
    @Published private(set) var aiWorkConfirmation: AIWorkConfirmation?
    @Published private(set) var aiWorkCleaning: Bool = false
    @Published private(set) var aiWorkSummary: String?
    @Published private(set) var aiWorkResults: [TrashResult] = []
    @Published private(set) var aiWorkWarnings: [String] = []
    /// 逐项勾选的会话与工作记录（按路径）；绝不混入页面底部的缓存一键清理。
    @Published private(set) var aiWorkSelection = Set<String>()
    /// 面板中展开明细的行与“保留的工作资料”只读区。
    @Published var aiWorkExpandedRows = Set<String>()
    @Published var aiWorkAgeDays = 90 { didSet { rebuildAIWorkRows() } }
    @Published var aiWorkStorageExpanded = false
    @Published var aiCacheExpanded = false
    /// 一次最多勾选的会话与工作记录数，避免误点“选择全部”造成超大范围清理。
    static let aiWorkSelectionLimit = 500

    // AI 工作资料与记忆（不建议删除）独立清理状态与属性
    @Published private(set) var aiStorageConfirmation: AIStorageConfirmation?
    @Published private(set) var aiStorageCleaning: Bool = false
    @Published private(set) var aiStorageSummary: String?
    @Published private(set) var aiStorageResults: [TrashResult] = []
    @Published var aiStorageSelection = Set<String>()

    var recordOperation: (@Sendable ([TrashResult]) -> Void)?
    var aiWorkActivity: @Sendable (AIWorkTool, URL) -> String? = AIWorkActivity.blockedReason
    private let aiCleanup: AIWorkCleanup

    /// 磁盘分析、重复文件、软件管理等其他任务是否在工作。
    var otherBusy: @MainActor () -> Bool = { false }
    let home: URL
    private var closed = false
    private var task: Task<Void, Never>?
    private var token: CancellationToken?
    private var changes: [AnyCancellable] = []

    init(cache: CacheModel, removal: ApplicationRemovalModel, home: URL = FileManager.default.homeDirectoryForCurrentUser, historyDefaults: UserDefaults? = nil) {
        self.cache = cache; self.removal = removal; self.home = home
        self.historyDefaults = historyDefaults
        self.aiCleanup = AIWorkCleanup(home: home)
        // 缓存清理扫描结果仅在当前 app 运行轮次生效，退出后不持久化恢复，启动时重新开始。
        lastAnalysis = nil
        historyDefaults?.removeObject(forKey: "analysisReport.cleanup")
        // 汇总卡片读取三个模型的状态，转发它们的变化。
        changes = [cache.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                   removal.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }]
    }

    var busy: Bool {
        if aiWorkCleaning { return true }
        switch phase { case .scanning, .measuring, .cleaning: return true; default: return false }
    }
    /// “全部扫描”进行中（含其他存储统计），清理阶段不算。
    var scanningAll: Bool {
        switch phase { case .scanning, .measuring: true; default: false }
    }
    /// 依次检查的三类项目；“其他存储”统计作为第 4 步。
    static let steps = [localized("应用缓存"), localized("开发与浏览器缓存"), localized("卸载残留")]
    /// 其他存储已统计的位置数与总数。
    @Published private(set) var measuring: (done: Int, total: Int)?
    /// 第 4 步最后一段：AI 工作资料扫描；位置统计完成后进度停满而不是回到步首。
    @Published private(set) var measuringAI = false
    private var maxProgressFraction: Double = 0
    /// 4 步各占 1/4，步内用各自的进度；步内总数未知时停在该步起点。阶段过渡时保证进度单调不后退。
    var progressEstimate: ProgressEstimate {
        let weights = [1.0, 1, 1, 1]
        let estimate: ProgressEstimate
        switch phase {
        case .scanning(let name):
            guard let step = Self.steps.firstIndex(of: name) else { return .unknown }
            // 子扫描完成后保留末次快照，直到总流程切到下一步。
            let inner = [cache.progress, developer.progress, leftovers.progress][step]?.unitEstimate ?? .unknown
            estimate = .phases(weights, index: step, inner: inner)
        case .measuring:
            estimate = .phases(weights, index: 3, inner: measuring.map { .units($0.done, of: $0.total) } ?? .unknown)
        default: return .unknown
        }
        guard let frac = estimate.fraction else { return estimate }
        let monotonic = max(frac, maxProgressFraction)
        maxProgressFraction = monotonic
        return ProgressEstimate(fraction: monotonic, estimated: estimate.estimated)
    }
    var progressCaption: String {
        switch phase {
        case .scanning(let name):
            let step = (Self.steps.firstIndex(of: name) ?? 0) + 1
            return localized("第 \(step)/4 步 · \(name)")
        case .measuring:
            let base = localized("第 4/4 步 · 其他存储") + (measuring.map { localized(" · \($0.done)/\($0.total) 个位置") } ?? "")
            return measuringAI ? base + localized(" · 正在扫描 AI 工作资料") : base
        default: return ""
        }
    }
    var canScan: Bool { !closed && !busy && !cache.busy && !removal.busy && !otherBusy() }
    var selectedCount: Int { cache.selection.count + developer.selection.count + leftovers.selection.count }
    var selectedSize: Int64 {
        let cacheSize = cache.selectedGroups.reduce(Int64(0)) { $0 + ($1.allocatedSize ?? 0) }
        let developerSize = developer.selectedGroups.reduce(Int64(0)) { $0 + ($1.allocatedSize ?? 0) }
        let leftoverSize = leftovers.selectedGroups.reduce(Int64(0)) { $0 + ($1.allocatedSize ?? 0) }
        return cacheSize + developerSize + leftoverSize
    }
    var canClean: Bool { !closed && !busy && !otherBusy() && (cache.canClean || developer.canClean || leftovers.canClean) }

    func scanAll() {
        guard canScan else { return }
        lastAnalysis = nil; historyDefaults?.removeObject(forKey: "analysisReport.cleanup")
        cache.discardResults(); developer.discardResults(); leftovers.discardResults()
        expandedCategories = []; aiExpanded = false; otherStorageExpanded = false
        let cancellation = CancellationToken(); token = cancellation
        // 同步进入扫描状态：任务启动前界面与其他入口就已看到忙碌。
        maxProgressFraction = 0
        summary = nil; storage = []; aiStorage = []; confirmation = nil; measuring = nil; measuringAI = false
        aiWorkGroups = []; aiWorkConfirmation = nil; aiWorkSummary = nil; aiWorkResults = []; aiWorkWarnings = []
        aiStorageConfirmation = nil; aiStorageCleaning = false; aiStorageSummary = nil; aiStorageResults = []; aiStorageSelection = []
        phase = .scanning(Self.steps[0])
        let home = home
        task = Task { [weak self] in
            guard let self else { return }
            let steps: [(String, () -> Void, () -> Bool)] = [
                (Self.steps[0], { self.cache.developerSelected = false; self.cache.start() }, { self.cache.busy }),
                (Self.steps[1], { self.developer.start() }, { self.cache.busy }),
                (Self.steps[2], { self.leftovers.start() }, { self.removal.busy })
            ]
            for (name, start, running) in steps {
                if cancellation.isCancelled { break }
                self.phase = .scanning(name)
                start()
                while running() { try? await Task.sleep(for: .milliseconds(50)) }
            }
            if !cancellation.isCancelled {
                self.phase = .measuring
                let ordinary = OtherStorage.locations(home: home)
                let locations = ordinary + OtherStorage.aiLocations(home: home)
                self.measuring = (0, locations.count)
                let measured = await Task.detached(priority: .utility) { [self] in
                    OtherStorage.measure(locations, token: cancellation) { done in
                        Task { @MainActor [weak self] in
                            guard let self, self.phase == .measuring, !self.measuringAI else { return }
                            self.measuring = (done, locations.count)
                        }
                    }
                }.value
                // 位置统计完成后第 4 步还没结束：AI 工作资料扫描仍在同一步内，进度停满而不是退回步首。
                self.measuring = (locations.count, locations.count)
                self.measuringAI = true
                self.applyStorageMeasurements(measured)
                let cleanup = self.aiCleanup
                do {
                    let result = try await Task.detached(priority: .utility) {
                        let groups = try cleanup.scan(token: cancellation)
                        return (groups, cleanup.warnings)
                    }.value
                    self.aiWorkGroups = result.0; self.aiWorkWarnings = result.1
                    // 保留仍有效的勾选；已被移走或不再出现的记录自动取消选择。
                    self.aiWorkSelection.formIntersection(Set(result.0.flatMap { $0.targets.map(\.id) }))
                } catch {
                    self.aiWorkGroups = []; self.aiWorkWarnings = [error.localizedDescription]
                    self.aiWorkSelection = []
                }
                self.measuringAI = false
                self.measuring = nil
            }
            self.phase = cancellation.isCancelled ? .idle : .ready
            if cancellation.isCancelled { self.summary = localized("扫描已取消，结果不完整") }
            else if !self.cache.scanFailed && !self.developer.scanFailed && !self.leftovers.scanFailed {
                let incomplete = self.cache.incomplete || self.developer.incomplete || self.leftovers.incomplete || (self.storage + self.aiStorage).contains(where: \.incomplete)
                var details: [String] = [
                    localized("应用缓存：\(self.cache.selectableCount) 项 · \(bytes(self.cache.selectableSize))"),
                    localized("开发与浏览器缓存：\(self.developer.otherCacheSelectableCount) 项 · \(bytes(self.developer.otherCacheSelectableSize))"),
                    localized("软件残留：\(self.leftovers.selectableCount) 项 · \(bytes(self.leftovers.selectableSize))")
                ]
                if self.developer.aiCacheSelectableCount > 0 {
                    details.append(localized("AI 缓存：\(self.developer.aiCacheSelectableCount) 项 · \(bytes(self.developer.aiCacheSelectableSize))"))
                }
                details.append(contentsOf: self.cache.errors.prefix(3).map { localized("应用缓存未完成：") + $0 })
                details.append(contentsOf: self.developer.errors.prefix(3).map { localized("开发缓存未完成：") + $0 })
                details.append(contentsOf: self.leftovers.errors.prefix(3).map { localized("软件残留未完成：") + $0 })
                let restrictions = self.cache.restrictions + self.developer.restrictions + self.leftovers.restrictions
                details.append(contentsOf: restrictions.prefix(6).map { localized("保留 \($0.count) 项：\($0.reason)") })
                details.append(contentsOf: (self.aiStorage + self.storage).map {
                    localized("\($0.location.name)：\(bytes($0.allocatedSize))") + ($0.issue.map { " · " + $0 } ?? "")
                })
                let skipped = (self.storage + self.aiStorage).filter(\.skipped).count
                var reportSummary = localized("可清理 \(bytes(self.cache.selectableSize + self.developer.selectableSize + self.leftovers.selectableSize))")
                reportSummary += incomplete ? localized(" · 部分检查未完成") : localized(" · 扫描完成")
                if skipped > 0 { reportSummary += localized(" · \(skipped) 处按规则跳过") }
                let report = AnalysisReport(summary: reportSummary, details: details)
                self.lastAnalysis = report
            }
        }
    }

    func cancel() {
        token?.cancel(); cache.cancel(); leftovers.cancel(); maxProgressFraction = 0
    }

    /// 每类按占用从大到小选择可清理项，每类最多 50 项。
    func selectAllSafe() {
        guard !busy else { return }
        cache.selectLargest(); developer.selectLargest(); leftovers.selectLargest()
    }
    /// 一键清理：按 selectAllSafe 的规则选择后生成合并确认；仍需用户在确认窗口中确认。
    func cleanAllSafe() {
        selectAllSafe(); prepareCleanup()
    }
    func clearSelection() {
        guard !busy else { return }
        cache.selection = []
        for id in developer.selection { developer.select(id, selected: false) }
        for id in leftovers.selection { leftovers.select(id, selected: false) }
    }

    func prepareCleanup() {
        guard canClean else { return }
        // 先清除各页面遗留的确认，合并确认只包含此刻已选的类别。
        cache.dismissConfirmation(); developer.dismissConfirmation(); leftovers.dismissConfirmation()
        if cache.canClean { cache.prepareCleanup() }
        if developer.canClean { developer.prepareCleanup() }
        if leftovers.canClean { leftovers.prepareCleanup() }
        let frozen = SmartCleanupConfirmation(cache: cache.confirmation, developer: developer.confirmation, leftovers: leftovers.confirmation)
        guard frozen.count > 0 else { message = localized("没有可清理的已选项目。"); return }
        confirmation = frozen
    }

    func dismissConfirmation() {
        confirmation = nil
        cache.dismissConfirmation(); developer.dismissConfirmation(); leftovers.dismissConfirmation()
    }

    func executeCleanup() {
        guard let frozen = confirmation, !busy, !otherBusy() else { return }
        confirmation = nil; summary = nil; phase = .cleaning("")
        task = Task { [weak self] in
            guard let self else { return }
            var moved = 0, size: Int64 = 0, failed = 0
            var expired: [String] = []
            func tally(_ results: [TrashResult]) {
                moved += results.filter { $0.destination != nil }.count
                size += results.filter { $0.destination != nil }.reduce(0) { $0 + ($1.allocatedSize ?? 0) }
                failed += results.filter { $0.error != nil }.count
            }
            // 每类执行前核对其当前确认仍是合并窗口里冻结的那一份；失效时不执行并如实报告。
            if let expected = frozen.cache {
                if self.cache.confirmation?.id == expected.id && !self.otherBusy() {
                    self.phase = .cleaning(localized("应用缓存")); self.cache.executeCleanup()
                    while self.cache.busy { try? await Task.sleep(for: .milliseconds(50)) }
                    tally(self.cache.results)
                } else { expired.append(localized("应用缓存")) }
            }
            if let expected = frozen.developer {
                if self.developer.confirmation?.id == expected.id && !self.otherBusy() {
                    self.phase = .cleaning(localized("开发与浏览器缓存")); self.developer.executeCleanup()
                    while self.cache.busy { try? await Task.sleep(for: .milliseconds(50)) }
                    tally(self.developer.results)
                } else { expired.append(localized("开发与浏览器缓存")) }
            }
            if let expected = frozen.leftovers {
                if self.leftovers.confirmation?.id == expected.id && !self.otherBusy() {
                    self.phase = .cleaning(localized("卸载残留")); self.leftovers.executeCleanup()
                    while self.removal.busy { try? await Task.sleep(for: .milliseconds(50)) }
                    tally(self.leftovers.results)
                } else { expired.append(localized("卸载残留")) }
            }
            self.cache.dismissConfirmation(); self.developer.dismissConfirmation(); self.leftovers.dismissConfirmation()
            self.phase = .done
            self.summary = localized("已移到废纸篓 \(moved) 个路径 · 占用估算 \(bytes(size))") + (failed > 0 ? localized(" · \(failed) 项保留或失败，展开各类明细查看结果") : "")
                + (expired.isEmpty ? "" : localized(" · \(expired.joined(separator: localized("、")))的确认已失效或有其他任务在工作，未执行")) + localized(" · 在 Finder 中清空废纸篓后才释放空间")
        }
    }

    // MARK: - AI Agent 会话与工作记录独立清理入口（不混入一键缓存清理）

    /// 面板展示行：旧会话、项目已删除的会话、其他会话、快照与计划。
    private func rebuildAIWorkRows() {
        aiWorkRows = AICleanupRows.rows(groups: aiWorkGroups, ageDays: aiWorkAgeDays)
        aiWorkTargetsByID = [:]
        for row in aiWorkRows { for target in row.targets { aiWorkTargetsByID[target.id] = target } }
    }
    var aiWorkTotalCount: Int { aiWorkGroups.reduce(0) { $0 + $1.count } }
    var aiWorkTotalSize: Int64 { aiWorkGroups.reduce(0) { $0 + $1.allocatedSize } }
    /// 当前年龄阈值下有资格勾选的全部记录。
    var aiWorkSelectableTargets: [AIWorkCleanupTarget] { aiWorkRows.flatMap(\.targets) }
    var aiWorkSelectedTargets: [AIWorkCleanupTarget] {
        aiWorkSelection.sorted().compactMap { aiWorkTargetsByID[$0] }
    }
    var aiWorkSelectedCount: Int { aiWorkSelection.reduce(0) { $0 + (aiWorkTargetsByID[$1] == nil ? 0 : 1) } }
    var aiWorkSelectedSize: Int64 { aiWorkSelectedTargets.reduce(0) { $0 + $1.allocatedSize } }
    func aiWorkSelectedCount(in row: AICleanupRow) -> Int { row.targets.filter { aiWorkSelection.contains($0.id) }.count }
    func isAIWorkSelected(_ target: AIWorkCleanupTarget) -> Bool { aiWorkSelection.contains(target.id) }

    /// 勾选/取消一行中的全部记录；超出单次上限时只选中未被选中的前若干项并说明。
    func setAIWorkRow(_ row: AICleanupRow, selected: Bool) {
        guard canScan else { return }
        guard selected else {
            aiWorkSelection.subtract(row.targets.map(\.id))
            return
        }
        let fresh = row.targets.map(\.id).filter { !aiWorkSelection.contains($0) }
        let room = Self.aiWorkSelectionLimit - aiWorkSelection.count
        guard room > 0 else {
            message = localized("一次最多选择 \(Self.aiWorkSelectionLimit) 项会话与工作记录。")
            return
        }
        aiWorkSelection.formUnion(fresh.prefix(room))
        if fresh.count > room { message = localized("一次最多选择 \(Self.aiWorkSelectionLimit) 项，本行只选中了前 \(room) 项。") }
    }

    func setAIWorkTarget(_ target: AIWorkCleanupTarget, selected: Bool) {
        guard canScan else { return }
        guard selected else {
            aiWorkSelection.remove(target.id)
            return
        }
        guard aiWorkSelection.count < Self.aiWorkSelectionLimit else {
            message = localized("一次最多选择 \(Self.aiWorkSelectionLimit) 项会话与工作记录。")
            return
        }
        aiWorkSelection.insert(target.id)
    }

    /// 按行顺序选择全部记录，仍受单次上限约束；执行前依旧逐项核验。
    func selectAllAIWork() {
        guard canScan else { return }
        let all = aiWorkSelectableTargets.map(\.id)
        guard all.count <= Self.aiWorkSelectionLimit else {
            message = localized("共 \(all.count) 项，超出一键选择上限；已选择前 \(Self.aiWorkSelectionLimit) 项，其余请逐行勾选。")
            aiWorkSelection = Set(all.prefix(Self.aiWorkSelectionLimit))
            return
        }
        aiWorkSelection = Set(all)
    }

    func clearAIWorkSelection() {
        guard canScan else { return }
        aiWorkSelection = []
    }

    var canCleanAIWork: Bool {
        canScan && !aiWorkSelection.isEmpty && aiWorkSelectedCount == aiWorkSelection.count
    }

    // MARK: - 「AI 清理与维护」卡片汇总

    /// 卡片数字 = 可清理的 AI 缓存 + 可逐项确认的会话与工作记录；与页面合计口径一致，不重复计数。
    var aiMaintenanceSize: Int64 { developer.aiCacheSelectableSize + aiWorkTotalSize }
    /// 相关工具名：有缓存或会话记录的工具，去重后按缓存规则顺序排列。
    var aiMaintenanceToolNames: [String] {
        var names = developer.aiToolNames
        for tool in AIWorkTool.allCases where aiWorkGroups.contains(where: { $0.rule.tool == tool }) && !names.contains(tool.displayName) {
            names.append(tool.displayName)
        }
        return names
    }
    var aiMaintenanceIncomplete: Bool {
        developer.incomplete || aiWorkWarnings.contains { !$0.isEmpty } || aiStorage.contains(where: \.incomplete)
    }
    var aiMaintenanceStatus: String {
        let tools = aiMaintenanceToolNames
        let caches = developer.aiCacheSelectableCount
        let records = aiWorkTotalCount
        guard !tools.isEmpty else { return localized("未发现 AI 工具的缓存与会话记录") }
        var text = localized("\(tools.count) 个工具 · 缓存 \(caches) 项 · 会话与工作记录 \(records) 项")
        if developer.aiCacheSelectedCount > 0 { text += localized(" · 已选 \(developer.aiCacheSelectedCount) 项缓存") }
        if aiWorkSelectedCount > 0 { text += localized(" · 已选 \(aiWorkSelectedCount) 项记录") }
        if caches == 0 && records == 0 { text += localized(" · 无可清理项") }
        return text
    }

    func prepareAIWorkCleanup() {
        guard canCleanAIWork else {
            if aiWorkSelectedTargets.isEmpty { message = localized("请先勾选要清理的会话或工作记录。") }
            return
        }
        let groups = AIWorkCleanupGroup.grouped(aiWorkSelectedTargets)
        guard !groups.isEmpty else {
            message = localized("请先勾选要清理的会话或工作记录。")
            return
        }
        aiWorkConfirmation = AIWorkConfirmation(groups: groups)
    }

    func dismissAIWorkConfirmation() {
        aiWorkConfirmation = nil
    }

    func executeAIWorkCleanup() {
        guard let frozen = aiWorkConfirmation, canScan else { return }
        aiWorkConfirmation = nil; aiWorkCleaning = true; aiWorkSummary = nil
        let cleanup = aiCleanup, activity = aiWorkActivity, record = recordOperation, home = home
        let previousGroups = aiWorkGroups, previousMeasurements = storage + aiStorage
        let cancellation = CancellationToken(); token = cancellation
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await Task.detached(priority: .utility) {
                let results = cleanup.move(groups: frozen.groups, token: cancellation, activity: activity, recordOperation: record)
                let paths = results.filter { $0.destination != nil }.map(\.path)
                let groups = (try? cleanup.remainingGroups(previousGroups)) ?? []
                let measurements = OtherStorage.refresh(previousMeasurements, locations: OtherStorage.locations(home: home) + OtherStorage.aiLocations(home: home),
                                                        changedPaths: paths, token: cancellation)
                return (results, groups, measurements, cleanup.warnings)
            }.value
            let moved = outcome.0.filter { $0.destination != nil }
            let failed = outcome.0.filter { $0.error != nil }.count
            self.aiWorkResults = outcome.0; self.aiWorkGroups = outcome.1; self.applyStorageMeasurements(outcome.2); self.aiWorkWarnings = outcome.3
            self.aiWorkSelection.formIntersection(Set(outcome.1.flatMap { $0.targets.map(\.id) }))
            self.aiWorkSummary = localized("已移到废纸篓 \(moved.count) 项会话与工作记录 · 占用估算 \(bytes(moved.reduce(0) { $0 + ($1.allocatedSize ?? 0) }))")
                + (failed > 0 ? localized(" · \(failed) 项保留或失败") : "")
                + (cancellation.isCancelled ? localized(" · 操作已取消，请重新扫描") : "")
                + localized(" · 在 Finder 中清空废纸篓后才释放空间")
            self.aiWorkCleaning = false
        }
    }

    // MARK: - AI 工作资料与记忆（不建议删除）清理选项

    var aiStorageSelectableItems: [StorageMeasurement] {
        aiStorage.filter { $0.allocatedSize > 0 && FileManager.default.fileExists(atPath: $0.location.url.path) }
    }
    var aiStorageSelectedItems: [StorageMeasurement] {
        aiStorage.filter { aiStorageSelection.contains($0.id) }
    }
    var aiStorageSelectedCount: Int { aiStorageSelectedItems.count }
    var aiStorageSelectedSize: Int64 { aiStorageSelectedItems.reduce(0) { $0 + $1.allocatedSize } }
    var canCleanAIStorage: Bool {
        canScan && !aiStorageCleaning && !aiStorageSelectedItems.isEmpty
    }

    func setAIStorageItem(_ item: StorageMeasurement, selected: Bool) {
        guard canScan else { return }
        if selected { aiStorageSelection.insert(item.id) }
        else { aiStorageSelection.remove(item.id) }
    }

    func selectAllAIStorage() {
        guard canScan else { return }
        aiStorageSelection = Set(aiStorageSelectableItems.map(\.id))
    }

    func clearAIStorageSelection() {
        guard canScan else { return }
        aiStorageSelection = []
    }

    func prepareAIStorageCleanup() {
        guard !closed, !busy, !otherBusy(), !aiStorageCleaning else { return }
        guard canCleanAIStorage else {
            if aiStorageSelectedItems.isEmpty { message = localized("请先勾选要清理的工作资料或记忆。") }
            return
        }
        aiStorageConfirmation = AIStorageConfirmation(items: aiStorageSelectedItems)
    }

    func dismissAIStorageConfirmation() {
        aiStorageConfirmation = nil
    }

    func executeAIStorageCleanup() {
        guard let frozen = aiStorageConfirmation, canScan else { return }
        aiStorageConfirmation = nil; aiStorageCleaning = true; aiStorageSummary = nil
        let home = home, record = recordOperation
        let itemsToClean = frozen.items
        let previousMeasurements = storage + aiStorage
        let cancellation = CancellationToken(); token = cancellation

        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await Task.detached(priority: .utility) {
                var results: [TrashResult] = []
                let allowedLocations = OtherStorage.aiLocations(home: home).map { $0.url.path }

                for item in itemsToClean {
                    guard !cancellation.isCancelled else {
                        results.append(TrashResult(id: 0, path: item.location.url.path, destination: nil, error: localized("操作已取消"), allocatedSize: item.allocatedSize))
                        continue
                    }
                    let url = item.location.url
                    let path = url.path

                    // 安全防御：限定必须在 home 下且在白名单中，绝不能是 home 根目录
                    guard path.hasPrefix(home.path + "/"),
                          !url.pathComponents.contains(".."),
                          !url.pathComponents.contains("."),
                          allowedLocations.contains(path) else {
                        results.append(TrashResult(id: 0, path: path, destination: nil, error: localized("非受许可的 AI 工作资料路径，已拒绝移走"), allocatedSize: item.allocatedSize))
                        continue
                    }

                    // 符号链接防御：防止误删软链目标外部数据
                    if let info = try? FileIdentity.read(url), info.isSymlink {
                        results.append(TrashResult(id: 0, path: path, destination: nil, error: localized("目标是符号链接，已拒绝移动以保护外部数据"), allocatedSize: item.allocatedSize))
                        continue
                    }

                    var destination: NSURL?
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                        results.append(TrashResult(id: 0, path: path, destination: destination as URL?, error: nil, allocatedSize: item.allocatedSize))
                    } catch {
                        results.append(TrashResult(id: 0, path: path, destination: nil, error: error.localizedDescription, allocatedSize: item.allocatedSize))
                    }
                }

                // 写入审计日志
                if !results.isEmpty {
                    if let record {
                        record(results)
                    } else {
                        let log = OperationLog(directory: home.appendingPathComponent("Library/Logs/MacEven"))
                        try? log.append(OperationRecord.batch(results, source: "aistorage"))
                    }
                }

                let measurements = OtherStorage.refresh(previousMeasurements, locations: OtherStorage.locations(home: home) + OtherStorage.aiLocations(home: home),
                                                        changedPaths: results.filter { $0.destination != nil }.map(\.path), token: cancellation)

                return (results, measurements)
            }.value

            let moved = outcome.0.filter { $0.destination != nil }
            let failed = outcome.0.filter { $0.error != nil }.count
            self.aiStorageResults = outcome.0
            self.applyStorageMeasurements(outcome.1)
            self.aiStorageSelection.subtract(outcome.0.filter { $0.destination != nil }.map(\.path))
            self.aiStorageSummary = localized("已移到废纸篓 \(moved.count) 处工作资料 · 占用估算 \(bytes(moved.reduce(0) { $0 + ($1.allocatedSize ?? 0) }))")
                + (failed > 0 ? localized(" · \(failed) 处保留或失败") : "")
                + localized(" · 清空废纸篓后释放空间")
            self.aiStorageCleaning = false
        }
    }

    private func applyStorageMeasurements(_ measurements: [StorageMeasurement]) {
        let ordinary = Set(OtherStorage.locations(home: home).map(\.id))
        let unique = Dictionary(measurements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        storage = unique.filter { ordinary.contains($0.id) }.sorted { $0.allocatedSize > $1.allocatedSize }
        aiStorage = unique.filter { !ordinary.contains($0.id) }.sorted { $0.allocatedSize > $1.allocatedSize }
    }

    func shutdown(_ completion: @escaping @MainActor @Sendable () -> Void) {
        closed = true; cancel(); confirmation = nil; aiWorkConfirmation = nil; aiStorageConfirmation = nil
        let pending = task
        Task { await pending?.value; completion() }
    }

}

// MARK: - 分类枚举定义
enum CleanupCategory: CaseIterable, Hashable {
    case appCache, developer, leftovers

    var title: String {
        switch self {
        case .appCache: localized("应用缓存")
        case .developer: localized("开发与浏览器缓存")
        case .leftovers: localized("软件残留")
        }
    }

    var symbol: String {
        switch self {
        case .appCache: "square.grid.2x2.fill"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .leftovers: "trash.fill"
        }
    }

    var hue: ThemeHue {
        switch self {
        case .appCache: .teal
        case .developer: .orange
        case .leftovers: .pink
        }
    }
}
