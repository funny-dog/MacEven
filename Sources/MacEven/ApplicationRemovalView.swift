import SwiftUI
import AppKit
import MacEvenCore

struct ApplicationRemovalView: View {
    @ObservedObject var removal: ApplicationRemovalModel
    @ObservedObject var software: SoftwareModel
    @ObservedObject var disk: AppModel
    @ObservedObject var cache: CacheModel
    @Environment(\.advancedMode) private var advanced
    private var otherBusy: Bool { disk.busy || cache.busy }
    var body: some View {
        PageScaffold(localized("应用"), subtitle: advanced ? localized("扫描 /Applications 与 ~/Applications") : localized("卸载不需要的应用")) {
            SoftwareTabPicker(software: software, removal: removal)
            if removal.scanning || removal.preparingData || removal.inspectingAll {
                Button(removal.inspectingAll ? localized("取消检测") : localized("取消扫描"), action: removal.cancel)
            } else {
                Button(localized("检测全部数据"), action: removal.inspectAllData).buttonStyle(.evenSecondary).disabled(!removal.canInspectAllData || otherBusy)
                    .help(localized("只读统计每个应用的关联数据（设置、缓存、容器等），完成后按「本体 + 数据」排序；不含系统与受保护应用，可随时取消"))
                Button(removal.applications.isEmpty ? localized("扫描已安装应用") : localized("重新扫描"), action: removal.start).buttonStyle(.evenPrimary).disabled(removal.busy || otherBusy)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if advanced { InlineNotice(localized("可仅删除 App 保留数据，或彻底卸载并清理确认的关联数据。"), message: localized("运行中的应用、系统和 MacEven 自身受保护，只能查看或在 Finder 中定位。"), tone: .neutral) }
                HStack(spacing: 8) {
                    if removal.busy && !removal.scanning { ProgressView().controlSize(.small) }
                    if !removal.scanning, removal.totalCount > 0 {
                        if removal.search.isEmpty {
                            Text(localized("已安装 App ")).foregroundStyle(Theme.muted) + Text(localized("\(removal.totalCount) 个")).fontWeight(.semibold)
                        } else {
                            Text(localized("匹配 ")).foregroundStyle(Theme.muted) + Text(localized("\(removal.matchedCount) 个")).fontWeight(.semibold)
                                + Text(localized(" · 共 \(removal.totalCount) 个")).foregroundStyle(Theme.muted)
                        }
                    }
                    Text(removal.status).foregroundStyle(Theme.muted).lineLimit(1)
                    if removal.inspectingAll, let bulk = removal.inspectingAllProgress {
                        Text(localized("· 第 \(bulk.done)/\(bulk.total) 项") + (removal.inspectingAllName.isEmpty ? "" : " · \(removal.inspectingAllName)"))
                            .font(.caption).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                    }
                    if advanced, !removal.scanning, let progress = removal.progress {
                        Text(localized("· 已检查 \(progress.visited) 项 · 占用估算 \(bytes(progress.allocatedSize)) · \(Int(progress.elapsed)) 秒")).font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                if removal.scanning { ScanProgressBar(estimate: removal.progressEstimate, caption: removal.progress?.caption(advanced: advanced) ?? localized("准备中…")) }
                if removal.inspectingAll {
                    ScanProgressBar(estimate: removal.dataProgressEstimate,
                        caption: localized("正在检测应用数据 · ") + (removal.inspectingAllName.isEmpty ? localized("准备中…") : removal.inspectingAllName) + localized(" · 只读，可取消"))
                }
                if otherBusy { InlineNotice(localized("磁盘或缓存任务正在工作，请结束后再扫描或卸载。"), tone: .neutral) }
                if removal.incomplete { InlineNotice(localized("结果不完整，应用卸载已禁用"), message: localized("请查看访问问题并重新扫描。")) }
                outcome
                HStack(spacing: 8) {
                    TextField(localized("搜索应用名称或路径"), text: $removal.search)
                        .textFieldStyle(.roundedBorder)
                        .disabled(removal.busy && !removal.inspectingAll)
                        .accessibilityLabel(localized("搜索应用名称或路径"))
                    Picker(localized("排序"), selection: $removal.sortMode) {
                        ForEach(ApplicationSortMode.allCases, id: \.self) { mode in Text(localizedText(mode.rawValue)).tag(mode) }
                    }
                    .labelsHidden().frame(width: 150).disabled(removal.busy || otherBusy || removal.totalCount == 0)
                    .help(localized("「本体 + 数据」需要先「检测全部数据」；未检测的应用只按本体大小参与排序"))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(removal.applications) { app in
                            ApplicationRemovalRow(removal: removal, app: app, expanded: removal.selection == app.id, otherBusy: otherBusy)
                        }
                        if removal.applications.isEmpty && !removal.scanning {
                            Text(emptyMessage)
                                .foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }.padding(.vertical, 2)
                }
                .frame(minHeight: 160, maxHeight: .infinity)
                .disabled(removal.busy && !removal.inspectingAll)
                Pager(page: removal.offset / 100 + 1, canPrevious: removal.offset > 0 && !removal.busy, canNext: removal.canNext && !removal.busy,
                    note: localized("每页最多 100 项 · 勾选可批量卸载，最多 \(ApplicationRemovalModel.batchLimit) 个"), previous: { removal.load(offset: removal.offset - 100) }, next: { removal.load(offset: removal.offset + 100) })
            }.padding(.horizontal, Theme.pagePadding).padding(.vertical, 16)
        } footer: {
            actionBar
        }
            .sheet(item: Binding(get: { removal.confirmation }, set: { if $0 == nil { removal.dismissConfirmation() } })) { frozen in
                ApplicationRemovalConfirmationView(removal: removal, frozen: frozen, otherBusy: otherBusy)
            }
            .alert(localized("应用操作提示"), isPresented: Binding(get: { removal.message != nil }, set: { if !$0 { removal.message = nil } })) {
                Button(localized("知道了")) { removal.message = nil }
            } message: { Text(removal.message ?? "") }
    }

    // 空列表提示：区分未扫描、扫描中与搜索无结果。
    private var emptyMessage: String {
        if removal.busy { return localized("正在读取…") }
        if removal.totalCount > 0 && !removal.search.isEmpty { return localized("没有匹配“\(removal.search)”的应用。试试其他名称、标识或路径。") }
        return localized("扫描后在这里列出已安装应用。点按一行展开，查看将移到废纸篓的应用包与只读的残留候选。")
    }

    // 底部操作栏：头像堆叠、『N 个 App · 本体 / 关联数据 · 合计』、『取消选择』、卸载方式、红色实心『移到废纸篓 · N 项』（点击后弹出确认）。
    private var actionBar: some View {
        let apps = removal.targets
        let size = apps.reduce(Int64(0)) { $0 + ($1.allocatedSize ?? 0) }
        let totals = removal.targetDataTotals
        let estimate = removal.removalMode == .includingData ? size + totals.included : size
        return VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 12) {
                if !apps.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(apps.prefix(3)) { app in
                            AppIcon(path: app.url.path, size: 26)
                                .padding(1).background(Circle().fill(PageGround.apps.color))
                        }
                    }.accessibilityHidden(true)
                }
                HStack(spacing: 4) {
                    if apps.isEmpty { Text(localized("未选择应用")).foregroundStyle(Theme.muted) }
                    else {
                        Text(localized("\(apps.count) 个 App")).fontWeight(.semibold)
                        Text(localized("· 本体 \(bytes(size))")).foregroundStyle(Theme.muted)
                        if removal.removalMode == .includingData {
                            if totals.unknown > 0 {
                                Text(localized("· 关联数据 \(totals.unknown) 个待检查")).foregroundStyle(Theme.muted)
                            } else {
                                Text(localized("· 关联数据 将清理 \(bytes(totals.included))")).foregroundStyle(Theme.muted)
                                if totals.retained > 0 { Text(localized(" · 保留 \(bytes(totals.retained))")).foregroundStyle(Theme.muted) }
                                Text(localized("· 合计 \(bytes(estimate))")).foregroundStyle(Theme.muted)
                            }
                        } else {
                            Text(localized("· 数据保留")).foregroundStyle(Theme.muted)
                        }
                        Text("·").foregroundStyle(Theme.muted)
                        Button(localized("取消选择")) { removal.clearChecked(); removal.selection = nil }.buttonStyle(.evenLink).disabled(removal.busy)
                    }
                }.font(.callout).monospacedDigit().lineLimit(1).layoutPriority(1)
                Spacer(minLength: 12)
                Picker(localized("卸载方式"), selection: $removal.removalMode) {
                    ForEach(ApplicationRemovalMode.allCases, id: \.self) { mode in Text(localizedText(mode.rawValue)).tag(mode) }
                }.labelsHidden().frame(width: 190).disabled(removal.busy || otherBusy)
                    .help(localized("仅删除 App 保留全部数据；彻底卸载会一并移走确认归属的关联数据"))
                if advanced { Button(localized("重新检查运行状态"), action: removal.recheck).disabled(removal.busy || otherBusy || removal.applications.isEmpty) }
                Button(apps.isEmpty ? localized("移到废纸篓") : localized("移到废纸篓 · \(apps.count) 项"), action: removal.prepareRemoval)
                    .destructiveEntryStyle().frame(minWidth: 170).disabled(!removal.canRemove || otherBusy)
                    .help(localized("点击后先确认；移到废纸篓不会立即释放空间，可在 Finder 的废纸篓中恢复。"))
            }
            .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
        }
        .background(PageGround.barShade)
    }

    // 上次操作结果、Dock 提示与访问问题；没有内容时不占位。
    @ViewBuilder private var outcome: some View {
        if !removal.results.isEmpty || removal.dockMessage != nil || (advanced && (!removal.errors.isEmpty || !removal.dataSkipRows.isEmpty || !removal.dataWarnings.isEmpty)) {
            VStack(alignment: .leading, spacing: 6) {
                if !removal.results.isEmpty {
                    let moved = removal.results.filter { $0.error == nil }.count
                    DisclosureGroup(localized("上次操作：\(moved) 项已移到废纸篓") + (moved == removal.results.count ? "" : localized("，\(removal.results.count - moved) 项保留"))) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(removal.results.enumerated()), id: \.offset) { _, result in
                                Text("\(result.path)\n\(result.error ?? localized("已移到废纸篓"))").font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let dock = removal.dockMessage { Text(dock).font(.callout).foregroundStyle(Theme.muted) }
                if advanced && !removal.dataSkipRows.isEmpty {
                    DisclosureGroup(localized("未检测关联数据的应用（\(removal.dataSkipRows.count) 个）")) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(removal.dataSkipRows.enumerated()), id: \.offset) { _, row in
                                Text(localized("\(row.name)：\(row.reason)")).font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if advanced && !removal.dataWarnings.isEmpty {
                    DisclosureGroup(localized("数据检测的访问问题（最多 100 条）")) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(removal.dataWarnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if advanced && !removal.errors.isEmpty {
                    DisclosureGroup(localized("访问问题（最多 100 条）")) {
                        ForEach(Array(removal.errors.enumerated()), id: \.offset) { _, error in Text(error).font(.caption).textSelection(.enabled) }
                    }
                }
            }.cardStyle(padding: 12)
        }
    }
}

// 可展开的应用行：标题行（图标、名称、大小、状态、勾选）；展开后分两段——『将移到废纸篓』与只读的『残留候选』。
private struct ApplicationRemovalRow: View {
    @ObservedObject var removal: ApplicationRemovalModel
    let app: InstalledApplication
    let expanded: Bool
    let otherBusy: Bool
    @Environment(\.advancedMode) private var advanced
    private var disabled: Bool { app.blockedReason != nil || app.allocatedSize == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                            .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                        AppIcon(path: app.url.path, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(app.name).fontWeight(.semibold).lineLimit(1)
                                if app.blockedReason != nil { Image(systemName: "lock").font(.caption).foregroundStyle(Theme.muted).accessibilityLabel(localized("受保护")) }
                            }
                            Text(meta).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        status
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(localized("\(app.name)，\(meta)"))
                    .accessibilityHint(expanded ? localized("收起详情") : localized("展开查看将移到废纸篓的应用包与残留候选"))
                Toggle(localized("选择 \(app.name)"), isOn: Binding(get: { removal.checked.contains(app.id) }, set: { removal.check(app.id, selected: $0) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(disabled)
                    .help(app.blockedReason ?? localized("勾选后可批量卸载（最多 \(ApplicationRemovalModel.batchLimit) 个）"))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .opacity(disabled ? 0.62 : 1)
            if expanded {
                Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 12)
                detail.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
            }
        }
        .background(expanded ? Theme.surfaceRaised.opacity(0.7) : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var meta: String {
        let size = app.allocatedSize.map { bytes($0) } ?? (advanced ? localized("未统计（只读）") : localized("未统计"))
        let identity = app.bundleIdentifier.isEmpty ? app.url.path : app.bundleIdentifier
        let base = advanced ? localized("本体 \(size) · \(identity)") : localized("本体 \(size)")
        guard removal.sortMode == .totalSize else { return base }
        // 合计排序时把排序依据显示出来；未检测数据的应用如实标明。
        guard let preview = removal.preview(for: app.id), let bundle = app.allocatedSize else { return base + localized(" · 数据未检测") }
        let total = localized("本体 \(size) · 数据 \(bytes(preview.allocatedSize)) · 合计 \(bytes(bundle + preview.allocatedSize))")
        return advanced ? total + " · \(identity)" : total
    }

    @ViewBuilder private var status: some View {
        if let reason = app.blockedReason { ReasonChip(reason: reason) }
        else if removal.isApplicationRunning(app) { Text(localized("运行中 · 确认后先退出")).font(.caption).foregroundStyle(Theme.warning).lineLimit(1) }
        else if removal.checked.contains(app.id) || expanded, let size = app.allocatedSize {
            Text(localized("移除 本体 ")).font(.caption).foregroundStyle(Theme.muted) + Text(bytes(size)).font(.caption.weight(.semibold)).monospacedDigit()
                + Text(dataSuffix).font(.caption).foregroundStyle(Theme.muted)
        }
    }

    /// 彻底卸载时把已检查的关联数据一并计入这一行的统计。
    private var dataSuffix: String {
        guard removal.removalMode == .includingData else { return "" }
        guard let preview = removal.preview(for: app.id) else { return localized(" · 数据待检查") }
        var text = localized(" · 数据 \(bytes(preview.includedSize))")
        if preview.retainedSize > 0 { text += localized("（另保留 \(bytes(preview.retainedSize))）") }
        return text
    }

    private func toggle() {
        guard !removal.busy else { return }
        if expanded { removal.selection = nil; return }
        removal.selection = app.id
        // 展开即检查大小与更多候选；只读，不会处理。
        if removal.canInspectData && !otherBusy { removal.inspectRelatedData() }
    }

    private var preview: ApplicationDataPreview? { removal.relatedData.flatMap { $0.applicationID == app.id ? $0 : nil } }
    private var includingData: Bool { removal.removalMode == .includingData }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            totals
            if removal.preview(for: app.id) == nil, let reason = removal.dataSkipReason(for: app.id) {
                Text(reason).font(.caption).foregroundStyle(Theme.muted)
            }
            sectionTitle(localized("将移到废纸篓"))
            pathRow(kind: localized("应用包"), path: app.url, size: app.allocatedSize.map(bytes) ?? localized("未统计"), locked: false)
            if includingData {
                if let preview {
                    ForEach(preview.items.filter(\.includedInRemoval)) { item in
                        pathRow(kind: item.category, path: item.url, size: item.allocatedSize.map(bytes) ?? localized("未统计"), locked: false)
                    }
                    Text(localized("彻底卸载：以上关联数据在确认时冻结，执行前重新校验。")).font(.caption).foregroundStyle(Theme.faint)
                } else {
                    Text(localized("彻底卸载：确认时会列出一并移走的关联数据。")).font(.caption).foregroundStyle(Theme.faint)
                }
            }
            HStack(spacing: 8) {
                sectionTitle(localized("残留候选"))
                Label(localized("共享或未确认的内容保留"), systemImage: "lock").font(.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                if removal.inspectingData && removal.selection == app.id { ProgressView().controlSize(.small) }
            }.padding(.top, 6)
            if let preview {
                let candidates = preview.items.filter { !(includingData && $0.includedInRemoval) }
                if candidates.isEmpty { Text(localized("未发现其他候选。")).font(.caption).foregroundStyle(Theme.muted) }
                ForEach(candidates) { item in
                    pathRow(kind: item.category, path: item.url, size: item.allocatedSize.map(bytes) ?? localized("未统计"), locked: true)
                    if let issue = item.issue { Text(issue).font(.caption).foregroundStyle(Theme.warning).textSelection(.enabled) }
                    if advanced { Text(item.evidence + (item.includedInRemoval ? localized(" · 选择彻底卸载时可一并移走") : localized(" · 保留，仅供核对"))).font(.caption2).foregroundStyle(Theme.faint) }
                }
                if advanced && !preview.warnings.isEmpty {
                    DisclosureGroup(localized("关联数据访问问题与扫描限制（\(preview.warnings.count) 条）")) {
                        ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).textSelection(.enabled) }
                    }.font(.caption)
                }
            } else {
                if app.cachePaths.isEmpty { Text(removal.inspectingData ? localized("正在检查关联数据与大小…") : localized("未找到按精确标识匹配的缓存。")).font(.caption).foregroundStyle(Theme.muted) }
                ForEach(app.cachePaths, id: \.path) { url in pathRow(kind: localized("缓存"), path: url, size: "—", locked: true) }
                if removal.canInspectData && !removal.inspectingData {
                    Button(localized("检查大小与更多候选"), action: removal.inspectRelatedData).buttonStyle(.evenLink).font(.caption).disabled(otherBusy)
                }
            }
            Text(localized("未找到更多精确匹配项，不代表没有其他残留。")).font(.caption).foregroundStyle(Theme.faint).padding(.top, 2)
            HStack {
                Button(localized("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }.buttonStyle(.evenLink).font(.caption)
                if advanced { Text(app.bundleIdentifier).font(.caption).foregroundStyle(Theme.faint).textSelection(.enabled) }
            }.padding(.top, 2)
        }
    }

    // 展开后的统计：本体 + 已检查的关联数据（区分将清理与保留），与 PearCleaner 之类的口径对齐。
    @ViewBuilder private var totals: some View {
        let bundle = app.allocatedSize
        HStack(spacing: 4) {
            Text(localized("本体 ")).foregroundStyle(Theme.muted)
            Text(bundle.map(bytes) ?? localized("未统计")).fontWeight(.semibold)
            if let preview = removal.preview(for: app.id) {
                Text(localized("· 关联数据 ")).foregroundStyle(Theme.muted)
                Text(bytes(preview.allocatedSize)).fontWeight(.semibold)
                Text(localized("（将清理 \(bytes(preview.includedSize))")).foregroundStyle(Theme.muted)
                if preview.retainedSize > 0 { Text(localized(" · 保留 \(bytes(preview.retainedSize))")).foregroundStyle(Theme.muted) }
                if preview.unmeasuredCount > 0 { Text(localized(" · 未统计 \(preview.unmeasuredCount) 项")).foregroundStyle(Theme.muted) }
                Text(localized("）")).foregroundStyle(Theme.muted)
                if let bundle { Text(localized("· 合计 \(bytes(bundle + preview.allocatedSize))")).foregroundStyle(Theme.muted) }
            } else if removal.inspectingData && removal.selection == app.id {
                Text(localized("· 正在检查关联数据…")).foregroundStyle(Theme.muted)
            }
        }
        .font(.callout).monospacedDigit().padding(.bottom, 2)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
    }

    private func pathRow(kind: String, path: URL, size: String, locked: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                if locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.faint).accessibilityLabel(localized("只读")) }
                Text(kind).lineLimit(1)
            }.font(.caption).foregroundStyle(Theme.muted).frame(width: 96, alignment: .leading)
            Text(path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: .anchored))
                .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(path.path).textSelection(.enabled)
            Spacer(minLength: 8)
            Text(size).font(.caption).monospacedDigit().foregroundStyle(Theme.text)
            Button { NSWorkspace.shared.activateFileViewerSelecting([path]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help(localized("在 Finder 中显示")).accessibilityLabel(localized("在 Finder 中显示 \(path.lastPathComponent)"))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// 关联数据行：简洁模式省略证据来源，只保留类别与是否纳入卸载；确认窗口始终用完整版本。
@MainActor func applicationRelatedDataRow(_ item: ApplicationRelatedData, advanced: Bool = true) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .top) {
            Text(item.url.path).textSelection(.enabled)
            Spacer()
            Text(item.allocatedSize.map(bytes) ?? localized("未统计")).monospacedDigit().fixedSize()
            Button(localized("查看")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        Text(advanced ? "\(item.category) · \(item.evidence) · \(item.includedInRemoval ? localized("可纳入完整卸载") : localized("保留，仅供核对"))" : "\(item.category) · \(item.includedInRemoval ? localized("彻底卸载时一并移走") : localized("保留"))").font(.caption).foregroundStyle(Theme.muted)
        if let issue = item.issue { Text(issue).font(.caption).foregroundStyle(Theme.warning).textSelection(.enabled) }
    }.padding(.vertical, 3)
}

// 卸载确认：冻结应用、模式、每个应用的数据计划与 Dock 图标；取消为默认按钮。
struct ApplicationRemovalConfirmationView: View {
    @ObservedObject var removal: ApplicationRemovalModel
    let frozen: ApplicationConfirmation
    let otherBusy: Bool
    private var batch: Bool { frozen.applications.count > 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            Text(headline)
            Text(frozen.includingData ? localized("App 与下面列出的数据将移到废纸篓。数据包括设置和沙盒内文稿，重新安装后可能无法恢复原状态。") : localized("只移走\(batch ? localized("这些") : localized("这个")) App，保留全部应用数据与缓存。"))
            Label(localized("确认后会先正常退出所选应用及其辅助进程，请保存工作并完成应用中的保存提示；拒绝退出或超时的应用会跳过，应用与数据保留。"), systemImage: "info.circle").font(.callout).foregroundStyle(Theme.warning)
            Text(localized("移到废纸篓不会立即释放空间；可在 Finder 废纸篓中恢复。操作前逐个再次检查运行状态和扫描文件身份，单个应用失败不影响其他应用。")).font(.caption)
            if frozen.includingData {
                Text(localized("共享容器、外部文稿、后台服务、自定义数据位置及无法确认归属的内容保留；以下列表不是全部残留的保证。")).font(.caption).foregroundStyle(Theme.warning)
            }
            if !frozen.dockMatches.isEmpty {
                Toggle(localized("同时从 Dock 移除 \(frozen.dockMatches.count) 个图标（\(frozen.dockMatches.map(\.label).joined(separator: localized("、")))）"), isOn: $removal.removeFromDock)
                    .toggleStyle(.checkbox)
                Text(localized("只移除成功移到废纸篓的应用的图标；修改前备份 Dock 设置，完成后 Dock 会重新启动。")).font(.caption).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(frozen.applications) { app in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                AppIcon(path: app.url.path, size: 22)
                                Text(app.name).font(.headline)
                                Spacer()
                                Text(app.allocatedSize.map(bytes) ?? localized("未统计")).monospacedDigit()
                            }
                            Text(app.url.path).font(.caption).textSelection(.enabled)
                            if frozen.includingData, let plan = frozen.dataPlans.first(where: { $0.applicationID == app.id }) {
                                Text(localized("将清理的关联数据 · 占用估算 \(bytes(plan.allocatedSize))")).font(.callout)
                                if plan.paths.isEmpty { Text(localized("未发现可确认归属的关联数据；不代表没有残留。")).font(.caption).foregroundStyle(Theme.muted) }
                                ForEach(plan.paths, id: \.path) { path in
                                    let itemSize: Int64? = frozen.relatedData?.items.first(where: { $0.url.path == path.path })?.allocatedSize
                                    HStack {
                                        Text(path.path).font(.caption).textSelection(.enabled)
                                        Spacer()
                                        Text(itemSize.map(bytes) ?? "").font(.caption).monospacedDigit()
                                    }
                                }
                                ForEach(Array(plan.retainedReasons.enumerated()), id: \.offset) { _, reason in
                                    Text(localized("本次保留：") + reason).font(.caption).foregroundStyle(Theme.warning).textSelection(.enabled)
                                }
                                if let preview = frozen.relatedData {
                                    let retained = preview.items.filter { !plan.paths.contains($0.url) }
                                    if !retained.isEmpty {
                                        Text(localized("另外发现的候选 · 本次保留")).font(.callout)
                                        ForEach(retained) { item in applicationRelatedDataRow(item) }
                                    }
                                }
                            } else if !frozen.includingData {
                                if let preview = frozen.relatedData {
                                    Text(localized("全部关联数据保留 · 已统计占用 \(bytes(preview.allocatedSize)) · 未统计 \(preview.unmeasuredCount) 项")).font(.callout)
                                    ForEach(preview.items) { item in applicationRelatedDataRow(item) }
                                } else {
                                    Text(localized("关联数据保留，不会随 App 删除。")).font(.caption).foregroundStyle(Theme.muted)
                                    ForEach(app.cachePaths, id: \.path) { path in Text(path.path).font(.caption).textSelection(.enabled) }
                                }
                            }
                        }.padding(.vertical, 4)
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(localized("取消"), action: removal.dismissConfirmation).keyboardShortcut(.defaultAction)
                Button(frozen.includingData ? localized("确认卸载并清理数据") : (batch ? localized("确认删除 \(frozen.applications.count) 个 App") : localized("确认仅删除 App")), role: .destructive, action: removal.executeRemoval)
                    .destructiveConfirmStyle().disabled(removal.busy || otherBusy)
            }.background { Button("", action: removal.dismissConfirmation).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        }.padding(24).frame(width: 660, height: 560)
    }
    private var title: String {
        switch (frozen.includingData, batch) {
        case (false, false): localized("仅删除 App？")
        case (true, false): localized("彻底卸载并清理关联数据？")
        case (false, true): localized("删除 \(frozen.applications.count) 个 App？")
        case (true, true): localized("彻底卸载 \(frozen.applications.count) 个应用并清理关联数据？")
        }
    }
    // 统计口径与列表一致：本体 + 关联数据（将清理 / 保留），并给出将移到废纸篓的合计。
    private var headline: String {
        let moving = localized("将移到废纸篓合计 \(bytes(frozen.allocatedSize))")
        if batch { return localized("\(frozen.applications.count) 个应用 · \(moving)") }
        let app = frozen.application
        var text = localized("\(app.name) · 本体 \(bytes(app.allocatedSize ?? 0))")
        if let preview = frozen.relatedData ?? removal.preview(for: app.id) {
            text += localized(" · 关联数据 \(bytes(preview.allocatedSize))（将清理 \(bytes(preview.includedSize))")
            if preview.retainedSize > 0 { text += localized(" · 保留 \(bytes(preview.retainedSize))") }
            if preview.unmeasuredCount > 0 { text += localized(" · 未统计 \(preview.unmeasuredCount) 项") }
            text += localized("）")
        }
        return text + " · " + moving
    }
}
