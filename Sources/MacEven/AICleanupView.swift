import SwiftUI
import AppKit
import MacEvenCore

private typealias AICleanupViewState<Value> = SwiftUI.State<Value>

/// 「AI 清理与维护」三件事各自说清楚后果：
/// 缓存会重建（随页面底部的「移到废纸篓」一起执行）；会话与工作记录不可恢复，只能在这里逐项勾选并单独确认。
struct AICleanupPanelView: View {
    @ObservedObject var smart: SmartScanModel
    @ObservedObject var developer: DeveloperCleanupModel

    @Environment(\.advancedMode) private var advanced
    @AICleanupViewState private var sessionOffsets: [String: Int] = [:]
    @StateObject private var compositionPresenter = CleanupCompositionPresenter()

    private var cacheGroups: [DeveloperCleanupGroup] { developer.aiCacheGroups }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            notices
            cacheSection
            sessionSection
            CleanupResultsSection(results: smart.aiWorkResults, errors: smart.aiWorkWarnings)
            readOnlySection
        }
        .onChange(of: smart.aiWorkAgeDays) { _, _ in sessionOffsets = [:] }
        .onChange(of: smart.scanningAll) { _, scanning in if scanning { sessionOffsets = [:] } }
    }

    // MARK: - 标题与提示

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ThemeHue.blue.base)
                    .accessibilityHidden(true)
                Text(localized("AI 清理与维护")).font(.headline)
                Spacer(minLength: 8)
                Text(smart.aiMaintenanceSize == 0 ? localized("无可清理项") : bytes(smart.aiMaintenanceSize))
                    .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
            }
            Text(headerSummary).font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var headerSummary: String {
        let names = smart.aiMaintenanceToolNames
        guard !names.isEmpty else { return localized("未发现 AI 工具的缓存与会话记录；工作资料在下方列出统计。") }
        let shown = names.prefix(3).joined(separator: localized("、"))
        return shown + (names.count > 3 ? localized(" 等 \(names.count) 个工具") : localized(" \(names.count) 个工具")) + localized(" · 与页面底部合计口径一致")
    }

    @ViewBuilder private var notices: some View {
        if let summary = smart.aiWorkSummary {
            InlineNotice(summary, tone: .neutral)
        } else if developer.scanFailed {
            InlineNotice(localized("AI 缓存检查未完成"), message: localized("可重新扫描后再试。"), tone: .warning)
        }
    }

    // MARK: - 第一层：缓存（删除后自动重建）

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(localized("缓存与旧版本"), size: developer.aiCacheSelectableSize, note: localized("删除后会自动重建"))
            if cacheGroups.isEmpty {
                Text(developer.scanning ? localized("正在读取 AI 缓存…") : localized("未发现 AI 工具的缓存。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            } else {
                cacheAggregateRow
                if smart.aiCacheExpanded { cacheList }
                CleanupRestrictionsSection(restrictions: developer.aiCacheRestrictions, errors: [], incomplete: false)
                Text(localized("这些缓存已计入页面底部的「移到废纸篓」；只想清理会话时，可在这里单独取消勾选。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private var cacheSelectedCount: Int { developer.aiCacheSelectedCount }
    private var cacheSelectableCount: Int { developer.aiCacheSelectableCount }

    private var cacheAggregateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AISelectionBox(
                    state: cacheSelectedCount == 0 ? .none : cacheSelectedCount == cacheSelectableCount ? .all : .some,
                    label: localized("选择全部 AI 缓存")
                ) { selected in
                    for group in cacheGroups where group.blockedReason == nil && group.allocatedSize != nil {
                        developer.select(group.id, selected: selected)
                    }
                }
                .disabled(developer.busy || developer.scanFailed)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(localized("缓存和临时文件")).font(.callout.weight(.semibold))
                        if cacheSelectedCount > 0 { Text(localized("已选 \(cacheSelectedCount)/\(cacheSelectableCount)")).font(.caption).foregroundStyle(Theme.muted) }
                        if developer.aiCacheReadOnlyCount > 0 {
                            Text(localized("\(developer.aiCacheReadOnlyCount) 项保留")).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Text(cacheSummary).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).help(cacheSummary)
                }
                Spacer(minLength: 8)
                Text(bytes(developer.aiCacheSelectableSize)).font(.callout.weight(.semibold)).monospacedDigit()
                expandChevron(expanded: smart.aiCacheExpanded, title: localized("缓存明细")) { smart.aiCacheExpanded.toggle() }
            }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
    }

    private var cacheSummary: String {
        let names = developer.aiToolNames
        let shown = names.prefix(3).joined(separator: localized("、"))
        let list = shown + (names.count > 3 ? localized(" 等") : "")
        return (list.isEmpty ? localized("AI 工具") : list) + localized("的缓存与日志，需要时自动重建；不涉及会话、记忆、配置与凭据")
    }

    private var cacheList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cacheGroups) { group in cacheRow(group) }
        }
        .padding(.leading, 8)
    }

    private func cacheRow(_ group: DeveloperCleanupGroup) -> some View {
        let blocked = group.blockedReason != nil || group.allocatedSize == nil || developer.scanFailed
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                AISelectionBox(state: developer.selection.contains(group.id) ? .all : .none, label: localized("选择 \(group.name)")) {
                    developer.select(group.id, selected: $0)
                }
                .disabled(developer.busy || blocked)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                        if group.blockedReason != nil {
                            Label(localized("需保留"), systemImage: "lock").help(group.blockedReason ?? "")
                                .font(.caption).foregroundStyle(Theme.muted)
                        } else if let advisory = group.advisoryReason {
                            StatusChip(text: localized("不建议删除"), tone: .neutral).help(advisory)
                        }
                        if advanced { StatusChip(text: group.rule.category) }
                    }
                    Text(group.rebuildCost).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).help(group.rebuildCost)
                }
                Spacer(minLength: 8)
                Text(group.allocatedSize.map(bytes) ?? localized("未统计")).font(.caption.weight(.medium)).monospacedDigit()
            }
            if let reason = group.blockedReason {
                Text(localized("保留原因：") + reason).font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if let advisory = group.advisoryReason {
                Text(advisory).font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let path = group.paths.first { pathRow(path, composition: { await developer.composition(of: group) }) }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 第二层：会话与工作区（不可恢复，逐项确认）

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(localized("会话与工作区"), size: smart.aiWorkTotalSize, note: localized("删除后无法继续这些会话，需逐项确认"))
            let rows = smart.aiWorkRows
            if rows.isEmpty {
                Text(smart.scanningAll ? localized("正在统计会话与工作记录…") : localized("未发现已知位置的会话或工作记录。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            } else {
                ForEach(rows) { row in sessionRow(row) }
                sessionFooter
            }
        }
    }

    private func sessionRow(_ row: AICleanupRow) -> some View {
        let selected = smart.aiWorkSelectedCount(in: row)
        let expanded = smart.aiWorkExpandedRows.contains(row.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AISelectionBox(state: selected == 0 ? .none : selected == row.count ? .all : .some, label: localized("选择 \(row.title)")) {
                    smart.setAIWorkRow(row, selected: $0)
                }
                .disabled(!smart.canScan)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.title).font(.callout.weight(.semibold))
                        if selected > 0 { Text(localized("已选 \(selected)/\(row.count)")).font(.caption).foregroundStyle(Theme.muted) }
                    }
                    Text(row.detail).font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if row.kind == .oldSessions { agePicker }
                Text(bytes(row.size)).font(.callout.weight(.semibold)).monospacedDigit()
                expandChevron(expanded: expanded, title: row.title) {
                    if expanded { smart.aiWorkExpandedRows.remove(row.id) } else { smart.aiWorkExpandedRows.insert(row.id) }
                }
            }
            if row.kind == .oldSessions && !advanced {
                Text(localized("“多久未用”按会话文件的最后修改时间判断；切换阈值会重新分组，勾选保持有效。"))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            if expanded { sessionTargetList(row) }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
    }

    private var agePicker: some View {
        Picker(localized("未使用时长"), selection: $smart.aiWorkAgeDays) {
            ForEach(AICleanupRows.ageOptions, id: \.self) { Text(localized("\($0) 天之前")).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 118)
        .disabled(!smart.canScan)
        .help(localized("超过该时长未修改的会话归入“旧会话记录”"))
    }

    private func sessionTargetList(_ row: AICleanupRow) -> some View {
        let offset = min(sessionOffsets[row.id] ?? 0, max(0, (row.count - 1) / 100 * 100))
        return VStack(alignment: .leading, spacing: 8) {
            if row.leavesEmptyDirectories {
                Text(localized("会话文件移走后可能留下空的日期目录，不影响工具继续使用。"))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            ForEach(Array(row.targets.dropFirst(offset).prefix(100))) { target in sessionTargetRow(target) }
            Pager(page: offset / 100 + 1, canPrevious: offset > 0, canNext: offset + 100 < row.count,
                  previous: { sessionOffsets[row.id] = max(0, offset - 100) },
                  next: { sessionOffsets[row.id] = offset + 100 })
        }
        .padding(.leading, 8)
    }

    private func sessionTargetRow(_ target: AIWorkCleanupTarget) -> some View {
        let selected = smart.isAIWorkSelected(target)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                AISelectionBox(state: selected ? .all : .none, label: localized("选择 \(target.url.lastPathComponent)")) {
                    smart.setAIWorkTarget(target, selected: $0)
                }
                .disabled(!smart.canScan)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(target.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        if target.projectMissing { StatusChip(text: localized("项目已删除"), tone: .neutral) }
                        if advanced { StatusChip(text: target.rule.title) }
                    }
                    Text(targetDetail(target)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        .help(targetDetail(target))
                }
                Spacer(minLength: 8)
                Text(bytes(target.allocatedSize)).font(.caption.weight(.medium)).monospacedDigit()
            }
            pathRow(target.url, composition: compositionProvider(target))
        }
        .padding(.vertical, 1)
    }

    /// 目录型会话/工作记录候选才提供「查看构成」；provider 用显式返回类型避免三元推断退化。
    private func compositionProvider(_ target: AIWorkCleanupTarget) -> (@MainActor () async -> CleanupComposition?)? {
        guard target.identity.isDirectory else { return nil }
        return { [smart] in await smart.aiWorkComposition(of: target) }
    }

    private func targetDetail(_ target: AIWorkCleanupTarget) -> String {
        var parts: [String] = []
        if let date = target.modifiedAt { parts.append(localized("最后修改 ") + date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: localizationLocale))) }
        // 目录型候选并列展示目录 mtime 与内部最新内容 mtime：两者差异大说明目录时间老但内容仍活跃。
        if target.identity.isDirectory, let newest = target.newestContentModified {
            parts.append(localized("最近内容修改 ") + newest.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: localizationLocale)))
        }
        if let name = target.projectName { parts.append(localized("项目 \(name)") + (target.projectMissing ? localized("（已不存在）") : "")) }
        parts.append(advanced ? target.url.path : displayPath(target.url))
        return parts.joined(separator: " · ")
    }

    private var sessionFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(smart.aiWorkSelectedCount > 0
                    ? localized("已选 \(smart.aiWorkSelectedCount) 项 · 占用估算 \(bytes(smart.aiWorkSelectedSize))")
                    : localized("尚未勾选任何会话与工作记录"))
                    .font(.callout.weight(.semibold)).monospacedDigit()
                Text(localized("会话与工作记录不会在「选择全部可清理项」中被选中；执行前逐项核验工具进程与文件变化。"))
                    .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(localized("清除选择"), action: smart.clearAIWorkSelection)
                .buttonStyle(.evenSecondary).controlSize(.small)
                .disabled(!smart.canScan || smart.aiWorkSelectedCount == 0)
            Button(localized("选择全部…"), action: smart.selectAllAIWork)
                .buttonStyle(.evenSecondary).controlSize(.small)
                .disabled(!smart.canScan || smart.aiWorkSelectableTargets.isEmpty)
            Button(localized("移到废纸篓 · \(bytes(smart.aiWorkSelectedSize))"), action: smart.prepareAIWorkCleanup)
                .destructiveEntryStyle()
                .disabled(!smart.canScan || !smart.canCleanAIWork)
        }
        .padding(.top, 2)
    }

    // MARK: - 工作资料与记忆（不建议删除，但提供删除选项）

    @ViewBuilder private var readOnlySection: some View {
        if !smart.aiStorage.isEmpty || smart.scanningAll {
            DisclosureGroup(isExpanded: $smart.aiWorkStorageExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("包含长期记忆、配置、凭据、生成产物与源码工作树，日常使用建议保留；如需释放空间可勾选移到废纸篓。"))
                        .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)

                    if !smart.aiStorageSelectableItems.isEmpty {
                        HStack(spacing: 8) {
                            AISelectionBox(
                                state: smart.aiStorageSelectedCount == 0 ? .none : smart.aiStorageSelectedCount == smart.aiStorageSelectableItems.count ? .all : .some,
                                label: localized("选择全部工作资料")
                            ) { selected in
                                if selected { smart.selectAllAIStorage() } else { smart.clearAIStorageSelection() }
                            }
                            .disabled(!smart.canScan || smart.aiStorageCleaning)
                            Text(localized("选择全部工作资料（不建议删除）"))
                                .font(.caption.weight(.medium))
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }

                    ForEach(smart.aiStorage) { item in
                        storageItemRow(item)
                    }

                    storageFooter

                    if !smart.aiStorageResults.isEmpty {
                        CleanupResultsSection(results: smart.aiStorageResults, errors: [])
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text(localized("工作资料与记忆（不建议删除）")).font(.callout.weight(.semibold))
                    if !smart.aiStorage.isEmpty {
                        Text(localized("（\(smart.aiStorage.count) 处 · \(bytes(smart.aiStorage.reduce(0) { $0 + $1.allocatedSize }))）"))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private func storageItemRow(_ item: StorageMeasurement) -> some View {
        let isSelected = smart.aiStorageSelection.contains(item.id)
        let canSelect = item.allocatedSize > 0 && !smart.aiStorageCleaning && smart.canScan
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                AISelectionBox(state: isSelected ? .all : .none, label: localized("选择 \(item.location.name)")) {
                    smart.setAIStorageItem(item, selected: $0)
                }
                .disabled(!canSelect)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.location.name).font(.callout.weight(.medium))
                        StatusChip(text: localized("不建议删除"), tone: .neutral)
                    }
                    Text(item.location.note).font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let issue = item.issue {
                        Text(issue).font(.caption).foregroundStyle(item.skipped ? Theme.muted : Theme.warning)
                    }
                }
                Spacer(minLength: 8)
                Text(item.issue != nil && item.allocatedSize == 0 ? localized("未统计") : bytes(item.allocatedSize))
                    .font(.caption.weight(.medium)).monospacedDigit()
            }
            pathRow(item.location.url, composition: { await smart.aiStorageComposition(of: item) })
        }
        .padding(.vertical, 2)
    }

    private var storageFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(smart.aiStorageSelectedCount > 0
                    ? localized("已选 \(smart.aiStorageSelectedCount) 处 · 占用估算 \(bytes(smart.aiStorageSelectedSize))")
                    : localized("未勾选工作资料与记忆"))
                    .font(.callout.weight(.semibold)).monospacedDigit()
                Text(localized("移到废纸篓后可在 Finder 废纸篓中随时撤销恢复。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Button(localized("清除选择"), action: smart.clearAIStorageSelection)
                .buttonStyle(.evenSecondary).controlSize(.small)
                .disabled(!smart.canScan || smart.aiStorageSelectedCount == 0 || smart.aiStorageCleaning)
            Button(localized("移到废纸篓 · \(bytes(smart.aiStorageSelectedSize))"), action: smart.prepareAIStorageCleanup)
                .destructiveEntryStyle()
                .disabled(!smart.canScan || !smart.canCleanAIStorage || smart.aiStorageCleaning)
        }
        .padding(.top, 4)
    }

    // MARK: - 小部件

    private func sectionHeader(_ title: String, size: Int64, note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            if size > 0 { Text(bytes(size)).font(.caption).monospacedDigit().foregroundStyle(Theme.muted) }
            Spacer(minLength: 8)
            Text(note).font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func expandChevron(expanded: Bool, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(expanded ? localized("已展开") : localized("已收起"))
        .accessibilityHint(localized("点击\(expanded ? localized("收起") : localized("展开"))明细"))
    }

    private func pathRow(_ url: URL, composition provider: (@MainActor () async -> CleanupComposition?)? = nil) -> some View {
        HStack(spacing: 6) {
            Text(displayPath(url))
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            if let provider {
                CompositionButton(label: localized("查看构成"), provider: provider, presenter: compositionPresenter)
            }
            Button(localized("在 Finder 查看")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.small).buttonStyle(.borderless).font(.system(size: 11))
        }
        .padding(.leading, 26)
    }

    private func displayPath(_ url: URL) -> String {
        let home = smart.home.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// 三态勾选框：全选 / 部分选中 / 未选；颜色之外还有形状与无障碍状态，不单靠颜色区分。
struct AISelectionBox: View {
    enum State { case none, some, all }

    let state: State
    let label: String
    let action: (Bool) -> Void

    var body: some View {
        Button {
            action(state != .all)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(state == .none ? Theme.muted : Theme.accent)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .all ? localized("已全选") : state == .some ? localized("部分选中") : localized("未选"))
        .accessibilityHint(localized("点击\(state == .all ? localized("取消选择") : localized("选择"))"))
    }

    private var symbol: String {
        switch state {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}
