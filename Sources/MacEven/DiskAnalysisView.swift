import SwiftUI
import AppKit
import MacEvenCore

// 使用属性包装器类型：SDK 27 同名宏需要 Xcode 专有插件。
private typealias DiskViewState<Value> = SwiftUI.State<Value>

struct DiskAnalysisView: View {
    @ObservedObject var model: AppModel
    var cleanup: SmartScanModel? = nil
    @DiskViewState private var showErrors = false
    @DiskViewState private var explained: PurposeLabel?
    @DiskViewState private var mapSidebar = 0
    @Environment(\.advancedMode) private var advanced
    var body: some View {
        PageScaffold(localized("磁盘分析"), subtitle: model.rootEntry == nil || model.scanning ? model.status : localized("大小为已分配块估算，移到废纸篓不会立即释放空间")) {
            if model.operating || model.loading { ProgressView().controlSize(.small) }
            if model.rootEntry != nil && !model.scanning {
                Button(localized("重新扫描")) { model.start() }
                    .disabled(model.operating).buttonStyle(.evenPrimary)
            }
        } content: {
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 12) {
                    if model.rootEntry != nil {
                        if model.browseMode == .treemap {
                            mapLayout(geometry: geometry)
                        } else if model.browseMode == .purposes {
                            purposesLayout(geometry: geometry)
                        } else {
                            defaultLayout(geometry: geometry)
                        }
                    } else {
                        overview
                        emptyState
                        scanNotes
                    }
                }
            }.padding(.horizontal, Theme.pagePadding).padding(.top, 10).padding(.bottom, 14)
            .alert(explained?.title ?? "", isPresented: Binding(get: { explained != nil }, set: { if !$0 { explained = nil } }), presenting: explained) { _ in
                Button(localized("知道了")) { explained = nil }
            } message: { label in
                Text(localized("\(label.detail)\n\n\(label.safety.title)：\(label.safety.explanation)。\n\n判断依据：\(label.evidence)") + (advanced ? localized("\n规则：\(label.ruleID)") : "")
                    + localized("\n\n用途说明只供参考，不会改变能否移到废纸篓。"))
            }
        } footer: {
            if model.rootEntry != nil && (model.browseMode != .treemap || cleanup == nil || mapSidebar == 0 || !model.selection.isEmpty) {
                ActionBar(localized("已选 \(model.selection.count) 项 · 占用估算 \(bytes(model.selectedSize))"), note: localized("移到废纸篓不会立即释放空间，可在 Finder 的废纸篓中恢复。")) {
                    Button(localized("在 Finder 中显示")) { reveal(ids: model.selection) }.buttonStyle(.evenSecondary).disabled(model.selection.isEmpty || model.busy)
                    Button(localized("移到废纸篓…"), action: model.prepareTrash).destructiveEntryStyle().disabled(!model.canTrash)
                }
            }
        }
        .sheet(item: Binding(get: { model.trashConfirmation }, set: { if $0 == nil { model.dismissTrashConfirmation() } })) { frozen in
            TrashConfirmationLayout(title: localized("确认移到废纸篓？"), summary: localized("已选 \(frozen.entries.count) 项，磁盘占用估算 \(bytes(frozen.allocatedSize))。"),
                paths: frozen.entries.map { ConfirmPath(path: $0.url.path, size: bytes($0.allocatedSize)) },
                notes: [localized("操作前会重新校验文件身份、类型和修改时间；文件已变化时会要求重新扫描。"),
                    localized("父目录与子项同时选中时，只处理父目录。"),
                    localized("移到废纸篓不会立即释放空间，可在 Finder 的废纸篓中恢复。MacEven 不会清空废纸篓。")],
                confirmDisabled: model.busy, cancel: model.dismissTrashConfirmation, confirm: model.trashSelected)
        }
        .alert(localized("操作信息"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(localized("知道了")) { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(isPresented: $showErrors) { errorSheet }
        .background(model.browseMode == .treemap ? Color(light: 0xf4f4f2, dark: 0x202022) : .clear)
    }

    @ViewBuilder private func mapLayout(geometry: GeometryProxy) -> some View {
        let compact = geometry.size.height < 380
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.incompleteResultNotice != nil { overview }
                HStack(spacing: 10) {
                    mapMetric(localized("扫描占用"), value: model.rootEntry.map { bytes($0.allocatedSize) } ?? "—", detail: compact ? nil : localized("已扫描范围 · 估算"), hue: .gray)
                    mapMetric(localized("当前目录"), value: model.treemapSnapshot.flatMap { $0.invalidSizeCount == 0 ? bytes($0.totalAllocatedSize) : nil } ?? "—",
                        detail: compact ? nil : model.treemapSnapshot.map { localized("\($0.totalCount.formatted()) 个子项") } ?? localized("正在加载…"), hue: .violet)
                    mapMetric(localized("已选占用"), value: bytes(model.selectedSize), detail: compact ? nil : localized("\(model.selection.count) 项 · 非可释放空间"), hue: .blue)
                    mapMetric(localized("其他子项"), value: model.treemapSnapshot.flatMap { $0.invalidSizeCount == 0 ? bytes($0.otherAllocatedSize) : nil } ?? "—",
                        detail: compact ? nil : model.treemapSnapshot.map { localized("\($0.otherCount.formatted()) 个较小子项") } ?? localized("正在加载…"), hue: .teal)
                }
            }
        }
        .frame(maxHeight: min(164, max(70, geometry.size.height - 276)))
        .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: 12) {
            TreemapView(model: model, compact: compact).frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                .cardStyle(padding: 12)
            VStack(spacing: 10) {
                if let cleanup {
                    Picker(localized("空间地图侧栏"), selection: $mapSidebar) {
                        Text(localized("目录明细")).tag(0)
                        Text(localized("清理建议")).tag(1)
                    }.pickerStyle(.segmented).labelsHidden()
                    if mapSidebar == 0 {
                        directoryColumn(compact: compact)
                    } else {
                        DiskRecommendationsView(model: model, smart: cleanup)
                    }
                } else {
                    directoryColumn(compact: compact)
                }
            }
                .frame(maxHeight: .infinity).cardStyle(padding: 12)
                .frame(width: min(310, max(264, geometry.size.width * 0.30)))
        }
        .frame(minHeight: 200, maxHeight: .infinity)
    }

    private func mapMetric(_ title: String, value: String, detail: String?, hue: ThemeHue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(hue.base).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(title).font(.caption).foregroundStyle(Theme.muted)
            }
            Text(value).font(.system(size: 23, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func defaultLayout(geometry: GeometryProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overview
                resultOverview
                scanNotes
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: min(280, max(60, geometry.size.height - 248)))
        .fixedSize(horizontal: false, vertical: true)
        results
    }

    @ViewBuilder private func purposesLayout(geometry: GeometryProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overview
                resultOverview
                HStack {
                    if let cat = model.purposeCategory {
                        Text(model.expandPurposeFiles ? localized("\(cat.title) · 占用最多的位置") : localized("已选用途：\(cat.title) · 包含 \(model.entries.count) 个位置"))
                            .font(model.expandPurposeFiles ? .headline : .callout.weight(.medium))
                    } else {
                        Text(model.expandPurposeFiles ? localized("按用途排序的文件位置") : localized("点击上方任意用途分类或下方按钮可展开具体文件列表"))
                            .font(model.expandPurposeFiles ? .headline : .caption)
                            .foregroundStyle(model.expandPurposeFiles ? Theme.text : Theme.muted)
                    }
                    Spacer()
                    Button(model.expandPurposeFiles ? localized("收起文件列表 ▲") : localized("展开文件列表 ▼")) {
                        withAnimation { model.expandPurposeFiles.toggle() }
                    }
                    .buttonStyle(.evenSecondary)
                    .controlSize(.small)
                }
                if model.expandPurposeFiles {
                    results
                }
                scanNotes
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var overview: some View {
        if model.rootEntry == nil && !model.scanning, let report = model.lastAnalysis {
            LastAnalysisNotice(report: report)
        }
        if let notice = model.incompleteResultNotice {
            let message = model.hasAuthorizableIssues
                ? localized("未扫描的内容未计入占用估算，下列大小可能偏小；授予完全磁盘访问权限并重新扫描可补全。")
                : localized("部分路径受权限或系统限制未计入占用估算。")
            InlineNotice(notice, message: message) {
                if !model.errorExamples.isEmpty {
                    Button(localized("查看访问错误")) { showErrors = true }
                }
                if model.hasAuthorizableIssues {
                    Button(localized("权限设置"), action: openPrivacy)
                }
            }
        }
        if model.scanning && model.rootEntry != nil {
            ScanProgressBar(estimate: model.progressEstimate, caption: model.progress?.caption(advanced: advanced) ?? localized("准备中…"))
            if advanced, let progress = model.progress {
                Text(progress.currentPath).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).help(progress.currentPath)
            }
        } else if !model.scanning, advanced, let progress = model.progress {
            HStack {
                Text(localized("已检查 \(progress.visited.formatted()) 项 · 占用估算 \(bytes(progress.allocatedSize)) · \(Int(progress.elapsed)) 秒 · \(progress.errorCountDescription)"))
                    .font(.callout).foregroundStyle(Theme.muted).monospacedDigit()
                Spacer()
                if let root = model.rootEntry { Text(localized("磁盘占用估算 \(bytes(root.allocatedSize))")).font(.callout.weight(.semibold)).monospacedDigit() }
            }
        }
    }

    @ViewBuilder private var scanNotes: some View {
        if advanced {
            Divider()
            HStack(alignment: .top) {
                Text(localized("大小是扫描时的估算，APFS 快照与共享块可能影响实际占用。废纸篓、其他卷和系统卷镜像不计入。"))
                    .font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                if !model.errorExamples.isEmpty { Button(localized("扫描问题")) { showErrors = true }.controlSize(.small) }
                if model.hasAuthorizableIssues { Button(localized("权限设置"), action: openPrivacy).controlSize(.small) }
            }
        }
    }

    @ViewBuilder private var resultOverview: some View {
        // 空间地图自带面包屑行。
        if model.showsBreadcrumbs && model.browseMode != .treemap {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.breadcrumbs) { item in
                        Button(item.id == 1 ? localized("内部磁盘") : item.name) { model.load(directory: item.id) }.buttonStyle(.evenLink)
                        Text("›").foregroundStyle(Theme.muted)
                    }
                }
            }.disabled(model.scanning || model.operating)
            if let label = model.directoryLabel {
                // 当前目录的用途只显示一次；行上不再重复同一条继承标签。
                HStack(spacing: 8) {
                    PurposePill(label: label)
                    Text(label.detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }.help(label.helpText)
            }
        }
        if model.browseMode == .largeFiles { largeFilesOverview }
        if model.browseMode == .spaceInsights { SpaceInsightsView(model: model) }
        if model.browseMode == .purposes { PurposeSummaryView(model: model) }
        if model.browseMode == .directory && !model.largeFiles { directoryTotal }
    }

    // 大文件排行说明与范围切换：默认可清理，一键切回全部前 100。
    private var largeFilesOverview: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.largeFilesScope == .cleanable ? localized("可清理的大文件") : localized("全盘最大的文件"))
                    .font(.headline)
                Text(largeFilesCaption)
                    .font(.caption).foregroundStyle(Theme.muted)
                    .lineLimit(2).truncationMode(.tail)
                    .help(largeFilesCaption)
                if let summary = largeFilesLockSummary {
                    Text(summary).font(.caption).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.tail).help(summary)
                }
            }
            Spacer(minLength: 8)
            Picker(localized("大文件范围"), selection: Binding(
                get: { model.largeFilesScope },
                set: { model.setLargeFilesScope($0) }
            )) {
                Text(localized("可清理")).tag(DiskLargeFilesScope.cleanable)
                Text(localized("全部")).tag(DiskLargeFilesScope.all)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(model.busy)
            .accessibilityLabel(localized("大文件范围"))
        }
    }

    private var largeFilesCaption: String {
        if model.largeFilesScope == .cleanable {
            var text = localized("主目录内可清理的普通文件，最多显示 100 项；主目录外、资料库、隐藏路径与应用包内部文件不计入。应用整体请在「软件」页处理。")
            if !model.loading && !model.entries.isEmpty && model.entries.count < 100 {
                text += localized(" 只有 \(model.entries.count) 项可清理文件。")
            }
            return text
        }
        var text = localized("最多显示 100 项，已排除应用包内部文件（本轮跳过 \(model.largeFilesSkippedBundleCount) 项）。应用整体请在「软件」页处理。")
        if model.largeFilesCapped { text += localized(" 已停止加载，当前仅列出部分结果。") }
        return text
    }

    private var largeFilesLockSummary: String? {
        guard model.largeFilesScope == .all, !model.loading, !model.blocked.isEmpty else { return nil }
        let counts = Dictionary(grouping: model.blocked.values, by: \.summaryLabel).mapValues(\.count)
        let parts = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }
        return localized("受保护 \(model.blocked.count) 项：\(parts.joined(separator: " · "))")
    }

    @ViewBuilder private var results: some View {
        if model.browseMode == .largeFiles && !model.loading && !model.scanning && model.entries.isEmpty {
            largeFilesEmptyState.frame(minHeight: 200, maxHeight: .infinity)
        } else {
            Group {
                if advanced { fullTable } else { simpleTable }
            }.frame(minHeight: 200, maxHeight: .infinity)
        }
        if !model.largeFiles && model.browseMode != .treemap {
            Pager(page: model.offset / 100 + 1, canPrevious: model.offset > 0 && !model.loading && !model.busy, canNext: model.canNext && !model.loading && !model.busy,
                previous: { model.load(offset: max(0, model.offset - 100)) }, next: { model.load(offset: model.offset + 100) })
        }
    }

    // 空状态：可清理为空时说明去向，全部为空时如实说明索引没有可排行文件。
    private var largeFilesEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(Theme.muted)
            Text(model.largeFilesScope == .cleanable ? localized("没有找到可清理的大文件") : localized("扫描索引里没有可排行的文件"))
                .font(.headline)
            if model.largeFilesScope == .cleanable {
                Text(localized("可以切换到「全部」查看受保护的大文件，或到「软件」页处理应用。"))
                    .font(.callout).foregroundStyle(Theme.muted)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 20)
    }

    private func totalSegments(_ total: Int64) -> [(String, Int64, Color)] {
        let top = Array(model.entries.sorted { $0.allocatedSize > $1.allocatedSize }.prefix(4))
        let colors = [ThemeHue.orange.base, ThemeHue.blue.base, ThemeHue.violet.base, ThemeHue.teal.base]
        var items: [(String, Int64, Color)] = top.enumerated().map { ($1.name, $1.allocatedSize, colors[$0]) }
        let rest = total - top.reduce(Int64(0)) { $0 + $1.allocatedSize }
        if rest > 0 { items.append((localized("其他"), rest, ThemeHue.gray.base.opacity(0.55))) }
        return items
    }

    // 目录合计：本页条目的占用构成（最多 4 段 + 其他），颜色只辅助，图例带文字。
    @ViewBuilder private var directoryTotal: some View {
        let total = model.entries.reduce(Int64(0)) { $0 + $1.allocatedSize }
        if total > 0 {
            let items = totalSegments(total)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.canNext || model.offset > 0 ? localized("本页合计（占用估算）") : localized("目录合计（占用估算）")).font(.callout).foregroundStyle(Theme.muted)
                    Text(bytes(total)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                }
                SegmentedBar(segments: items.map { .init(fraction: Double($0.1) / Double(total), color: $0.2, label: $0.0) })
                HStack(spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 5) {
                            Circle().fill(item.2).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text("\(item.0) \(bytes(item.1))").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }.cardStyle()
        }
    }

    private var emptyState: some View {
        ViewThatFits(in: .vertical) {
            scanStart.padding(.vertical, 24)
            ScrollView { scanStart.padding(.vertical, 12) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanStart: some View {
        VStack(spacing: 16) {
            DiskScanOrb(scanning: model.scanning, estimate: model.progressEstimate, disabled: model.operating,
                start: { model.start() }, cancel: model.cancel)
            Text(model.scanning ? localized("正在建立磁盘索引") : localized("了解空间用在哪里")).font(.system(size: 23, weight: .semibold))
            Text(model.scanning ? localized("可以关闭窗口，扫描会继续。") : localized("扫描内部磁盘，按目录、用途或空间地图查看占用。"))
                .font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            if model.scanning {
                Text(model.progress?.caption(advanced: advanced) ?? localized("正在准备扫描…"))
                    .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                    .lineLimit(2).multilineTextAlignment(.center)
                    .help(model.progress?.currentPath ?? "")
                    .accessibilityIdentifier("disk-scan-caption")
            } else {
                Label(localized("扫描仅分析文件，清理由你确认"), systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }.frame(maxWidth: .infinity)
    }

    private var tableDisabled: Bool { model.busy || model.loading || (model.treemapSnapshot?.invalidSizeCount ?? 0) > 0 }

    private var fullTable: some View {
        Table(model.entries, selection: $model.selection) {
            TableColumn(localized("名称")) { nameCell($0) }.width(min: 200, ideal: 300)
            TableColumn(model.browseMode == .purposes ? localized("用途占用 ↓") : localized("磁盘占用估算 ↓")) { sizeCell($0) }.width(120)
            TableColumn(localized("逻辑大小")) { Text(bytes($0.logicalSize)).monospacedDigit().foregroundStyle(Theme.muted) }.width(100)
            TableColumn(localized("最近修改")) { item in
                if item.identity.modified > 0 {
                    Text(Date(timeIntervalSince1970: Double(item.identity.modified) / 1_000_000_000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: localizationLocale)))
                        .font(.caption).foregroundStyle(Theme.muted)
                } else { Text(localized("未知")).foregroundStyle(Theme.muted) }
            }.width(135)
            TableColumn(localized("路径")) { item in Text(item.url.path).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.muted).help(item.url.path) }
        }
        .tableCard().disabled(tableDisabled)
        .contextMenu(forSelectionType: Int64.self) { contextMenu($0) }
    }

    // 简洁模式：只保留名称与占用两列。
    private var simpleTable: some View {
        Table(model.entries, selection: $model.selection) {
            TableColumn(localized("名称")) { nameCell($0) }.width(min: 200, ideal: 400)
            TableColumn(localized("大小 ↓")) { sizeCell($0) }.width(120)
        }
        .tableCard().disabled(tableDisabled)
        .contextMenu(forSelectionType: Int64.self) { contextMenu($0) }
    }

    // 原生表格保留键盘多选与 VoiceOver，和地图共用选择及清理校验。
    private func directoryColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(localized("目录明细")).font(.headline)
                    Spacer(minLength: 4)
                    if let directory = model.selectedEntries.first, model.selection.count == 1, directory.isDirectory {
                        Button(localized("打开目录")) { model.load(directory: directory.id) }
                            .buttonStyle(.evenLink).font(.caption).disabled(model.busy)
                    }
                }
                if !compact { Text(localized("与地图同步选择 · 锁定项目只读")).font(.caption).foregroundStyle(Theme.muted) }
            }
            Table(model.entries, selection: $model.selection) {
                TableColumn(localized("名称")) { nameCell($0) }.width(min: 100, ideal: 160)
                TableColumn(localized("大小 ↓")) { Text(bytes($0.allocatedSize)).monospacedDigit() }.width(70)
            }
            .tableCard().disabled(tableDisabled).accessibilityIdentifier("disk-map-directory")
            .contextMenu(forSelectionType: Int64.self) { contextMenu($0) }
            if !compact {
                Text(model.treemapSnapshot.map { $0.otherCount > 0 ? localized("列出最大 \($0.entries.count) 项，其余 \($0.otherCount) 项合并为“其他”") : localized("右键可在 Finder 中显示或复制路径") } ?? localized("右键可在 Finder 中显示或复制路径"))
                    .font(.caption).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
    }

    // 按用途浏览时显示归属该用途的部分；与整个文件夹不同时在悬停说明里给出两者。
    private func sizeCell(_ item: DiskEntry) -> some View {
        let size = model.listedSize(item)
        return Text(bytes(size)).monospacedDigit()
            .help(size == item.allocatedSize ? "" : localized("其中 \(bytes(size)) 归于这一用途；整个文件夹 \(bytes(item.allocatedSize))，其余部分属于更具体的用途。"))
    }

    private func nameCell(_ item: DiskEntry) -> some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder" : item.identity.isSymlink ? "link" : "doc")
                .foregroundStyle(item.isDirectory ? Theme.primary : Theme.muted)
            if item.isDirectory {
                Button(item.name) { model.browseMode == .purposes ? model.browse(directory: item.id) : model.load(directory: item.id) }
                    .buttonStyle(.evenLink).disabled(model.largeFiles)
            } else { Text(item.name).lineLimit(1) }
            if let label = model.labels[item.id], !(label.inherited && label.ruleID == model.directoryLabel?.ruleID) {
                PurposePill(label: label).layoutPriority(-1)
            }
            if model.browseMode == .purposes {
                // 用途列表里的条目来自各处，名称常重复（如多个 Caches），附上所在位置。
                Text(location(of: item)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).layoutPriority(-2)
            }
            if advanced && item.duplicate { Text(localized("硬链接")).font(.caption).foregroundStyle(Theme.muted) }
            if let kind = model.blocked[item.id] {
                // 简洁模式用灰色锁图标，原因在悬停说明。
                let reason = kind.lockReason
                if advanced { PillLabel(text: localized("受保护"), tint: Theme.warning).help(reason).accessibilityLabel(localized("受保护：\(reason)")) }
                else { Image(systemName: "lock").font(.caption).foregroundStyle(Theme.muted).help(reason).accessibilityLabel(localized("受保护：\(reason)")) }
            }
        }.help(item.url.path)
    }

    @ViewBuilder private func contextMenu(_ ids: Set<Int64>) -> some View {
        Button(localized("这是什么？")) { explained = ids.first.flatMap { model.labels[$0] } }
            .disabled(ids.count != 1 || ids.first.flatMap { model.labels[$0] } == nil)
        Button(localized("在 Finder 中显示")) { reveal(ids: ids) }.disabled(ids.isEmpty)
        Button(localized("复制路径")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.entries.filter { ids.contains($0.id) }.map { $0.url.path }.joined(separator: "\n"), forType: .string)
        }.disabled(ids.isEmpty)
    }

    private var errorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.hasOnlySystemProtectedIssues ? localized("系统保护与限制项") : localized("扫描问题")).font(.title2)
            if model.hasOnlySystemProtectedIssues {
                Text(localized("所列路径受 macOS 系统完整性保护（SIP）、Data Vault 或系统服务专有权限保护，按设计无法且无需通过用户授权获取。不影响常规磁盘分析与清理。同一路径只计一次，以下最多显示 100 条样例。"))
            } else {
                Text(localized("当前结果不完整，未扫描的内容未计入占用估算。同一路径只计一次；未能定位路径的错误单独统计。以下最多显示 100 条样例。"))
            }
            if let summary = model.summary { Text(summary.errorCountDescription).font(.headline) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let issues = model.summary?.issues, !issues.isEmpty {
                        Text(localized("样例中的原因说明")).font(.headline)
                        ForEach(ScanIssueCategory.allCases.filter { category in issues.contains { $0.category == category } }, id: \.self) { category in
                            Text(localized("\(category.title)：\(category.guidance)")).font(.callout)
                        }
                        Divider()
                    }
                    Text(model.errorExamples.joined(separator: "\n\n")).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if model.hasAuthorizableIssues {
                    Button(localized("权限设置"), action: openPrivacy)
                }
                Spacer()
                Button(localized("关闭")) { showErrors = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 650, height: 450)
    }

    private func openPrivacy() {
        NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL)
    }

    private func location(of item: DiskEntry) -> String {
        let parent = item.url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent == home ? "~" : parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
    }

    private func reveal(ids: Set<Int64>) {
        NSWorkspace.shared.activateFileViewerSelecting(model.entries.filter { ids.contains($0.id) }.map(\.url))
    }
}

// 用途标签：颜色区分安全等级；“勿动”用灰色，避免把系统目录渲染得像警报。
private struct PurposePill: View {
    let label: PurposeLabel
    var body: some View {
        PillLabel(text: (label.inherited ? localized("属于：") : "") + label.title, tint: label.safety.tint)
            .lineLimit(1).opacity(label.inherited ? 0.75 : 1)
            .help(label.helpText)
            .accessibilityLabel(localized("用途：\(label.title)，\(label.safety.title)"))
    }
}

extension PurposeSafety {
    var tint: Color {
        switch self {
        case .keep: return ThemeHue.gray.ink
        case .caution: return ThemeHue.orange.ink
        case .regenerable: return ThemeHue.green.ink
        }
    }
}

private extension PurposeLabel {
    var helpText: String { localized("\(title)：\(detail)\n\(safety.title)：\(safety.explanation)") }
}
