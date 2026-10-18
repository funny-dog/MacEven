import AppKit
import SwiftUI
import MacEvenCore

// 只布局独立的隐藏测试窗口，不打开或操作用户正在使用的应用。
@main struct DiskLayoutChecks {
    @MainActor static func main() async throws {
        precondition(AppPage.disk.sidebarPage == .disk)
        precondition(AppPage.sidebarGroups.flatMap(\.pages).contains(.disk))
        precondition(AppPage.applications.order == 6 && AppPage.settings.order == 7, "order 5 stays reserved for the duplicate-files browse shortcut")
        precondition(AppPage.cleanup.title == "缓存清理")
        precondition(DiskMapPalette.index(for: "/Applications") == 3)
        precondition(DiskMapPalette.index(for: "/System") == 1)
        precondition(DiskMapPalette.index(for: "/Library") == 5)
        precondition(DiskMapPalette.index(for: "/Users") == 0)
        precondition(Set(["/Applications", "/System", "/Library", "/Users"].map { DiskMapPalette.index(for: $0) }).count == 4,
            "top-level folders must remain visually distinct even without purpose labels")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-layout-\(UUID())")
        let root = base.appendingPathComponent("fixture")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        for index in 0..<105 { try Data([1]).write(to: root.appendingPathComponent("file-\(index).pdf")) }
        let model = AppModel(cacheDirectory: base.appendingPathComponent("sessions"))
        model.start(root: root)
        let deadline = Date().addingTimeInterval(20)
        while model.scanning || model.loading {
            precondition(Date() < deadline, "layout fixture scan timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(model.rootEntry != nil && !model.entries.isEmpty)

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        for (scanning, estimate, disabled) in [(false, ProgressEstimate.unknown, false), (true, .unknown, false),
            (true, .expected(40, of: 100), false), (false, .unknown, true)] {
            var orbFrame = CGRect.zero
            let host = NSHostingView(rootView: DiskScanOrb(scanning: scanning, estimate: estimate, disabled: disabled, start: {}, cancel: {})
                .background {
                    GeometryReader { geometry in
                        Color.clear.onAppear { orbFrame = geometry.frame(in: .named("scan-check")) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: "scan-check"))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 280), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            precondition(orbFrame.size == NSSize(width: 220, height: 220), "scan control must keep its circular footprint across states")
            precondition(abs(orbFrame.midX - host.bounds.midX) < 1 && abs(orbFrame.midY - host.bounds.midY) < 1,
                "scan control must remain centered")
            precondition(!window.isVisible, "scan button check must remain hidden")
            window.contentView = nil
        }
        print("PASS: centered circular scan control in idle/scanning/disabled states, known/unknown progress")
        for advanced in [false, true] {
            let host = NSHostingView(rootView: DiskAnalysisView(model: model).environment(\.advancedMode, advanced))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            for mode in [DiskBrowseMode.purposes, .directory, .largeFiles, .spaceInsights, .treemap] {
                model.setBrowseMode(mode)
                if mode == .purposes { model.expandPurposeFiles = true }
                while model.loading { try await Task.sleep(for: .milliseconds(20)) }
                if mode == .largeFiles {
                    // 默认「可清理」：临时夹具根在主目录外，列表为空，应显示空状态而不是空表。
                    func scopePicker() -> NSSegmentedControl? {
                        descendants(host).compactMap({ $0 as? NSSegmentedControl }).first {
                            $0.segmentCount == 2 && $0.label(forSegment: 0) == "可清理" && $0.label(forSegment: 1) == "全部"
                        }
                    }
                    guard let scope = scopePicker() else { preconditionFailure("large files scope picker missing") }
                    precondition(scope.selectedSegment == 0, "cleanable scope should be the initial large files view")
                    for size in [NSSize(width: 760, height: 560), NSSize(width: 960, height: 800)] {
                        window.setContentSize(size)
                        try await Task.sleep(for: .milliseconds(80))
                        host.layoutSubtreeIfNeeded()
                        precondition(descendants(host).compactMap({ $0 as? NSTableView }).isEmpty,
                            "empty cleanable list must show the empty state at \(size)")
                        precondition(!window.isVisible, "layout check must keep the fixture window hidden")
                        print("PASS: disk layout largeFiles cleanable empty state, advanced=\(advanced), size=\(size)")
                    }
                    model.setLargeFilesScope(.all)
                    while model.loading { try await Task.sleep(for: .milliseconds(20)) }
                    try await Task.sleep(for: .milliseconds(50))
                    host.layoutSubtreeIfNeeded()
                    guard let switched = scopePicker() else { preconditionFailure("large files scope picker missing after switch") }
                    precondition(switched.selectedSegment == 1, "scope picker must reflect the query scope")
                }
                for size in [NSSize(width: 760, height: 560), NSSize(width: 960, height: 800), NSSize(width: 760, height: 560)] {
                    window.setContentSize(size)
                    try await Task.sleep(for: .milliseconds(80))
                    host.layoutSubtreeIfNeeded()
                    guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first,
                        let scroll = table.enclosingScrollView else { preconditionFailure("native disk table missing") }
                    let rect = scroll.convert(scroll.bounds, to: host)
                    precondition(scroll.contentView.bounds.height >= 170, "disk list compressed: \(mode), advanced=\(advanced), viewport=\(scroll.contentView.bounds.height)")
                    precondition(rect.minY >= 0 && rect.maxY <= host.bounds.height - 30, "table overlaps footer or leaves content: \(rect), host=\(host.bounds)")
                    if mode == .treemap {
                        precondition(rect.minX > host.bounds.midX, "directory details must sit to the right of the map")
                        precondition(rect.maxX <= host.bounds.width && rect.width < host.bounds.width * 0.45,
                            "directory details must leave most of the width for the map")
                    }
                    if mode == .spaceInsights && size.height == 560 {
                        let overviewScrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter { $0 !== scroll }
                        precondition(overviewScrolls.contains { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height }, "overflowing overview must remain scrollable")
                    }
                    precondition(!window.isVisible, "layout check must keep the fixture window hidden")
                    print("PASS: disk layout \(mode), advanced=\(advanced), size=\(size), listHeight=\(scroll.contentView.bounds.height)")
                }
                if mode == .largeFiles {
                    // 切回默认范围，验证后续高级轮次仍从「可清理」开始。
                    model.setLargeFilesScope(.cleanable)
                    while model.loading { try await Task.sleep(for: .milliseconds(20)) }
                    try await Task.sleep(for: .milliseconds(50))
                    host.layoutSubtreeIfNeeded()
                    precondition(descendants(host).compactMap({ $0 as? NSTableView }).isEmpty, "cleanable scope must return to the empty state")
                }
            }
            window.contentView = nil
        }
        // 顶部导航占用纵向空间：同时验证整窗，避免独立页面通过而实际列表被挤压。
        let monitor = MonitorModel(historyURL: base.appendingPathComponent("history.sqlite"))
        let cacheHome = base.appendingPathComponent("cleanup-home")
        let cacheIDs = ["com.example.mapsafe", "com.apple.mapfixture", "unknown.owner", "com.example.empty"]
        for id in cacheIDs {
            let directory = cacheHome.appendingPathComponent("Library/Caches/" + id)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if id != "com.example.empty" { try Data(repeating: 1, count: 8192).write(to: directory.appendingPathComponent("cache.bin")) }
        }
        let logs = cacheHome.appendingPathComponent(".codex/log")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: logs.appendingPathComponent("codex-tui.log"))
        let invalid = cacheHome.appendingPathComponent(".claude/cache")
        try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data([1]).write(to: invalid.appendingPathComponent("important.swift"))
        let cache = CacheModel(home: cacheHome, applications: [
            CacheApplication(id: "com.example.mapsafe", name: "Map safe cache"),
            CacheApplication(id: "com.apple.mapfixture", name: "Protected cache"),
            CacheApplication(id: "com.example.empty", name: "Empty cache")
        ], cacheDirectory: base.appendingPathComponent("cache"), isRunning: { _ in false }, developerActivity: { _, _ in nil })
        cache.start()
        while cache.busy { try await Task.sleep(for: .milliseconds(20)) }
        cache.developer.start()
        while cache.busy { try await Task.sleep(for: .milliseconds(20)) }
        let recommendations = DiskCleanupRecommendation.items(cache: cache.recommendationGroups, developer: cache.developer.recommendationGroups)
        precondition(recommendations.count == 2, "recommendations must exclude unknown, protected, zero-sized and unverified paths")
        precondition(recommendations.contains { $0.groupID == "com.example.mapsafe" })
        precondition(recommendations.map(\.size) == recommendations.map(\.size).sorted(by: >))
        precondition(Set(recommendations.map(\.id)).count == recommendations.count)
        cache.load(offset: 100)
        cache.developer.load(offset: 100)
        precondition(DiskCleanupRecommendation.items(cache: cache.recommendationGroups, developer: cache.developer.recommendationGroups).map(\.id) == recommendations.map(\.id),
            "recommendations must not disappear when cleanup details change pages")
        cache.load(offset: 0); cache.developer.load(offset: 0)
        print("PASS: only verified nonempty cache recommendations; protected, unknown and unverified entries excluded; stable across detail pagination")
        let removal = ApplicationRemovalModel(home: base, roots: [], cacheDirectory: base.appendingPathComponent("removal"))
        let duplicate = DuplicateModel(home: base, cacheDirectory: base.appendingPathComponent("duplicates"))
        let software = SoftwareModel()
        let smart = SmartScanModel(cache: cache, removal: removal, home: base)
        let (defaults, suite) = makeTestDefaults(prefix: "MacEven.WindowChecks")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StatusSettings(defaults: defaults)
        model.page = .disk
        for advanced in [false, true] {
            settings.advancedMode = advanced
            model.setBrowseMode(.purposes)
            model.expandPurposeFiles = true
            let host = NSHostingView(rootView: ContentView(model: model, monitor: monitor, cache: cache, removal: removal,
                duplicate: duplicate, software: software, onSystemPageChange: { _ in })
                .environmentObject(smart).environmentObject(settings))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            for mode in [DiskBrowseMode.purposes, .treemap] {
                model.setBrowseMode(mode)
                while model.loading { try await Task.sleep(for: .milliseconds(20)) }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    host.appearance = NSAppearance(named: appearance)
                    for size in [NSSize(width: 1000, height: 560), NSSize(width: 1180, height: 820)] {
                        window.setContentSize(size)
                        try await Task.sleep(for: .milliseconds(100))
                        host.layoutSubtreeIfNeeded()
                        if mode == .treemap {
                            guard let sidebar = descendants(host).compactMap({ $0 as? NSSegmentedControl }).first(where: {
                                $0.segmentCount == 2 && $0.label(forSegment: 0) == "目录明细" && $0.label(forSegment: 1) == "清理建议"
                            }) else { preconditionFailure("details/recommendations sidebar picker missing") }
                            precondition(sidebar.selectedSegment == 0, "details should be the initial sidebar")
                            precondition(!cache.busy && smart.phase == .idle, "opening the map must not trigger an automatic cache scan")
                            sidebar.selectedSegment = 1
                            sidebar.sendAction(sidebar.action, to: sidebar.target)
                            try await Task.sleep(for: .milliseconds(80))
                            host.layoutSubtreeIfNeeded()
                            let recommendationScrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter {
                                $0.convert($0.bounds, to: host).minX > host.bounds.midX && $0.contentView.bounds.height >= 100
                            }
                            precondition(!recommendationScrolls.isEmpty, "recommendation list must remain scrollable in the right sidebar")
                            sidebar.selectedSegment = 0
                            sidebar.sendAction(sidebar.action, to: sidebar.target)
                            try await Task.sleep(for: .milliseconds(80))
                            host.layoutSubtreeIfNeeded()
                        }
                        precondition(host.bounds.size == size, "navigation expanded the minimum window size")
                        guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first,
                            let scroll = table.enclosingScrollView else { preconditionFailure("whole-window disk table missing") }
                        let rect = scroll.convert(scroll.bounds, to: host)
                        precondition(scroll.contentView.bounds.height >= 170, "top navigation compressed the disk list")
                        precondition(rect.minY >= 0 && rect.maxY <= host.bounds.height - 30, "whole-window table overlaps the footer")
                        precondition(!window.isVisible, "whole-window check must remain hidden")
                        print("PASS: whole-window navigation \(mode), advanced=\(advanced), \(appearance.rawValue), size=\(size), listHeight=\(scroll.contentView.bounds.height)")
                        if mode == .treemap {
                            let sidebar = descendants(host).compactMap { $0 as? NSSegmentedControl }.first {
                                $0.segmentCount == 2 && $0.label(forSegment: 0) == "目录明细"
                            }!
                            precondition(sidebar.selectedSegment == 0, "details should stay selected")
                        }
                    }
                }
            }
            // 统一浏览方式控件：重复文件是磁盘分析的一个浏览方式，选中即切换，不产生独立页面路由。
            let expectedSegments = advanced ? ["按用途", "目录", "空间地图", "大文件 · 前 100 项", "重复文件", "分类与筛选"]
                : ["按用途", "目录", "空间地图", "大文件", "重复文件"]
            window.setContentSize(NSSize(width: 1000, height: 560))
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let segmented = descendants(host).compactMap { $0 as? NSSegmentedControl }
            guard let picker = segmented.first(where: { control in
                control.segmentCount == expectedSegments.count &&
                    (0..<control.segmentCount).allSatisfy { index in control.label(forSegment: index) == expectedSegments[index] }
            }) else { preconditionFailure("unified disk browse picker missing") }
            precondition(picker.isEnabled, "idle browse picker must allow switching")
            picker.selectedSegment = 4
            picker.sendAction(picker.action, to: picker.target)
            precondition(model.browseMode == .duplicates, "picking duplicates did not switch browse mode")
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            precondition(host.bounds.size == NSSize(width: 1000, height: 560), "duplicates browse expanded the minimum window")
            picker.selectedSegment = 0
            picker.sendAction(picker.action, to: picker.target)
            try await Task.sleep(for: .milliseconds(100))
            precondition(model.browseMode == .purposes && !window.isVisible)
            print("PASS: unified browse picker reaches duplicates and back, advanced=\(advanced)")
            model.page = .disk
            window.contentView = nil
        }
        settings.advancedMode = false
        let tools = SystemTools()
        let notifications = StatusNotifications(defaults: defaults)
        let journal = OperationJournal(log: OperationLog(directory: base.appendingPathComponent("logs")))
        let protection = ProtectionModel(store: ProtectionStore(url: base.appendingPathComponent("protection.json")))
        let delegate = AppDelegate(model: model, monitor: monitor, cache: cache, removal: removal, duplicate: duplicate,
            settings: settings, tools: tools, stats: OperationStats(defaults: defaults), notifications: notifications,
            software: software, journal: journal, protection: protection, smart: smart)
        let menu = NSMenuItem(title: "高级模式 (beta)", action: #selector(AppDelegate.toggleAdvancedMode), keyEquivalent: "")
        precondition(delegate.validateMenuItem(menu) && menu.state == .off)
        delegate.toggleAdvancedMode()
        precondition(delegate.validateMenuItem(menu) && menu.state == .on && settings.advancedMode)
        precondition(StatusSettings(defaults: defaults).advancedMode, "advanced mode must persist")
        delegate.toggleAdvancedMode()
        precondition(delegate.validateMenuItem(menu) && menu.state == .off && !settings.advancedMode)
        let settingsHost = NSHostingView(rootView: SettingsPage(monitor: monitor)
            .environmentObject(settings).environmentObject(tools).environmentObject(notifications)
            .environmentObject(protection).environmentObject(journal))
        settingsHost.sizingOptions = []
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        settingsWindow.contentView = settingsHost
        for advanced in [true, false] {
            try await Task.sleep(for: .milliseconds(100))
            settingsHost.layoutSubtreeIfNeeded()
            guard let picker = descendants(settingsHost).compactMap({ $0 as? NSSegmentedControl }).first(where: {
                $0.segmentCount == 2 && $0.label(forSegment: 1) == "高级 (beta)"
            }) else { preconditionFailure("advanced beta picker missing") }
            precondition(picker.isEnabled, "advanced beta mode must be enabled")
            picker.selectedSegment = advanced ? 1 : 0
            picker.sendAction(picker.action, to: picker.target)
            precondition(settings.advancedMode == advanced, "interface picker did not switch mode")
            precondition(!settingsWindow.isVisible)
        }
        settingsWindow.contentView = nil
        print("PASS: advanced beta mode enabled in settings and menu, with persistence")
        let error: String? = await withCheckedContinuation { continuation in
            model.shutdown { continuation.resume(returning: $0) }
        }
        precondition(error == nil)
        let cacheError: String? = await withCheckedContinuation { continuation in
            cache.shutdown { continuation.resume(returning: $0) }
        }
        precondition(cacheError == nil)
    }
}
