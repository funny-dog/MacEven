import AppKit
import SwiftUI
import MacEvenCore

// 只布局隐藏测试窗口，不打开实际菜单面板或启动采样。
@main struct PopoverLayoutChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-popover-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let monitor = MonitorModel(historyURL: base.appendingPathComponent("history.sqlite"))
        let disk = AppModel(cacheDirectory: base.appendingPathComponent("disk"))
        let cache = CacheModel(home: base, applications: [], cacheDirectory: base.appendingPathComponent("cache"))
        let removal = ApplicationRemovalModel(home: base, roots: [], cacheDirectory: base.appendingPathComponent("removal"))
        let duplicate = DuplicateModel(home: base, cacheDirectory: base.appendingPathComponent("duplicates"))
        let (defaults, suite) = makeTestDefaults(prefix: "MacEven.WindowChecks")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StatusSettings(defaults: defaults)
        let stats = OperationStats(defaults: defaults)
        let tools = SystemTools()
        monitor.setPopoverVisible(true)

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for advanced in [false, true] {
            settings.advancedMode = advanced
            for overflowing in [false, true] {
                let now = Date()
                let keys = ["cpu", "memory", "disk", "network"]
                let errors = overflowing ? Dictionary(uniqueKeysWithValues: keys.map { ($0, String(repeating: "测试采集错误说明，", count: 16)) }) : [:]
                monitor.accept(SystemSnapshot(timestamp: now, uptime: 120, cpuPercent: 12,
                    physicalMemoryBytes: 16 << 30, usedMemoryBytes: 8 << 30,
                    diskTotalBytes: 1000 << 30, diskAvailableBytes: 400 << 30,
                    networkRate: NetworkRate(download: 1024, upload: 512), networkInterface: "en0", errors: errors))
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let host = NSHostingView(rootView: MonitorPopoverView(monitor: monitor, disk: disk, cache: cache,
                        removal: removal, duplicate: duplicate, openWindow: {}, quit: {})
                        .environmentObject(settings).environmentObject(stats).environmentObject(tools).environment(\.locale, localizationLocale))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: appearance)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first else { preconditionFailure("panel scroll area missing") }
                    let rect = scroll.convert(scroll.bounds, to: host)
                    precondition(host.bounds.width == 380 && host.bounds.height <= 620, "panel exceeds its size limit")
                    precondition(rect.minY >= 40 && rect.maxY <= host.bounds.height - 40, "scroll area overlaps fixed header or footer")
                    precondition(scroll.contentView.bounds.height > 200, "panel content is compressed")
                    precondition((scroll.documentView?.bounds.width ?? 0) <= scroll.contentView.bounds.width + 1, "panel content overflows horizontally")
                    if overflowing { precondition((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height, "long warnings must scroll") }
                    precondition(!window.isVisible, "layout check must remain hidden")
                    print("PASS: popover advanced=\(advanced), overflowing=\(overflowing), \(appearance.rawValue)")
                    window.contentView = nil
                }
            }
        }
        monitor.setPopoverVisible(false)
        let error: String? = await withCheckedContinuation { continuation in monitor.shutdown { continuation.resume(returning: $0) } }
        precondition(error == nil)
    }
}
