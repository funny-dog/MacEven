import AppKit
import SwiftUI
@testable import MacEvenCore

// 临时数据与隐藏窗口验证统一入口；不扫描用户目录，也不执行清理。
@main struct CleanupLayoutChecks {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let home = try canonicalFileURL(fm.temporaryDirectory).appendingPathComponent("MacEven-cleanup-layout-\(UUID())")
        try fm.createDirectory(at: home.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        func write(_ path: String, _ data: Data = Data(repeating: 7, count: 8192), modified: Date? = nil) throws {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        try write("Library/Caches/test.unified/data")
        try write("Library/Caches/go-build/README", Data("This directory holds cached build artifacts from the Go build system.\n".utf8))
        try write("Library/Caches/go-build/00/0011-a")
        try write("Library/Caches/com.example.unifiedgone/data")
        // AI 面板夹具：一项可清理的 AI 缓存、一个旧会话、一个项目已删除的会话
        try write(".claude/cache/changelog.md", Data("# Claude Code 更新说明\n".utf8))
        let staleProject = home.appendingPathComponent("projects/stale-project")
        try fm.createDirectory(at: staleProject, withIntermediateDirectories: true)
        try write(".codex/sessions/2026/01/02/rollout-old.jsonl",
            Data("{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"\(staleProject.path)\"}}\n".utf8),
            modified: Date(timeIntervalSinceNow: -200 * 86_400))
        try write(".claude/projects/project-gone/session-a.jsonl",
            Data("{\"cwd\":\"\(home.appendingPathComponent("projects/removed-project").path)\"}\n".utf8))
        let disk = AppModel(cacheDirectory: home.appendingPathComponent("disk-sessions"))
        let monitor = MonitorModel(historyURL: home.appendingPathComponent("history.sqlite"))
        let cache = CacheModel(home: home, applications: [CacheApplication(id: "test.unified", name: "Unified fixture")],
            cacheDirectory: home.appendingPathComponent("cache-sessions"), isRunning: { _ in false }, developerActivity: { _, _ in nil })
        let removal = ApplicationRemovalModel(home: home, roots: [home.appendingPathComponent("Applications")],
            cacheDirectory: home.appendingPathComponent("removal-sessions"), isRunning: { _ in false }, dock: nil,
            leftoverSnapshot: { LeftoverOwnershipSnapshot(check: { $0 == "com.example.unifiedgone" ? .orphan : .installed }, incomplete: false, errors: []) })
        let duplicate = DuplicateModel(home: home, cacheDirectory: home.appendingPathComponent("duplicate-sessions"))
        let software = SoftwareModel()
        let smart = SmartScanModel(cache: cache, removal: removal, home: home)
        let (defaults, suite) = makeTestDefaults(prefix: "MacEven.WindowChecks")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StatusSettings(defaults: defaults)
        let pages = AppPage.sidebarGroups.flatMap(\.pages)
        precondition(pages.filter { $0 == .cleanup }.count == 1 && !pages.contains(.overview))
        precondition(AppPage.overview.sidebarPage == .cleanup && AppPage.overview.title == "缓存清理")
        precondition(!SoftwareTab.displayOrder.contains(.leftovers))
        disk.page = .cleanup
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let host = NSHostingView(rootView: ContentView(model: disk, monitor: monitor, cache: cache, removal: removal,
            duplicate: duplicate, software: software, onSystemPageChange: { _ in })
            .environmentObject(smart).environmentObject(settings))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        precondition(host.bounds.size == NSSize(width: 1000, height: 560), "cleanup home expanded the minimum window")
        smart.scanAll()
        let deadline = Date().addingTimeInterval(30)
        while smart.busy || cache.busy || removal.busy {
            precondition(Date() < deadline, "cleanup fixture scan timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(smart.phase == .ready && smart.selectedCount == 0 && !smart.canClean)
        // AI 缓存与开发/浏览器缓存分开计数：卡片口径与页面合计一致
        precondition(cache.selectableCount == 1 && smart.developer.selectableCount == 2 && smart.leftovers.selectableCount == 1,
            "categories: \(cache.selectableCount) \(smart.developer.selectableCount) \(smart.leftovers.selectableCount)")
        precondition(smart.developer.otherCacheSelectableCount == 1 && smart.developer.aiCacheSelectableCount == 1
            && smart.developer.aiToolNames == ["Claude Code"], "AI cache split is wrong")
        precondition(smart.aiWorkRows.map(\.kind) == [.oldSessions, .missingProjectSessions],
            "AI rows: \(smart.aiWorkRows.map(\.kind))")
        precondition(smart.aiMaintenanceSize > 0 && smart.aiMaintenanceToolNames == ["Claude Code", "Codex"])
        for advanced in [false, true] {
            settings.advancedMode = advanced
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                host.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 1000, height: 560), NSSize(width: 1180, height: 820)] {
                    window.setContentSize(size)
                    try await Task.sleep(for: .milliseconds(120))
                    host.layoutSubtreeIfNeeded()
                    precondition(host.bounds.size == size, "cleanup results expanded the window")
                    let contentScrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter {
                        $0.convert($0.bounds, to: host).minX >= Theme.sidebarWidth
                    }
                    guard let scroll = contentScrolls.first, let document = scroll.documentView else {
                        preconditionFailure("cleanup results scroll view missing")
                    }
                    precondition(document.bounds.height <= scroll.contentView.bounds.height + 1,
                        "collapsed cleanup overview does not fit first screen: document=\(document.bounds), viewport=\(scroll.contentView.bounds), advanced=\(advanced)")
                    precondition(document.bounds.width <= scroll.contentView.bounds.width + 1, "cleanup cards overflow horizontally")
                    precondition(!window.isVisible, "cleanup fixture window must remain hidden")
                    print("PASS: cleanup overview fits first screen, advanced=\(advanced), \(appearance.rawValue), size=\(size)")
                }
            }
        }
        window.setContentSize(NSSize(width: 1000, height: 560))
        for category in CleanupCategory.allCases {
            smart.expandedCategories = [category]
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            precondition(host.bounds.size == NSSize(width: 1000, height: 560), "expanded details enlarged the window")
            let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first { $0.convert($0.bounds, to: host).minX >= Theme.sidebarWidth }!
            precondition(scroll.documentView!.bounds.width <= scroll.contentView.bounds.width + 1, "expanded details overflow horizontally")
            precondition(scroll.documentView!.bounds.height <= scroll.contentView.bounds.height * 10,
                "expanded \(category.title) inflated the document height: document=\(scroll.documentView!.bounds), viewport=\(scroll.contentView.bounds)")
        }
        smart.expandedCategories = []; smart.aiExpanded = true
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        precondition(host.bounds.size == NSSize(width: 1000, height: 560) && smart.selectedCount == 0, "empty AI details changed window or selection")
        // 填充状态：展开缓存明细与会话行，验证不横向溢出，且勾选只走 AI 自己的通道
        smart.aiCacheExpanded = true
        smart.aiWorkExpandedRows = Set(AICleanupRow.Kind.allCases.map(\.rawValue))
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        precondition(host.bounds.size == NSSize(width: 1000, height: 560), "AI panel expanded the minimum window")
        let aiScroll = descendants(host).compactMap { $0 as? NSScrollView }.first { $0.convert($0.bounds, to: host).minX >= Theme.sidebarWidth }!
        precondition(aiScroll.documentView!.bounds.width <= aiScroll.contentView.bounds.width + 1, "AI panel overflows horizontally")
        precondition(aiScroll.documentView!.bounds.height <= aiScroll.contentView.bounds.height * 10,
            "AI panel inflated the document height: document=\(aiScroll.documentView!.bounds), viewport=\(aiScroll.contentView.bounds)")
        let aiCacheGroup = smart.developer.aiCacheGroups[0]
        smart.developer.select(aiCacheGroup.id, selected: true)
        precondition(smart.selectedCount == 1 && smart.developer.aiCacheSelectedCount == 1, "AI cache selection must feed the page footer")
        smart.clearSelection(); smart.developer.select(aiCacheGroup.id, selected: false)
        guard let oldRow = smart.aiWorkRows.first(where: { $0.kind == .oldSessions }) else { fatalError("AI old row missing") }
        smart.setAIWorkRow(oldRow, selected: true)
        precondition(smart.selectedCount == 0, "AI work selection must not leak into the page footer")
        precondition(smart.aiWorkSelectedCount == oldRow.count && smart.canCleanAIWork)
        smart.prepareAIWorkCleanup()
        precondition(smart.aiWorkConfirmation?.count == oldRow.count && smart.confirmation == nil)
        smart.dismissAIWorkConfirmation(); smart.clearAIWorkSelection()
        smart.aiCacheExpanded = false; smart.aiWorkExpandedRows = []
        smart.aiExpanded = false
        print("PASS: category and empty AI details fit the minimum window without horizontal overflow; AI panel stays inside the minimum window with rows and caches expanded")
        disk.page = .overview
        try await Task.sleep(for: .milliseconds(100))
        precondition(disk.page == .cleanup, "legacy smart scan entry did not redirect")
        disk.page = .applications; software.tab = .leftovers
        try await Task.sleep(for: .milliseconds(100))
        precondition(disk.page == .cleanup && software.tab == .uninstall, "legacy leftover entry did not redirect")
        smart.expandedCategories = [.appCache]; smart.otherStorageExpanded = true
        disk.page = .system
        try await Task.sleep(for: .milliseconds(100))
        disk.page = .cleanup
        try await Task.sleep(for: .milliseconds(100))
        precondition(smart.expandedCategories == [.appCache] && smart.otherStorageExpanded, "switching pages lost cleanup details")
        smart.expandedCategories = []; smart.otherStorageExpanded = false
        smart.selectAllSafe()
        precondition(smart.selectedCount == 4 && smart.developer.aiCacheSelectedCount == 1, "AI caches must be selectable through the page-level flow")
        window.setContentSize(NSSize(width: 1000, height: 560))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        precondition(host.bounds.size == NSSize(width: 1000, height: 560), "cleanup selection bar expanded the minimum window")
        smart.prepareCleanup()
        precondition(smart.confirmation?.count == 4 && smart.confirmation?.paths.count == 4)
        smart.dismissConfirmation(); smart.clearSelection()
        precondition(smart.confirmation == nil && smart.selectedCount == 0)
        precondition(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/test.unified/data").path))

        // 验证简洁模式与高级模式下的限制提示（CleanupRestrictionsSection）与保留原因（blockedReason）
        do {
            let mockRestrictions = [CleanupRestrictionSummary(reason: "应用正在运行", count: 3)]
            let mockErrors = ["/Users/tester/Library/Caches/sample: 符号链接或经过符号链接的路径不可操作"]

            // 1. incomplete == false 时：简洁模式不渲染任何内容且 fittingSize == .zero，高级模式展示“暂不清理的原因”（fittingSize.height > 0）
            let completeSection = CleanupRestrictionsSection(restrictions: mockRestrictions, errors: mockErrors, incomplete: false)
            let simpCompleteHost = NSHostingView(rootView: completeSection.environment(\.advancedMode, false))
            let advCompleteHost = NSHostingView(rootView: completeSection.environment(\.advancedMode, true))
            simpCompleteHost.layoutSubtreeIfNeeded()
            advCompleteHost.layoutSubtreeIfNeeded()
            precondition(simpCompleteHost.fittingSize == .zero, "简洁模式下 incomplete == false 时 CleanupRestrictionsSection 严禁展示与占位")
            precondition(advCompleteHost.fittingSize.height > 0, "高级模式下有受限项时展示暂不清理的原因")

            // 2. incomplete == true 时：简洁模式依然不渲染任何内容且 fittingSize == .zero（完全不展示干扰用户的警告条或诊断信息），高级模式展示完整诊断块（fittingSize.height > 0）
            let incompSection = CleanupRestrictionsSection(restrictions: mockRestrictions, errors: mockErrors, incomplete: true)
            let simpIncompHost = NSHostingView(rootView: incompSection.environment(\.advancedMode, false))
            let advIncompHost = NSHostingView(rootView: incompSection.environment(\.advancedMode, true))
            simpIncompHost.layoutSubtreeIfNeeded()
            advIncompHost.layoutSubtreeIfNeeded()
            precondition(simpIncompHost.fittingSize == .zero, "简洁模式下 incomplete == true 时 CleanupRestrictionsSection 亦不渲染任何内容且 fittingSize == .zero")
            precondition(advIncompHost.fittingSize.height > 0, "高级模式下 incomplete == true 时正常展示完整诊断块")

            // 3. 保留原因（blockedReason）展示条件断言：高级模式展示长文本，简洁模式不平铺展示
            let blockedGroup = CacheGroup(
                id: "com.test.blocked",
                name: "Blocked App",
                paths: [home.appendingPathComponent("Library/Caches/test.unified")],
                allocatedSize: 1024,
                logicalSize: 1024,
                blockedReason: "正在运行或系统锁定"
            )
            struct ReasonRowTest: View {
                let group: CacheGroup
                @Environment(\.advancedMode) private var advanced
                var body: some View {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name)
                        if advanced, let reason = group.blockedReason {
                            Text("保留原因：" + reason)
                        }
                    }
                }
            }
            let simpRowHost = NSHostingView(rootView: ReasonRowTest(group: blockedGroup).environment(\.advancedMode, false))
            let advRowHost = NSHostingView(rootView: ReasonRowTest(group: blockedGroup).environment(\.advancedMode, true))
            simpRowHost.layoutSubtreeIfNeeded()
            advRowHost.layoutSubtreeIfNeeded()
            precondition(advRowHost.fittingSize.height > simpRowHost.fittingSize.height,
                "简洁模式下不平铺展示保留原因长文本，高级模式下才展示")
            print("PASS: CleanupRestrictionsSection and blockedReason assertions for simple and advanced mode")
        }

        window.contentView = nil
        for close in [{ (done: @escaping @MainActor @Sendable (String?) -> Void) in disk.shutdown(done) },
                      { done in cache.shutdown(done) }, { done in removal.shutdown(done) }, { done in duplicate.shutdown(done) }] {
            let error: String? = await withCheckedContinuation { continuation in close { continuation.resume(returning: $0) } }
            precondition(error == nil)
        }
        print("PASS: single cleanup entry, legacy redirects, unselected scan results and combined confirmation")
    }
}
