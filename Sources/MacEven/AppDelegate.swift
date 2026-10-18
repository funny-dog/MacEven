import AppKit
import SwiftUI
import Combine
import Darwin
import MacEvenCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    private let model: AppModel
    private let monitor: MonitorModel
    private let cache: CacheModel
    private let removal: ApplicationRemovalModel
    private let duplicate: DuplicateModel
    let software: SoftwareModel
    private let settings: StatusSettings
    private let tools: SystemTools
    private let stats: OperationStats
    private let notifications: StatusNotifications
    private let journal: OperationJournal
    private let protection: ProtectionModel
    private let smart: SmartScanModel
    private let shortcut = GlobalShortcut()
    private var subscriptions: [AnyCancellable] = []
    private var toolTimer: Timer?
    private var settingsPending = false
    init(model: AppModel, monitor: MonitorModel, cache: CacheModel, removal: ApplicationRemovalModel, duplicate: DuplicateModel, settings: StatusSettings? = nil, tools: SystemTools? = nil, stats: OperationStats? = nil, notifications: StatusNotifications? = nil, software: SoftwareModel? = nil, journal: OperationJournal? = nil, protection: ProtectionModel? = nil, smart: SmartScanModel? = nil) {
        self.model = model; self.monitor = monitor; self.cache = cache; self.removal = removal; self.duplicate = duplicate
        self.software = software ?? SoftwareModel()
        self.settings = settings ?? StatusSettings(); self.tools = tools ?? SystemTools()
        self.stats = stats ?? OperationStats(); self.notifications = notifications ?? StatusNotifications()
        self.journal = journal ?? OperationJournal(); self.protection = protection ?? ProtectionModel()
        self.smart = smart ?? SmartScanModel(cache: cache, removal: removal, historyDefaults: .standard)
        super.init()
        self.smart.otherBusy = { [weak model, weak duplicate, weak software = self.software] in
            model?.busy == true || model?.loading == true || duplicate?.busy == true || software?.busy == true
        }
        model.recordOperation = self.journal.recorder(source: "disk")
        model.applicationCatalog = { CacheCatalog.discover().applications }
        cache.recordOperation = self.journal.recorder(source: "cache")
        cache.developer.recordOperation = self.journal.recorder(source: "developer")
        removal.recordOperation = self.journal.recorder(source: "applications")
        removal.leftovers.recordOperation = self.journal.recorder(source: "leftovers")
        duplicate.recordOperation = self.journal.recorder(source: "duplicates")
        self.smart.recordOperation = self.journal.recorder(source: "aiwork")
        self.software.otherBusy = { [weak model, weak cache, weak removal, weak duplicate, weak smart = self.smart] in
            model?.busy == true || model?.loading == true || cache?.busy == true || removal?.busy == true || duplicate?.busy == true || smart?.busy == true
        }
    }
    private var window: NSWindow?
    private var onboardingWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var popoverGlobalMonitor: Any?
    private var popoverLocalMonitor: Any?
    private var observation: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var systemPage = true
    private var windowOpen = false
    private var terminating = false
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        // Local updates use the same orderly shutdown as the Quit menu.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.quit() } }
        terminationSignal = source; source.resume()
        // 扫描结果仅在当前 App 运行轮次生效，清理旧版本在 UserDefaults 遗留的历史扫描报告
        UserDefaults.standard.removeObject(forKey: "analysisReport.disk")
        UserDefaults.standard.removeObject(forKey: "analysisReport.cleanup")
        UserDefaults.standard.removeObject(forKey: "analysisReport.duplicates")
        model.prepareSessions(); setupMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "CPU — · RAM —"
        item.button?.target = self; item.button?.action = #selector(togglePopover(_:))
        item.button?.setAccessibilityLabel(localized("MacEven 系统状态"))
        statusItem = item
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let popoverContent = NSHostingController(rootView: MonitorPopoverView(monitor: monitor, disk: model, cache: cache, removal: removal, duplicate: duplicate,
            openWindow: { [weak self] in self?.openWindow() }, quit: { [weak self] in self?.quit() })
            .environmentObject(settings).environmentObject(tools).environmentObject(stats).environmentObject(notifications).environment(\.locale, localizationLocale))
        // 弹窗大小跟随内容：简洁模式自适应高度，高级模式固定 380×620。
        popoverContent.sizingOptions = [.preferredContentSize]
        popover.contentViewController = popoverContent
        observation = Publishers.CombineLatest(monitor.$snapshot, monitor.$hardware).sink { [weak self] snapshot, hardware in
            self?.updateStatusItem(snapshot: snapshot, hardware: hardware)
            if let hardware { self?.notifications.updateHardware(hardware) }
        }
        subscriptions.append(settings.objectWillChange.sink { [weak self] in
            guard let self, !self.settingsPending else { return }; self.settingsPending = true
            DispatchQueue.main.async { [weak self] in self?.settingsPending = false; self?.applySettings() }
        })
        subscriptions.append(model.$trashResults.sink { [weak self] in self?.stats.record($0, source: "disk") })
        subscriptions.append(cache.$results.sink { [weak self] in self?.stats.record($0, source: "cache") })
        subscriptions.append(cache.developer.$results.sink { [weak self] in self?.stats.record($0, source: "developer") })
        subscriptions.append(removal.$results.sink { [weak self] in self?.stats.record($0, source: "applications") })
        subscriptions.append(removal.leftovers.$results.sink { [weak self] in self?.stats.record($0, source: "leftovers") })
        subscriptions.append(duplicate.$results.sink { [weak self] in self?.stats.record($0, source: "duplicates") })
        subscriptions.append(smart.$aiWorkResults.sink { [weak self] in self?.stats.record($0, source: "aiwork") })
        // 累计记录：各页扫描从未运行变为运行时计一次。
        for scanning in [model.$scanning.eraseToAnyPublisher(), cache.$scanning.eraseToAnyPublisher(), cache.developer.$scanning.eraseToAnyPublisher(),
            removal.$scanning.eraseToAnyPublisher(), removal.leftovers.$scanning.eraseToAnyPublisher(), duplicate.$scanning.eraseToAnyPublisher()] {
            subscriptions.append(scanning.removeDuplicates().dropFirst().filter { $0 }.sink { [weak self] _ in self?.stats.recordScan() })
        }
        subscriptions.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.settings.refreshLoginItemStatus()
        })
        subscriptions.append(NotificationCenter.default.publisher(for: .openOnboarding).sink { [weak self] _ in
            self?.showOnboarding()
        })
        shortcut.activate = { [weak self] in self?.togglePopover(nil) }
        tools.start(); applySettings()
        toolTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tools.refreshPrivacy()
                self.notifications.updatePrivacy(camera: self.tools.cameraInUse, microphone: self.tools.microphoneInUse)
                self.updateStatusItem(snapshot: self.monitor.snapshot, hardware: self.monitor.hardware)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tools.prepareForSleep(); self?.monitor.prepareForSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.resetAfterWake() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.popover.isShown == true { self?.popover.performClose(nil) }
            }
        })
        subscriptions.append(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification).sink { [weak self] _ in
            if self?.popover.isShown == true { self?.popover.performClose(nil) }
        })
        monitor.start(); if !settings.menuBarOnly { openWindow() } else { NSApp.setActivationPolicy(.accessory) }
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasCompletedOnboarding {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            showOnboarding()
        }
    }
    private func applySettings() {
        let error = shortcut.setEnabled(settings.globalHotkeyEnabled)
        if settings.hotkeyError != error { settings.hotkeyError = error }
        monitor.setPinnedPaths(settings.pinnedExecutablePaths)
        NSApp.setActivationPolicy(settings.menuBarOnly || !windowOpen ? .accessory : .regular)
        updateStatusItem(snapshot: monitor.snapshot, hardware: monitor.hardware)
    }
    private func updateStatusItem(snapshot: MacEvenCore.SystemSnapshot?, hardware: MacEvenCore.HardwareSnapshot?) {
        let fields = [settings.primaryMetric, settings.secondaryMetric].compactMap { statusMetricText($0, snapshot: snapshot, hardware: hardware) }
        var lines = fields
        if settings.showNetworkSpeed {
            let network = [StatusMetric.download, .upload].compactMap { statusMetricText($0, snapshot: snapshot, hardware: hardware) }
            if settings.layoutStyle == .stacked {
                if fields.count == 2 {
                    lines = zip(fields, network).map { $0 + " · " + $1 }
                } else if fields.count == 1 {
                    lines = [fields[0], network.joined(separator: " · ")]
                } else {
                    lines = network
                }
            } else {
                if fields.isEmpty {
                    lines = [network.joined(separator: " · ")]
                } else {
                    lines.append(network.joined(separator: " · "))
                }
            }
        }
        guard let button = statusItem?.button else { return }
        if lines.isEmpty {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            let conf = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: "MacEven")?.withSymbolConfiguration(conf)
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(localized("MacEven 系统状态"))
            button.toolTip = localized("MacEven 系统状态")
            return
        }
        button.setAccessibilityLabel(localized("MacEven：") + lines.joined(separator: localized("，")))
        button.toolTip = lines.joined(separator: localized("，")) + localized("；内存为已用量估算，温度为 CPU 温区均值。")
        if settings.layoutStyle == .stacked && lines.count >= 2 {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = createStackedStatusImage(line1: lines[0], line2: lines[1])
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = ""
            let title = lines.joined(separator: " · ")
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor])
        }
    }

    private func createStackedStatusImage(line1: String, line2: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attr1 = NSAttributedString(string: line1, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        let attr2 = NSAttributedString(string: line2, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        let size1 = attr1.size()
        let size2 = attr2.size()
        let width = ceil(max(size1.width, size2.width))
        let height: CGFloat = 22.0
        let gap: CGFloat = 0.5
        let totalTextHeight = size1.height + size2.height + gap
        let startY = (height - totalTextHeight) / 2.0
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            attr2.draw(in: NSRect(x: 0, y: startY, width: width, height: size2.height))
            attr1.draw(in: NSRect(x: 0, y: startY + size2.height + gap, width: width, height: size1.height))
            return true
        }
        image.isTemplate = true
        return image
    }
    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) }
        else if let button = statusItem?.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    func popoverDidShow(_ notification: Notification) {
        monitor.setPopoverVisible(true)
        installPopoverMonitors()
    }
    func popoverDidClose(_ notification: Notification) {
        monitor.setPopoverVisible(false)
        removePopoverMonitors()
    }

    private func installPopoverMonitors() {
        removePopoverMonitors()
        popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if let window = self.popover.contentViewController?.view.window, event.window == window {
                return event
            }
            if let button = self.statusItem?.button, let buttonWindow = button.window, event.window == buttonWindow {
                let locationInButton = button.convert(event.locationInWindow, from: nil)
                if button.bounds.contains(locationInButton) {
                    return event
                }
            }
            if let eventWindow = event.window, eventWindow.level == .popUpMenu || NSStringFromClass(type(of: eventWindow)).contains("Menu") {
                return event
            }
            self.popover.performClose(nil)
            return event
        }
    }

    private func removePopoverMonitors() {
        if let monitor = popoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverGlobalMonitor = nil
        }
        if let monitor = popoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverLocalMonitor = nil
        }
    }
    private func actionItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    private func setupMenu() {
        let main = NSMenu(); let appMenu = NSMenu(); let appItem = NSMenuItem()
        appItem.submenu = appMenu; main.addItem(appItem)
        appMenu.addItem(actionItem(localized("关于 MacEven"), #selector(about), ""))
        appMenu.addItem(actionItem(localized("检查更新…"), #selector(checkForUpdates), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(actionItem(localized("退出 MacEven"), #selector(quit), "q"))
        let editItem = NSMenuItem(title: localized("编辑"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: localized("编辑"))
        edit.addItem(NSMenuItem(title: localized("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: localized("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit; main.addItem(editItem)
        // 显示：切换简洁 / 高级模式，勾选状态在 validateMenuItem 中随设置刷新。
        let viewItem = NSMenuItem(title: localized("显示"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: localized("显示"))
        viewMenu.addItem(actionItem(localized("高级模式 (beta)"), #selector(toggleAdvancedMode), ""))
        let sidebarMenuItem = actionItem(localized("折叠侧边栏"), #selector(toggleSidebarMenu), "s")
        sidebarMenuItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(sidebarMenuItem)
        viewItem.submenu = viewMenu; main.addItem(viewItem)
        let windowItem = NSMenuItem(title: localized("窗口"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: localized("窗口"))
        windowMenu.addItem(actionItem(localized("打开 MacEven"), #selector(openWindow), ""))
        windowMenu.addItem(.separator())
        // 保留现有快捷键；⌘5 进入磁盘分析的重复文件浏览方式。
        for page in AppPage.allCases.filter({ $0 != .overview }).sorted(by: { $0.order < $1.order }) {
            let item = actionItem(page.title, #selector(openPage(_:)), String(page.order))
            item.representedObject = page.rawValue; windowMenu.addItem(item)
            if page == .disk { windowMenu.addItem(actionItem(localized("重复文件"), #selector(openDuplicates), "5")) }
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(actionItem(localized("应用卸载"), #selector(openApplications), ""))
        windowMenu.addItem(actionItem(localized("启动项"), #selector(openStartupItems), ""))
        windowItem.submenu = windowMenu; main.addItem(windowItem); NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
    @objc func openWindow() {
        popover.performClose(nil)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1180,height: 820),
                styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
            window.title = "MacEven"; window.isReleasedWhenClosed = false; window.delegate = self
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(PageGround.status.color)   // 侧边栏延伸到标题栏下，窗口控件落在侧边栏顶部
            let hosting = NSHostingView(rootView: ContentView(model: model, monitor: monitor, cache: cache, removal: removal, duplicate: duplicate, software: software,
                onSystemPageChange: { [weak self] selected in self?.systemPage = selected; self?.updateProcessVisibility() })
                .environmentObject(settings).environmentObject(tools).environmentObject(stats).environmentObject(notifications)
                .environmentObject(journal).environmentObject(protection).environmentObject(smart).environment(\.locale, localizationLocale))
            // 只采用 SwiftUI 内容的最小尺寸（ContentView 根视图 1000×560），不采用最大尺寸，避免页面内容把窗口锁死；
            // 置空会让 SwiftUI 把 contentMinSize 重置为 0，下限失效。560 兼顾 1280×800 且 Dock 常驻时仅约 712pt 的可用高度。
            hosting.sizingOptions = [.minSize]
            window.contentView = hosting
            window.contentMinSize = NSSize(width: 1000, height: 560)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            // 缩放下限由 contentMinSize 保证；frame 由 AppKit 自动保存到 UserDefaults，返回 true 表示已恢复上次尺寸与位置。
            if !window.setFrameAutosaveName("MacEvenMainWindow") { window.center() }
            self.window = window
        }
        windowOpen = true
        NSApp.setActivationPolicy(settings.menuBarOnly ? .accessory : .regular)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); updateProcessVisibility()
    }
    private func updateProcessVisibility() {
        monitor.setProcessPageVisible(windowOpen && window?.isVisible == true && window?.isMiniaturized == false && systemPage)
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc func checkForUpdates() {
        UpdateAlertManager.checkForUpdates()
    }
    @objc func showOnboarding() {
        NSApp.setActivationPolicy(.regular)
        if onboardingWindow == nil {
            let hosting = NSHostingController(rootView: OnboardingView(onClose: { [weak self] in
                self?.onboardingWindow?.close()
            }).environment(\.locale, localizationLocale))
            let win = NSWindow(contentViewController: hosting)
            win.title = localized("欢迎使用 MacEven")
            win.styleMask = [.titled, .closable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 600, height: 520))
            win.center()
            self.onboardingWindow = win
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        onboardingWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func toggleAdvancedMode() { settings.advancedMode.toggle() }
    @objc func toggleSidebarMenu() {
        openWindow()
        settings.toggleSidebar()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAdvancedMode) {
            menuItem.state = settings.advancedMode ? .on : .off
        } else if menuItem.action == #selector(toggleSidebarMenu) {
            menuItem.title = settings.sidebarCollapsed ? localized("展开侧边栏") : localized("折叠侧边栏")
        }
        return true
    }
    @objc func openPage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let page = AppPage(rawValue: raw) else { return }
        model.page = page; openWindow()
    }
    @objc func openCleanup() { model.page = .cleanup; openWindow() }
    @objc func openApplications() { if !software.busy && !removal.busy { software.tab = .uninstall }; model.page = .applications; openWindow() }
    @objc func openStartupItems() { openWindow(); model.page = .applications; software.tab = .startup }
    @objc func openDuplicates() {
        model.page = .disk
        model.setBrowseMode(.duplicates)
        openWindow()
    }
    @objc func quit() {
        removePopoverMonitors()
        // Leave the current executor job before AppKit enters its termination loop.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === onboardingWindow {
            onboardingWindow = nil
        }
        if let closing = notification.object as? NSWindow, closing === window {
            windowOpen = false; updateProcessVisibility(); NSApp.setActivationPolicy(.accessory)
        }
    }
    func windowDidMiniaturize(_ notification: Notification) { updateProcessVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateProcessVisibility() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true; observation = nil; subscriptions.removeAll(); toolTimer?.invalidate(); toolTimer = nil
        shortcut.stop(); tools.shutdown(); popover.performClose(nil)
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        smart.cancel(); model.cancel(); cache.cancel(); removal.cancel(); duplicate.cancel()
        smart.shutdown { [weak self] in
            self?.software.shutdown { [weak self] in self?.finishSoftwareTermination() }
        }
        return .terminateLater
    }
    private func finishSoftwareTermination() {
        duplicate.shutdown { [weak self] error in
            if let error { NSLog(localized("MacEven 重复文件索引清理失败：%@"), error) }
            self?.removal.shutdown { [weak self] error in
                if let error { NSLog(localized("MacEven 应用索引清理失败：%@"), error) }
                self?.finishTermination()
            }
        }
    }
    private func finishTermination() {
        cache.shutdown { [weak self] error in
            if let error { NSLog(localized("MacEven 缓存索引清理失败：%@"), error) }
            self?.monitor.shutdown { [weak self] error in
                if let error { NSLog(localized("MacEven 历史保存失败：%@"), error) }
                self?.model.shutdown { error in
                    if let error { NSLog(localized("MacEven 索引清理失败，将在下次启动重试：%@"), error) }
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }
}

extension Notification.Name {
    public static let openOnboarding = Notification.Name("local.maceven.openOnboarding")
}
