import SwiftUI
import AppKit
import MacEvenCore

// “缓存清理”（原智能扫描）：依次检查应用缓存、开发与浏览器缓存、软件残留，并只读统计其他存储。默认不选任何项目。
struct SmartScanView: View {
    @ObservedObject var smart: SmartScanModel
    @ObservedObject var cache: CacheModel
    @ObservedObject var removal: ApplicationRemovalModel

    @Environment(\.advancedMode) private var advanced

    private var developer: DeveloperCleanupModel { smart.developer }
    private var leftovers: LeftoverModel { smart.leftovers }

    private var isIdle: Bool { smart.phase == .idle && smart.summary == nil }
    private var isCancelled: Bool { smart.phase == .idle && smart.summary != nil }
    private var cleanableSize: Int64 { cache.selectableSize + developer.selectableSize + leftovers.selectableSize }

    private var phaseText: String {
        switch smart.phase {
        case .idle: smart.summary ?? (advanced ? localized("点击“全部扫描”依次检查三类可清理项目与其他存储") : localized("点击“全部扫描”查找可清理的空间"))
        case .scanning(let name): localized("正在检查\(name)…")
        case .measuring: advanced ? localized("正在统计其他存储（只读）…") : localized("正在完成扫描…")
        case .ready: localized("扫描完成 · 默认未选任何项目")
        case .cleaning(let name): localized("正在清理\(name)…")
        case .done: smart.summary ?? localized("清理完成")
        }
    }

    var body: some View {
        PageScaffold(localized("缓存清理"), subtitle: advanced ? localized("汇总可清理空间；所有清理都是移到废纸篓") : localized("找出可以清理的空间")) {
            if smart.scanningAll {
                Button(localized("取消扫描"), action: smart.cancel)
            } else if !isIdle {
                Button(localized("重新扫描"), action: smart.scanAll)
                    .buttonStyle(.evenPrimary)
                    .disabled(!smart.canScan)
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !smart.canScan && !smart.busy {
                        InlineNotice(localized("其他任务正在工作，请结束后再扫描。"), tone: .neutral)
                    }

                    if isCancelled, let summary = smart.summary {
                        InlineNotice(localized("扫描已取消"), message: summary, tone: .warning) {
                            Button(localized("重新扫描"), action: smart.scanAll).controlSize(.small)
                        }
                    }

                    if smart.scanningAll {
                        scanningProgressView
                    }

                    if isIdle {
                        heroInitial
                    } else {
                        compactOverview
                        categoryRows

                        if advanced {
                            advancedSection
                        }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            if advanced || smart.selectedCount > 0 {
                ActionBar(
                    localized("已选 \(smart.selectedCount) 项 · 占用估算 \(bytes(smart.selectedSize))"),
                    note: localized("确认窗口列出全部路径；执行前每类重新核验。移到废纸篓不会立即释放空间。")
                ) {
                    Button(localized("清除选择"), action: smart.clearSelection).disabled(!smart.canScan || smart.selectedCount == 0)
                    Button(localized("选择全部可清理项"), action: smart.selectAllSafe).disabled(!smart.canScan || smart.phase == .idle)
                    Button(localized("移到废纸篓…"), action: smart.prepareCleanup).destructiveEntryStyle().disabled(!smart.canScan || !smart.canClean)
                }
            }
        }
        .onChange(of: smart.scanningAll) { _, scanning in
            if scanning { smart.expandedCategories = []; smart.otherStorageExpanded = false }
        }
        .background(confirmationSheets)
        .alert(localized("缓存清理提示"), isPresented: Binding(get: { smart.message != nil }, set: { if !$0 { smart.message = nil } })) {
            Button(localized("知道了")) { smart.message = nil }
        } message: {
            Text(smart.message ?? "")
        }
    }

    private var scanningProgressView: some View {
        let caption = smart.progressCaption.isEmpty ? localized("正在扫描…") : smart.progressCaption
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text(caption)
                    .font(.callout.weight(.medium))
                Spacer()
                Button(localized("取消扫描"), action: smart.cancel).controlSize(.small)
            }
            ScanProgressBar(estimate: smart.progressEstimate, caption: smart.progressCaption)
        }
        .cardStyle(padding: 12)
    }

    @ViewBuilder private var confirmationSheets: some View {
        EmptyView()
            .sheet(item: Binding(get: { smart.confirmation }, set: { if $0 == nil { smart.dismissConfirmation() } })) { frozen in
                TrashConfirmationLayout(
                    title: localized("将选中的 \(frozen.count) 项移到废纸篓？"),
                    summary: localized("合计占用估算 \(bytes(frozen.allocatedSize))，按类别依次执行。"),
                    paths: frozen.paths,
                    notes: [
                        localized("确认后，应用与浏览器缓存会先请求相关应用正常退出，请保存工作并完成保存提示；拒绝退出或超时会保留相应缓存。"),
                        localized("应用缓存可能被应用重新生成；开发与浏览器缓存需要重新构建或重新下载；AI 诊断日志清理后旧排错记录将丢失；软件残留可能包含已卸载应用的设置与文稿。"),
                        localized("每类在执行前重新核验运行状态、用途、归属、保护列表与文件身份，无法确认的内容会保留。"),
                        localized("移到废纸篓不会立即释放空间，可在 Finder 的废纸篓中恢复。MacEven 不会清空废纸篓。")
                    ],
                    confirmDisabled: smart.busy || smart.otherBusy(),
                    cancel: smart.dismissConfirmation,
                    confirm: smart.executeCleanup
                )
            }
            .sheet(item: Binding(get: { smart.aiWorkConfirmation }, set: { if $0 == nil { smart.dismissAIWorkConfirmation() } })) { frozen in
                TrashConfirmationLayout(
                    title: localized("将选中的 \(frozen.count) 项 AI 会话与工作记录移到废纸篓？"),
                    summary: localized("合计占用估算 \(bytes(frozen.allocatedSize))。已明确保留长期记忆、配置、凭据与项目源码。"),
                    paths: frozen.paths,
                    notes: frozen.notes,
                    confirmDisabled: smart.busy || smart.otherBusy() || smart.aiWorkCleaning,
                    cancel: smart.dismissAIWorkConfirmation,
                    confirm: smart.executeAIWorkCleanup
                )
            }
            .sheet(item: Binding(get: { smart.aiStorageConfirmation }, set: { if $0 == nil { smart.dismissAIStorageConfirmation() } })) { frozen in
                TrashConfirmationLayout(
                    title: localized("将选中的 \(frozen.count) 处 AI 工作资料与记忆移到废纸篓？"),
                    summary: localized("合计占用估算 \(bytes(frozen.allocatedSize))。这些内容属于工具工作资料（不建议删除）。"),
                    paths: frozen.confirmPaths,
                    notes: [
                        localized("这些内容在日常使用中不建议删除；移到废纸篓后不会立即抹除，可在 Finder 废纸篓中随时恢复。"),
                        localized("清除模型、记忆或工作资料后，相关 AI 工具可能需要重新下载模型权重或重新生成记忆与配置。"),
                        localized("源码工作树若含有未提交修改，清除后将无法恢复未提交代码，请确认无未保存工作。")
                    ],
                    confirmDisabled: smart.busy || smart.otherBusy() || smart.aiStorageCleaning,
                    cancel: smart.dismissAIStorageConfirmation,
                    confirm: smart.executeAIStorageCleanup
                )
            }
    }

    // MARK: - 扫描完成紧凑总览条
    private var compactOverview: some View {
        HStack(spacing: 12) {
            if smart.busy && !smart.scanningAll { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                if smart.busy && !smart.scanningAll {
                    Text(phaseText).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                } else if smart.phase == .done {
                    Text(smart.summary ?? localized("清理完成"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(localized("移到废纸篓不会立即释放空间，在 Finder 中清空后生效"))
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(localized("共 \(bytes(cleanableSize))"))
                            .font(.system(size: 19, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                        Text(smart.selectedCount > 0 ? localized("已选 \(smart.selectedCount) 项 · \(bytes(smart.selectedSize))") : localized("可清理空间 · 尚未选择项目"))
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }

            if let report = smart.lastAnalysis, !smart.scanningAll {
                Text(localized("完成于 ") + report.completedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: localizationLocale)))
                    .font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize().multilineTextAlignment(.trailing)
            }
            Spacer(minLength: 8)

            if smart.phase == .ready {
                Button(localized("选择可清理项"), action: smart.selectAllSafe)
                    .controlSize(.small)
                    .disabled(cleanableSize == 0 || !smart.canScan)
                    .help(localized("按占用大小选择当前页项目，每类最多 50 项；仍需确认后才会清理。"))
            }
        }
        .cardStyle(padding: 10)
    }

    // 明细占满整行，卡片保留两列宽度，避免表格挤进半宽卡片。
    // 注意：这些跨两列的明细行不要加 .gridCellUnsizedAxes(.horizontal)：它与内容里的
    // Text.fixedSize(horizontal: false, vertical: true) 组合时，Grid 会按约零宽测量文本高度，
    // 行高会爆炸到上万点（展开后出现整屏空白）。横向不溢出由 CleanupLayoutChecks 断言看护。
    private var categoryRows: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                categoryCard(.appCache, size: cache.selectableSize, count: cache.selectableCount,
                    readOnly: cache.readOnlyCount, selected: cache.selection.count, incomplete: cache.incomplete, status: cache.status, issues: cache.errors)
                categoryCard(.developer, size: developer.otherCacheSelectableSize, count: developer.otherCacheSelectableCount,
                    readOnly: developer.otherCacheReadOnlyCount, selected: developer.otherCacheSelectedCount, incomplete: developer.incomplete, status: developer.status, issues: developer.errors)
            }
            if smart.expandedCategories.contains(.appCache) {
                expandedDetails(localized("应用缓存")) { AppCacheDetailsView(cache: cache) }.gridCellColumns(2)
            }
            if smart.expandedCategories.contains(.developer) {
                expandedDetails(localized("开发与浏览器缓存")) { DeveloperCacheDetailsView(model: developer) }.gridCellColumns(2)
            }
            GridRow {
                categoryCard(.leftovers, size: leftovers.selectableSize, count: leftovers.selectableCount,
                    readOnly: leftovers.readOnlyCount, selected: leftovers.selection.count, incomplete: leftovers.incomplete, status: leftovers.status, issues: leftovers.errors)
                CleanupCategoryCard(title: localized("AI 清理与维护"), symbol: "sparkles", hue: .blue,
                    size: smart.aiMaintenanceSize,
                    status: smart.aiMaintenanceStatus,
                    badge: smart.aiMaintenanceIncomplete ? localized("不完整") : localized("可逐项确认"),
                    expanded: smart.aiExpanded) {
                        smart.aiExpanded.toggle()
                        if smart.aiExpanded { smart.aiWorkStorageExpanded = false }
                    }
            }
            if smart.expandedCategories.contains(.leftovers) {
                expandedDetails(localized("软件残留")) { LeftoverDetailsView(model: leftovers) }.gridCellColumns(2)
            }
            if smart.aiExpanded {
                AICleanupPanelView(smart: smart, developer: developer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle(padding: 12)
                    .accessibilityElement(children: .contain)
                    .disabled(!smart.canScan)
                    .gridCellColumns(2)
            }
        }
    }

    private func expandedDetails<Detail: View>(_ title: String, @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            detail()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 12)
        .accessibilityElement(children: .contain)
        .disabled(!smart.canScan)
    }

    private func categoryCard(
        _ category: CleanupCategory, size: Int64, count: Int, readOnly: Int,
        selected: Int, incomplete: Bool, status: String, issues: [String]
    ) -> some View {
        let caption: String
        if incomplete {
            caption = advanced ? (localized("未完成：") + (issues.first ?? status)) : localized("未完成 · 未核验项目已保留")
        } else if count == 0 && readOnly == 0 {
            caption = status
        } else {
            caption = localized("\(count) 项可清理") + (selected > 0 ? localized(" · 已选 \(selected) 项") : "") + (advanced && readOnly > 0 ? localized(" · \(readOnly) 项保留，点击查看原因") : "")
        }
        return CleanupCategoryCard(title: category.title, symbol: category.symbol, hue: category.hue,
            size: size, status: caption, badge: incomplete ? localized("不完整") : nil,
            expanded: smart.expandedCategories.contains(category)) {
                if smart.expandedCategories.contains(category) { smart.expandedCategories.remove(category) }
                else { smart.expandedCategories.insert(category) }
            }
    }

    // MARK: - 未扫描首页
    private var heroInitial: some View {
        VStack(spacing: 18) {
            ScanFilesMark()
                .frame(width: 240, height: 240)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(localized("让 Mac 轻装上阵"))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(localized("一次检查应用、开发与浏览器缓存及软件残留"))
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            Button(action: smart.scanAll) {
                Text(localized("开始扫描")).frame(width: 160)
            }
            .buttonStyle(.evenHero)
            .disabled(!smart.canScan)

            Text(localized("只会移到废纸篓，确认前不会改动任何文件。"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    // MARK: - 高级模式附加区（说明 + 可折叠其他存储只读区）
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup(isExpanded: $smart.otherStorageExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localized("“选择全部可清理项”在每类中按占用从大到小选择，每类最多 50 项；只读、受保护、正在使用或统计不完整的项目不会被选中。也可以在上方展开各类逐项挑选。"))
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Text(localized("这些位置通常很大，但需要用对应的工具管理，MacEven 不提供删除。"))
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        if smart.storage.isEmpty {
                            Text(smart.phase == .measuring ? localized("统计中…") : localized("扫描后显示存在的位置。"))
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                        ForEach(smart.storage) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.location.name).font(.callout.weight(.medium))
                                    Spacer()
                                    Text(item.issue != nil && item.allocatedSize == 0 ? localized("未统计") : bytes(item.allocatedSize)).monospacedDigit().font(.callout)
                                    Button(localized("在 Finder 查看")) {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.location.url])
                                    }
                                    .controlSize(.small)
                                }
                                Text(item.location.note).font(.caption).foregroundStyle(Theme.muted)
                                if let issue = item.issue {
                                    Text(issue).font(.caption).foregroundStyle(item.skipped ? Theme.muted : Theme.warning)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack {
                        Text(localized("其他存储 · 只读"))
                            .font(.headline)
                        if !smart.storage.isEmpty {
                            Text(localized("（\(smart.storage.count) 处 · \(bytes(smart.storage.reduce(0) { $0 + $1.allocatedSize }))）"))
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .cardStyle(padding: 12)
        }
    }
}

struct CleanupCategoryCard: View {
    let title: String
    let symbol: String
    let hue: ThemeHue
    let size: Int64
    let status: String
    let badge: String?
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(hue.gradient, in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    Spacer(minLength: 0)
                    if let badge { StatusChip(text: badge, tone: badge == localized("不完整") ? .warning : .neutral) }
                }.frame(height: 36)
                HStack(alignment: .firstTextBaseline) {
                    Text(badge == localized("不完整") && size == 0 ? localized("未完成统计") : bytes(size)).font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    Text(expanded ? localized("收起明细") : localized("展开明细")).font(.caption).foregroundStyle(Theme.muted)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                Text(status).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).help(status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 12, hue: hue)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(expanded ? hue.base : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(localized("\(bytes(size))，\(status)，\(expanded ? localized("已展开") : localized("已收起"))"))
        .accessibilityHint(localized("点击\(expanded ? localized("收起") : localized("展开"))明细"))
    }
}

// 文件与扫描线沿用项目配色，避免球体图形。
private struct ScanFilesMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24).fill(ThemeHue.blue.base.opacity(0.12))
                .frame(width: 144, height: 166).rotationEffect(.degrees(-12)).offset(x: -22, y: 4)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 116, weight: .light))
                .foregroundStyle(ThemeHue.blue.base.gradient)
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .medium)).foregroundStyle(ThemeHue.teal.base)
                .offset(x: 72, y: -70)
        }
    }
}
