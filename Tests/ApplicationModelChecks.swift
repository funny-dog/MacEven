import Foundation
import Darwin
import MacEvenCore

final class ApplicationRunningState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var allowQuit = false
    private var requests = 0
    func set(_ value: Bool) { lock.withLock { running = value } }
    var quitRequests: Int { lock.withLock { requests } }
    func permitQuit() { lock.withLock { allowQuit = true } }
    func quit(_ id: String, _ url: URL?) -> String? {
        lock.withLock {
            guard running && id == "test.closed" else { return nil }
            requests += 1
            guard allowQuit else { return "测试应用拒绝退出，应用保留。" }
            running = false; return nil
        }
    }
    func check(_ app: InstalledApplication) -> Bool { lock.withLock { running && app.bundleIdentifier == "test.closed" } }
}

final class DockRestartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func restart() -> String? { lock.withLock { value += 1 }; return nil }
}

@main struct ApplicationModelChecks {
    @MainActor static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() { precondition(Date() < deadline, "application model did not settle"); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor static func main() async {
        do { try await check() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func check() async throws {
        let fm = FileManager.default
        let ownBundle = try canonicalFileURL(Bundle.main.bundleURL)
        precondition(ownBundle.path == Bundle.main.bundleURL.resolvingSymlinksInPath().path, "fixture must use an unaliased app path")
        precondition(ownBundle.pathExtension == "app", "run the packaged check-application-model.sh harness")
        let base = ownBundle.deletingLastPathComponent().deletingLastPathComponent()
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        var trash: [URL] = []
        defer { for path in trash { try? fm.removeItem(at: path) }; try? fm.removeItem(at: home) }
        for n in 0..<104 {
            let path = apps.appendingPathComponent("App-\(n).app/Contents")
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
            let id = n == 0 ? "test.closed" : "test.app\(n)"
            let plist = ["CFBundleIdentifier": id, "CFBundleName": "App \(n)", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path.appendingPathComponent("Info.plist"))
        }
        let running = ApplicationRunningState(), session = home.appendingPathComponent("app-sessions")
        let keptCache = home.appendingPathComponent("Library/Caches/test.closed")
        try fm.createDirectory(at: keptCache, withIntermediateDirectories: true)
        // 归属判断：父子标识、LaunchServices、运行中、启动项、同厂商依次判断，命中即停止。
        let owner = LeftoverCatalog.ownership(installedIdentifiers: ["com.vendor.app", "org.other.tool"], launchdLabels: ["io.cli.agent", "net.daemon.helper.updater"],
            launchServices: { $0 == "com.found.elsewhere" }, running: { $0 == "com.live.process" })
        precondition(owner("com.vendor.app") == .installed && owner("COM.VENDOR.APP.helper") == .installed && owner("com.vendor") != .orphan)
        precondition(owner("com.found.elsewhere") == .installed && owner("org.other.tool.extension") == .installed)
        if case .review = owner("com.live.process") {} else { preconditionFailure("running process not kept") }
        if case .review = owner("io.cli.agent") {} else { preconditionFailure("launchd label not kept") }
        if case .review = owner("net.daemon.helper") {} else { preconditionFailure("launchd child label not kept") }
        if case .review = owner("com.vendor.otherapp") {} else { preconditionFailure("same vendor not kept for review") }
        precondition(owner("com.gone.app") == .orphan && owner("org.otherwise.thing") == .orphan)

        // Dock 使用独立测试域，绝不读写真实 com.apple.dock，也不重启真实 Dock。
        let dockDomain = "local.maceven.applicationchecks.dock.\(UUID())", restarts = DockRestartCounter()
        defer {
            CFPreferencesSetAppValue("cleanup" as CFString, true as CFPropertyList, dockDomain as CFString)
            _ = CFPreferencesAppSynchronize(dockDomain as CFString)
            let delete = Process(); delete.executableURL = URL(fileURLWithPath: "/usr/bin/defaults"); delete.arguments = ["delete", dockDomain]
            delete.standardOutput = FileHandle.nullDevice; delete.standardError = FileHandle.nullDevice
            if (try? delete.run()) != nil { delete.waitUntilExit() }
        }
        func tile(_ path: String, _ label: String) -> [String: Any] {
            ["tile-data": ["file-label": label, "bundle-identifier": "test.unused", "file-data": ["_CFURLString": URL(fileURLWithPath: path).absoluteString + "/", "_CFURLStringType": 15]]]
        }
        let dockTarget = apps.appendingPathComponent("App-0.app").path
        CFPreferencesSetAppValue("persistent-apps" as CFString, [tile("/Applications/Safari.app", "Safari"), tile(dockTarget, "App 0")] as CFPropertyList, dockDomain as CFString)
        precondition(CFPreferencesAppSynchronize(dockDomain as CFString))
        let dock = DockCleaner(domain: dockDomain, backupDirectory: home.appendingPathComponent("dock-backups"), restart: { restarts.restart() })
        let leftoverRoot = home.appendingPathComponent("Library/Caches/com.example.leftover")
        try fm.createDirectory(at: leftoverRoot, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 4096).write(to: leftoverRoot.appendingPathComponent("data"))
        let snapshot: @Sendable () -> LeftoverOwnershipSnapshot = {
            LeftoverOwnershipSnapshot(check: { $0 == "com.example.leftover" ? .orphan : .installed }, incomplete: false, errors: [])
        }
        let model = ApplicationRemovalModel(home: home, roots: [apps], cacheDirectory: session, isRunning: running.check, quitApplication: running.quit, dock: dock, leftoverSnapshot: snapshot)
        model.start(); model.cancel(); model.start()
        try await wait { !model.busy }
        precondition(model.applications.count == 100 && model.canNext && !model.incomplete)
        model.selection = ownBundle.path
        precondition(!model.canRemove && model.selected?.blockedReason != nil && model.selected?.allocatedSize != nil, "running MacEven bundle size or removal protection missing")
        precondition(!model.canInspectData, "protected self bundle enabled unsupported related data inspection")
        model.load(offset: 100); precondition(model.applications.count == 5 && !model.canNext)
        model.load(offset: 0)
        // 搜索只过滤内存中的有界列表：命中数基于全部应用，重置分页，无结果不残留。
        let scannedCount = model.totalCount
        model.search = "App 42"; precondition(model.offset == 0 && model.matchedCount == 1 && model.applications.count == 1 && !model.canNext, "search did not narrow the list")
        model.search = "no-such-application"; precondition(model.matchedCount == 0 && model.applications.isEmpty && !model.canNext, "no-match search leaked items")
        model.search = ""; precondition(model.matchedCount == scannedCount && model.applications.count == min(scannedCount, 100) && model.canNext == (scannedCount > 100), "clearing search did not restore the list")
        let target = apps.appendingPathComponent("App-0.app").path
        running.set(true); model.recheck(); try await wait { !model.busy }
        model.selection = target; precondition(model.canRemove, "running app should be selectable for uninstall")
        running.set(false); precondition(model.canRemove, "running state incorrectly blocks uninstall preparation")
        model.recheck(); try await wait { !model.busy }; model.selection = target
        precondition(model.canRemove)
        model.prepareRemoval(); try await wait { !model.busy }; let frozen = model.confirmation!
        precondition(frozen.dockMatches.map(\.label) == ["App 0"], "dock tile for the selected application not found")
        model.selection = nil; precondition(model.confirmation == frozen)
        precondition(running.quitRequests == 0, "preparation quit before confirmation")
        running.set(true); model.executeRemoval(); try await wait { !model.busy }
        precondition(model.results.count == 1 && model.results[0].destination == nil && model.results[0].error != nil)
        running.set(false); model.recheck(); try await wait { !model.busy }
        model.selection = target; model.prepareRemoval(); model.start()
        try await wait { !model.busy }; model.executeRemoval()
        precondition(fm.fileExists(atPath: target), "stale confirmation removed application")
        model.selection = target; model.prepareRemoval(); try await wait { !model.busy }; model.selection = nil
        running.set(true); running.permitQuit()
        model.executeRemoval()
        try await wait { !model.busy }; trash += model.results.compactMap(\.destination)
        precondition(running.quitRequests == 2 && !running.check(frozen.application), "uninstall did not close the application")
        precondition(trash.count == 1 && model.results[0].error == nil && !fm.fileExists(atPath: target))
        let remainingTiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, dockDomain as CFString) as? [[String: Any]]
        precondition(remainingTiles?.count == 1 && restarts.count == 1 && model.dockMessage?.contains("1") == true, "dock tile not removed after a successful move")
        let dockBackups = try fm.contentsOfDirectory(atPath: home.appendingPathComponent("dock-backups").path)
        precondition(dockBackups.count == 1, "dock settings not backed up")
        precondition(model.lastOperation?.cachePaths.map(\.path) == [keptCache.path], "lost cache residual paths after removal")
        precondition(model.removalMode == .appOnly, "default no longer preserves data")
        let fullApplication = model.applications.first { $0.blockedReason == nil }!
        let fullTarget = fullApplication.id
        let fullData = home.appendingPathComponent("Library/Application Support/\(fullApplication.bundleIdentifier)")
        try fm.createDirectory(at: fullData, withIntermediateDirectories: true)
        let nameCandidate = home.appendingPathComponent("Library/Caches/\(fullApplication.name)")
        try fm.createDirectory(at: nameCandidate, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 8192).write(to: nameCandidate.appendingPathComponent("data"))
        model.selection = fullTarget; model.inspectRelatedData()
        try await wait { !model.busy }
        precondition(model.relatedData?.applicationID == fullTarget && model.relatedData?.items.count == 2 && model.relatedData!.allocatedSize > 0, "preview size or ownership missing")
        model.selection = nil
        precondition(model.relatedData == nil, "preview leaked to another selection")
        model.selection = fullTarget; model.inspectRelatedData(); model.selection = nil
        try await wait { !model.busy }
        precondition(model.relatedData == nil && model.message == nil, "stale preview or cancellation error published")
        model.selection = fullTarget; model.inspectRelatedData(); model.cancel()
        try await wait { !model.busy }
        precondition(model.relatedData == nil && model.confirmation == nil && model.message == nil, "cancelled preview published")
        let orphan = apps.appendingPathComponent("Orphan.app")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        let webApp = apps.appendingPathComponent("WebApp.app/Contents")
        try fm.createDirectory(at: webApp, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.web", "CFBundlePackageType": "AAPL"], format: .xml, options: 0).write(to: webApp.appendingPathComponent("Info.plist"))
        let malformed = apps.appendingPathComponent("Malformed.app/Contents")
        try fm.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("invalid plist".utf8).write(to: malformed.appendingPathComponent("Info.plist"))
        model.removalMode = .includingData; model.selection = fullTarget; model.prepareRemoval()
        try await wait { !model.busy }
        guard Set(model.confirmation?.dataPlans.first?.paths.map(\.path) ?? []) == Set([fullData.path, nameCandidate.path]) else {
            throw MacEvenError("full removal failed with the running MacEven bundle in the same Applications directory: \(model.message ?? model.status)")
        }
        precondition(model.confirmation?.relatedData?.items.count == 2, "full confirmation omitted retained candidates")
        model.removalMode = .appOnly; model.selection = nil; model.executeRemoval()
        try await wait { !model.busy }; trash += model.results.compactMap(\.destination)
        precondition(model.results.count == 3 && model.results.allSatisfy { $0.error == nil && $0.destination != nil })
        precondition(!fm.fileExists(atPath: fullTarget) && !fm.fileExists(atPath: fullData.path) && fm.fileExists(atPath: keptCache.path) && fm.fileExists(atPath: orphan.path), "frozen mode or isolated data failed")
        precondition(fm.fileExists(atPath: webApp.path) && fm.fileExists(atPath: malformed.path), "unrelated invalid bundles removed")
        precondition(!fm.fileExists(atPath: nameCandidate.path), "confirmed product-name cache was retained")
        precondition(restarts.count == 1, "dock restarted although no remaining tile matched")

        // 批量卸载：勾选跨页保留，确认冻结全部应用，逐个执行。
        model.recheck(); try await wait { !model.busy }
        let batch = model.applications.filter { $0.blockedReason == nil && $0.allocatedSize != nil }.prefix(2).map(\.id)
        precondition(batch.count == 2)
        for id in batch { model.check(id, selected: true) }
        model.load(offset: 100); precondition(model.checked.count == 2 && model.targets.count == 2 && model.canRemove, "batch selection lost across pages")
        model.removalMode = .appOnly; model.prepareRemoval(); try await wait { !model.busy }
        precondition(model.confirmation?.applications.map(\.id) == model.targets.map(\.id) && model.confirmation?.dataPlans.isEmpty == true)
        model.executeRemoval(); try await wait { !model.busy }; trash += model.results.compactMap(\.destination)
        precondition(model.results.count == 2 && model.results.allSatisfy { $0.destination != nil && $0.error == nil } && model.checked.isEmpty, "batch removal failed")
        precondition(batch.allSatisfy { !fm.fileExists(atPath: $0) })
        model.load(offset: 0)
        let candidates = model.applications.filter({ $0.blockedReason == nil && $0.allocatedSize != nil }).map(\.id)
        precondition(candidates.count > ApplicationRemovalModel.batchLimit)
        for id in candidates.prefix(ApplicationRemovalModel.batchLimit + 1) { model.check(id, selected: true) }
        precondition(model.checked.count <= ApplicationRemovalModel.batchLimit && model.message != nil, "batch limit not enforced")
        model.message = nil; model.clearChecked()

        // 一键检测全部应用数据：只读、可取消，完成后自动按「本体 + 数据」排序，可随时切回本体排序。
        // 重新扫描让刚创建的数据目录与无效包进入列表（recheck 只复核运行状态，不重扫文件系统）。
        model.start(); try await wait { !model.busy }
        model.load(offset: 0)
        let bulkTargets = Array(model.applications.filter {
            $0.blockedReason == nil && $0.allocatedSize != nil && !$0.bundleIdentifier.hasPrefix("com.apple.") && !$0.bundleIdentifier.hasPrefix("local.maceven")
        }.prefix(2))
        precondition(bulkTargets.count == 2, "not enough applications for bulk data inspection")
        let bigData = home.appendingPathComponent("Library/Caches/\(bulkTargets[0].bundleIdentifier)")
        let smallData = home.appendingPathComponent("Library/Caches/\(bulkTargets[1].bundleIdentifier)")
        try fm.createDirectory(at: bigData, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 32768).write(to: bigData.appendingPathComponent("data"))
        try fm.createDirectory(at: smallData, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 4096).write(to: smallData.appendingPathComponent("data"))
        precondition(model.canInspectAllData && model.inspectedDataCount == 0 && model.sortMode == .bundleSize, "bulk inspection precondition wrong")
        model.inspectAllData()
        try await wait { !model.busy }
        precondition(!model.inspectingAll && model.inspectedDataCount >= 2, "bulk inspection did not finish")
        precondition(model.sortMode == .totalSize, "bulk inspection did not switch to total sorting")
        precondition(model.preview(for: bulkTargets[0].id)?.allocatedSize == 32768 && model.preview(for: bulkTargets[1].id)?.allocatedSize == 4096, "bulk preview sizes wrong")
        precondition(model.totalSize(of: bulkTargets[0]) == 32768 + (bulkTargets[0].allocatedSize ?? 0), "total size helper wrong")
        precondition(zip(model.applications, model.applications.dropFirst()).allSatisfy { model.totalSize(of: $0) >= model.totalSize(of: $1) }, "total sorting order wrong")
        let ranking = Dictionary(uniqueKeysWithValues: model.applications.enumerated().map { ($0.element.id, $0.offset) })
        precondition((ranking[bulkTargets[0].id] ?? .max) < (ranking[bulkTargets[1].id] ?? .min), "total sorting did not put the larger data first")
        precondition(model.dataSkips[orphan.path] != nil, "orphan application missing a skip reason")
        precondition(model.dataSkipRows.contains { $0.name == "Malformed" && $0.reason.contains("标识") }, "skip reason missing for an unreadable identifier: \(model.dataSkipRows.map { "\($0.name)|\($0.reason.prefix(16))" })")
        precondition(model.dataSkipRows.contains { $0.reason.contains("MacEven 自身受保护") }, "MacEven itself not skipped with a reason")
        model.check(bulkTargets[0].id, selected: true); model.removalMode = .includingData
        precondition(model.targetDataTotals.included == 32768 && model.targetDataTotals.unknown == 0, "action bar totals did not reuse bulk data")
        model.removalMode = .appOnly; model.clearChecked()
        model.sortMode = .bundleSize
        precondition(zip(model.applications, model.applications.dropFirst()).allSatisfy { ($0.allocatedSize ?? 0) >= ($1.allocatedSize ?? 0) }, "bundle sorting not restored")
        model.inspectAllData(); model.cancel()
        try await wait { !model.busy }
        precondition(!model.inspectingAll && model.status.contains("取消") && model.sortMode == .bundleSize, "cancelled bulk inspection published wrong state: \(model.status)")
        model.start(); try await wait { !model.busy }
        precondition(model.sortMode == .bundleSize && model.inspectedDataCount == 0 && model.dataSkips.isEmpty, "rescan did not clear bulk data state")

        // 运行中彻底卸载：确认前不退出；退出产生的数据写入只在原确认范围内重新统计。
        let quitApp = apps.appendingPathComponent("QuitFull.app")
        let quitContents = quitApp.appendingPathComponent("Contents")
        try fm.createDirectory(at: quitContents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.closed", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: quitContents.appendingPathComponent("Info.plist"))
        let quitData = home.appendingPathComponent("Library/Application Support/test.closed")
        try fm.createDirectory(at: quitData, withIntermediateDirectories: true)
        try Data([1]).write(to: quitData.appendingPathComponent("data"))
        let quitState = ApplicationRunningState(); quitState.set(true); quitState.permitQuit()
        let quitModel = ApplicationRemovalModel(home: home, roots: [apps], cacheDirectory: home.appendingPathComponent("quit-sessions"),
            isRunning: quitState.check, quitApplication: { id, url in
                guard url?.path == quitApp.path, id == "test.closed" else { return "退出对象错误" }
                if let failure = quitState.quit(id, url) { return failure }
                do { try Data([1,2,3,4]).write(to: quitData.appendingPathComponent("data")) } catch { return error.localizedDescription }
                return nil
            }, dock: nil, leftoverSnapshot: snapshot)
        quitModel.start(); try await wait { !quitModel.busy }
        quitModel.check(quitApp.path, selected: true); quitModel.removalMode = .includingData
        precondition(quitModel.canRemove, "running full uninstall cannot be selected")
        quitModel.prepareRemoval(); try await wait { !quitModel.busy }
        precondition(quitModel.confirmation != nil && quitState.quitRequests == 0, "preparation quit the app or omitted data confirmation")
        quitModel.executeRemoval(); try await wait { !quitModel.busy }
        trash += quitModel.results.compactMap(\.destination)
        precondition(quitState.quitRequests == 1 && quitModel.results.count == 3 && quitModel.results.allSatisfy { $0.destination != nil && $0.error == nil }, "running full uninstall failed: \(quitModel.results)")
        precondition(!fm.fileExists(atPath: quitApp.path) && !fm.fileExists(atPath: quitData.path))
        let quitError: String? = await withCheckedContinuation { continuation in quitModel.shutdown { continuation.resume(returning: $0) } }
        precondition(quitError == nil)

        // 卸载残留子模型：与卸载互斥，默认未选，执行前复核归属并经日志钩子记录。
        let recorded = DockRestartCounter()
        model.leftovers.recordOperation = { _ in _ = recorded.restart() }
        model.leftovers.start(); precondition(model.busy, "leftover scan not reflected in removal busy state")
        model.start(); precondition(!model.scanning, "application scan started during leftover scan")
        try await wait { !model.busy }
        precondition(model.leftovers.groups.map(\.id) == ["com.example.leftover"] && model.leftovers.selection.isEmpty && !model.leftovers.incomplete)
        model.leftovers.select("com.example.leftover", selected: true); model.leftovers.prepareCleanup()
        precondition(model.leftovers.confirmation?.groups.count == 1)
        model.leftovers.executeCleanup(); try await wait { !model.busy }
        trash += model.leftovers.results.compactMap(\.destination)
        precondition(model.leftovers.results.count == 1 && model.leftovers.results[0].destination != nil && !fm.fileExists(atPath: leftoverRoot.path) && recorded.count == 1, "leftover cleanup failed")
        for _ in 0..<12 {
            model.start(); try await wait { !model.busy }
            precondition(model.applications.count <= 100)
            let folders = try fm.contentsOfDirectory(at: session, includingPropertiesForKeys: [])
            precondition(folders.filter { $0.lastPathComponent.hasPrefix("session-") }.count == 1, "application sessions accumulated")
        }
        let disk = AppModel(cacheDirectory: home.appendingPathComponent("disk-sessions"))
        let tree = home.appendingPathComponent("tree")
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        disk.start(root: tree); try await wait { !disk.busy && !disk.loading }
        let error: String? = await withCheckedContinuation { c in model.shutdown { c.resume(returning: $0) } }
        precondition(error == nil && disk.rootEntry != nil)
        model.start(); precondition(!model.scanning)
        let diskError: String? = await withCheckedContinuation { c in disk.shutdown { c.resume(returning: $0) } }
        precondition(diskError == nil)
        print("PASS: application model pagination, restart, running recheck, frozen and stale confirmation, owned trash, 12 bounded sessions, isolated shutdown, bulk data inspection with total sorting")
    }
}
