import Foundation
import AppKit
import Combine
import MacEvenCore

enum SoftwareTab: String, CaseIterable { case updates = "更新", startup = "启动项", uninstall = "卸载", leftovers = "残留" }
struct SoftwareConfirmation: Identifiable, Sendable {
    let id = UUID()
    let generation: UUID
    let entry: SoftwareEntry?
    let entries: [SoftwareEntry]
    let startup: StartupItem?
    let enabled: Bool

    init(generation: UUID, entry: SoftwareEntry? = nil, entries: [SoftwareEntry] = [], startup: StartupItem? = nil, enabled: Bool = false) {
        self.generation = generation
        self.entry = entry
        self.entries = entries
        self.startup = startup
        self.enabled = enabled
    }
}

@MainActor final class SoftwareModel: ObservableObject {
    // The model admits one task at a time; shutdown waits before releasing this service.
    private final class StartupState: @unchecked Sendable {
        let service: StartupItems
        init(_ service: StartupItems) { self.service = service }
    }
    @Published var tab: SoftwareTab = .updates
    @Published private(set) var entries: [SoftwareEntry] = []
    @Published private(set) var startupItems: [StartupItem] = []
    @Published private(set) var checking = false
    @Published private(set) var operating = false
    @Published private(set) var status = localized("点击检查更新；不会自动升级软件")
    @Published private(set) var errors: [String] = []
    @Published private(set) var confirmation: SoftwareConfirmation?
    @Published var selection: String?
    @Published var startupSelection: String?
    @Published var search = "" { didSet { offset = 0 } }
    @Published var offset = 0
    var otherBusy: () -> Bool = { false }
    var busy: Bool { checking || operating }
    /// 所有可直接升级的应用（仅 Homebrew 且无阻挡原因、有更新的项）
    var upgradableEntries: [SoftwareEntry] { entries.filter(\.canUpgrade) }
    /// 有可用更新的 App Store 应用；只汇总入口，安装始终由商店的「全部更新」执行
    var appStoreUpdatableEntries: [SoftwareEntry] { entries.filter { $0.source == .appStore && $0.hasUpdate && $0.blockedReason == nil } }
    /// 更新检查已完成的应用数；读取目录阶段为 nil。
    @Published private(set) var checkedCount: Int?
    /// 正在检查更新（不含启动项检查与升级）。
    @Published private(set) var checkingUpdates = false
    var progressEstimate: ProgressEstimate {
        guard checkingUpdates, let checkedCount else { return .unknown }
        return .units(checkedCount, of: entries.count)
    }
    var filteredEntries: [SoftwareEntry] { entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) } }
    var visibleEntries: [SoftwareEntry] { Array(filteredEntries.dropFirst(offset).prefix(100)) }
    var visibleStartupItems: [StartupItem] {
        Array(startupItems.filter {
            $0.kind == .loginItem && (
                search.isEmpty
                || $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.label.localizedCaseInsensitiveContains(search)
                || $0.url.path.localizedCaseInsensitiveContains(search)
                || ($0.appName?.localizedCaseInsensitiveContains(search) ?? false)
            )
        }.dropFirst(offset).prefix(100))
    }
    var selectedEntry: SoftwareEntry? { entries.first { $0.id == selection } }
    var selectedStartup: StartupItem? { startupItems.first { $0.id == startupSelection } }
    private let scan: @Sendable (CancellationToken) throws -> SoftwareScanResult
    private let check: @Sendable (SoftwareEntry, CancellationToken) async throws -> SoftwareEntry
    private let upgrade: @Sendable (SoftwareEntry, CancellationToken) throws -> SoftwareEntry
    private let startup: StartupState
    private var task: Task<Void, Never>?
    private var token: CancellationToken?
    private var generation = UUID()
    private var closed = false
    nonisolated static let checkConcurrency = 8
    init(scan: @escaping @Sendable (CancellationToken) throws -> SoftwareScanResult = { try SoftwareUpdates.discover(token: $0) },
         check: @escaping @Sendable (SoftwareEntry, CancellationToken) async throws -> SoftwareEntry = { try await SoftwareUpdates.check($0, token: $1) },
         upgrade: @escaping @Sendable (SoftwareEntry, CancellationToken) throws -> SoftwareEntry = { try SoftwareUpdates.upgrade($0, token: $1) },
         startup: StartupItems = StartupItems()) {
        self.scan = scan; self.check = check; self.upgrade = upgrade; self.startup = StartupState(startup)
    }
    func refresh() {
        guard !closed, !busy, !otherBusy() else { return }
        let run = UUID(), cancellation = CancellationToken(); generation = run; token = cancellation
        checking = true; checkingUpdates = true; checkedCount = nil; confirmation = nil; selection = nil; entries = []; errors = []; offset = 0; status = localized("正在读取应用与刷新 Homebrew 元数据…")
        let scan = scan, check = check
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try scan(cancellation)
                await self?.publishCatalog(result, run: run)
                let checkOne: @Sendable (SoftwareEntry) async -> SoftwareEntry = { entry in
                    do { return try await check(entry, cancellation) }
                    catch {
                        var row = entry; row.note = localized("检查失败：") + String(error.localizedDescription.prefix(500)); row.hasUpdate = false
                        return row
                    }
                }
                // 联网检查彼此独立，限宽并发执行；进度按已完成数量计算
                await withTaskGroup(of: SoftwareEntry.self) { group in
                    let entries = result.entries
                    var next = 0, completed = 0
                    while next < min(Self.checkConcurrency, entries.count) { let entry = entries[next]; next += 1; group.addTask { await checkOne(entry) } }
                    while let row = await group.next() {
                        completed += 1
                        await self?.publishEntry(row, run: run, progress: completed)
                        if next < entries.count, !cancellation.isCancelled { let entry = entries[next]; next += 1; group.addTask { await checkOne(entry) } }
                    }
                }
                await self?.finish(run: run, message: cancellation.isCancelled ? localized("检查已取消 · 未完成项保持尚未检查") : localized("检查完成 · 未知或失败项目不代表已是最新"))
            } catch { await self?.finish(run: run, message: localized("检查失败：") + error.localizedDescription) }
        }
    }
    private func publishCatalog(_ result: SoftwareScanResult, run: UUID) {
        guard !closed, generation == run else { return }; entries = result.entries; errors = result.errors; checkedCount = 0
    }
    private func publishEntry(_ entry: SoftwareEntry, run: UUID, progress: Int) {
        guard !closed, generation == run, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry; checkedCount = progress; status = localized("正在检查更新 \(progress)/\(entries.count)")
    }
    private func finish(run: UUID, message: String) {
        guard !closed, generation == run else { return }; checking = false; checkingUpdates = false; operating = false; checkedCount = nil; status = message
    }
    func cancel() { guard checking else { return }; token?.cancel(); task?.cancel(); status = localized("正在取消检查…") }
    func prepareUpgrade(_ entry: SoftwareEntry) {
        guard !closed, !busy, !otherBusy(), entry.canUpgrade, entries.contains(where: { $0.id == entry.id && $0.version == entry.version }) else { return }
        confirmation = SoftwareConfirmation(generation: generation, entry: entry, startup: nil, enabled: false)
    }
    func prepareUpgradeAll() {
        guard !closed, !busy, !otherBusy() else { return }
        let targets = entries.filter(\.canUpgrade)
        guard !targets.isEmpty else { return }
        confirmation = SoftwareConfirmation(generation: generation, entries: targets)
    }
    func refreshStartup() {
        guard !closed, !busy, !otherBusy() else { return }
        let run = UUID(), cancellation = CancellationToken(); generation = run; token = cancellation
        checking = true; confirmation = nil; startupSelection = nil; startupItems = []; errors = []; offset = 0; status = localized("正在检查开机登录项…")
        let startup = startup
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try startup.service.scan(token: cancellation, includeServices: false)
                await self?.publishStartup(result, run: run)
                await self?.finish(run: run, message: localized("登录项读取完成 · 共 \(result.items.count) 个自启应用"))
            } catch { await self?.finish(run: run, message: localized("登录项检查失败：") + error.localizedDescription) }
        }
    }
    func promptAddStartupItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = localized("添加为启动项")
        panel.message = localized("选择在开机登录时要自动启动的应用程序")
        if panel.runModal() == .OK, let url = panel.url {
            addStartupItem(at: url)
        }
    }
    func addStartupItem(at url: URL) {
        guard !closed, !busy, !otherBusy() else { return }
        operating = true; status = localized("正在添加启动项…")
        let run = UUID(); generation = run
        let startup = startup
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                try startup.service.addLoginItem(at: url)
                if let result = try? startup.service.scan(token: CancellationToken(), includeServices: false) {
                    await self?.publishStartup(result, run: run)
                }
                let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? FileManager.default.displayName(atPath: url.path)
                await self?.finish(run: run, message: localized("已添加启动项：\(name)"))
            } catch {
                await self?.finish(run: run, message: localized("添加启动项失败：") + error.localizedDescription)
            }
        }
    }
    private func publishStartup(_ result: StartupScanResult, run: UUID) {
        guard !closed, generation == run else { return }; startupItems = result.items; errors = result.errors
    }
    func prepareStartup(_ item: StartupItem, enabled: Bool) {
        guard !closed, !busy, !otherBusy(), item.kind == .loginItem,
            startupItems.contains(where: { $0.id == item.id }) else { return }
        confirmation = SoftwareConfirmation(generation: generation, entry: nil, startup: item, enabled: false)
    }
    func dismissConfirmation() { confirmation = nil }
    func execute() {
        guard !closed, !busy, !otherBusy(), let frozen = confirmation, frozen.generation == generation else { return }
        confirmation = nil; operating = true; status = localized("正在执行并复核结果；请等待当前操作结束…")
        let upgrade = upgrade, startup = startup, cancellation = CancellationToken(); token = cancellation
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                if let entry = frozen.entry {
                    let result = try upgrade(entry, cancellation)
                    await self?.publishEntry(result, run: frozen.generation, progress: 1)
                    await self?.finish(run: frozen.generation, message: localized("已核验安装版本：\(result.name) \(result.version)"))
                } else if !frozen.entries.isEmpty {
                    var successes: [SoftwareEntry] = []
                    var failures: [(SoftwareEntry, String)] = []
                    let total = frozen.entries.count
                    for (index, entry) in frozen.entries.enumerated() {
                        if cancellation.isCancelled { break }
                        await self?.updateOperatingStatus(run: frozen.generation, message: localized("正在升级 (\(index + 1)/\(total))：\(entry.name)…"))
                        do {
                            guard entry.canUpgrade else { throw MacEvenError(localized("应用不支持直接升级。")) }
                            let result = try upgrade(entry, cancellation)
                            successes.append(result)
                            await self?.applyUpgradeResult(result, run: frozen.generation)
                        } catch {
                            let errorMsg = error.localizedDescription
                            failures.append((entry, errorMsg))
                            await self?.recordUpgradeFailure(entry: entry, error: errorMsg, run: frozen.generation)
                        }
                    }
                    let summary: String
                    if cancellation.isCancelled {
                        summary = localized("更新已取消 · 已完成 \(successes.count) 项，跳过 \(total - successes.count - failures.count) 项")
                    } else if failures.isEmpty {
                        summary = localized("一键更新完成 · 成功更新 \(successes.count) 个软件")
                    } else if successes.isEmpty {
                        summary = localized("一键更新未成功 · \(failures.count) 项更新未通过复核")
                    } else {
                        summary = localized("一键更新完成 · \(successes.count) 项成功，\(failures.count) 项失败")
                    }
                    await self?.finish(run: frozen.generation, message: summary)
                } else if let item = frozen.startup {
                    if item.kind == .loginItem {
                        try startup.service.removeLoginItem(item)
                        if let result = try? startup.service.scan(token: CancellationToken(), includeServices: false) {
                            await self?.publishStartup(result, run: frozen.generation)
                        }
                        await self?.finish(run: frozen.generation, message: localized("已从登录项中移除：\(item.displayName)"))
                    }
                }
            } catch {
                if frozen.startup != nil, let result = try? startup.service.scan(token: CancellationToken(), includeServices: false) { await self?.publishStartup(result, run: frozen.generation) }
                await self?.finish(run: frozen.generation, message: localized("操作未通过复核，请刷新检查实际状态：") + error.localizedDescription)
            }
        }
    }
    private func updateOperatingStatus(run: UUID, message: String) {
        guard !closed, generation == run else { return }; status = message
    }
    private func applyUpgradeResult(_ result: SoftwareEntry, run: UUID) {
        guard !closed, generation == run, let index = entries.firstIndex(where: { $0.id == result.id }) else { return }; entries[index] = result
    }
    private func recordUpgradeFailure(entry: SoftwareEntry, error: String, run: UUID) {
        guard !closed, generation == run else { return }
        if errors.count < 100 { errors.append(localized("\(entry.name) 升级失败：\(error)")) }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].note = localized("升级失败：\(error)")
            entries[index].blockedReason = localized("升级失败：\(error)")
        }
    }
    func shutdown(_ completion: @escaping @MainActor @Sendable () -> Void) {
        closed = true; confirmation = nil
        if !operating { token?.cancel(); task?.cancel() }
        let pending = task
        Task { await pending?.value; checking = false; operating = false; completion() }
    }
}
