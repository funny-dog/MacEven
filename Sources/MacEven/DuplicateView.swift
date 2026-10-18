import SwiftUI
import AppKit
import MacEvenCore

struct DuplicateView: View {
    @ObservedObject var model: DuplicateModel
    let otherBusy: Bool
    @Environment(\.advancedMode) private var advanced
    private var selectedSize: Int64 { model.selectedEntries.reduce(0) { $0 + $1.allocatedSize } }
    var body: some View {
        PageScaffold(localized("重复文件"), subtitle: subtitle) {
            if model.busy { Button(localized("取消任务"), action: model.cancel) }
            else {
                if advanced {
                    Picker(localized("最小文件"), selection: $model.minimumSize) {
                        ForEach(DuplicateFiles.minimumSizeOptions, id: \.self) { size in
                            Text(size <= 1 ? localized("全部大小") : "≥ \(bytes(size))").tag(size)
                        }
                    }.fixedSize().help(localized("只查找不小于此大小的文件"))
                }
                Button(model.lastScope != nil ? localized("重新扫描") : localized("开始扫描"), action: model.start)
                    .disabled(otherBusy).buttonStyle(.evenPrimary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if model.summary == nil && !model.scanning, let report = model.lastAnalysis {
                    LastAnalysisNotice(report: report)
                }
                Text(advanced ? localized("只扫描启动磁盘的个人文件夹（不含资源库），与磁盘分析同为系统盘范围；隐藏路径、软件包、硬链接、APFS 克隆、空文件及云占位文件跳过。先比大小，再抽样比对，最后计算 SHA-256；先明确保留一份，再选择副本。")
                     : localized("查找个人文件夹内\(minimumText)内容相同的文件。选择一组后，默认保留最早的一份并勾选其余副本，可以改选。"))
                    .font(.caption).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { if model.busy && !model.scanning { ProgressView().controlSize(.small) }; Text(statusText).font(.callout.weight(.semibold)) }
                    if model.scanning { ScanProgressBar(estimate: model.progressEstimate, caption: model.progressCaption) }
                    // 遍历一结束即统计候选，抽样与完整哈希期间持续展示。
                    if model.scanning, let stats = model.liveStats {
                        Text(localized("已发现 \(stats.groups) 组大小相同的候选 · \(stats.files) 个文件 · 占用估算 \(bytes(stats.bytes))"))
                            .font(.callout).foregroundStyle(Theme.text).monospacedDigit()
                    }
                    if advanced, let progress = model.progress {
                        Text(localized("\(phaseTitle(progress.phase)) · 已检查 \(progress.visited) · 已比对 \(progress.hashed) · 读取 \(bytes(progress.readBytes)) · \(Int(progress.elapsed)) 秒"))
                            .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                        if model.scanning { Text(progress.currentPath).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).help(progress.currentPath) }
                    }
                    if advanced, let summary = model.summary {
                        Text(localized("\(summary.incremental ? localized("增量扫描") : localized("完整扫描")) · 本次检查 \(summary.visited) 项 · 复用 \(summary.cached) 个哈希 · 读取 \(bytes(summary.readBytes))"))
                            .font(.caption).foregroundStyle(Theme.muted)
                        Text(localized("本次遍历：小于门槛跳过 \(summary.filteredSmall) · 共享数据块跳过 \(summary.filteredShared) · 比对中跳过 \(summary.skipped) · \(summary.errors) 个访问或变化错误"))
                            .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                if model.summary != nil && model.incomplete { InlineNotice(localized("结果不完整或索引失效，清理已禁用"), message: localized("请重新扫描。")) }
                else if let summary = model.summary, summary.errors > 0, !model.busy {
                    InlineNotice(localized("已跳过 \(summary.errors) 个无法读取或扫描中变化的项目"), message: localized("其余结果可以正常清理，移到废纸篓前仍会逐字节复核。"), tone: .neutral)
                }
                if otherBusy { InlineNotice(localized("其他文件任务正在进行，请结束后再扫描或清理。"), tone: .neutral) }
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(advanced ? localized("内容匹配候选组") : localized("重复组")).font(.headline)
                        if advanced {
                            Table(model.groups, selection: groupSelection) {
                                TableColumn(localized("份数")) { group in Text(String(group.memberCount)).monospacedDigit() }.width(45)
                                TableColumn(localized("逻辑大小")) { group in Text(bytes(group.logicalSize)).monospacedDigit() }.width(85)
                                TableColumn(localized("占用估算 ↓")) { group in Text(bytes(group.allocatedSize)).monospacedDigit() }
                            }.tableCard().disabled(model.busy)
                        } else {
                            Table(model.groups, selection: groupSelection) {
                                TableColumn(localized("份数")) { group in Text(String(group.memberCount)).monospacedDigit() }.width(45)
                                TableColumn(localized("大小 ↓")) { group in Text(bytes(group.allocatedSize)).monospacedDigit() }
                            }.tableCard().disabled(model.busy)
                        }
                        Pager(page: model.groupOffset / 100 + 1, canPrevious: model.groupOffset > 0 && !model.busy, canNext: model.canNextGroups && !model.busy, note: localized("每页 100 组"),
                            previous: { model.loadGroups(offset: model.groupOffset - 100) }, next: { model.loadGroups(offset: model.groupOffset + 100) })
                    }.padding(.trailing, 8).frame(minWidth: 250, idealWidth: 290)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(advanced ? localized("组内文件 · 每页最多 100 项") : localized("组内文件")).font(.headline)
                        Table(model.members) {
                            TableColumn(localized("副本")) { entry in
                                Toggle(localized("选择副本 \(entry.name)"), isOn: Binding(get: { model.selectedIDs.contains(entry.id) }, set: { selected in
                                    if selected && entry.id != model.keeperID { model.selectedIDs.insert(entry.id) }
                                    else { model.selectedIDs.remove(entry.id) }
                                })).labelsHidden().toggleStyle(.checkbox).disabled(entry.id == model.keeperID || model.busy)
                                    .accessibilityLabel(localized("选择副本 \(entry.url.path)"))
                            }.width(40)
                            TableColumn(localized("保留")) { entry in
                                if entry.id == model.keeperID { PillLabel(text: localized("保留")).accessibilityLabel(localized("保留 \(entry.url.path)")) }
                                else { Button(localized("设为保留")) { model.keep(id: entry.id) }.buttonStyle(.evenLink).accessibilityLabel(localized("保留 \(entry.url.path)")) }
                            }.width(80)
                            TableColumn(localized("文件与完整路径")) { entry in
                                VStack(alignment: .leading) {
                                    Text(entry.name).lineLimit(1)
                                    // 两个模式都显示各自的绝对路径，便于区分位于不同文件夹的同名副本。
                                    Text(entry.url.path).font(.caption).foregroundStyle(Theme.muted).lineLimit(advanced ? 2 : 1).truncationMode(.middle)
                                }.help(entry.url.path)
                            }
                            TableColumn(advanced ? localized("占用估算") : localized("大小")) { entry in Text(bytes(entry.allocatedSize)).monospacedDigit() }.width(85)
                        }.tableCard().disabled(model.busy)
                        Pager(page: model.memberOffset / 100 + 1, canPrevious: model.memberOffset > 0 && !model.busy, canNext: model.canNextMembers && !model.busy,
                            previous: { pageMembers(model.memberOffset - 100) }, next: { pageMembers(model.memberOffset + 100) })
                    }.padding(.leading, 8).frame(minWidth: 420)
                }.frame(minHeight: 220)
                // 跳过明细只在高级模式列出；简洁模式由上方提示说明数量。
                if !model.results.isEmpty || (advanced && !(model.summary?.errorExamples.isEmpty ?? true)) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.results.enumerated()), id: \.offset) { _, result in
                                Text("\(result.path)\n\(result.error ?? localized("已移到废纸篓"))").font(.callout).textSelection(.enabled)
                            }
                            if advanced, let errors = model.summary?.errorExamples, !errors.isEmpty {
                                DisclosureGroup(localized("已跳过的项目（最多 100 条）")) {
                                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in Text(error).font(.callout).textSelection(.enabled) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100).cardStyle(padding: 12)
                }
                if advanced {
                    Text(localized("大小、抽样与 SHA-256 均相同形成候选，清理前逐字节复核。占用为估算；已排除 APFS 克隆，但快照仍可能影响实际释放量；移到废纸篓不会立即释放空间。"))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, Theme.pagePadding).padding(.vertical, 16)
        } footer: {
            ActionBar(advanced ? localized("已选 \(model.selectedIDs.count) 个副本 · 占用估算 \(bytes(selectedSize)) · 一次最多 50 项") : localized("已选 \(model.selectedIDs.count) 个副本 · \(bytes(selectedSize))"), note: model.keeperPath.map { localized("保留：\($0)") } ?? localized("请选择一个组，并明确指定保留文件。")) {
                Button(localized("移到废纸篓…"), action: model.prepareCleanup).destructiveEntryStyle().disabled(!model.canClean || otherBusy)
            }
        }
        .sheet(item: Binding(get: { model.confirmation }, set: { if $0 == nil { model.dismissConfirmation() } })) { frozen in
            TrashConfirmationLayout(title: localized("将这些副本移到废纸篓？"), summary: localized("\(frozen.targetIDs.count) 个副本，占用估算 \(bytes(frozen.allocatedSize))。"),
                paths: frozen.targetPaths.map { ConfirmPath(path: $0) },
                notes: [localized("逐字节比较后移到废纸篓。文件变化即停止，已成功的项不会自动回滚。"),
                    localized("APFS 实际释放量不保证。"),
                    localized("移到废纸篓不会立即释放空间，可在 Finder 的废纸篓中恢复。MacEven 不会清空废纸篓。")],
                confirmDisabled: model.busy || otherBusy, cancel: model.dismissConfirmation, confirm: model.executeCleanup) {
                Label(localized("保留：\(frozen.keeperPath)"), systemImage: "lock").textSelection(.enabled)
            }
        }
        .alert(localized("重复文件任务提示"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(localized("知道了")) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
    private var subtitle: String {
        advanced ? localized("\(model.scopeSummary)（不含资源库）") : localized("启动磁盘 · 个人文件")
    }
    private var minimumText: String { model.minimumSize <= 1 ? "" : localized(" \(bytes(model.minimumSize)) 以上") }
    private func phaseTitle(_ phase: String) -> String {
        switch phase {
        case "incremental": return localized("检查变更 / 更新目录")
        case "sampling": return localized("抽样比对")
        case "hashing": return localized("内容哈希")
        default: return localized("目录扫描")
        }
    }
    private var statusText: String {
        guard !advanced, !model.busy, model.summary != nil, !model.incomplete, model.results.isEmpty else { return model.status }
        return model.groups.isEmpty ? localized("没有找到重复文件") : localized("找到 \(model.groups.count)\(model.canNextGroups ? "+" : "") 组重复文件")
    }
    private var groupSelection: Binding<String?> {
        Binding(get: { model.activeGroupID }, set: { id in if let id { model.loadMembers(groupID: id, offset: 0) } })
    }
    private func pageMembers(_ offset: Int) {
        if let group = model.activeGroupID { model.loadMembers(groupID: group, offset: offset) }
    }
}
