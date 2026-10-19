import Foundation
import AppKit
import MacEvenCore

final class InstallGate: @unchecked Sendable {
    private let lock = NSLock()
    let release = DispatchSemaphore(value: 0)
    private var started = false
    private var cancelled = false
    var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func install(_ token: CancellationToken) {
        lock.lock(); started = true; lock.unlock()
        release.wait()
        lock.lock(); cancelled = token.isCancelled; lock.unlock()
    }
}

final class Tracker: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return list }
    func add(_ val: String) { lock.lock(); list.append(val); lock.unlock() }
}

@main struct SoftwareModelChecks {
    @MainActor static func main() async throws {
        let entry = SoftwareEntry(id: "sample", name: "Sample", version: "1.0", source: .unknown)
        let model = SoftwareModel(scan: { _ in SoftwareScanResult(entries: [entry]) })
        model.refresh()
        while model.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(model.entries.count == 1 && model.entries[0].note.contains("未识别"), "unknown source not shown as current")
        model.prepareUpgrade(entry)
        precondition(model.confirmation == nil, "unsupported upgrade must not confirm")
        model.otherBusy = { true }; model.refresh()
        precondition(!model.busy, "other file operation must block updates")
        model.otherBusy = { false }; model.refresh()
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
        precondition(!model.busy && model.confirmation == nil, "shutdown must finish and reject late results")
        model.refresh(); precondition(!model.busy, "closed model cannot restart")
        // 更新检查按已检查的应用数显示精确进度；结束后清除。
        let pair = [SoftwareEntry(id: "a", name: "A", version: "1", source: .unknown), SoftwareEntry(id: "b", name: "B", version: "1", source: .unknown)]
        // a 先完成、b 后完成；两者并发执行，总耗时应接近较慢的一项而非两者之和
        let paced = SoftwareModel(scan: { _ in SoftwareScanResult(entries: pair) }, check: { entry, _ in try await Task.sleep(for: .milliseconds(entry.id == "a" ? 300 : 900)); return entry })
        let pacedStart = Date()
        paced.refresh()
        precondition(paced.checkingUpdates && paced.progressEstimate == .unknown, "catalog phase should be indeterminate")
        let pacedDeadline = Date().addingTimeInterval(10)
        while paced.checkedCount != 1 { precondition(Date() < pacedDeadline, "update check progress missing"); try await Task.sleep(for: .milliseconds(5)) }
        precondition(paced.progressEstimate.percentText == "50%", "update check progress wrong: \(paced.progressEstimate)")
        while paced.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(Date().timeIntervalSince(pacedStart) < 1.15, "update checks must run concurrently")
        precondition(!paced.checkingUpdates && paced.checkedCount == nil && paced.progressEstimate == .unknown, "update progress left after check")
        var old = SoftwareEntry(id: "formula:sample", name: "Sample", version: "1.0", source: .homebrewFormula)
        old.brewToken = "sample"; old.latestVersion = "2.0"; old.hasUpdate = true
        var new = SoftwareEntry(id: old.id, name: old.name, version: "2.0", source: .homebrewFormula)
        new.brewToken = "sample"; new.latestVersion = "2.0"
        let initial = old, updated = new, gate = InstallGate()
        let installation = SoftwareModel(scan: { _ in SoftwareScanResult(entries: [initial]) }, check: { entry, _ in entry }, upgrade: { _, token in gate.install(token); return updated })
        installation.refresh()
        while installation.busy { try await Task.sleep(for: .milliseconds(10)) }
        installation.prepareUpgrade(installation.entries[0]); installation.execute()
        while !gate.isStarted { try await Task.sleep(for: .milliseconds(10)) }
        var finished = false
        installation.shutdown { finished = true }
        try await Task.sleep(for: .milliseconds(30))
        precondition(!finished && installation.operating, "shutdown must wait for active installer")
        gate.release.signal()
        while !finished { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!gate.wasCancelled && !installation.busy, "active installer must finish without forced cancellation")

        // MARK: - 批量一键更新检查
        // 1. 批量正常：多项可升级项串行执行、忽略不可升级渠道（Sparkle/AppStore/固定版本）、避免搜索/分页漏项
        var item1 = SoftwareEntry(id: "formula:pkg1", name: "Pkg1", version: "1.0", source: .homebrewFormula)
        item1.brewToken = "pkg1"; item1.latestVersion = "2.0"; item1.hasUpdate = true
        var item2 = SoftwareEntry(id: "cask:pkg2", name: "Pkg2", version: "1.0", source: .homebrewCask)
        item2.brewToken = "pkg2"; item2.latestVersion = "1.5"; item2.hasUpdate = true
        var sparkleItem = SoftwareEntry(id: "sparkle:app", name: "SparkleApp", version: "1.0", source: .sparkle)
        sparkleItem.hasUpdate = true; sparkleItem.latestVersion = "2.0"
        var appStoreItem = SoftwareEntry(id: "appstore:app", name: "AppStoreApp", version: "1.0", source: .appStore)
        appStoreItem.hasUpdate = true; appStoreItem.latestVersion = "2.0"
        var currentStoreItem = SoftwareEntry(id: "appstore:current", name: "CurrentStoreApp", version: "2.0", source: .appStore)
        currentStoreItem.latestVersion = "2.0"
        var blockedStoreItem = SoftwareEntry(id: "appstore:system", name: "SystemStoreApp", version: "1.0", source: .appStore)
        blockedStoreItem.hasUpdate = true; blockedStoreItem.latestVersion = "2.0"
        blockedStoreItem.blockedReason = "系统和 MacEven 自身由对应系统更新入口管理。"
        var blockedItem = SoftwareEntry(id: "formula:blocked", name: "BlockedPkg", version: "1.0", source: .homebrewFormula)
        blockedItem.brewToken = "blocked"; blockedItem.latestVersion = "2.0"; blockedItem.hasUpdate = true
        blockedItem.blockedReason = "Homebrew 固定版本，保留。"

        let batchItems = [item1, item2, sparkleItem, appStoreItem, currentStoreItem, blockedStoreItem, blockedItem]
        let upgradedOrder = Tracker()
        let batchModel = SoftwareModel(
            scan: { _ in SoftwareScanResult(entries: batchItems) },
            check: { entry, _ in entry },
            upgrade: { entry, _ in
                upgradedOrder.add(entry.id)
                var updated = SoftwareEntry(id: entry.id, name: entry.name, url: entry.url, bundleIdentifier: entry.bundleIdentifier, version: entry.latestVersion ?? "2.0", source: entry.source)
                updated.brewToken = entry.brewToken
                updated.latestVersion = entry.latestVersion
                updated.hasUpdate = false
                return updated
            }
        )
        batchModel.refresh()
        while batchModel.busy { try await Task.sleep(for: .milliseconds(10)) }

        // 仅 Homebrew 且无阻挡的项可直接升级；商店入口只汇总有更新且无阻挡的 App Store 应用
        precondition(batchModel.upgradableEntries.count == 2, "only canUpgrade entries allowed in upgradableEntries")
        precondition(batchModel.appStoreUpdatableEntries.map(\.id) == ["appstore:app"], "store batch must include only updatable, unblocked App Store entries")
        // 避免搜索过滤或分页漏项
        batchModel.search = "nonexistent"
        batchModel.offset = 100
        precondition(batchModel.filteredEntries.isEmpty && batchModel.visibleEntries.isEmpty, "filtered should be empty")
        batchModel.prepareUpgradeAll()
        precondition(batchModel.confirmation?.entries.count == 2, "batch confirmation must capture all upgradable items regardless of filter/offset")
        batchModel.search = ""; batchModel.offset = 0

        batchModel.execute()
        while batchModel.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(upgradedOrder.values == ["formula:pkg1", "cask:pkg2"], "upgrades must execute sequentially on supported items only")
        precondition(batchModel.entries.first(where: { $0.id == "formula:pkg1" })?.version == "2.0", "pkg1 version must be updated")
        precondition(batchModel.entries.first(where: { $0.id == "cask:pkg2" })?.version == "1.5", "pkg2 version must be updated")
        precondition(batchModel.status.contains("一键更新完成") && batchModel.status.contains("成功更新 2 个软件"), "batch success status wrong: \(batchModel.status)")
        precondition(batchModel.errors.isEmpty, "batch success errors should be empty")
        precondition(batchModel.appStoreUpdatableEntries.map(\.id) == ["appstore:app"], "store entries must stay for the store batch entry after Homebrew batch upgrade")

        // 2. 混合失败：单项失败记录错误并继续后续项，最终汇总成功与失败
        var failItem = SoftwareEntry(id: "formula:fail", name: "FailPkg", version: "1.0", source: .homebrewFormula)
        failItem.brewToken = "fail"; failItem.latestVersion = "2.0"; failItem.hasUpdate = true
        var okItem = SoftwareEntry(id: "formula:ok", name: "OkPkg", version: "1.0", source: .homebrewFormula)
        okItem.brewToken = "ok"; okItem.latestVersion = "2.0"; okItem.hasUpdate = true
        let mixItems = [failItem, okItem]

        let mixExecutionOrder = Tracker()
        let mixModel = SoftwareModel(
            scan: { _ in SoftwareScanResult(entries: mixItems) },
            check: { entry, _ in entry },
            upgrade: { entry, _ in
                mixExecutionOrder.add(entry.id)
                if entry.id == "formula:fail" { throw MacEvenError("下载依赖哈希校验失败") }
                var updated = SoftwareEntry(id: entry.id, name: entry.name, url: entry.url, bundleIdentifier: entry.bundleIdentifier, version: entry.latestVersion ?? "2.0", source: entry.source)
                updated.brewToken = entry.brewToken
                updated.latestVersion = entry.latestVersion
                updated.hasUpdate = false
                return updated
            }
        )
        mixModel.refresh()
        while mixModel.busy { try await Task.sleep(for: .milliseconds(10)) }
        mixModel.prepareUpgradeAll()
        mixModel.execute()
        while mixModel.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(mixExecutionOrder.values == ["formula:fail", "formula:ok"], "mix batch must continue after single failure")
        precondition(mixModel.entries.first(where: { $0.id == "formula:ok" })?.version == "2.0", "ok item should be updated")
        precondition(mixModel.entries.first(where: { $0.id == "formula:fail" })?.version == "1.0", "failed item should remain at old version")
        precondition(mixModel.errors.count == 1 && mixModel.errors[0].contains("FailPkg 升级失败：下载依赖哈希校验失败"), "failure must be recorded in errors")
        precondition(mixModel.status.contains("1 项成功") && mixModel.status.contains("1 项失败"), "mix status wrong: \(mixModel.status)")

        // 3. 忙碌防重入：批量操作期间禁止重入 execute / prepareUpgradeAll / refresh
        var busyItem1 = SoftwareEntry(id: "formula:busy1", name: "Busy1", version: "1.0", source: .homebrewFormula)
        busyItem1.brewToken = "busy1"; busyItem1.latestVersion = "2.0"; busyItem1.hasUpdate = true
        var busyItem2 = SoftwareEntry(id: "formula:busy2", name: "Busy2", version: "1.0", source: .homebrewFormula)
        busyItem2.brewToken = "busy2"; busyItem2.latestVersion = "2.0"; busyItem2.hasUpdate = true
        let busyItems = [busyItem1, busyItem2]
        let busyGate = InstallGate()
        let reentrancyModel = SoftwareModel(
            scan: { _ in SoftwareScanResult(entries: busyItems) },
            check: { entry, _ in entry },
            upgrade: { entry, token in
                if entry.id == "formula:busy1" { busyGate.install(token) }
                var updated = SoftwareEntry(id: entry.id, name: entry.name, url: entry.url, bundleIdentifier: entry.bundleIdentifier, version: entry.latestVersion ?? "2.0", source: entry.source)
                updated.brewToken = entry.brewToken
                updated.latestVersion = entry.latestVersion
                updated.hasUpdate = false
                return updated
            }
        )
        reentrancyModel.refresh()
        while reentrancyModel.busy { try await Task.sleep(for: .milliseconds(10)) }
        reentrancyModel.prepareUpgradeAll()
        reentrancyModel.execute()
        while !busyGate.isStarted { try await Task.sleep(for: .milliseconds(10)) }
        precondition(reentrancyModel.operating && reentrancyModel.busy, "reentrancyModel must be operating")

        // 重复调用防御
        reentrancyModel.prepareUpgradeAll()
        precondition(reentrancyModel.confirmation == nil, "prepareUpgradeAll must be blocked when operating")
        reentrancyModel.execute()
        reentrancyModel.refresh()
        precondition(reentrancyModel.operating, "refresh must be blocked when operating")

        busyGate.release.signal()
        while reentrancyModel.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!reentrancyModel.busy && reentrancyModel.status.contains("成功更新 2 个软件"), "reentrancyModel should complete properly")

        // 4. 启动项检查取消报告
        final class BlockingRunner: @unchecked Sendable {
            let lock = NSLock()
            private var started = false
            var entered: Bool { lock.withLock { started } }
            func run(url: URL, args: [String], token: CancellationToken?) throws -> SoftwareCommandResult {
                lock.withLock { started = true }
                let deadline = Date().addingTimeInterval(2)
                while token?.isCancelled != true && Date() < deadline { usleep(1_000) }
                precondition(token?.isCancelled == true, "read-only command did not receive cancellation")
                throw MacEvenError("检查已取消。")
            }
        }
        let blockingRunner = BlockingRunner()
        let blockingStartup = StartupItems(systemRoots: [], cancellableRunner: blockingRunner.run)
        let startupModel = SoftwareModel(startup: blockingStartup)
        startupModel.refreshStartup()
        precondition(startupModel.busy, "model should be busy during startup refresh")
        let startupDeadline = Date().addingTimeInterval(2)
        while !blockingRunner.entered {
            precondition(Date() < startupDeadline, "startup command did not begin")
            try await Task.sleep(for: .milliseconds(5))
        }
        startupModel.cancel()
        while startupModel.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(startupModel.status.contains("检查已取消"), "cancelled startup refresh must report cancelled: \(startupModel.status)")

        print("Software model checks passed")
    }
}
