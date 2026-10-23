import SwiftUI
import AppKit
import MacEvenCore

// MARK: - 清理结果与错误统一展示
struct CleanupResultsSection: View {
    let results: [TrashResult]
    let errors: [String]

    private var movedCount: Int { results.filter { $0.error == nil }.count }
    private var failedCount: Int { results.filter { $0.error != nil }.count }

    private var headerTitle: String {
        if failedCount == 0 {
            return localized("清理结果 · 全部 \(movedCount) 项已移到废纸篓")
        } else if movedCount == 0 {
            return localized("清理结果 · \(failedCount) 项已保留")
        } else {
            return localized("清理结果 · \(movedCount) 项已移走，\(failedCount) 项已保留")
        }
    }

    /// 提取常见的保留错误原因进行合并展示，避免一屏重复几十遍相同长文字
    private var commonFailedReason: String? {
        let errs = results.compactMap(\.error)
        guard !errs.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for err in errs { counts[err, default: 0] += 1 }
        let top = counts.sorted { $0.value > $1.value }.first
        if let top, top.value > 1 {
            return localized("主要保留原因：\(top.key)（共 \(top.value) 项）")
        }
        return nil
    }

    var body: some View {
        if !results.isEmpty || !errors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !results.isEmpty {
                    if results.count <= 5 {
                        Text(headerTitle + localized(" · 空间将在清空废纸篓后释放"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        if let reason = commonFailedReason {
                            Text(reason).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                        ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                            resultRow(result)
                        }
                    } else {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                                    resultRow(result)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(headerTitle + localized("（共 \(results.count) 项，点击展开明细）"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                if let reason = commonFailedReason {
                                    Text(reason).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
                if !errors.isEmpty {
                    DisclosureGroup(localized("访问或统计问题（最多 100 条）")) {
                        ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(8)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func resultRow(_ result: TrashResult) -> some View {
        HStack(alignment: .top) {
            Text(result.path)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(result.error ?? localized("已移到废纸篓"))
                .font(.caption)
                .foregroundStyle(result.error == nil ? Theme.muted : Theme.warning)
                .lineLimit(1)
        }
    }
}

// 保护策略与实际扫描失败分开说明，仅在高级模式下展示诊断信息，简洁模式下不渲染任何内容与警告条。
struct CleanupRestrictionsSection: View {
    let restrictions: [CleanupRestrictionSummary]
    let errors: [String]
    let incomplete: Bool
    @Environment(\.advancedMode) private var advanced

    var body: some View {
        if advanced && (incomplete || !restrictions.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                if incomplete {
                    Text(localized("本次检查未完成")).font(.callout.weight(.semibold)).foregroundStyle(Theme.warning)
                    if errors.isEmpty { Text(localized("检查已取消、达到上限或索引不可用，请重新扫描；未核验的项目会保留。")).font(.caption) }
                    ForEach(Array(errors.prefix(3).enumerated()), id: \.offset) { _, error in
                        Text(error).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(localized("权限不足时可在系统设置中为 MacEven 开启完全磁盘访问，再重新扫描；占用或文件变化需结束相关任务后重试。"))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                if !restrictions.isEmpty {
                    Text(localized("暂不清理的原因")).font(.callout.weight(.semibold))
                    ForEach(restrictions.prefix(5)) { item in
                        Text(localized("\(item.count) 项 · \(item.reason)")).font(.caption)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - 应用缓存明细
struct AppCacheDetailsView: View {
    @ObservedObject var cache: CacheModel
    @Environment(\.advancedMode) private var advanced
    @StateObject private var compositionPresenter = CleanupCompositionPresenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = cache.message { InlineNotice(message) { Button(localized("关闭")) { cache.message = nil } } }
            CleanupRestrictionsSection(restrictions: cache.restrictions, errors: cache.errors, incomplete: cache.incomplete)
            if !cache.groups.isEmpty {
                Text(localized("已统计占用 \(bytes(cache.measuredSize)) · 可清理 \(bytes(cache.selectableSize))") + (cache.incomplete ? localized(" · 部分统计未完成，合计可能偏小") : ""))
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            if cache.groups.isEmpty {
                Text(cache.scanning ? localized("正在读取应用缓存…") : localized("未发现可清理的应用缓存。"))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(cache.groups) { group in
                            appCacheRow(group)
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 220)

                HStack {
                    Pager(
                        page: cache.offset / 100 + 1,
                        canPrevious: cache.offset > 0 && !cache.busy,
                        canNext: cache.canNext && !cache.busy,
                        note: localized("每页最多 100 项，每次最多 50 个应用"),
                        previous: { cache.load(offset: cache.offset - 100) },
                        next: { cache.load(offset: cache.offset + 100) }
                    )
                    Spacer()
                    if advanced {
                        Button(localized("重新检查运行状态"), action: cache.recheck)
                            .disabled(cache.busy || cache.groups.isEmpty)
                            .controlSize(.small)
                    }
                }
            }

            CleanupResultsSection(results: cache.results, errors: cache.errors)
        }
    }

    private func appCacheRow(_ group: CacheGroup) -> some View {
        let isRunning = cache.isApplicationRunning(group.id)
        let isBlocked = group.blockedReason != nil || group.allocatedSize == nil || cache.scanFailed
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(localized("选择 \(group.name)"), isOn: Binding(
                    get: { cache.selection.contains(group.id) },
                    set: { selected in
                        if selected {
                            if cache.selection.count >= 50 {
                                cache.message = localized("一次最多选择 50 个应用。")
                                return
                            }
                            cache.selection.insert(group.id)
                        } else {
                            cache.selection.remove(group.id)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(cache.busy || isBlocked)

                AppIcon(bundleIdentifier: group.id, size: 20)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if let reason = group.blockedReason {
                            ReasonChip(reason: reason)
                        } else if isRunning {
                            StatusChip(text: localized("运行中 · 确认后退出并清理"), tone: .warning)
                        }
                    }
                }

                Spacer(minLength: 8)

                Text(group.allocatedSize.map(bytes) ?? localized("未统计（只读）"))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }

            if advanced, let reason = group.blockedReason {
                Text(localized("保留原因：") + reason).font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !group.paths.isEmpty {
                ForEach(group.paths, id: \.path) { path in
                    HStack(spacing: 4) {
                        Text(path.path)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        if path == group.paths.first {
                            CompositionButton(label: localized("查看构成"), provider: { await cache.composition(of: group) }, presenter: compositionPresenter)
                        }
                        Button(localized("在 Finder 查看")) {
                            NSWorkspace.shared.activateFileViewerSelecting([path])
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 开发与浏览器缓存明细
struct DeveloperCacheDetailsView: View {
    @ObservedObject var model: DeveloperCleanupModel
    @Environment(\.advancedMode) private var advanced
    @StateObject private var compositionPresenter = CleanupCompositionPresenter()

    /// 明细与卡片口径一致：这里只列开发与浏览器缓存，AI Agent 缓存在「AI 清理与维护」中逐项确认。
    private var groups: [DeveloperCleanupGroup] { model.groups.filter { $0.rule.aiToolName == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message { InlineNotice(message) { Button(localized("关闭")) { model.message = nil } } }
            CleanupRestrictionsSection(restrictions: model.otherCacheRestrictions, errors: model.errors, incomplete: model.incomplete)

            if !model.aiCacheGroups.isEmpty {
                Text(localized("\(model.aiCacheGroups.count) 项 AI Agent 缓存显示在「AI 清理与维护」卡片中，勾选同样计入页面底部的清理。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            if !groups.isEmpty {
                Text(localized("已统计占用 \(bytes(groups.reduce(0) { $0 + ($1.allocatedSize ?? 0) })) · 可清理 \(bytes(model.otherCacheSelectableSize))") + (model.incomplete ? localized(" · 部分统计未完成，合计可能偏小") : ""))
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            if groups.isEmpty {
                Text(model.scanning ? localized("正在检查开发与浏览器缓存…") : model.aiCacheGroups.isEmpty ? localized("未发现可清理的开发或浏览器缓存。") : localized("开发与浏览器缓存没有可展示项目。"))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(groups) { group in
                            developerRow(group)
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 220)

                HStack {
                    Pager(
                        page: model.offset / 100 + 1,
                        canPrevious: model.offset > 0 && !model.busy,
                        canNext: model.canNext && !model.busy,
                        note: localized("占用为物理大小估算 · 每次最多选择 50 项"),
                        previous: { model.load(offset: model.offset - 100) },
                        next: { model.load(offset: model.offset + 100) }
                    )
                    Spacer()
                    if advanced {
                        Button(localized("重新检查活动状态"), action: model.recheck)
                            .disabled(model.busy || model.groups.isEmpty)
                            .controlSize(.small)
                    }
                }
            }

            CleanupResultsSection(results: model.results, errors: model.errors)
        }
    }

    private func developerRow(_ group: DeveloperCleanupGroup) -> some View {
        let isBlocked = group.blockedReason != nil || group.allocatedSize == nil || model.scanFailed
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(localized("选择 \(group.name)"), isOn: Binding(
                    get: { model.selection.contains(group.id) },
                    set: { selected in
                        if selected && model.selection.count >= 50 {
                            model.message = localized("一次最多选择 50 项。")
                            return
                        }
                        model.select(group.id, selected: selected)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(model.busy || isBlocked)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if let reason = group.blockedReason {
                            Label(localized("需保留"), systemImage: "lock").help(reason)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Text(advanced ? "\(group.rule.category) · \(group.rule.name) · \(group.rebuildCost)" : group.rebuildCost)
                        .help(group.rebuildCost)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(group.allocatedSize.map(bytes) ?? (advanced ? localized("未统计（只读）") : localized("未统计")))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }

            if advanced, let reason = group.blockedReason {
                Text(localized("保留原因：") + reason).font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !group.paths.isEmpty {
                ForEach(group.paths, id: \.path) { path in
                    HStack(spacing: 4) {
                        Text(path.path)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        CompositionButton(label: localized("查看构成"), provider: { await model.composition(of: group) }, presenter: compositionPresenter)
                        Button(localized("在 Finder 查看")) {
                            NSWorkspace.shared.activateFileViewerSelecting([path])
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 软件残留明细
struct LeftoverDetailsView: View {
    @ObservedObject var model: LeftoverModel
    @Environment(\.advancedMode) private var advanced

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message { InlineNotice(message) { Button(localized("关闭")) { model.message = nil } } }
            CleanupRestrictionsSection(restrictions: model.restrictions, errors: model.errors, incomplete: model.incomplete)

            if model.groups.isEmpty {
                Text(model.scanning ? localized("正在扫描卸载残留…") : localized("未发现已卸载应用残留。"))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.groups) { group in
                            leftoverRow(group)
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 220)

                HStack {
                    Pager(
                        page: model.offset / 100 + 1,
                        canPrevious: model.offset > 0 && !model.busy,
                        canNext: model.canNext && !model.busy,
                        note: localized("每页最多 100 个标识 · 每次最多选择 50 个"),
                        previous: { model.load(offset: model.offset - 100) },
                        next: { model.load(offset: model.offset + 100) }
                    )
                    Spacer()
                    if advanced {
                        Button(localized("重新检查安装与运行状态"), action: model.recheck)
                            .disabled(model.busy || model.groups.isEmpty)
                            .controlSize(.small)
                    }
                }
            }

            CleanupResultsSection(results: model.results, errors: model.errors)
        }
    }

    private func leftoverRow(_ group: LeftoverGroup) -> some View {
        let isBlocked = group.blockedReason != nil || group.allocatedSize == nil || model.incomplete
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(localized("选择 \(group.id)"), isOn: Binding(
                    get: { model.selection.contains(group.id) },
                    set: { selected in
                        model.select(group.id, selected: selected)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(model.busy || isBlocked)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.id)
                            .font(.callout.weight(.medium))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        if let reason = group.blockedReason {
                            Label(localized("需保留"), systemImage: "lock").help(reason)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Text(advanced ? localized("未找到对应应用 · 属于已卸载残留或未注册组件") : localized("未找到对应应用"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(group.allocatedSize.map(bytes) ?? (advanced ? localized("未统计（只读）") : localized("未统计")))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }

            if advanced, let reason = group.blockedReason {
                Text(localized("保留原因：") + reason).font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !group.paths.isEmpty {
                ForEach(group.paths, id: \.path) { path in
                    HStack(spacing: 4) {
                        Text(path.path)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button(localized("在 Finder 查看")) {
                            NSWorkspace.shared.activateFileViewerSelecting([path])
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
