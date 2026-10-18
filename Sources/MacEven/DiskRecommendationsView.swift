import SwiftUI
import AppKit
import MacEvenCore

// 使用属性包装器类型别名：SDK 27 同名宏需要 Xcode 专有插件。
private typealias RecommendationState<Value> = SwiftUI.State<Value>

/// 空间地图推荐清理候选项（供视图与测试访问）。
struct DiskCleanupRecommendation: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable, Hashable {
        case cache
        case developer
    }

    let source: Source
    let groupID: String
    let name: String
    let size: Int64
    let path: String
    let detail: String
    let id: String

    init(source: Source, groupID: String, name: String, size: Int64, path: String, detail: String) {
        self.source = source
        self.groupID = groupID
        self.name = name
        self.size = size
        self.path = path
        self.detail = detail
        self.id = "\(source.rawValue):\(groupID)"
    }

    /// 纯静态候选投影：仅 blockedReason == nil 且 allocatedSize > 0 可推荐，按 size 降序、id 升序稳定排序。
    static func items(cache: [CacheGroup], developer: [DeveloperCleanupGroup]) -> [DiskCleanupRecommendation] {
        var items: [DiskCleanupRecommendation] = []

        for group in cache {
            guard group.blockedReason == nil, let size = group.allocatedSize, size > 0 else { continue }
            let path = group.paths.first?.path ?? ""
            items.append(DiskCleanupRecommendation(
                source: .cache,
                groupID: group.id,
                name: group.name,
                size: size,
                path: path,
                detail: localized("应用可重新生成缓存")
            ))
        }

        for group in developer {
            guard group.blockedReason == nil, let size = group.allocatedSize, size > 0 else { continue }
            let path = group.paths.first?.path ?? ""
            let detail = group.rebuildCost.isEmpty ? localized("可重新生成或下载") : group.rebuildCost
            items.append(DiskCleanupRecommendation(
                source: .developer,
                groupID: group.id,
                name: group.name,
                size: size,
                path: path,
                detail: detail
            ))
        }

        items.sort { a, b in
            if a.size != b.size {
                return a.size > b.size
            }
            return a.id < b.id
        }

        return items
    }
}

/// 空间地图右侧推荐清理侧栏组件。
struct DiskRecommendationsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var smart: SmartScanModel

    @RecommendationState private var selectedIDs: Set<String> = []

    private var recommendations: [DiskCleanupRecommendation] {
        DiskCleanupRecommendation.items(
            cache: smart.cache.recommendationGroups,
            developer: smart.developer.recommendationGroups
        )
    }

    private var cautionEntries: [DiskEntry] {
        Array(model.entries.filter { entry in
            model.labels[entry.id]?.safety == .caution && model.blocked[entry.id] == nil
        }.prefix(6))
    }

    private var isNotAnalyzed: Bool {
        smart.phase == .idle && smart.lastAnalysis == nil && recommendations.isEmpty
    }

    private var selectedItems: [DiskCleanupRecommendation] {
        recommendations.filter { selectedIDs.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    private var allTop50Selected: Bool {
        let top50 = Set(recommendations.prefix(50).map(\.id))
        return !top50.isEmpty && selectedIDs == top50
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(localized("用户缓存建议")).font(.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                Button(isNotAnalyzed ? localized("分析推荐项") : localized("重新分析")) { smart.scanAll() }
                    .buttonStyle(.evenLink).font(.caption).disabled(!smart.canScan)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = smart.summary {
                        InlineNotice(smart.phase == .done ? localized("清理完成") : localized("扫描状态"), message: summary, tone: smart.phase == .done ? .good : .neutral)
                    }

                    if smart.busy {
                        busySection
                    } else if isNotAnalyzed {
                        unscannedSection
                    }
                    if smart.cache.incomplete || smart.developer.incomplete {
                        InlineNotice(localized("部分项目未能核验"), message: localized("受限或无法确认的内容已保留。\n") +
                            ([smart.cache.message, smart.developer.message].compactMap { $0 } + smart.cache.errors + smart.developer.errors).prefix(2).joined(separator: "\n"), tone: .warning)
                    }

                    if !recommendations.isEmpty {
                        safeSection
                    } else if !isNotAnalyzed && !smart.busy {
                        emptySection
                    }

                    if !cautionEntries.isEmpty {
                        cautionSection
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footerBar
        }
        .frame(maxHeight: .infinity)
        .onChange(of: recommendations) { _, newItems in
            let validIDs = Set(newItems.map(\.id))
            selectedIDs.formIntersection(validIDs)
        }
        .sheet(item: Binding(get: { smart.confirmation }, set: { if $0 == nil { smart.dismissConfirmation() } })) { frozen in
            TrashConfirmationLayout(
                title: localized("将选中的 \(frozen.count) 项移到废纸篓？"),
                summary: localized("合计占用估算 \(bytes(frozen.allocatedSize))，按类别依次执行。"),
                paths: frozen.paths,
                notes: [
                    localized("确认后，应用与浏览器缓存会先请求相关应用正常退出，请保存工作并完成保存提示；拒绝退出或超时会保留相应缓存。"),
                    localized("应用缓存可能被应用重新生成；开发与浏览器缓存需要重新构建或重新下载；确认前请保存相关项目的工作进度。"),
                    localized("每类在执行前重新核验运行状态、用途、归属、保护列表与文件身份，无法确认的内容会保留。"),
                    localized("移到废纸篓不会立即释放空间，可在 Finder 的废纸篓中恢复。MacEven 不会清空废纸篓。")
                ],
                confirmDisabled: smart.busy || smart.otherBusy(),
                cancel: smart.dismissConfirmation,
                confirm: {
                    smart.executeCleanup()
                    selectedIDs.removeAll()
                }
            )
        }
        .alert(localized("缓存清理提示"), isPresented: Binding(get: { smart.message != nil }, set: { if !$0 { smart.message = nil } })) {
            Button(localized("知道了")) { smart.message = nil }
        } message: {
            Text(smart.message ?? "")
        }
    }

    // MARK: - 子视图

    private var busySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(smart.progressCaption.isEmpty ? localized("正在检查可清理项目…") : smart.progressCaption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            ScanProgressBar(estimate: smart.progressEstimate, caption: smart.progressCaption)
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
    }

    private var unscannedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("尚未分析推荐项"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(localized("扫描应用与开发缓存，找出可安全移到废纸篓的项目。"))
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
    }

    private var emptySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized("暂无可安全清理推荐"))
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.text)
            Text(localized("未发现符合安全推荐规则的缓存或开发临时文件。"))
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
    }

    private var safeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(ThemeHue.green.base).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(localized("可安全清理"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ThemeHue.green.ink)
                Spacer()
                Text(bytes(recommendations.reduce(0) { $0 + $1.size }))
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(recommendations) { item in
                    recommendationRow(item)
                }
            }
        }
    }

    private func recommendationRow(_ item: DiskCleanupRecommendation) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { checked in
                    if checked {
                        if selectedIDs.count >= 50 {
                            smart.message = localized("每批最多选择 50 项。")
                            return
                        }
                        selectedIDs.insert(item.id)
                    } else {
                        selectedIDs.remove(item.id)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel(localized("\(item.name)，\(bytes(item.size))"))
            .accessibilityHint(item.detail)
            .disabled(smart.busy)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 4)
                    Text(bytes(item.size))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(item.name)\n\(item.path)\n\(item.detail)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var cautionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(ThemeHue.orange.base).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(localized("需要确认"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ThemeHue.orange.ink)
                Spacer()
                Text(localized("前 6 项 · 只读"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(cautionEntries) { entry in
                    cautionRow(entry)
                }
            }
        }
    }

    private func cautionRow(_ entry: DiskEntry) -> some View {
        let label = model.labels[entry.id]
        return HStack(spacing: 6) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .font(.caption)
                .foregroundStyle(ThemeHue.orange.base)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
                Text(label?.title ?? localized("需手动确认"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(bytes(entry.allocatedSize))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.text)

            Button {
                model.selectTreemapEntry(entry.id)
            } label: {
                Image(systemName: "scope")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help(localized("在空间地图中定位"))
            .accessibilityLabel(localized("在空间地图中定位 \(entry.name)"))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contextMenu {
            Button(localized("在空间地图中定位")) {
                model.selectTreemapEntry(entry.id)
            }
            Button(localized("在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
    }

    private var footerBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text(localized("已选 \(selectedItems.count) 项"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(bytes(selectedSize))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }

            HStack(spacing: 8) {
                Button(allTop50Selected ? localized("清除选择") : localized("选择安全项")) {
                    if allTop50Selected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(recommendations.prefix(50).map(\.id))
                    }
                }
                .buttonStyle(.evenSecondary)
                .controlSize(.small)
                .disabled(smart.busy || recommendations.isEmpty)
                .help(localized("按占用从大到小选择已核验缓存，每批最多 50 项。"))

                Spacer()

                Button(localized("移到废纸篓…"), action: prepareCleanup)
                    .destructiveEntryStyle()
                    .controlSize(.small)
                    .disabled(smart.busy || smart.otherBusy() || selectedIDs.isEmpty)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 清理准备

    private func prepareCleanup() {
        guard !smart.busy, !smart.otherBusy(), !selectedItems.isEmpty else { return }
        smart.clearSelection()
        smart.cache.load(offset: 0)
        smart.developer.load(offset: 0)
        for item in selectedItems {
            switch item.source {
            case .cache:
                smart.cache.selection.insert(item.groupID)
            case .developer:
                smart.developer.select(item.groupID, selected: true)
            }
        }
        smart.prepareCleanup()
    }
}
