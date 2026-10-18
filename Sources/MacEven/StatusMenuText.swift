import Foundation
import MacEvenCore

func statusMetricText(_ metric: StatusMetric, snapshot: SystemSnapshot?, hardware: HardwareSnapshot?, now: Date = Date()) -> String? {
    if metric == .none { return nil }
    let s = snapshot.flatMap { now.timeIntervalSince($0.timestamp) <= 6 ? $0 : nil }
    let h = hardware.flatMap { now.timeIntervalSince($0.sampledAt) <= 30 ? $0 : nil }
    let value: String
    switch metric {
    case .none: return nil
    case .cpu: value = s?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—"
    case .ram: value = s?.usedMemoryBytes.map { memoryText($0) } ?? "—"
    case .gpu: value = h?.gpu.first?.deviceUtilizationPercent.map { String(format: "%.0f%%", $0) } ?? "—"
    case .battery: value = h?.battery.currentCapacityPercent.map { "\($0)%" } ?? "—"
    case .thermal: value = temperatureValue(h).map { String(format: "%.0f°C", $0) } ?? "—"
    case .download: value = s?.networkRate.map { speedText($0.download) } ?? "—"
    case .upload: value = s?.networkRate.map { speedText($0.upload) } ?? "—"
    }
    return "\(metric.shortName) \(value)"
}
