import SwiftUI
import AppKit
import MacEvenCore

private typealias ProcessViewState<Value> = SwiftUI.State<Value>

/// CPU 占比显示模式：实时 vs 1 分钟均值
enum CPUDisplayMode: String, CaseIterable {
    case realtime = "实时"
    case oneMinuteAvg = "1 分钟均值"
}

struct ProcessStatusSection: View {
    @ObservedObject var monitor: MonitorModel
    @EnvironmentObject var settings: StatusSettings
    @ProcessViewState private var grouped = true
    @ProcessViewState private var selected: ProcessIdentity?
    @ProcessViewState private var confirmation: ProcessDetail?
    @ProcessViewState private var cpuMode: CPUDisplayMode = .realtime
    @ProcessViewState private var pendingKillGroup: ProcessGroup?
    @ProcessViewState private var pendingKillIdentity: ProcessIdentity?
    // 搜索只过滤模型已有的有界列表，不触发额外采集。
    @ProcessViewState private var query = ""
    @Environment(\.advancedMode) private var advanced

    var body: some View {
        Group {
            if advanced { advancedBody } else { simpleBody }
        }
        .onChange(of: monitor.processDetail?.entry.id) { _, id in
            guard let detail = monitor.processDetail else { return }
            if let pendingGroup = pendingKillGroup, pendingGroup.entries.contains(where: { $0.id == id }) {
                confirmation = detail
                pendingKillGroup = nil
            } else if let pendingId = pendingKillIdentity, pendingId == id {
                confirmation = detail
                pendingKillIdentity = nil
            }
        }
        .alert(confirmation != nil ? localized("要退出“\(confirmation!.entry.name)”吗？") : localized("退出进程"),
               isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button(localized("强制结束"), role: .destructive) {
                if let target = confirmation {
                    monitor.requestProcessExit(target, force: true, allowDirectForce: true)
                }
                confirmation = nil
            }
            Button(localized("正常退出")) {
                if let target = confirmation {
                    monitor.requestProcessExit(target, force: false)
                }
                confirmation = nil
            }
            Button(localized("取消"), role: .cancel) {
                confirmation = nil
            }
        } message: {
            if let target = confirmation {
                Text(localized("PID \(target.entry.id.pid)\n\(target.path ?? localized("路径不可用"))\n强制结束将直接终止进程（类似活动监视器的强制退出），可能丢失未保存的数据。"))
            }
        }
    }

    // 简洁模式：有搜索框，按应用列出 CPU 或内存最高的 10 个（含固定应用置顶），带明确的「结束」与「固定」操作按钮。
    private var simpleBody: some View {
        let isMemory = monitor.processOrder.metric == .memory
        let sorted = visibleGroups.sorted { a, b in
            if isMemory {
                let am = a.totalMemoryBytes ?? 0
                let bm = b.totalMemoryBytes ?? 0
                return am > bm
            } else {
                return (cpuValue(a) ?? -1) > (cpuValue(b) ?? -1)
            }
        }
        let pinned = sorted.filter { group in
            (group.applicationPath ?? group.executablePath).map { settings.isPinned(path: $0) } ?? false
        }
        let unpinned = sorted.filter { group in
            !((group.applicationPath ?? group.executablePath).map { settings.isPinned(path: $0) } ?? false)
        }
        let top = (pinned + unpinned).prefix(max(10, pinned.count))
        let peakCPU = max(top.compactMap { cpuValue($0) }.max() ?? 1, 1)
        let peakMemory = max(top.compactMap { $0.totalMemoryBytes }.max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isMemory
                    ? (pinned.isEmpty ? localized("内存占用最高的应用") : localized("内存占用最高的应用 · 含固定置顶"))
                    : (pinned.isEmpty ? localized("CPU 占用最高的应用") : localized("CPU 占用最高的应用 · 含固定置顶")))
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Text(localized("排序")).font(.caption).foregroundStyle(Theme.muted)
                    Picker(localized("排序"), selection: Binding(
                        get: { monitor.processOrder.metric == .memory ? ProcessSortMetric.memory : ProcessSortMetric.cpu },
                        set: { monitor.processOrder = ProcessOrder(metric: $0) }
                    )) {
                        Text("CPU").tag(ProcessSortMetric.cpu)
                        Text(localized("内存")).tag(ProcessSortMetric.memory)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                    .help(localized("选择按 CPU 还是内存排序"))
                }

                if !isMemory {
                    Picker("CPU", selection: $cpuMode) {
                        ForEach(CPUDisplayMode.allCases, id: \.self) { Text(localizedText($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                    .help(cpuMode == .realtime ? localized("显示实时 CPU 占比") : localized("显示过去 1 分钟的 CPU 平均占比（基于滑动窗口计算）"))
                }
                TextField(localized("搜索"), text: $query).textFieldStyle(.roundedBorder).frame(width: 120)
                    .accessibilityLabel(localized("搜索应用或进程名称"))
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text(localized("名称"))
                    Text("")
                    Button {
                        monitor.processOrder = .cpu
                    } label: {
                        HStack(spacing: 2) {
                            Text("CPU\(cpuMode == .oneMinuteAvg ? localized(" 均值") : "")")
                            if !isMemory { Text("↓").font(.caption2) }
                        }
                        .foregroundStyle(!isMemory ? Theme.accent : Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .gridColumnAlignment(.trailing)
                    .help(localized("点击按 CPU 占比排序"))

                    Button {
                        monitor.processOrder = .memory
                    } label: {
                        HStack(spacing: 2) {
                            Text(localized("内存"))
                            if isMemory { Text("↓").font(.caption2) }
                        }
                        .foregroundStyle(isMemory ? Theme.accent : Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .gridColumnAlignment(.trailing)
                    .help(localized("点击按内存占用排序"))

                    Text(localized("操作")).gridColumnAlignment(.trailing)
                }.font(.caption).foregroundStyle(Theme.muted)
                Divider()
                ForEach(Array(top)) { group in
                    let isPinned = (group.applicationPath ?? group.executablePath).map { settings.isPinned(path: $0) } ?? false
                    GridRow {
                        HStack(spacing: 8) {
                            HeatMarker(hot: isMemory ? false : ProcessHeat.isHot(cpuValue(group)), height: 20)
                            AppIcon(path: group.applicationPath, size: 20)
                            Text(group.name).lineLimit(1)
                            if isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                                    .help(localized("已固定置顶"))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if isMemory {
                            MeterBar(
                                fraction: group.totalMemoryBytes.map { Double($0) / Double(peakMemory) },
                                tint: Theme.dataMemory,
                                height: 7
                            ).frame(width: 110)
                        } else {
                            MeterBar(
                                fraction: cpuValue(group).map { $0 / peakCPU },
                                tint: ProcessHeat.isHot(cpuValue(group)) ? Theme.dataHeat : Theme.dataCPU,
                                height: 7
                            ).frame(width: 110)
                        }
                        ProcessCPUText(value: cpuValue(group))
                        Text(memoryText(group.totalMemoryBytes)).monospacedDigit().foregroundStyle(Theme.muted)
                        HStack(spacing: 8) {
                            pinButton(group.applicationPath ?? group.executablePath)
                            Button {
                                promptExit(group: group)
                            } label: {
                                Label(localized("结束"), systemImage: "xmark.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(localized("结束或强制退出该应用（类似活动监视器）"))
                        }
                    }
                    .contextMenu {
                        if let path = group.applicationPath ?? group.executablePath {
                            Button(settings.isPinned(path: path) ? localized("取消固定") : localized("固定此应用（置顶）")) {
                                settings.togglePin(path: path)
                            }
                            Divider()
                        }
                        Button(localized("强制结束（Force Quit）"), role: .destructive) {
                            promptExit(group: group)
                        }
                        Button(localized("正常退出")) {
                            promptExit(group: group)
                        }
                    }
                }
            }
            if monitor.processList == nil { Text(localized("进程采集中")).font(.caption).foregroundStyle(Theme.muted) }
            else if top.isEmpty { Text(localized("没有匹配的应用")).font(.caption).foregroundStyle(Theme.muted) }
            if let error = monitor.processError { Text(error).foregroundStyle(Theme.warning) }
            if let msg = monitor.processActionMessage { Text(msg).font(.caption).foregroundStyle(Theme.muted) }
        }
    }

    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(advanced ? localized("进程 · 每秒刷新") : localized("进程")).font(.headline)
                    if advanced { Text(localized("最多枚举 8192 个，显示 200 项 · CPU 以单核心 100% 计")).font(.caption).foregroundStyle(Theme.muted) }
                }
                Spacer()
                Picker("CPU", selection: $cpuMode) {
                    ForEach(CPUDisplayMode.allCases, id: \.self) { Text(localizedText($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).frame(width: 160)
                    .help(cpuMode == .realtime ? localized("显示实时 CPU 占比") : localized("显示过去 1 分钟的 CPU 平均占比"))
                Button(role: .destructive) {
                    if let selected { promptExit(identity: selected) }
                } label: {
                    Label(localized("结束进程"), systemImage: "xmark.octagon")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selected == nil || monitor.processActionBusy)
                .help(selected == nil ? localized("请先选择下方列表中的进程") : localized("结束或强制退出当前选中的进程（类似活动监视器）"))
                Toggle(localized("按应用聚合"), isOn: $grouped).toggleStyle(.switch).controlSize(.small)
                TextField(localized("名称或 PID"), text: $query).textFieldStyle(.roundedBorder).frame(width: 130)
                    .accessibilityLabel(localized("搜索进程名称或 PID"))
                Picker(localized("排序"), selection: Binding(get: { monitor.processOrder.metric }, set: { monitor.processOrder = ProcessOrder(metric: $0) })) {
                    Text(localized("名称")).tag(ProcessSortMetric.name); Text("PID").tag(ProcessSortMetric.pid)
                    Text("CPU").tag(ProcessSortMetric.cpu); Text(localized("能耗")).tag(ProcessSortMetric.energy); Text(localized("内存")).tag(ProcessSortMetric.memory)
                }.frame(width: 140)
                Button(monitor.processOrder.direction == .ascending ? localized("升序 ↑") : localized("降序 ↓")) { monitor.processOrder = monitor.processOrder.reversed() }
                ActivityMonitorButton()
            }
            if advanced {
                Text(localized("CPU 按单核心 100% 计；内存为物理占用。最多枚举 8192 个进程、展示 200 项，未知指标排在最后。主窗口或菜单可见时才刷新进程。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if grouped {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleGroups) { group in
                            DisclosureGroup {
                                ForEach(group.entries.prefix(200)) { entry in processRow(entry) }
                                if group.entries.count > 200 { Text(localized("该应用仅展开前 200 个子进程")).font(.caption) }
                            } label: {
                                HStack {
                                    HeatMarker(hot: ProcessHeat.isHot(cpuValue(group)))
                                    Text(group.name).lineLimit(1)
                                    Text(localized("\(group.processCount) 项")).font(.caption).foregroundStyle(Theme.muted)
                                    Spacer()
                                    ProcessCPUText(value: cpuValue(group)).frame(width: 90, alignment: .trailing)
                                    Text(memoryText(group.totalMemoryBytes)).frame(width: 110, alignment: .trailing)
                                    pinButton(group.applicationPath ?? group.executablePath)
                                    Button {
                                        promptExit(group: group)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                            .foregroundStyle(Theme.warning)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(localized("结束该应用"))
                                }.monospacedDigit()
                            }.padding(5)
                        }
                    }
                }.frame(height: 280)
            } else if advanced {
                Table(visibleEntries, selection: $selected) {
                    TableColumn(localized("名称")) { entry in HStack { HeatMarker(hot: ProcessHeat.isHot(cpuEntryValue(entry))); Text(entry.name).lineLimit(1); pinButton(entry.applicationPath ?? entry.executablePath) } }
                    TableColumn("PID") { Text(String($0.id.pid)).monospacedDigit() }.width(70)
                    TableColumn("CPU\(cpuMode == .oneMinuteAvg ? " (1m)" : "")") { ProcessCPUText(value: cpuEntryValue($0)) }.width(90)
                    TableColumn(localized("能耗")) { Text($0.energyImpact.map { String(format: "%.1f", $0) } ?? localized("不可用")).monospacedDigit() }.width(85)
                    TableColumn(localized("内存")) { Text(memoryText($0.memoryBytes)).monospacedDigit() }.width(110)
                    TableColumn(localized("操作")) { entry in
                        Button {
                            promptExit(identity: entry.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(Theme.warning)
                        }
                        .buttonStyle(.borderless)
                        .help(localized("结束此进程"))
                    }.width(45)
                }.frame(height: 280)
            } else {
                Table(visibleEntries, selection: $selected) {
                    TableColumn(localized("名称")) { entry in HStack { HeatMarker(hot: ProcessHeat.isHot(cpuEntryValue(entry))); Text(entry.name).lineLimit(1); pinButton(entry.applicationPath ?? entry.executablePath) } }
                    TableColumn("PID") { Text(String($0.id.pid)).monospacedDigit() }.width(70)
                    TableColumn("CPU\(cpuMode == .oneMinuteAvg ? " (1m)" : "")") { ProcessCPUText(value: cpuEntryValue($0)) }.width(90)
                    TableColumn(localized("内存")) { Text(memoryText($0.memoryBytes)).monospacedDigit() }.width(110)
                    TableColumn(localized("操作")) { entry in
                        Button {
                            promptExit(identity: entry.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(Theme.warning)
                        }
                        .buttonStyle(.borderless)
                        .help(localized("结束此进程"))
                    }.width(45)
                }.frame(height: 280)
            }
            if advanced, let list = monitor.processList {
                TimelineView(.periodic(from: .now, by: 2)) { context in
                    Text(localized("更新于 \(list.updatedAt.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: localizationLocale)))\(list.incomplete ? localized(" · 部分进程未读取或已退出") : "")\(context.date.timeIntervalSince(list.updatedAt) > 6 ? localized(" · 已过期") : "")"))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            if advanced {
                Text(localized("独立 Energy Impact 尚未取得可靠来源；能耗保留未知，不用 CPU 排行冒充耗电应用。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if let error = monitor.processError { Text(error).foregroundStyle(Theme.warning) }
            if let detail = monitor.processDetail { details(detail) }
            if let message = monitor.processActionMessage { Text(message).font(.caption).foregroundStyle(Theme.muted) }
        }
        .onChange(of: selected) { _, identity in if let identity { monitor.selectProcess(identity) } else { monitor.clearProcessSelection() } }
    }

    private func promptExit(group: ProcessGroup) {
        if let first = group.entries.first {
            if let detail = monitor.processDetail, detail.entry.id == first.id {
                confirmation = detail
                return
            }
            pendingKillGroup = group
            monitor.selectProcess(first.id)
        }
    }

    private func promptExit(identity: ProcessIdentity) {
        if let detail = monitor.processDetail, detail.entry.id == identity {
            confirmation = detail
            return
        }
        pendingKillIdentity = identity
        monitor.selectProcess(identity)
    }

    private var visibleGroups: [ProcessGroup] {
        var groups = monitor.processList?.groups ?? []
        if !query.isEmpty {
            groups = groups.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.entries.contains(where: matches) }
        }
        if cpuMode == .oneMinuteAvg && monitor.processOrder.metric == .cpu {
            let ascending = monitor.processOrder.direction == .ascending
            groups.sort { a, b in
                let ac = a.totalCPUPercentAvg ?? -1.0
                let bc = b.totalCPUPercentAvg ?? -1.0
                return ascending ? ac < bc : ac > bc
            }
        }
        return groups
    }

    private var visibleEntries: [ProcessEntry] {
        var entries = (monitor.processList?.entries ?? []).filter { query.isEmpty || matches($0) }
        if cpuMode == .oneMinuteAvg && monitor.processOrder.metric == .cpu {
            let ascending = monitor.processOrder.direction == .ascending
            entries.sort { a, b in
                let ac = a.cpuPercentAvg ?? -1.0
                let bc = b.cpuPercentAvg ?? -1.0
                return ascending ? ac < bc : ac > bc
            }
        }
        return entries
    }

    private func matches(_ entry: ProcessEntry) -> Bool {
        entry.name.localizedCaseInsensitiveContains(query) || String(entry.id.pid).contains(query)
    }

    private func cpuValue(_ group: ProcessGroup) -> Double? {
        cpuMode == .realtime ? group.totalCPUPercent : group.totalCPUPercentAvg
    }

    private func cpuEntryValue(_ entry: ProcessEntry) -> Double? {
        cpuMode == .realtime ? entry.cpuPercent : entry.cpuPercentAvg
    }

    private func processRow(_ entry: ProcessEntry) -> some View {
        HStack {
            Button {
                if selected == entry.id { monitor.selectProcess(entry.id) } else { selected = entry.id }
            } label: {
                HStack {
                    HeatMarker(hot: ProcessHeat.isHot(cpuEntryValue(entry)), height: 12)
                    Text(entry.name).lineLimit(1); Spacer()
                    Text(String(entry.id.pid)).frame(width: 70)
                    ProcessCPUText(value: cpuEntryValue(entry)).frame(width: 90)
                    if advanced { Text(entry.energyImpact.map { String(format: "%.1f", $0) } ?? localized("不可用")).frame(width: 85) }
                    Text(memoryText(entry.memoryBytes)).frame(width: 110)
                }.font(.caption).monospacedDigit().contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button {
                promptExit(identity: entry.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(Theme.warning)
            }
            .buttonStyle(.borderless)
            .help(localized("结束此进程"))
        }.padding(5)
    }

    @ViewBuilder private func pinButton(_ path: String?) -> some View {
        if let path {
            let pinned = settings.isPinned(path: path)
            Button { settings.togglePin(path: path) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? Theme.accent : Theme.muted)
            }
            .buttonStyle(.borderless)
            .help(pinned ? localized("取消固定（取消置顶）") : localized("固定此应用（置顶）"))
            .accessibilityLabel(pinned ? localized("取消固定") : localized("固定"))
        }
    }

    private func details(_ detail: ProcessDetail) -> some View {
        GroupBox(localized("进程详情")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(detail.entry.name) · PID \(detail.entry.id.pid)").bold()
                if advanced { Text(purpose(detail.entry)).font(.caption).foregroundStyle(Theme.muted) }
                Text(detail.path ?? detail.unavailableReason ?? localized("路径不可用")).textSelection(.enabled)
                HStack {
                    Button(localized("复制路径")) { if let path = detail.path { copy(path) } }.disabled(detail.path == nil)
                    Button(localized("复制 PID")) { copy(String(detail.entry.id.pid)) }
                    pinButton(detail.entry.applicationPath ?? detail.path)
                    Spacer()
                    Button(localized("正常退出")) {
                        monitor.requestProcessExit(detail, force: false)
                    }.disabled(detail.path == nil || monitor.processActionBusy)
                    Button(localized("强制结束"), role: .destructive) {
                        monitor.requestProcessExit(detail, force: true, allowDirectForce: true)
                    }.disabled(detail.path == nil || monitor.processActionBusy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func purpose(_ entry: ProcessEntry) -> String {
        if let path = entry.applicationPath { return localized("应用组成进程：\(URL(fileURLWithPath: path).lastPathComponent)。依据本机可执行路径，不推断具体业务。") }
        if entry.executablePath?.hasPrefix("/System/") == true { return localized("macOS 内置应用或组件（依据 /System 路径）；操作时复核用户、路径和进程身份。") }
        return localized("独立进程：\(entry.name)。系统未提供用途说明；名称与路径用于识别。")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
