import SwiftUI
import AppKit
import MacEvenCore

extension AppPage {
    var sidebarPage: AppPage { switch self { case .overview: .cleanup; default: self } }
    var title: String { switch self { case .applications: localized("应用与软件"); case .overview: localizedText(AppPage.cleanup.rawValue); default: localizedText(rawValue) } }
    var symbol: String {
        switch self {
        case .system: "gauge.with.dots.needle.67percent"
        case .overview: "sparkles"
        case .disk: "chart.pie.fill"
        case .cleanup: "sparkles"
        case .applications: "square.grid.2x2.fill"
        case .settings: "gearshape.fill"
        }
    }
    // 页面色：侧边栏图标块与页内默认图表色（icon-*）。
    var hue: ThemeHue {
        switch self { case .system: .green; case .overview: .violet; case .disk: .orange; case .cleanup: .violet; case .applications: .blue; case .settings: .gray }
    }
    // 每页一种窗口底色（ground-*），缓存清理与全局保持一致采用 status 底色。
    var ground: PageGround {
        switch self { case .system: .status; case .overview: .status; case .disk: .disk; case .cleanup: .status; case .applications: .apps; case .settings: .settings }
    }
    // 窗口菜单快捷键 ⌘N 与顺序；5 保留给磁盘分析内的重复文件浏览方式。
    var order: Int {
        switch self { case .system: 1; case .overview: 2; case .disk: 3; case .cleanup: 4; case .applications: 6; case .settings: 7 }
    }
    // 侧边栏分组：概览 / 空间 / 软件；设置固定在底部。
    static let sidebarGroups: [(title: String, pages: [AppPage])] = [
        (localized("概览"), [.system]), (localized("空间"), [.disk, .cleanup]), (localized("软件"), [.applications])
    ]
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: MonitorModel
    @ObservedObject var cache: CacheModel
    @ObservedObject var removal: ApplicationRemovalModel
    @ObservedObject var duplicate: DuplicateModel
    @ObservedObject var software: SoftwareModel
    @EnvironmentObject var smart: SmartScanModel
    @EnvironmentObject var settings: StatusSettings
    let onSystemPageChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, monitor: monitor, cache: cache, removal: removal, duplicate: duplicate, software: software)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.pageHue, model.page.sidebarPage.hue)
        }
        .foregroundStyle(Theme.text)
        .background { ZStack { model.page.sidebarPage.ground.color; model.page.sidebarPage.ground.gradient }.ignoresSafeArea() }
        .environment(\.pageGround, model.page.sidebarPage.ground)
        .tint(Theme.accent)
        .environment(\.advancedMode, settings.advancedMode)
        .frame(minWidth: 1000, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .onAppear { onSystemPageChange(model.page == .system); normalizeNavigation() }
        .onChange(of: model.page) { _, value in onSystemPageChange(value == .system); normalizeNavigation() }
        .onChange(of: settings.advancedMode) { _, _ in normalizeNavigation() }
        .onChange(of: software.tab) { _, _ in normalizeNavigation() }
    }

    // 旧扫描与残留入口归入缓存清理；简洁模式下再归一进阶标签与筛选。
    private func normalizeNavigation() {
        if model.page == .overview { model.page = .cleanup }
        if model.page == .applications && software.tab == .leftovers {
            model.page = .cleanup; software.tab = .uninstall
        }
        guard !settings.advancedMode else { return }
        // 简洁模式不停留进阶浏览方式：分类筛选与空间地图都切回目录占用；重复文件两种模式都可用。
        if model.browseMode == .spaceInsights || model.browseMode == .treemap { model.setBrowseMode(.directory) }
    }

    @ViewBuilder private var detail: some View {
        switch model.page {
        case .system: SystemStatusView(monitor: monitor, openDisk: {
            model.page = .disk
        })
        case .overview, .cleanup:
            SmartScanView(smart: smart, cache: cache, removal: removal)
                .disabled(duplicate.busy || software.busy)
        case .disk: diskDetail.disabled(smart.busy)
        case .applications: SoftwareView(software: software, removal: removal, disk: model, cache: cache, duplicate: duplicate)
                .disabled(smart.busy)
        case .settings: SettingsPage(monitor: monitor)
        }
    }

    private var diskDetail: some View {
        let advanced = settings.advancedMode
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker(localized("浏览方式"), selection: Binding(get: { model.browseMode }, set: { model.setBrowseMode($0) })) {
                    Text(localized("按用途")).tag(DiskBrowseMode.purposes)
                    Text(localized("目录")).tag(DiskBrowseMode.directory)
                    Text(localized("空间地图")).tag(DiskBrowseMode.treemap)
                    Text(advanced ? localized("大文件 · 前 100 项") : localized("大文件")).tag(DiskBrowseMode.largeFiles)
                    Text(localized("重复文件")).tag(DiskBrowseMode.duplicates)
                    // 分类筛选是进阶浏览方式；切到简洁模式时 normalizeNavigation 会切回目录。
                    if advanced || model.browseMode == .spaceInsights { Text(localized("分类与筛选")).tag(DiskBrowseMode.spaceInsights) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(model.busy || model.loading || duplicate.busy || cache.busy || removal.busy || software.busy || (model.rootEntry == nil && model.browseMode != .duplicates))
                if model.browseMode == .treemap && smart.scanningAll {
                    Button(localized("取消分析"), action: smart.cancel).buttonStyle(.evenSecondary)
                }
            }
            .padding(.horizontal, Theme.pagePadding).padding(.top, 16)
            if model.browseMode == .duplicates {
                DuplicateView(model: duplicate, otherBusy: model.busy || model.loading || cache.busy || removal.busy || software.busy)
            } else {
                DiskAnalysisView(model: model, cleanup: smart).disabled(cache.busy || removal.busy || duplicate.busy || software.busy)
            }
        }
    }
}

// 侧边栏：全 App 唯一的一级导航。自上而下：标志、CPU / 内存 / 磁盘三环、分组条目、后台任务块、设置。
// 支持展开（232pt）与折叠（68pt）双态，折叠后只显示居中可点击图标，保持极简专注。
private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: MonitorModel
    @ObservedObject var cache: CacheModel
    @ObservedObject var removal: ApplicationRemovalModel
    @ObservedObject var duplicate: DuplicateModel
    @ObservedObject var software: SoftwareModel
    @EnvironmentObject var smart: SmartScanModel
    @EnvironmentObject var settings: StatusSettings

    var body: some View {
        VStack(alignment: settings.sidebarCollapsed ? .center : .leading, spacing: 0) {
            header
            if !settings.sidebarCollapsed {
                SidebarRings(monitor: monitor).padding(.bottom, 6)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: settings.sidebarCollapsed ? .center : .leading, spacing: 2) {
                    ForEach(AppPage.sidebarGroups, id: \.title) { group in
                        if !settings.sidebarCollapsed {
                            Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        } else if group.title != AppPage.sidebarGroups.first?.title {
                            Spacer().frame(height: 6)
                        }
                        ForEach(group.pages) { item($0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: settings.sidebarCollapsed ? .center : .leading)
            }
            BackgroundTasksCard(model: model, cache: cache, developer: cache.developer, removal: removal, duplicate: duplicate, software: software,
                advanced: settings.advancedMode, collapsed: settings.sidebarCollapsed)
            item(.settings)
        }
        .padding(.horizontal, settings.sidebarCollapsed ? 0 : 10).padding(.bottom, 12)
        .frame(width: settings.sidebarCollapsed ? Theme.sidebarCollapsedWidth : Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PageGround.sidebarShade.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1).ignoresSafeArea() }
        .animation(.easeInOut(duration: 0.2), value: settings.sidebarCollapsed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("主导航"))
    }

    @ViewBuilder private var header: some View {
        if settings.sidebarCollapsed {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    settings.toggleSidebar()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 28)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(localized("展开侧边栏 (⌃⌘S)"))
            .accessibilityLabel(localized("展开侧边栏"))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 38)
            .padding(.bottom, 12)
        } else {
            HStack(spacing: 8) {
                BrandMark(size: 30)
                Text("MacEven").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.toggleSidebar()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 26, height: 26)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.control, .command])
                .help(localized("折叠侧边栏 (⌃⌘S)"))
                .accessibilityLabel(localized("折叠侧边栏"))
            }
            .padding(.horizontal, 8).padding(.top, 38).padding(.bottom, 12)
        }
    }

    // 文件类任务运行时，其他文件类页面禁用并说明原因；系统状态与设置始终可进入。
    private func disabledReason(_ page: AppPage) -> String? {
        guard page != .system && page != .settings && page != model.page.sidebarPage else { return nil }
        let owner: AppPage? = {
            if model.busy || model.loading || duplicate.busy { return .disk }
            if smart.busy || cache.busy || removal.leftovers.busy { return .cleanup }
            if software.busy || removal.busy { return .applications }
            return nil
        }()
        guard let owner, owner != page else { return nil }
        return localized("\(owner.title)任务进行中，暂不可切换")
    }

    @ViewBuilder private func badge(_ page: AppPage) -> some View {
        switch page {
        case .cleanup where smart.phase == .ready:
            // 数值类徽标：无底色的 ink-muted 文字。
            let size = cache.selectableSize + smart.developer.selectableSize + smart.leftovers.selectableSize
            Text(bytes(size)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(model.page == page ? Theme.navActiveText.opacity(0.7) : Theme.muted)
        case .applications:
            // 待办计数：badge-alert 药丸。
            let count = software.entries.filter(\.hasUpdate).count
            if count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.badge, in: Capsule())
                    .accessibilityLabel(localized("\(count) 个可更新"))
            }
        default: EmptyView()
        }
    }

    private func item(_ page: AppPage) -> some View {
        let current = model.page.sidebarPage == page
        let reason = disabledReason(page)
        let hasUpdate = page == .applications && software.entries.contains(where: \.hasUpdate)
        return Button {
            if !current { model.page = page }
        } label: {
            if settings.sidebarCollapsed {
                ZStack(alignment: .topTrailing) {
                    SidebarIcon(page: page)
                    if hasUpdate {
                        Circle()
                            .fill(Theme.badge)
                            .frame(width: 7, height: 7)
                            .offset(x: 2, y: -2)
                    }
                }
                .frame(width: 44, height: 38)
                .background {
                    if current {
                        RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(Theme.navActive)
                            .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            } else {
                HStack(spacing: 10) {
                    SidebarIcon(page: page)
                    Text(page.title).font(.system(size: 14, weight: current ? .semibold : .regular)).lineLimit(1)
                        .foregroundStyle(current ? Theme.navActiveText : Theme.text)
                    Spacer(minLength: 4)
                    badge(page)
                }
                .padding(.horizontal, 8).frame(height: 38)
                .background {
                    if current {
                        RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(Theme.navActive)
                            .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .opacity(reason != nil ? 0.45 : 1)
        .help(reason ?? "\(page.title) · ⌘\(page.order)")
        .accessibilityLabel(hasUpdate ? localized("\(page.title)，有更新") : page.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

// 三环概览：CPU / 内存 / 磁盘占比；未取得读数时只画轨道并显示“—”。
private struct SidebarRings: View {
    @ObservedObject var monitor: MonitorModel
    var body: some View {
        let s = monitor.snapshot
        let memory: Double? = {
            guard let used = s?.usedMemoryBytes, let total = s?.physicalMemoryBytes, total > 0 else { return nil }
            return Double(used) / Double(total)
        }()
        let disk: Double? = {
            guard let total = s?.diskTotalBytes, let available = s?.diskAvailableBytes, total > 0, available <= total else { return nil }
            return 1 - Double(available) / Double(total)
        }()
        HStack(spacing: 4) {
            ring("CPU", s?.cpuPercent.map { $0 / 100 }, Theme.dataCPU)
            ring(localized("内存"), memory, Theme.dataMemory)
            ring(localized("磁盘"), disk, Theme.dataDisk)
        }
        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func ring(_ name: String, _ fraction: Double?, _ tint: Color) -> some View {
        let text = fraction.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))" } ?? "—"
        return VStack(spacing: 3) {
            RingGauge(fraction: fraction, tint: tint, track: Theme.border, lineWidth: 5) {
                Text(text).font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
            }.frame(width: 46, height: 46)
            Text(name).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fraction == nil ? localized("\(name) 未取得读数") : "\(name) \(text)%")
    }
}

// 后台任务卡：读取各模型已有的 busy / scanning，不新增状态。
private struct BackgroundTasksCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var cache: CacheModel
    @ObservedObject var developer: DeveloperCleanupModel
    @ObservedObject var removal: ApplicationRemovalModel
    @ObservedObject var duplicate: DuplicateModel
    @ObservedObject var software: SoftwareModel
    let advanced: Bool
    var collapsed: Bool = false

    var body: some View {
        if collapsed {
            compactIndicator(activeTasks)
        } else {
            card(activeTasks)
        }
    }

    @ViewBuilder
    private func compactIndicator(_ tasks: [String]) -> some View {
        if tasks.isEmpty {
            EmptyView()
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.dataDisk)
                .frame(width: 44, height: 32)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .padding(.vertical, 4)
                .help(localized("后台任务进行中：\n") + tasks.joined(separator: "\n"))
                .accessibilityLabel(localized("后台任务进行中：\(tasks.joined(separator: localized("，")))"))
        }
    }

    private func card(_ tasks: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tasks.first.map { localized("后台任务 · \($0.components(separatedBy: " · ").first ?? $0)") } ?? localized("后台任务")).font(.system(size: 12, weight: .semibold))
            if advanced { row(localized("系统监控 · 运行中"), tone: .good) }
            if tasks.isEmpty {
                row(model.rootEntry == nil ? localized("空闲 · 没有正在运行的扫描") : diskIdleText, tone: model.rootEntry != nil && model.incompleteResultNotice != nil ? .warning : .neutral)
            } else {
                ForEach(tasks.dropFirst(), id: \.self) { row($0, tone: .warning) }
                // 总数未知：只画不确定活动条，不显示百分比。
                ProgressView().progressViewStyle(.linear).tint(Theme.dataDisk).controlSize(.small).padding(.top, 4)
                    .accessibilityLabel(localized("\(tasks[0])，总数未知"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .padding(.top, 8).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var activeTasks: [String] {
        var result: [String] = []
        if model.scanning { result.append(localized("磁盘扫描 · 进行中")) } else if model.operating || model.loading { result.append(localized("磁盘分析 · 处理中")) }
        if cache.scanning || cache.operating || cache.loading { result.append(localized("应用缓存 · 进行中")) }
        if developer.busy { result.append(localized("开发与浏览器缓存 · 进行中")) }
        if removal.busy { result.append(localized("应用扫描 · 进行中")) }
        if duplicate.busy { result.append(localized("重复文件 · 进行中")) }
        if software.busy { result.append(localized("软件检查 · 进行中")) }
        return result
    }

    private var diskIdleText: String {
        if model.rootEntry == nil { return localized("磁盘扫描 · 空闲") }
        return model.incompleteResultNotice == nil ? localized("磁盘扫描 · 已完成") : localized("磁盘扫描 · 完成但不完整")
    }

    private func row(_ text: String, tone: StatusTone, busy: Bool = false) -> some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini) }
            else if tone != .neutral { Circle().fill(tone == .good ? Theme.dataCPU : tone.color).frame(width: 6, height: 6).accessibilityHidden(true) }
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
}

// 侧边栏图标：每页一色的渐变圆角块 + 白色字形，两个主题相同；磁盘空状态也沿用。
struct SidebarIcon: View {
    let page: AppPage
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(page.hue.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 0.75, y: 0.5)
            .accessibilityHidden(true)
    }
}
