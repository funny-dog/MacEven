import SwiftUI
import AppKit
import Charts
import MacEvenCore

private typealias MonitorViewState<Value> = SwiftUI.State<Value>

struct SystemStatusView: View {
    @ObservedObject var monitor: MonitorModel
    var openDisk: (() -> Void)? = nil
    @MonitorViewState private var hours = -1
    @Environment(\.advancedMode) private var advanced
    var body: some View {
        PageScaffold(localized("系统状态"), subtitle: subtitle) {
            // 趋势范围与趋势卡只在高级模式出现。
            if advanced {
                Picker(localized("趋势范围"), selection: $hours) {
                    Text(localized("60 秒")).tag(-1)
                    Text(localized("10 分钟")).tag(0)
                    Text(localized("1 小时")).tag(1)
                    Text(localized("24 小时")).tag(24)
                    Text(localized("7 天")).tag(168)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
            }
        } content: {
            if monitor.pageVisible {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MetricCardsGrid(monitor: monitor, openDisk: openDisk)
                        if advanced { trends }
                        ProcessStatusSection(monitor: monitor).cardStyle()
                    }.padding(.horizontal, Theme.pagePadding).padding(.top, 4).padding(.bottom, Theme.pagePadding)
                }
            }
        }
        .onChange(of: hours) { _, value in if value > 0 { monitor.loadHistory(hours: value) } }
    }

    private var subtitle: String {
        guard let h = monitor.hardware else { return localized("硬件采集中") }
        var parts = [h.cpu.model, localized("\(h.cpu.logicalCores) 核")]
        if let uptime = monitor.snapshot?.uptime { parts.append(localized("运行 ") + Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated).locale(localizationLocale))) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trends: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(hours > 0 ? localized("历史趋势 · 分钟均值与峰值") : localized("实时趋势 · \(hours == -1 ? localized("最近 60 秒") : localized("最近 10 分钟"))")).font(.headline)
                Spacer()
                if monitor.historyLoading { ProgressView().controlSize(.small) }
                if hours > 0 { Button(localized("刷新历史")) { monitor.loadHistory(hours: hours) }.disabled(monitor.historyLoading) }
            }
            Text(localized("历史保留七天，每分钟保存均值与峰值；退出和睡眠期间不补记，空白表示没有有效数据。网速仅统计当前主接口，不累加多个接口。清除历史在“设置”中。"))
                .font(.caption).foregroundStyle(Theme.muted)
            if let error = monitor.historyError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
            if hours > 0 {
                let interfaces = Set(monitor.history.compactMap(\.interface)).sorted().map { $0 == "接口切换" ? localized("接口切换") : $0 }
                Text(localized("历史接口：") + (interfaces.isEmpty ? localized("无有效接口") : interfaces.joined(separator: localized("、")))).font(.caption).foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(hours > 0 ? MonitorMetric.allCases : MonitorMetric.quickMetrics) { metric in
                    MonitorTrend(metric: metric, recent: hours == -1 ? monitor.recent.filter { ($0.timestamp.timeIntervalSince(monitor.snapshot?.timestamp ?? Date())) >= -60 } : monitor.recent, history: monitor.history, historical: hours > 0, seconds: hours == -1 ? 60 : 600)
                }
            }
            if hours <= 0 {
                DisclosureGroup(localized("硬件趋势 · GPU、内存压力、温区与风扇")) {
                    let samples = hours == -1 ? monitor.hardwareRecent.filter { $0.sampledAt >= Date().addingTimeInterval(-60) } : monitor.hardwareRecent
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                        HardwareTrend(title: localized("GPU（%）"), samples: samples) { $0.gpu.first?.deviceUtilizationPercent }
                        HardwareTrend(title: localized("内存压力（1 正常 / 2 警告 / 4 紧急）"), samples: samples) { pressureCode($0.memoryPressure.level).map(Double.init) }
                        HardwareTrend(title: localized("CPU 温区（°C）"), samples: samples) { temperatureValue($0) }
                        HardwareTrend(title: localized("GPU 温区（°C）"), samples: samples) { temperatureValue($0, gpu: true) }
                        HardwareTrend(title: localized("风扇（RPM）"), samples: samples) { $0.smcThermal.fanSpeedsRPM.first }
                    }.padding(.top, 8)
                }
            }
            if let h = monitor.hardware {
                DisclosureGroup(localized("硬件详情与数据来源")) { HardwareDetails(monitor: monitor, h: h).padding(.top, 8) }
            }
        }.cardStyle()
    }
}

// 采集错误与过期提示，与 0.11.0 MetricOverview 相同口径。
private struct MetricStaleNotices: View {
    @ObservedObject var monitor: MonitorModel
    let now: Date
    var body: some View {
        let lines = notices(now)
        if !lines.isEmpty {
            InlineNotice(localized("部分指标不可用或已过期"), message: lines.joined(separator: "\n"))
        }
    }
    private func notices(_ now: Date) -> [String] {
        var lines: [String] = []
        guard let snapshot = monitor.snapshot else { return lines }
        let names = ["cpu": "CPU", "memory": localized("内存"), "disk": localized("磁盘"), "network": localized("网络")]
        for key in ["cpu", "memory", "disk", "network"] {
            if let error = snapshot.errors[key] { lines.append(localized("\(names[key]!)：\(error)")) }
            if let updated = snapshot.updatedAt[key], now.timeIntervalSince(updated) > (key == "disk" ? 90 : 6) {
                lines.append(localized("\(names[key]!) 数据已过期 · 最后更新 \(updated.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: localizationLocale)))"))
            }
        }
        if let h = monitor.hardware, now.timeIntervalSince(h.sampledAt) > 30 { lines.append(localized("硬件数据已过期 · 最后更新 \(h.sampledAt.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: localizationLocale)))")) }
        return lines
    }
}

// 4 列状态卡：CPU、内存、GPU、电池 / 磁盘、网络、风扇。每张卡三态：有读数 / 未取得（虚线、“—”、写原因）/ 不适用（虚线、写能力判断）。
// 只读取 MonitorModel 已有的有界数组；读不到就说读不到，不用其他数据估算。
private struct MetricCardsGrid: View {
    @ObservedObject var monitor: MonitorModel
    let openDisk: (() -> Void)?
    @Environment(\.advancedMode) private var advanced
    private let cardHeight: CGFloat = 156
    var body: some View {
        let s = monitor.snapshot; let h = monitor.hardware
        let window = monitor.recent.filter { $0.timestamp.timeIntervalSince(s?.timestamp ?? Date()) >= -60 }
        // 每 2 秒复核数据是否过期；无提示时不占位。
        TimelineView(.periodic(from: .now, by: 2)) { context in
            VStack(alignment: .leading, spacing: 14) {
                MetricStaleNotices(monitor: monitor, now: context.date)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 4), alignment: .leading, spacing: 14) {
                    Group {
                        if advanced {
                            cpuCard(s, h, window)
                            memoryCard(s, h, window)
                            gpuCard(h)
                            batteryCard(h)
                            diskCard(s)
                            networkCard(s, window)
                            fanCard(h)
                        } else {
                            cpuCard(s, h, window)
                            memoryCard(s, h, window)
                            diskCard(s)
                            networkCard(s, window)
                            if let h, h.battery.isInstalled {
                                batteryCard(h)
                            }
                        }
                    }
                    .frame(height: cardHeight)
                    .environment(\.cardFillsHeight, true)
                }
            }
        }
    }

    private func cpuCard(_ s: SystemSnapshot?, _ h: HardwareSnapshot?, _ window: [SystemSnapshot]) -> some View {
        let temp = temperatureValue(h)
        let caption: String = {
            guard let h else { return localized("采集中") }
            if advanced, let p = h.cpu.performanceCores, let e = h.cpu.efficiencyCores { return localized("\(p) 性能核心 · \(e) 能效核心") }
            return localized("整机 · \(h.cpu.logicalCores) 个逻辑核心")
        }()
        let value = s?.cpuPercent.map { String(format: "%.0f", $0) }
        // 纵轴随近 60 秒峰值放大（至少 20%），低负载时也能看出起伏。
        let peak = window.compactMap(\.cpuPercent).max() ?? 0
        return MetricCard("CPU", detail: temp.map { String(format: "%.0f°C", $0) }, value: value ?? "—", unit: value == nil ? nil : "%",
            caption: caption, symbol: "cpu", tint: Theme.dataCPU, unavailable: value == nil) {
            Spacer(minLength: 0)
            Sparkline(values: window.map(\.cpuPercent), maximum: min(100, max(20, peak * 1.3)), color: Theme.dataCPU).frame(height: 36)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(localized("CPU \(value.map { $0 + "%" } ?? localized("未取得读数"))，近 60 秒趋势"))
    }

    private func memoryCard(_ s: SystemSnapshot?, _ h: HardwareSnapshot?, _ window: [SystemSnapshot]) -> some View {
        let level = h?.memoryPressure.level
        let fraction: Double? = {
            guard let used = s?.usedMemoryBytes, let total = s?.physicalMemoryBytes, total > 0 else { return nil }
            return Double(used) / Double(total)
        }()
        let series: [Double?] = window.map { sample in
            guard let used = sample.usedMemoryBytes, case let total = sample.physicalMemoryBytes, total > 0 else { return nil }
            return Double(used) / Double(total) * 100
        }
        // 内存压力紧急 / 告警时用芯片写明，颜色只是第二通道。
        let chip: String? = level == .critical ? localized("内存紧张") : level == .warning ? localized("压力告警") : advanced ? localized("压力\(pressureText(level))") : nil
        var caption = "\(memoryText(s?.usedMemoryBytes)) / \(memoryText(s?.physicalMemoryBytes))"
        if let swap = s?.swapUsedBytes, swap > 0 { caption += localized(" · 交换 \(memoryText(swap))") }
        return MetricCard(localized("内存"), detail: chip, value: fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—", unit: fraction == nil ? nil : "%",
            caption: fraction == nil ? localized("未取得读数") : caption, symbol: "memorychip", tint: Theme.dataMemory, unavailable: fraction == nil) {
            Spacer(minLength: 0)
            Sparkline(values: series, maximum: 100, color: level == .critical ? Theme.dangerText : Theme.dataMemory).frame(height: 36)
        }
        .accessibilityElement(children: .combine)
    }

    private func gpuCard(_ h: HardwareSnapshot?) -> some View {
        let gpu = h?.gpu.first?.deviceUtilizationPercent
        let temp = temperatureValue(h, gpu: true)
        return MetricCard("GPU", detail: gpu == nil ? nil : temp.map { String(format: "%.0f°C", $0) }, value: gpu.map { String(format: "%.0f", $0) } ?? "—",
            unit: gpu == nil ? nil : "%", caption: gpu == nil ? (h == nil ? localized("采集中") : localized("未取得读数 · 不会用 CPU 数据估算")) : localized("设备利用率"),
            symbol: "rectangle.3.group", tint: Theme.dataDisk, unavailable: gpu == nil) {
            Spacer(minLength: 0)
            if let gpu { MeterBar(fraction: gpu / 100, tint: Theme.dataDisk, height: 8, track: Theme.track) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func batteryCard(_ h: HardwareSnapshot?) -> some View {
        if let h, h.battery.isInstalled {
            let b = h.battery
            let state = b.isCharging == true ? localized("正在充电") : b.isACConnected == true ? localized("接通电源") : b.isCharging == false ? localized("使用电池") : localized("电源状态未知")
            let low = (b.currentCapacityPercent ?? 100) <= 20
            MetricCard(localized("电池"), detail: b.condition, value: b.currentCapacityPercent.map(String.init) ?? "—", unit: b.currentCapacityPercent == nil ? nil : "%",
                caption: advanced ? [state, b.cycleCount.map { localized("循环 \($0) 次") }].compactMap { $0 }.joined(separator: " · ") : state,
                symbol: b.isCharging == true ? "battery.100.bolt" : "battery.75", tint: low ? Theme.warning : Theme.dataPower,
                unavailable: b.currentCapacityPercent == nil) {
                Spacer(minLength: 0)
                MeterBar(fraction: b.currentCapacityPercent.map { Double($0) / 100 }, tint: low ? Theme.warning : Theme.dataPower, height: 8, track: Theme.track)
            }
            .accessibilityElement(children: .combine)
        } else {
            MetricCard(localized("电池"), value: h == nil ? "—" : localized("不适用"), caption: h == nil ? localized("采集中") : localized("此机型无内置电池"), symbol: "battery.0", unavailable: true)
        }
    }

    private func diskCard(_ s: SystemSnapshot?) -> some View {
        let total = s?.diskTotalBytes; let available = s?.diskAvailableBytes
        let fraction: Double? = {
            guard let total, let available, total > 0, available <= total else { return nil }
            return 1 - Double(available) / Double(total)
        }()
        let parts = memoryText(available).split(separator: " ")
        return MetricCard(localized("磁盘"), detail: total.map { memoryText($0) }, value: available == nil ? "—" : String(parts.first ?? ""),
            unit: available == nil ? nil : localized("\(parts.dropFirst().joined(separator: " ")) 可用"),
            caption: fraction.map { localized("已用 \(Int(($0 * 100).rounded()))% · 卷容量口径") } ?? localized("未取得读数"), symbol: "internaldrive", tint: Theme.dataDisk,
            unavailable: available == nil) {
            Spacer(minLength: 0)
            MeterBar(fraction: fraction, tint: Theme.dataDisk, height: 8, track: Theme.track)
            if let openDisk {
                HStack {
                    if advanced { Button(localized("刷新容量"), action: monitor.refreshDisk).buttonStyle(.evenLink).font(.caption) }
                    Spacer()
                    Button(localized("查看占用 ›"), action: openDisk).buttonStyle(.evenLink).font(.caption.weight(.semibold))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func networkCard(_ s: SystemSnapshot?, _ window: [SystemSnapshot]) -> some View {
        let unavailable = s?.networkRate == nil
        return VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: localized("网络"), symbol: "wifi", tint: unavailable ? nil : Theme.dataNetwork, chip: s?.networkInterface)
            rate(localized("↓ 下行"), s?.networkRate?.download, window.map { $0.networkRate?.download }, dashed: false, height: 28)
            rate(localized("↑ 上行"), s?.networkRate?.upload, window.map { $0.networkRate?.upload }, dashed: true, height: 16)
            if unavailable { Text(localized("未取得读数")).font(.system(size: 11)).foregroundStyle(Theme.muted) }
        }
        .cardStyle(unavailable: unavailable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("网络下行 \(speedText(s?.networkRate?.download))，上行 \(speedText(s?.networkRate?.upload))"))
    }

    // 下行实线、上行虚线，不靠色相区分。
    private func rate(_ title: String, _ value: Double?, _ values: [Double?], dashed: Bool, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Text(value == nil ? "—" : speedText(value)).font(.system(size: 15, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            Sparkline(values: values, color: Theme.dataNetwork, fill: !dashed, dashed: dashed).frame(height: height)
        }
    }

    private func fanCard(_ h: HardwareSnapshot?) -> some View {
        let speeds = h?.smcThermal.fanSpeedsRPM ?? []
        let none = h?.smcThermal.fanCount == 0
        let value = speeds.isEmpty ? (none ? localized("不适用") : "—") : String(format: "%.0f", speeds[0])
        let caption = speeds.isEmpty ? (h == nil ? localized("采集中") : none ? localized("此机型无风扇") : localized("未取得读数")) :
            speeds.count > 1 ? speeds.map { String(format: "%.0f", $0) }.joined(separator: " · ") + " RPM" : localized("热状态 · \(thermalText(h?.thermalState))")
        return MetricCard(localized("风扇"), value: value, unit: speeds.isEmpty ? nil : "RPM", caption: caption, symbol: "fanblades", tint: Theme.dataHeat,
            unavailable: speeds.isEmpty) { Spacer(minLength: 0) }
            .accessibilityElement(children: .combine)
    }
}

// 菜单栏面板（Mole 布局）：顶部机型芯片，2×3 迷你卡（三态），前五进程三列，工具行，累计记录。
// 与主窗口共享 MonitorModel 的最新快照，面板自身不采样。
struct MonitorPopoverView: View {
    @ObservedObject var monitor: MonitorModel
    @ObservedObject var disk: AppModel
    @ObservedObject var cache: CacheModel
    @ObservedObject var removal: ApplicationRemovalModel
    @ObservedObject var duplicate: DuplicateModel
    let openWindow: () -> Void
    let quit: () -> Void
    @EnvironmentObject var stats: OperationStats
    @EnvironmentObject var settings: StatusSettings
    @EnvironmentObject var tools: SystemTools

    var body: some View {
        Group {
            if monitor.popoverVisible {
                TimelineView(.periodic(from: .now, by: 2)) { context in
                    VStack(spacing: 0) {
                        header(context.date)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 10)
                        Divider()
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                tasks
                                staleNotices(context.date)
                                metricGrid(now: context.date)
                                if !settings.advancedMode, let h = monitor.hardware, h.battery.isInstalled {
                                    batteryRow(h)
                                }
                                if settings.advancedMode, let h = monitor.hardware {
                                    hardwareSection(h)
                                }
                                if settings.advancedMode {
                                    processSection
                                }
                                toolsRow
                                if settings.advancedMode {
                                    records
                                    PrivacyIndicators().cardStyle(padding: 10)
                                }
                            }
                            .padding(12)
                        }
                        .frame(maxHeight: settings.advancedMode ? nil : 480)
                        Divider()
                        footer
                    }
                }
            }
        }
        .frame(width: 380)
        .frame(height: settings.advancedMode ? 620 : nil)
        .foregroundStyle(Theme.text)
        .background(PageGround.status.color)
    }

    // 标志与名称；下一行三枚芯片：机型、内存、运行时间。
    private func header(_ now: Date) -> some View {
        let s = monitor.snapshot; let h = monitor.hardware
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text("MacEven").font(.headline.weight(.semibold)).foregroundStyle(Theme.text)
                if settings.advancedMode {
                    Text(localized("高级")).font(.caption2.weight(.medium)).foregroundStyle(Theme.primary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.primary.opacity(0.12), in: Capsule())
                }
                Spacer()
                if let s {
                    Text(ageText(now.timeIntervalSince(s.timestamp)))
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 6) {
                ChipLabel(text: h.map { $0.cpu.model } ?? localized("硬件采集中"))
                if let total = s?.physicalMemoryBytes, total > 0 { ChipLabel(text: memoryText(total)) }
                if let uptime = s?.uptime {
                    ChipLabel(text: localized("已运行 ") + Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2).locale(localizationLocale)))
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func staleNotices(_ now: Date) -> some View {
        let s = monitor.snapshot; let h = monitor.hardware
        let names = ["cpu": "CPU", "memory": localized("内存"), "disk": localized("磁盘"), "network": localized("网络")]
        let warnings: [String] = {
            var list: [String] = []
            if let s {
                for key in ["cpu", "memory", "disk", "network"] {
                    if let error = s.errors[key] {
                        list.append(localized("\(names[key] ?? key)：\(error)"))
                    }
                    if let updated = s.updatedAt[key], now.timeIntervalSince(updated) > (key == "disk" ? 90 : 6) {
                        list.append(localized("\(names[key] ?? key) 数据已过期 · 最后更新 \(updated.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: localizationLocale)))"))
                    }
                }
            }
            if let h, now.timeIntervalSince(h.sampledAt) > 30 {
                list.append(localized("硬件数据已过期 · 最后更新 \(h.sampledAt.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: localizationLocale)))"))
            }
            return list
        }()
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warning.opacity(0.2), lineWidth: 1))
        }
    }

    // 2×2（简洁）或 2×3（高级）迷你卡。读不到写原因，不用其他数据估算。
    private func metricGrid(now: Date) -> some View {
        let s = monitor.snapshot; let h = monitor.hardware
        let window = monitor.recent.filter { $0.timestamp.timeIntervalSince(s?.timestamp ?? now) >= -60 }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Group {
                cpuCard(s, h, window)
                memoryCard(s, h)
                diskCard(s)
                networkCard(s, window)
                if settings.advancedMode {
                    batteryCard(h)
                    fanCard(h)
                }
            }
            .frame(height: 104)
            .environment(\.cardFillsHeight, true)
        }
    }

    private func cpuCard(_ s: SystemSnapshot?, _ h: HardwareSnapshot?, _ window: [SystemSnapshot]) -> some View {
        let peak = window.compactMap(\.cpuPercent).max() ?? 0
        let value = s?.cpuPercent.map { String(format: "%.0f", $0) }
        let caption = value == nil ? (s == nil ? localized("采集中") : localized("未取得读数")) :
            settings.advancedMode && peak > 0 ? localized("近 60 秒峰值 \(Int(peak))%") : h.map { localized("整机 · \($0.cpu.logicalCores) 核") } ?? localized("整机")
        return PopoverMiniCard(title: "CPU", symbol: "cpu", tint: Theme.dataCPU, value: value ?? "—", unit: value == nil ? nil : "%",
            caption: caption, unavailable: value == nil) {
            Sparkline(values: window.map(\.cpuPercent), maximum: min(100, max(20, peak * 1.3)), color: Theme.dataCPU).frame(height: 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("CPU \(value.map { $0 + "%" } ?? localized("未取得读数"))，近 60 秒趋势"))
    }

    private func memoryCard(_ s: SystemSnapshot?, _ h: HardwareSnapshot?) -> some View {
        let level = h?.memoryPressure.level
        let fraction: Double? = {
            guard let used = s?.usedMemoryBytes, let total = s?.physicalMemoryBytes, total > 0 else { return nil }
            return Double(used) / Double(total)
        }()
        // 压力紧张 / 告警时写在脚注里，颜色只是第二通道。
        let pressure = level == .critical ? localized("内存紧张 · ") : level == .warning ? localized("压力告警 · ") : ""
        return PopoverMiniCard(title: localized("内存"), symbol: "memorychip", tint: Theme.dataMemory,
            value: fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—", unit: fraction == nil ? nil : "%",
            caption: fraction == nil ? localized("未取得读数") : pressure + "\(memoryText(s?.usedMemoryBytes)) / \(memoryText(s?.physicalMemoryBytes))",
            unavailable: fraction == nil) {
            MeterBar(fraction: fraction, tint: level == .critical ? Theme.dangerText : level == .warning ? Theme.warning : Theme.dataMemory, height: 6)
        }
        .accessibilityElement(children: .combine)
    }

    private func diskCard(_ s: SystemSnapshot?) -> some View {
        let total = s?.diskTotalBytes; let available = s?.diskAvailableBytes
        let fraction: Double? = {
            guard let total, let available, total > 0, available <= total else { return nil }
            return 1 - Double(available) / Double(total)
        }()
        let parts = memoryText(available).split(separator: " ")
        return PopoverMiniCard(title: localized("磁盘"), symbol: "internaldrive", tint: Theme.dataDisk,
            value: available == nil ? "—" : String(parts.first ?? ""), unit: available == nil ? nil : localized("\(parts.dropFirst().joined(separator: " ")) 可用"),
            caption: fraction.map { localized("已用 \(Int(($0 * 100).rounded()))% · 共 \(memoryText(total))") } ?? localized("未取得读数"), unavailable: available == nil) {
            MeterBar(fraction: fraction, tint: Theme.dataDisk, height: 6)
        }
        .accessibilityElement(children: .combine)
    }

    // 下行写在大数字，上行写在脚注；曲线只画下行。
    private func networkCard(_ s: SystemSnapshot?, _ window: [SystemSnapshot]) -> some View {
        let rate = s?.networkRate
        let parts = speedText(rate?.download).split(separator: " ")
        return PopoverMiniCard(title: localized("网络"), symbol: "wifi", tint: Theme.dataNetwork,
            value: rate == nil ? "—" : String(parts.first ?? ""), unit: rate == nil ? nil : parts.dropFirst().joined(separator: " "),
            caption: rate == nil ? (s?.networkInterface == nil ? localized("未连接或未取得读数") : localized("未取得读数")) : "↑ \(speedText(rate?.upload)) · \(s?.networkInterface ?? "")",
            unavailable: rate == nil) {
            Sparkline(values: window.map { $0.networkRate?.download }, color: Theme.dataNetwork).frame(height: 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("网络下行 \(speedText(rate?.download))，上行 \(speedText(rate?.upload))"))
    }

    @ViewBuilder private func batteryCard(_ h: HardwareSnapshot?) -> some View {
        if let h, h.battery.isInstalled {
            let b = h.battery
            let low = (b.currentCapacityPercent ?? 100) <= 20
            PopoverMiniCard(title: localized("电池"), symbol: b.isCharging == true ? "battery.100.bolt" : "battery.75", tint: low ? Theme.warning : Theme.dataPower,
                value: b.currentCapacityPercent.map(String.init) ?? "—", unit: b.currentCapacityPercent == nil ? nil : "%",
                caption: b.isCharging == true ? localized("正在充电") : b.isACConnected == true ? localized("接通电源") : b.isACConnected == false ? localized("使用电池") : localized("电源状态未知"),
                unavailable: b.currentCapacityPercent == nil) {
                MeterBar(fraction: b.currentCapacityPercent.map { Double($0) / 100 }, tint: low ? Theme.warning : Theme.dataPower, height: 6)
            }
            .accessibilityElement(children: .combine)
        } else {
            PopoverMiniCard(title: localized("电池"), symbol: "battery.0", tint: nil, value: h == nil ? "—" : localized("不适用"), unit: nil,
                caption: h == nil ? localized("采集中") : localized("此机型无内置电池"), unavailable: true) { EmptyView() }
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func batteryRow(_ h: HardwareSnapshot) -> some View {
        let b = h.battery
        let low = (b.currentCapacityPercent ?? 100) <= 20
        HStack(spacing: 8) {
            Image(systemName: b.isCharging == true ? "battery.100.bolt" : "battery.75")
                .font(.callout)
                .foregroundStyle(low ? Theme.warning : Theme.dataPower)
            Text(localized("内置电池")).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
            Text(b.currentCapacityPercent.map { "\($0)%" } ?? "—")
                .font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(Theme.text)
            MeterBar(fraction: b.currentCapacityPercent.map { Double($0) / 100 }, tint: low ? Theme.warning : Theme.dataPower, height: 6)
                .frame(maxWidth: 80)
            Spacer()
            Text(b.isCharging == true ? localized("正在充电") : b.isACConnected == true ? localized("接通电源") : b.isACConnected == false ? localized("使用电池") : localized("电源状态未知"))
                .font(.caption2).foregroundStyle(Theme.muted)
        }
        .cardStyle(padding: 8)
    }

    private func fanCard(_ h: HardwareSnapshot?) -> some View {
        let speeds = h?.smcThermal.fanSpeedsRPM ?? []
        let none = h?.smcThermal.fanCount == 0
        return PopoverMiniCard(title: localized("风扇"), symbol: "fanblades", tint: Theme.dataHeat,
            value: speeds.isEmpty ? (none ? localized("不适用") : "—") : String(format: "%.0f", speeds[0]), unit: speeds.isEmpty ? nil : "RPM",
            caption: speeds.isEmpty ? (h == nil ? localized("采集中") : none ? localized("此机型无风扇") : localized("未取得读数")) : localized("热状态 · \(thermalText(h?.thermalState))"),
            unavailable: speeds.isEmpty) { EmptyView() }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func hardwareSection(_ h: HardwareSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localized("硬件传感器")).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text(localized("热状态 · \(thermalText(h.thermalState))")).font(.caption2).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 8) {
                sensorTile("GPU", percentText(h.gpu.first?.deviceUtilizationPercent))
                sensorTile(localized("CPU温区"), temperatureText(temperatureValue(h)))
                sensorTile(localized("GPU温区"), temperatureText(temperatureValue(h, gpu: true)))
                sensorTile(localized("内存压力"), pressureText(h.memoryPressure.level))
            }
        }
        .cardStyle(padding: 10)
    }

    private func sensorTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 后台任务放在最上面：能算出总数时显示百分比（估算标“约”），未知总数只显示活动条、数量、耗时与取消。
    @ViewBuilder private var tasks: some View {
        if disk.scanning {
            task(localized("磁盘扫描进行中"), estimate: disk.progressEstimate, detail: disk.progress?.caption(advanced: true) ?? disk.status,
                path: disk.progress?.currentPath, cancel: disk.cancel)
        }
        if cache.scanning { task(localized("应用缓存扫描进行中"), estimate: cache.progressEstimate, detail: cache.progress?.caption() ?? cache.status, path: nil, cancel: cache.cancel) }
        if cache.developer.scanning {
            task(localized("开发缓存检查进行中"), estimate: cache.developer.progressEstimate, detail: cache.developer.progress?.caption() ?? cache.developer.status, path: nil, cancel: cache.cancel)
        }
        if removal.scanning { task(localized("应用扫描进行中"), estimate: removal.progressEstimate, detail: removal.progress?.caption() ?? removal.status, path: nil, cancel: removal.cancel) }
        if duplicate.scanning { task(localized("重复文件扫描进行中"), estimate: duplicate.progressEstimate, detail: duplicate.progressCaption, path: nil, cancel: duplicate.cancel) }
        else if duplicate.busy { task(localized("重复文件任务进行中"), estimate: .unknown, detail: duplicate.status, path: nil, cancel: duplicate.cancel) }
    }

    private func task(_ title: String, estimate: ProgressEstimate, detail: String, path: String?, cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Button(localized("取消"), action: cancel).buttonStyle(.evenLink).font(.callout)
            }
            ScanProgressBar(estimate: estimate, caption: detail)
            if let path { Text(path).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle) }
        }.cardStyle(padding: 12)
    }

    // 高占用进程：只显示前五，三列（名称、内存、% CPU）；高占用行加 data-heat 标记并加粗数值。
    private var processSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(settings.advancedMode ? localized("高占用进程 · 当前排序/置顶") : localized("高占用进程"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(localized("内存")).font(.caption2).foregroundStyle(Theme.muted).frame(width: 65, alignment: .trailing)
                Text("% CPU").font(.caption2).foregroundStyle(Theme.muted).frame(width: 52, alignment: .trailing)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            let entries = Array((monitor.processList?.entries ?? []).prefix(5))
            if entries.isEmpty {
                Text(monitor.processList == nil ? localized("进程采集中…") : localized("暂无活跃进程"))
                    .font(.caption2).foregroundStyle(Theme.muted)
                    .padding(.vertical, 2)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        HeatMarker(hot: ProcessHeat.isHot(entry.cpuPercent), height: 12)
                        Text(entry.name).font(.caption).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 8)
                        Text(memoryText(entry.memoryBytes)).font(.caption).monospacedDigit()
                            .foregroundStyle(Theme.muted).frame(width: 65, alignment: .trailing)
                        ProcessCPUText(value: entry.cpuPercent).font(.caption)
                            .foregroundStyle(Theme.text).frame(width: 52, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .cardStyle(padding: 10)
    }

    // 工具行：保持唤醒（15 / 30 / 60 分钟，睡眠和退出时取消）、打开 MacEven。
    private var toolsRow: some View {
        HStack(spacing: 8) {
            if let until = tools.awakeUntil {
                Button { tools.stopAwake() } label: { toolLabel(localized("取消唤醒"), symbol: "cup.and.saucer.fill") }
                    .help(localized("保持唤醒至 \(until.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: localizationLocale)))；点击取消"))
            } else {
                Menu {
                    ForEach([15, 30, 60], id: \.self) { minutes in Button(localized("\(minutes) 分钟")) { tools.keepAwake(minutes: minutes) } }
                } label: { toolLabel(localized("保持唤醒"), symbol: "cup.and.saucer") }
                    .menuStyle(.button).menuIndicator(.hidden).help(localized("阻止显示器睡眠；睡眠和退出时取消"))
            }
            Button(action: openWindow) { toolLabel(localized("打开 MacEven"), symbol: "macwindow") }
        }
        .buttonStyle(.plain)
    }

    private func toolLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
            Text(title).font(.caption).foregroundStyle(Theme.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
    }

    // 累计记录：来自操作记录，不是监控历史；移到废纸篓不等于释放空间。
    private var records: some View {
        HStack(spacing: 0) {
            record("\(stats.movedItems)", localized("已移到废纸篓"), help: localized("自 0.9 起累计移到废纸篓的路径数，不等于释放空间"))
            record("\(stats.uninstalledApps)", localized("已卸载"), help: localized("自 0.28.0 起经应用卸载移到废纸篓的 App 数"))
            record("\(stats.scans)", localized("已扫描"), help: localized("自 0.28.0 起开始的扫描次数，含中途取消"))
        }
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityLabel(localized("累计记录"))
    }

    private func record(_ value: String, _ title: String, help: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
            Text(title).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).help(help)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(localized("检查更新…")) {
                UpdateAlertManager.checkForUpdates()
            }
            .buttonStyle(.evenSecondary)
            Spacer()
            Button(localized("退出 MacEven"), action: quit).buttonStyle(.evenSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func ageText(_ seconds: TimeInterval) -> String {
        seconds < 2 ? localized("刚刚更新") : localized("\(Int(seconds)) 秒前更新")
    }
}

// 菜单面板迷你卡：与 MetricCard 同一信息顺序（标题、数值、图形、脚注），尺寸缩小；未取得 / 不适用为虚线框。
private struct PopoverMiniCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color?
    let value: String
    let unit: String?
    let caption: String
    let unavailable: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: title, symbol: symbol, tint: unavailable ? nil : tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .bold)).monospacedDigit().foregroundStyle(unavailable ? Theme.muted : Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            Spacer(minLength: 0)
            content()
            Text(caption).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail).help(caption)
        }
        .cardStyle(padding: 10, unavailable: unavailable)
    }
}

struct ActivityMonitorButton: View {
    @MonitorViewState private var error: String?
    var body: some View {
        Button(localized("打开活动监视器")) {
            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, failure in
                let message = failure?.localizedDescription
                DispatchQueue.main.async { error = message }
            }
        }.alert(localized("无法打开活动监视器"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(localized("知道了")) { error = nil }
        } message: { Text(error ?? "") }
    }
}

// Chart conversion consumes only bounded model arrays; gaps get distinct series.
enum MonitorMetric: String, CaseIterable, Identifiable {
    case cpu, memory, download, upload, gpu, pressure, cpuTemperature, gpuTemperature, fan
    static let quickMetrics: [MonitorMetric] = [.cpu,.memory,.download,.upload]
    var id: String { rawValue }
    var title: String {
        switch self { case .cpu: localized("CPU（%）"); case .memory: localized("已用内存估算（GiB）"); case .download: localized("下载（MiB/s）"); case .upload: localized("上传（MiB/s）"); case .gpu: localized("GPU（%）"); case .pressure: localized("内存压力等级"); case .cpuTemperature: localized("CPU 温区（°C）"); case .gpuTemperature: localized("GPU 温区（°C）"); case .fan: localized("风扇（RPM）") }
    }
    var divisor: Double {
        switch self { case .cpu, .gpu, .pressure, .cpuTemperature, .gpuTemperature, .fan: 1; case .memory: 1_073_741_824; case .download, .upload: 1_048_576 }
    }
    func value(_ sample: SystemSnapshot) -> Double? {
        switch self {
        case .cpu: sample.cpuPercent
        case .memory: sample.usedMemoryBytes.map { Double($0) }
        case .download: sample.networkRate?.download
        case .upload: sample.networkRate?.upload
        case .gpu, .pressure, .cpuTemperature, .gpuTemperature, .fan: nil
        }
    }
    func aggregate(_ bucket: HistoryBucket) -> AggregateValue? {
        switch self { case .cpu: bucket.cpu; case .memory: bucket.memory; case .download: bucket.download; case .upload: bucket.upload; case .gpu: bucket.gpu; case .pressure: bucket.pressure; case .cpuTemperature: bucket.cpuTemperature; case .gpuTemperature: bucket.gpuTemperature; case .fan: bucket.fan }
    }
    var isNetwork: Bool { self == .download || self == .upload }
}
struct MonitorChartPoint: Identifiable {
    let id: Int
    let time: Date
    let value: Double
    let peak: Double?
    let segment: Int
}
func monitorPoints(metric: MonitorMetric, recent: [SystemSnapshot], history: [HistoryBucket], historical: Bool) -> [MonitorChartPoint] {
    var result: [MonitorChartPoint] = []; var segment = 0
    if historical {
        var previous: HistoryBucket?
        for (index, bucket) in history.enumerated() {
            if bucket.hasGap || (metric.isNetwork && (bucket.interface == "接口切换" || previous?.interface != bucket.interface)) { segment += 1 }
            if let aggregate = metric.aggregate(bucket), let mean = aggregate.mean, mean.isFinite, aggregate.peak.isFinite {
                result.append(.init(id: index, time: bucket.timestamp, value: mean / metric.divisor, peak: aggregate.peak / metric.divisor, segment: segment))
            } else { segment += 1 }
            previous = bucket
        }
    } else {
        var previous: SystemSnapshot?
        for (index, sample) in recent.enumerated() {
            if let previous {
                let seconds = sample.uptime - previous.uptime
                let wallSeconds = sample.timestamp.timeIntervalSince(previous.timestamp)
                if seconds > 6 || seconds <= 0 || wallSeconds <= 0 || abs(wallSeconds - seconds) > 1 || (metric.isNetwork && previous.networkGeneration != sample.networkGeneration) { segment += 1 }
            }
            if let value = metric.value(sample), value.isFinite {
                result.append(.init(id: index, time: sample.timestamp, value: value / metric.divisor, peak: nil, segment: segment))
            } else { segment += 1 }
            previous = sample
        }
    }
    return result
}
func isolatedMonitorPointIDs(_ points: [MonitorChartPoint]) -> Set<Int> {
    var counts: [Int: Int] = [:]
    for point in points { counts[point.segment, default: 0] += 1 }
    return Set(points.filter { counts[$0.segment] == 1 }.map(\.id))
}
struct MonitorTrend: View {
    let metric: MonitorMetric
    let recent: [SystemSnapshot]
    let history: [HistoryBucket]
    let historical: Bool
    var seconds = 600
    var body: some View {
        let points = monitorPoints(metric: metric, recent: recent, history: history, historical: historical)
        let isolated = isolatedMonitorPointIDs(points)
        VStack(alignment: .leading) {
            Text(metric.title).font(.headline)
            if points.isEmpty { Text(localized("暂无有效数据")).foregroundStyle(Theme.muted).frame(height: 130) }
            else {
                Chart(points) { point in
                    LineMark(x: .value(localized("时间"), point.time), y: .value(historical ? localized("均值") : localized("实时值"), point.value), series: .value(localized("连续段"), "mean-\(point.segment)"))
                        .foregroundStyle(Theme.primary)
                    if isolated.contains(point.id) {
                        PointMark(x: .value(localized("时间"), point.time), y: .value(localized("数值"), point.value)).foregroundStyle(Theme.primary)
                    }
                    if let peak = point.peak {
                        LineMark(x: .value(localized("时间"), point.time), y: .value(localized("峰值"), peak), series: .value(localized("连续段"), "peak-\(point.segment)"))
                            .foregroundStyle(Theme.warning).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        if isolated.contains(point.id) {
                            PointMark(x: .value(localized("时间"), point.time), y: .value(localized("峰值"), peak)).foregroundStyle(Theme.warning).symbol(.diamond)
                        }
                    }
                }.chartYScale(domain: .automatic(includesZero: true)).frame(height: 130)
                Text(historical ? localized("实线：分钟均值 · 橙色虚线：峰值") : localized("最近 \(seconds == 60 ? localized("60 秒") : localized("10 分钟")) · 可见时每秒采样"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
func memoryText(_ value: UInt64?) -> String {
    guard let value else { return localized("不可用") }
    return value == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .memory)
}
func speedText(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return localized("采集中") }
    let count = Int64(min(value, Double(Int64.max / 2)))
    return count == 0 ? "0 KB/s" : ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal) + "/s"
}
