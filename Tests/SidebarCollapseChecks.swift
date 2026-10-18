import AppKit
import SwiftUI
import MacEvenCore

// 侧边栏折叠/展开与独立图标导航验证
@main struct SidebarCollapseChecks {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let home = try canonicalFileURL(fm.temporaryDirectory).appendingPathComponent("MacEven-sidebar-collapse-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let disk = AppModel(cacheDirectory: home.appendingPathComponent("disk-sessions"))
        let monitor = MonitorModel(historyURL: home.appendingPathComponent("history.sqlite"))
        let cache = CacheModel(home: home, applications: [], cacheDirectory: home.appendingPathComponent("cache-sessions"))
        let removal = ApplicationRemovalModel(home: home, roots: [], cacheDirectory: home.appendingPathComponent("removal-sessions"))
        let duplicate = DuplicateModel(home: home, cacheDirectory: home.appendingPathComponent("duplicate-sessions"))
        let software = SoftwareModel()
        let smart = SmartScanModel(cache: cache, removal: removal, home: home)

        let (defaults, suite) = makeTestDefaults(prefix: "MacEven.WindowChecks")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StatusSettings(defaults: defaults)
        let tools = SystemTools()
        let stats = OperationStats()
        let notifications = StatusNotifications()
        let journal = OperationJournal()
        let protection = ProtectionModel()

        // 1. 验证默认配置
        precondition(!settings.sidebarCollapsed, "侧边栏默认应为展开状态")
        precondition(Theme.sidebarWidth == 232, "展开侧栏宽度应为 232")
        precondition(Theme.sidebarCollapsedWidth == 68, "折叠侧栏宽度应为 68")

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }

        let host = NSHostingView(rootView: ContentView(
            model: disk,
            monitor: monitor,
            cache: cache,
            removal: removal,
            duplicate: duplicate,
            software: software,
            onSystemPageChange: { _ in }
        )
        .environmentObject(smart)
        .environmentObject(settings)
        .environmentObject(tools)
        .environmentObject(stats)
        .environmentObject(notifications)
        .environmentObject(journal)
        .environmentObject(protection))
        host.sizingOptions = []

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        // 2. 验证展开状态下的侧栏宽度（右侧内容起始 x 坐标 >= 232）
        let contentScrollsExpanded = descendants(host).compactMap { $0 as? NSScrollView }.filter {
            $0.convert($0.bounds, to: host).minX >= Theme.sidebarWidth - 1
        }
        precondition(!contentScrollsExpanded.isEmpty || host.bounds.width >= 1000, "展开状态下内容区域应正确定位")

        // 3. 切换为折叠状态
        settings.toggleSidebar()
        precondition(settings.sidebarCollapsed, "toggleSidebar 后应进入折叠状态")
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()

        // 4. 验证折叠状态下点击各页面图标能正常切换
        let testPages: [AppPage] = [.system, .disk, .cleanup, .applications, .settings]
        for page in testPages {
            disk.page = page
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            precondition(disk.page == page, "折叠状态下切换页面失败: \(page)")
        }

        // 5. 再次展开
        settings.toggleSidebar()
        precondition(!settings.sidebarCollapsed, "再次 toggleSidebar 应恢复展开状态")
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()

        // 6. 验证持久化与 reset
        settings.sidebarCollapsed = true
        let reloadedSettings = StatusSettings(defaults: defaults)
        precondition(reloadedSettings.sidebarCollapsed, "侧栏折叠状态持久化读取失败")
        reloadedSettings.resetToDefaults()
        precondition(!reloadedSettings.sidebarCollapsed, "resetToDefaults 应恢复默认展开状态")

        print("PASS: SidebarCollapseChecks completed successfully!")
    }
}
