import SwiftUI
import Charts
import MacEvenCore

func pressureCode(_ level: MemoryPressureLevel?) -> Int? {
    switch level { case .normal: 1; case .warning: 2; case .critical: 4; default: nil }
}
func pressureText(_ level: MemoryPressureLevel?) -> String {
    switch level { case .normal: localized("正常"); case .warning: localized("警告"); case .critical: localized("紧急"); default: localized("不可用") }
}
func thermalText(_ value: ThermalState?) -> String {
    switch value { case .nominal: localized("正常"); case .fair: localized("温热"); case .serious: localized("严重"); case .critical: localized("紧急"); default: localized("不可用") }
}
func temperatureValue(_ value: HardwareSnapshot?, gpu: Bool = false) -> Double? {
    value?.temperature(gpu: gpu)
}
func percentText(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? localized("不可用") }
func temperatureText(_ value: Double?) -> String { value.map { String(format: "%.1f °C", $0) } ?? localized("不可用") }

// 硬件明细折叠区：核心、传感器、配件与网络接口及其来源说明。
struct HardwareDetails: View {
    @ObservedObject var monitor: MonitorModel
    let h: HardwareSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
    }
    @ViewBuilder private var content: some View {
        DisclosureGroup(localized("CPU 核心与硬件来源")) {
            Text("\(h.cpu.performanceCores.map { localized("\($0) 个性能核心") } ?? localized("性能核心数量未知")) · \(h.cpu.efficiencyCores.map { localized("\($0) 个能效核心") } ?? localized("能效核心数量未知"))")
                .font(.caption)
            Text(localized("Mach 逻辑核心编号不保证对应能效/性能分组；每项是两个采样点之间的利用率。")).font(.caption).foregroundStyle(Theme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                ForEach(h.cpu.cores, id: \.coreIndex) { core in
                    VStack { Text(localized("核心 \(core.coreIndex + 1)")); Text(percentText(core.usagePercent)).bold() }.font(.caption).padding(8)
                }
            }
            Text(localized("内存压力来源：\(h.memoryPressure.source)；原始等级 \(h.memoryPressure.rawVMPressureLevel.map(String.init) ?? localized("不可用"))。"))
                .font(.caption).foregroundStyle(Theme.muted)
            ForEach(Array(h.gpu.enumerated()), id: \.offset) { _, gpu in
                Text(localized("GPU：\(gpu.model) · \(gpu.coreCount.map { localized("\($0) 核") } ?? localized("核心数未知")) · IOAccelerator 驱动利用率 · \(gpu.ioClass ?? localized("驱动未提供"))")).font(.caption)
            }
        }
        DisclosureGroup(localized("温度传感器 · AppleSMC 原始键")) {
            Text(localized("温区均值只汇总有效的 CPU/GPU 温区键，不代表某个物理核心。其他机型映射尚未实机核验。")).font(.caption).foregroundStyle(Theme.muted)
            ForEach(h.smcThermal.temperaturesCelsius.keys.sorted(), id: \.self) { key in
                LabeledContent(key, value: temperatureText(h.smcThermal.temperaturesCelsius[key])).font(.caption)
            }
            ForEach(h.unavailableReasons.keys.sorted(), id: \.self) { key in
                if let reason = h.unavailableReasons[key], key != "bluetooth_ios", key != "smc" { Text(localized("\(key)：\(reason)")).font(.caption).foregroundStyle(Theme.warning) }
            }
            if let reason = h.smcThermal.unavailableReason { Text(reason).foregroundStyle(Theme.warning).font(.caption) }
        }
        DisclosureGroup(localized("配件电量")) {
            if h.bluetoothAccessories.isEmpty { Text(localized("未读取到有电量数据的配件；这不表示所有配件已被识别。")).font(.caption) }
            ForEach(h.bluetoothAccessories) { device in
                VStack(alignment: .leading) {
                    LabeledContent(device.name, value: device.batteryPercent.map { "\($0)%" } ?? localized("不可用"))
                    Text(localized("\(device.source) · 左 \(device.leftBatteryPercent.map(String.init) ?? "—") / 右 \(device.rightBatteryPercent.map(String.init) ?? "—") / 盒 \(device.caseBatteryPercent.map(String.init) ?? "—")%"))
                        .font(.caption).foregroundStyle(Theme.muted)
                    if let percent = device.batteryPercent, percent <= 20 { Label(localized("低电量"), systemImage: "battery.25percent").foregroundStyle(Theme.warning) }
                }
            }
            Text(localized("电量是本次读取到的系统缓存，驱动未提供设备上报时间，不能保证配件的实时电量。")).font(.caption).foregroundStyle(Theme.muted)
            Text(h.bluetoothiOSUnavailableReason).font(.caption).foregroundStyle(Theme.muted)
        }
        DisclosureGroup(localized("网络接口与本机地址")) {
            ForEach(h.networkInterfaces) { interface in
                VStack(alignment: .leading) {
                    Text("\(interface.name) · \(interface.isUp ? localized("启用") : localized("停用"))\(interface.isVPN ? localized(" · 隧道接口") : "")\(interface.name == monitor.snapshot?.networkInterface ? localized(" · 当前计速接口") : "")").font(.caption.bold())
                    Text((interface.ipv4Addresses + interface.ipv6Addresses).joined(separator: " · ")).font(.caption).textSelection(.enabled)
                    if !interface.ipv4Netmasks.isEmpty { Text(localized("掩码 \(interface.ipv4Netmasks.joined(separator: " · "))")).font(.caption).foregroundStyle(Theme.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }
            Text(localized("隧道类型不能证明 VPN 已连接；网速沿用系统主接口，避免累加重叠流量。")).font(.caption).foregroundStyle(Theme.muted)
        }
    }
}

private struct HardwarePoint: Identifiable {
    let id: Int
    let time: Date
    let value: Double
    let segment: Int
}
struct HardwareTrend: View {
    let title: String
    let samples: [HardwareSnapshot]
    let value: (HardwareSnapshot) -> Double?
    var body: some View {
        let points = points()
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            if points.isEmpty { Text(localized("暂无有效数据")).foregroundStyle(Theme.muted).frame(height: 100) }
            else {
                Chart(points) { point in
                    LineMark(x: .value(localized("时间"), point.time), y: .value(localized("读数"), point.value), series: .value(localized("连续段"), String(point.segment)))
                    PointMark(x: .value(localized("时间"), point.time), y: .value(localized("读数"), point.value)).symbolSize(8)
                }.frame(height: 100)
            }
        }
    }
    private func points() -> [HardwarePoint] {
        var result: [HardwarePoint] = []; var segment = 0; var previous: Date?
        for (index, sample) in samples.enumerated() {
            if let previous, sample.sampledAt.timeIntervalSince(previous) > 12 || sample.sampledAt <= previous { segment += 1 }
            if let reading = value(sample), reading.isFinite { result.append(.init(id: index, time: sample.sampledAt, value: reading, segment: segment)) }
            else { segment += 1 }
            previous = sample.sampledAt
        }
        return result
    }
}
