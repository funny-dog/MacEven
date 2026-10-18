import Foundation
import AppKit
import Combine
import Darwin
import MacEvenCore

// A failed GUI check must exit with a log, not trap and open macOS crash dialogs.
func windowFailure(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> Never {
    fputs("FAIL: \(file):\(line): \(message)\n", stderr)
    exit(EXIT_FAILURE)
}
func windowRequire(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "condition failed", file: StaticString = #fileID, line: UInt = #line) {
    if !condition() { windowFailure(message(), file: file, line: line) }
}

// Integration harness uses the real app delegate, view and model; production has no test switches.
@main struct WindowChecks {
    @MainActor static func main() throws {
        let config = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/fixture.txt")
        let root = URL(fileURLWithPath: try String(contentsOf: config, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        fputs("WindowChecks bundle=\(Bundle.main.bundleURL.path) id=\(Bundle.main.bundleIdentifier ?? "none")\n", stderr)
        let cutoffNow = Date(timeIntervalSince1970: 1_800_000_000)
        let form = SpaceFilterForm(category: .document, minMiB: "1", maxMiB: "2", days: 30)
        let frozen = try form.filter(now: cutoffNow)
        windowRequire(frozen.minAllocated == 1_048_576 && frozen.maxAllocated == 2_097_152)
        windowRequire(frozen.notModifiedSince == 1_797_408_000_000_000_000, "time cutoff not frozen in nanoseconds")
        for text in ["-1", "1.5", "9223372036854775808", "8796093022208"] {
            do { _ = try SpaceFilterForm(minMiB: text).filter(now: cutoffNow); windowFailure("invalid MiB accepted: \(text)") }
            catch { }
        }
        do { _ = try SpaceFilterForm(minMiB: "2", maxMiB: "1").filter(now: cutoffNow); windowFailure("reversed range accepted") }
        catch { }
        let spaceTree = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/MacEven-window-space-\(UUID())")
        let spaceDocs = spaceTree.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: spaceDocs, withIntermediateDirectories: true)
        for i in 0..<105 { try Data([1]).write(to: spaceDocs.appendingPathComponent("file-\(i).PDF")) }
        for name in ["image.jpg", "movie.MP4", "sound.mp3", "archive.zip", "code.swift", "unknown"] {
            try Data([2]).write(to: spaceTree.appendingPathComponent(name))
        }
        defer { try? FileManager.default.removeItem(at: spaceTree) }
        let app = NSApplication.shared
        let model = AppModel(cacheDirectory: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("window-check-cache"))
        let monitor = MonitorModel(historyURL: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("window-check-history/monitor.sqlite"))
        let cacheHome = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-window-cache-\(UUID())")
        try FileManager.default.createDirectory(at: cacheHome.appendingPathComponent("Library/Caches/test.window"), withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: cacheHome.appendingPathComponent("Library/Caches/test.window/data"))
        var developerTrash: [URL] = []
        defer { for path in developerTrash { try? FileManager.default.removeItem(at: path) }; try? FileManager.default.removeItem(at: cacheHome) }
        let cache = CacheModel(home: cacheHome, applications: [CacheApplication(id: "test.window", name: "Window Cache App")], cacheDirectory: cacheHome.appendingPathComponent("sessions"), isRunning: { _ in false }, developerActivity: { _, _ in nil })
        let testApp = cacheHome.appendingPathComponent("Applications/Window App.app/Contents")
        try FileManager.default.createDirectory(at: testApp, withIntermediateDirectories: true)
        let appInfo = ["CFBundleIdentifier": "test.window", "CFBundleName": "Window App", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0).write(to: testApp.appendingPathComponent("Info.plist"))
        // dock: nil —— 窗口检查不读写真实 Dock。
        let removal = ApplicationRemovalModel(home: cacheHome, roots: [try canonicalFileURL(cacheHome.appendingPathComponent("Applications"))], cacheDirectory: cacheHome.appendingPathComponent("app-sessions"), isRunning: { _ in false }, dock: nil)
        let duplicateHome = try canonicalFileURL(cacheHome)
        let duplicateTree = duplicateHome.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: duplicateTree, withIntermediateDirectories: true)
        for name in ["keep", "copy"] { try Data([8,9,10]).write(to: duplicateTree.appendingPathComponent(name)) }
        let duplicate = DuplicateModel(home: duplicateHome, cacheDirectory: duplicateHome.appendingPathComponent("duplicate-sessions"))
        // 夹具是 3 字节小文件：按“全部大小”扫描才能形成重复组（默认 1 MB 门槛会全部过滤）。
        duplicate.minimumSize = 1
        // 域名会登记到 MACEVEN_TEST_DEFAULTS_LOG，进程退出后由 check-window.sh 删除残留 plist。
        let (defaults, suite) = makeTestDefaults(prefix: "MacEven.WindowChecks")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StatusSettings(defaults: defaults)
        windowRequire(!settings.advancedMode, "default interface is not simple mode")
        // 下面的流程覆盖树状图、启动项等进阶界面，先切到高级模式；结尾再验证简洁模式的归一。
        settings.advancedMode = true
        let tools = SystemTools()
        let stats = OperationStats(defaults: defaults)
        let softwareSample = SoftwareEntry(id: "test.software.window", name: "Software Window Sample", version: "1.0", source: .unknown)
        let software = SoftwareModel(scan: { _ in SoftwareScanResult(entries: [softwareSample]) }, startup: StartupItems(home: cacheHome, systemRoots: [], runner: { _, args in
            SoftwareCommandResult(status: 0, output: args.first == "list" ? "PID\tStatus\tLabel\n" : "disabled services = {\n}\n", error: "")
        }))
        // 日志与保护列表使用临时位置，不写入真实的 ~/Library/Logs/MacEven 或用户保护列表。
        let journal = OperationJournal(log: OperationLog(directory: cacheHome.appendingPathComponent("window-logs")))
        let protection = ProtectionModel(store: ProtectionStore(url: cacheHome.appendingPathComponent("window-protection.json")))
        // 智能扫描的“其他存储”只统计临时主目录。
        let smart = SmartScanModel(cache: cache, removal: removal, home: cacheHome)
        let delegate = AppDelegate(model: model, monitor: monitor, cache: cache, removal: removal, duplicate: duplicate,
            settings: settings, tools: tools, stats: stats, notifications: StatusNotifications(defaults: defaults), software: software,
            journal: journal, protection: protection, smart: smart)
        app.delegate = delegate; app.setActivationPolicy(.regular)
        let base = Date()
        let samples = [
            SystemSnapshot(timestamp: base, uptime: 1, cpuPercent: 10, networkRate: NetworkRate(download: 1, upload: 2), networkGeneration: 1),
            SystemSnapshot(timestamp: base.addingTimeInterval(2), uptime: 3),
            SystemSnapshot(timestamp: base.addingTimeInterval(4), uptime: 5, cpuPercent: 30),
            SystemSnapshot(timestamp: base.addingTimeInterval(30), uptime: 31, cpuPercent: 40)
        ]
        let points = monitorPoints(metric: .cpu, recent: samples, history: [], historical: false)
        windowRequire(points.count == 3 && points[0].segment != points[1].segment && points[1].segment != points[2].segment, "chart bridged missing data or sleep gap")
        windowRequire(isolatedMonitorPointIDs(points) == [0, 2, 3], "isolated historical segments have no visible markers")
        let memoryPoints = monitorPoints(metric: .memory, recent: [SystemSnapshot(timestamp: base, uptime: 1, usedMemoryBytes: 1_073_741_824)], history: [], historical: false)
        windowRequire(memoryPoints.count == 1 && memoryPoints[0].value == 1, "memory chart did not convert bytes to GiB numerically")
        let chartDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-chart-check-\(UUID())")
        let chartStore = try MonitorHistory(url: chartDirectory.appendingPathComponent("history.sqlite"))
        let chartMinute = Int64(Date().timeIntervalSince1970 / 60) * 60 - 180
        for offset in 0..<3 {
            var value = MinuteAggregate(minuteUTC: chartMinute + Int64(offset * 60), cpu: AggregateValue(value: 20, seconds: 60))
            value.memory = AggregateValue(value: 1_073_741_824, seconds: 60)
            value.download = AggregateValue(value: 1_048_576, seconds: 60); value.interface = "接口切换"
            try chartStore.write(value, now: Date())
        }
        let mixedHistory = try chartStore.query(from: Date(timeIntervalSince1970: Double(chartMinute)), to: Date())
        chartStore.close(); try FileManager.default.removeItem(at: chartDirectory)
        let mixedCPU = monitorPoints(metric: .cpu, recent: [], history: mixedHistory, historical: true)
        let mixedRAM = monitorPoints(metric: .memory, recent: [], history: mixedHistory, historical: true)
        let mixedNetwork = monitorPoints(metric: .download, recent: [], history: mixedHistory, historical: true)
        windowRequire(mixedCPU.count == 3 && Set(mixedCPU.map(\.segment)).count == 1 && mixedRAM.allSatisfy { $0.value == 1 }, "interface changes cut CPU or changed RAM chart values")
        windowRequire(isolatedMonitorPointIDs(mixedNetwork) == [0, 1, 2], "mixed interfaces connected network history")
        for jump in [122.0, -122.0] {
            let shifted = monitorPoints(metric: .cpu, recent: [
                SystemSnapshot(timestamp: base, uptime: 1, cpuPercent: 10),
                SystemSnapshot(timestamp: base.addingTimeInterval(jump), uptime: 3, cpuPercent: 20)
            ], history: [], historical: false)
            windowRequire(shifted.count == 2 && shifted[0].segment != shifted[1].segment, "real-time chart bridged wall-clock jump")
        }
        var scanSamples = 0
        let observation = monitor.$snapshot.sink { value in if model.scanning && value != nil { scanSamples += 1 } }
        model.start(root: root)
        _ = Task { @MainActor in
            let deadline = Date().addingTimeInterval(120)
            while monitor.snapshot?.cpuPercent == nil || model.scanning {
                windowRequire(Date() < deadline, "window did not start monitoring")
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let item = Mirror(reflecting: delegate).children.compactMap({ $0.value as? NSStatusItem }).first,
                let label = item.button?.accessibilityLabel() else { windowFailure("status accessibility label missing") }
            windowRequire(label.contains("CPU") && label.contains("RAM") && label.contains("%"), "status accessibility label omitted live metrics")
            settings.primaryMetric = .gpu; settings.secondaryMetric = .thermal; settings.layoutStyle = .stacked; settings.showNetworkSpeed = true
            try await Task.sleep(for: .seconds(1))
            windowRequire(item.button?.accessibilityLabel()?.contains("GPU") == true && item.button?.accessibilityLabel()?.contains("TEMP") == true, "menu settings did not reach actual status item")
            settings.primaryMetric = .cpu; settings.secondaryMetric = .ram; settings.layoutStyle = .horizontal; settings.showNetworkSpeed = false
            settings.menuBarOnly = true
            try await Task.sleep(for: .milliseconds(200))
            windowRequire(NSApp.activationPolicy() == .accessory, "menu-only mode did not hide Dock")
            settings.menuBarOnly = false
            try await Task.sleep(for: .milliseconds(200))
            windowRequire(NSApp.activationPolicy() == .regular, "normal mode did not restore Dock")
            settings.globalHotkeyEnabled = true
            try await Task.sleep(for: .milliseconds(200))
            windowRequire(settings.hotkeyError == nil, "real global shortcut registration failed")
            settings.globalHotkeyEnabled = false
            if !CommandLine.arguments.contains("--feature-integration") {
                tools.keepAwake(minutes: 15)
                windowRequire(tools.awakeUntil != nil && tools.error == nil, "native awake assertion failed")
                tools.prepareForSleep(); windowRequire(tools.awakeUntil == nil, "sleep failed to release tools")
            }
            windowRequire(monitor.hardware?.cpu.cores.count == ProcessInfo.processInfo.processorCount, "native per-core reading missing")
            for _ in 0..<3 where scanSamples < 2 {
                model.start(root: root)
                while model.scanning { try await Task.sleep(for: .milliseconds(20)) }
            }
            var peakUsage = rusage(); windowRequire(getrusage(RUSAGE_SELF, &peakUsage) == 0)
            print("scanAndWindowPeakRSS=\(peakUsage.ru_maxrss) concurrentSamples=\(scanSamples)")
            windowRequire(scanSamples >= 2, "fixture finished too early to verify concurrent scan and monitoring")
            guard let window = NSApp.windows.first(where: { $0.title == "MacEven" }) else { windowFailure("main window missing") }
            model.page = .disk
            model.showSpaceInsights()
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.browseMode == .spaceInsights && model.entries.count <= 100)
            windowRequire(model.categoryStats.reduce(0) { $0 + $1.count } == 100000, "category scope total missing fixture files")
            windowRequire(model.filteredCount == 100000 && model.canNext)
            model.load(offset: 100)
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.entries.count == 100 && model.offset == 100)
            model.applySpaceFilter(try SpaceFilter(category: .document))
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.entries.isEmpty && model.filteredCount == 0)
            model.clearSpaceFilter()
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.entries.count == 100 && model.offset == 0)
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(window.isVisible, "space insights native window missing")
            model.start(root: spaceTree)
            while model.scanning || model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.categoryStats.count == 7 && model.categoryStats.allSatisfy { $0.count > 0 }, "seven native categories missing")
            if CommandLine.arguments.contains("--inspect-space") { print("INSPECT: seven categories ready"); fflush(stdout); try await Task.sleep(for: .seconds(20)) }
            model.setBrowseMode(.directory)
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            model.setBrowseMode(.treemap)
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.treemapSnapshot?.totalCount == 7 && model.entries.count == 7, "root treemap data missing")
            let documentDirectory = model.entries.first { $0.name == "Documents" }!
            model.load(directory: documentDirectory.id)
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.treemapSnapshot?.totalCount == 105 && model.entries.count == 64, "treemap used the current page instead of complete directory")
            windowRequire(model.treemapSnapshot?.otherCount == 41, "treemap other summary missing")
            model.selectTreemapEntry(model.entries[0].id)
            windowRequire(model.selection.count == 1 && model.selectedEntries.count == 1)
            for size in [NSSize(width: 1000, height: 700), NSSize(width: 1200, height: 800)] {
                window.setContentSize(size)
                try await Task.sleep(for: .milliseconds(300))
                windowRequire(window.isVisible && model.treemapSnapshot?.totalCount == 105, "resize lost treemap scope")
            }
            model.load(directory: documentDirectory.id)
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            model.showSpaceInsights()
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.filteredCount == 105 && model.entries.count == 100)
            model.load(offset: 100)
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(model.entries.count == 5 && !model.canNext)
            model.selection = [model.entries[0].id]; model.prepareTrash()
            let confirmedPaths = model.trashConfirmation!.entries.map { $0.url.path }
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(!window.sheets.isEmpty, "disk native fixed-target confirmation missing")
            model.selection = []
            windowRequire(model.trashConfirmation?.entries.map { $0.url.path } == confirmedPaths)
            model.applySpaceFilter(try SpaceFilter(category: .image))
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(window.sheets.isEmpty && model.trashConfirmation == nil, "filter did not dismiss stale native confirmation")
            model.clearSpaceFilter()
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            cache.start()
            while cache.busy { try await Task.sleep(for: .milliseconds(50)) }
            delegate.openCleanup()
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(model.page == .cleanup && window.isVisible, "cleanup menu did not navigate to real page")
            windowRequire(cache.groups.count == 1 && cache.groups[0].logicalSize == 3)
            windowRequire(CacheCatalog.isRunning("local.maceven.windowchecks"), "native running-app check missed this real App")
            cache.selection = ["test.window"]; smart.prepareCleanup()
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(!window.sheets.isEmpty, "cleanup confirmation did not present native sheet")
            cache.selection = []
            windowRequire(cache.confirmation?.groups.first?.paths.count == 1)
            smart.dismissConfirmation()
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(window.sheets.isEmpty, "cleanup confirmation did not dismiss")
            let hash = String(repeating: "a", count: 56)
            let metadata = cacheHome.appendingPathComponent("Library/Caches/pip/http-v2/a/a/a/a/a/" + hash)
            try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("cc=4,metadata".utf8).write(to: metadata)
            try Data([1,2,3]).write(to: URL(fileURLWithPath: metadata.path + ".body"))
            cache.developerSelected = true
            cache.developer.start(); windowRequire(cache.busy && cache.developer.scanning, "developer busy missing from the shared cache model")
            cache.cancel()
            while cache.busy { try await Task.sleep(for: .milliseconds(20)) }
            windowRequire(cache.developer.incomplete, "shared menu cancellation missed the developer scan")
            cache.developer.start()
            while cache.busy { try await Task.sleep(for: .milliseconds(20)) }
            windowRequire(cache.developer.groups.count == 1 && cache.developer.selection.isEmpty && !cache.developer.canClean, "developer defaults or native scope incorrect")
            cache.developer.select("pip", selected: true); smart.prepareCleanup()
            let developerFrozen = cache.developer.confirmation!
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(!window.sheets.isEmpty, "developer native confirmation missing")
            cache.developer.select("pip", selected: false)
            windowRequire(cache.developer.confirmation == developerFrozen, "developer native confirmation changed with selection")
            let beforeMoved = stats.movedItems
            smart.executeCleanup()
            while smart.busy || cache.busy { try await Task.sleep(for: .milliseconds(20)) }
            developerTrash += cache.developer.results.compactMap(\.destination)
            windowRequire(cache.developer.results.count == 1 && cache.developer.results[0].destination != nil && cache.developer.results[0].error == nil, "developer temporary sample failed to move")
            windowRequire(stats.movedItems == beforeMoved + 1, "developer operation was not recorded by the real app delegate")
            journal.flush()
            for _ in 0..<100 where !journal.recent.contains(where: { $0.source == "developer" && $0.moved }) { try await Task.sleep(for: .milliseconds(20)) }
            windowRequire(journal.recent.contains { $0.source == "developer" && $0.moved && $0.allocatedSize != nil } && journal.failure == nil, "developer operation missing from operation log")
            windowRequire(FileManager.default.fileExists(atPath: journal.log.fileURL.path) && journal.log.fileURL.path.hasPrefix(cacheHome.path), "window check wrote outside its temporary log")
            windowRequire(FileManager.default.fileExists(atPath: cacheHome.appendingPathComponent("Library/Caches/test.window/data").path), "developer cleanup touched application cache")
            cache.developerSelected = false
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(window.sheets.isEmpty, "developer sheet did not close after operation")
            removal.start()
            while removal.busy { try await Task.sleep(for: .milliseconds(50)) }
            delegate.openApplications()
            software.tab = .updates
            software.refresh()
            while software.busy { try await Task.sleep(for: .milliseconds(20)) }
            windowRequire(software.entries.count == 1 && window.isVisible, "software updates view missing")
            software.tab = .startup
            software.refreshStartup()
            while software.busy { try await Task.sleep(for: .milliseconds(20)) }
            windowRequire(software.startupItems.isEmpty && software.errors.isEmpty, "software startup view fixture failed")
            software.tab = .uninstall
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(model.page == .applications && removal.applications.count == 1 && window.isVisible, "application page missing")
            removal.selection = removal.applications[0].id; removal.prepareRemoval()
            while removal.busy { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(!window.sheets.isEmpty, "application removal confirmation not presented")
            windowRequire(removal.confirmation?.application.cachePaths.count == 1)
            removal.selection = nil; removal.dismissConfirmation()
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(window.sheets.isEmpty, "application removal sheet not dismissed")
            removal.removalMode = .includingData
            removal.selection = removal.applications[0].id; removal.prepareRemoval()
            while removal.busy { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(!window.sheets.isEmpty && removal.confirmation?.dataPlans.first?.paths.count == 1, "full uninstall data confirmation missing")
            removal.dismissConfirmation(); removal.removalMode = .appOnly
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(window.sheets.isEmpty && FileManager.default.fileExists(atPath: testApp.path), "full uninstall cancel changed app")
            software.tab = .leftovers
            removal.leftovers.start()
            while removal.busy { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(model.page == .cleanup && software.tab == .uninstall && window.isVisible && removal.leftovers.groups.allSatisfy { $0.id != "test.window" } && removal.leftovers.results.isEmpty, "leftover tab or scan scope failed")
            software.tab = .uninstall
            duplicate.start(scope: .folder(duplicateTree))
            while duplicate.busy { try await Task.sleep(for: .milliseconds(50)) }
            delegate.openDuplicates()
            windowRequire(model.page == .disk && model.browseMode == .duplicates && duplicate.groups.count == 1)
            duplicate.loadMembers(groupID: duplicate.groups[0].id, offset: 0)
            while duplicate.busy { try await Task.sleep(for: .milliseconds(50)) }
            let keeper = duplicate.members.first { $0.name == "keep" }!
            let copy = duplicate.members.first { $0.name == "copy" }!
            duplicate.keep(id: keeper.id); duplicate.selectedIDs = [keeper.id]
            windowRequire(!duplicate.canClean, "native duplicate page allowed selected keeper")
            duplicate.selectedIDs = [copy.id]; duplicate.prepareCleanup()
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(!window.sheets.isEmpty, "duplicate native confirmation missing")
            duplicate.selectedIDs = []
            windowRequire(duplicate.confirmation?.targetPaths == [copy.url.path] && duplicate.confirmation?.keeperPath == keeper.url.path)
            duplicate.dismissConfirmation()
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(window.sheets.isEmpty, "duplicate confirmation did not dismiss")
            model.page = .overview
            smart.scanAll()
            while smart.busy { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(model.page == .cleanup && smart.phase == .ready && smart.selectedCount == 0 && window.isVisible, "smart scan page did not finish or selected by default")
            model.page = .settings
            windowRequire(protection.addIdentifier("test.window.protected") && protection.entries.count == 1, "settings protection list rejected a valid identifier")
            try await Task.sleep(for: .milliseconds(500))
            windowRequire(window.isVisible && !journal.recent.isEmpty, "settings page with protection and operation cards not shown")
            model.page = .system
            try await Task.sleep(for: .milliseconds(300))
            delegate.togglePopover(nil)
            try await Task.sleep(for: .seconds(2))
            windowRequire(monitor.processList != nil, "visible menu has no processes")
            window.performClose(nil)
            try await Task.sleep(for: .milliseconds(200))
            // Transient AppKit popovers may close when the main window closes.
            delegate.openWindow()
            for _ in 0..<3 {
                delegate.togglePopover(nil)
                try await Task.sleep(for: .milliseconds(100))
                delegate.togglePopover(nil)
            }
            window.miniaturize(nil)
            try await Task.sleep(for: .seconds(2))
            windowRequire(monitor.processList == nil, "minimized window kept process polling")
            window.deminiaturize(nil)
            try await Task.sleep(for: .seconds(2))
            let beforeClose = monitor.snapshot?.uptime
            window.performClose(nil)
            try await Task.sleep(for: .seconds(3))
            windowRequire(monitor.snapshot?.uptime != beforeClose, "window close stopped sampling")
            windowRequire(monitor.processList == nil, "closed window kept refreshing processes")
            if CommandLine.arguments.contains("--status-resource") || CommandLine.arguments.contains("--status-hidden-resource") {
                if let popup = Mirror(reflecting: delegate).children.compactMap({ $0.value as? NSPopover }).first { popup.behavior = .applicationDefined }
                for phase in CommandLine.arguments.contains("--status-resource") ? ["foreground", "menu", "hidden"] : ["hidden"] {
                    if phase == "foreground" { delegate.openWindow(); model.page = .system }
                    if phase == "menu" { window.performClose(nil); delegate.togglePopover(nil) }
                    if phase == "hidden", let popup = Mirror(reflecting: delegate).children.compactMap({ $0.value as? NSPopover }).first, popup.isShown { delegate.togglePopover(nil) }
                    try await Task.sleep(for: .seconds(3))
                    var startUsage = rusage(); windowRequire(getrusage(RUSAGE_SELF, &startUsage) == 0)
                    let start = ProcessInfo.processInfo.systemUptime
                    print("statusResource start phase=\(phase)"); fflush(stdout)
                    var minimum = UInt64.max; var maximum: UInt64 = 0
                    while ProcessInfo.processInfo.systemUptime - start < 600 {
                        var info = rusage_info_v2()
                        let status = withUnsafeMutablePointer(to: &info) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }
                        windowRequire(status == 0)
                        minimum = min(minimum, info.ri_resident_size); maximum = max(maximum, info.ri_resident_size)
                        windowRequire(monitor.recent.count <= 600 && monitor.hardwareRecent.count <= 600, "recent buffers exceeded limit")
                        try await Task.sleep(for: .seconds(1))
                    }
                    var endUsage = rusage(); windowRequire(getrusage(RUSAGE_SELF, &endUsage) == 0)
                    func cpuSeconds(_ usage: rusage) -> Double { Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000 }
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    let percent = (cpuSeconds(endUsage) - cpuSeconds(startUsage)) / elapsed / Double(ProcessInfo.processInfo.activeProcessorCount) * 100
                    print("statusResource phase=\(phase) seconds=\(elapsed) wholeMachineCPUPercent=\(percent) minRSS=\(minimum) maxRSS=\(maximum) cores=\(ProcessInfo.processInfo.activeProcessorCount)"); fflush(stdout)
                    windowRequire(percent < (phase == "hidden" ? 1 : 5), "monitor CPU exceeded measured acceptance budget")
                    if phase == "hidden" { windowRequire(monitor.processList == nil, "hidden process polling continued") }
                }
            }
            delegate.openWindow()
            windowRequire(window.isVisible, "main window did not reopen")
            windowRequire(model.rootEntry != nil, "reopening lost disk result")
            windowRequire(cache.groups.count == 1, "reopening lost cache result")
            windowRequire(removal.applications.count == 1, "reopening lost application result")
            windowRequire(duplicate.groups.count == 1 && duplicate.keeperID == keeper.id, "reopening lost duplicate result")
            // 简洁模式：启动项标签保留，树状图浏览切换后回到目录占用。
            software.tab = .startup
            model.setBrowseMode(.treemap)
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            settings.advancedMode = false
            try await Task.sleep(for: .milliseconds(500))
            while model.loading { try await Task.sleep(for: .milliseconds(50)) }
            windowRequire(window.isVisible && software.tab == .startup && model.browseMode == .directory, "simple mode did not leave advanced views")
            model.page = .system
            try await Task.sleep(for: .milliseconds(300))
            windowRequire(window.isVisible, "simple mode system page missing")
            withExtendedLifetime(observation) {}
            print("PASS: simple mode default and normalization of startup tab and treemap browsing")
            print("PASS: real window, treemap complete scope and resize, developer cancellation/frozen confirmation/temporary trash/statistics, cache/application/duplicate pages and native confirmations, running-app API, repeated popover, close/reopen, retained scans and monitoring")
            fflush(stdout)
            try FileManager.default.removeItem(at: spaceTree)
            delegate.quit()
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
