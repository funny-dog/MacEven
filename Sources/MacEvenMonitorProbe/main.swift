import Foundation
import Darwin
import MacEvenCore

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS, "RSS sampling failed")
    return info.resident_size
}
// 保留内存：先让所有 malloc zone 归还空闲页，再读物理占用（含被压缩的页），
// 排除分配器缓存与系统压缩对 RSS 的干扰，只剩真实存活的内存
func retainedFootprintBytes() -> UInt64 {
    _ = malloc_zone_pressure_relief(nil, 0)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS, "footprint sampling failed")
    return info.phys_footprint
}
func cpuSeconds() -> Double {
    var usage = rusage(); precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
func argument(_ key: String, default value: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: key) else { return value }
    guard index + 1 < CommandLine.arguments.count, let result = Int(CommandLine.arguments[index + 1]), result > 0 else { fatalError("invalid \(key)") }
    return result
}
let seconds = argument("--seconds", default: 1800)
let interval = argument("--interval", default: 2)
precondition(interval <= 6, "interval must fit valid sample coverage")
setbuf(stdout, nil)

var fixed = HistoryAccumulator(); var completed = 0
for index in 0..<100_000 {
    let time = Double(index * 2)
    let buckets = fixed.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: time), uptime: time,
        cpuPercent: 20, usedMemoryBytes: 1_000_000, networkRate: NetworkRate(download: 100, upload: 200), networkInterface: "fixture", networkGeneration: 1))
    precondition(buckets.count <= 1, "fixed reducer produced unbounded catch-up")
    for bucket in buckets {
        precondition(bucket.cpu?.coveredSeconds == 60 && bucket.cpu?.mean == 20 && bucket.cpu?.peak == 20)
        completed += 1
    }
}
precondition(completed == 3333 && fixed.finish() != nil)
print("PASS: 100000 fixed inputs, bounded minute reducer; completed=\(completed)")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-monitor-probe-\(UUID())")
let url = directory.appendingPathComponent("monitor.sqlite")
let history = try MonitorHistory(url: url)
defer { history.close(); try? FileManager.default.removeItem(at: directory) }
let monitor = SystemMonitor()
var accumulator = HistoryAccumulator()
let start = ProcessInfo.processInfo.systemUptime
let initialCPU = cpuSeconds()
var count = 0; var minimum = UInt64.max; var maximum: UInt64 = 0; var databaseBytes: UInt64 = 0
// 预热 5 分钟后每 5 分钟记录一次保留内存检查点；RSS min/max 仅供记录
let warmupSeconds = 300.0, checkpointSeconds = 300.0
var checkpoints: [(seconds: Double, bytes: UInt64)] = []
var nextCheckpoint = warmupSeconds
while ProcessInfo.processInfo.systemUptime - start < Double(seconds) {
    try autoreleasepool {
        let sample = monitor.sample()
        for minute in accumulator.append(sample) { try history.write(minute, now: Date()) }
        count += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let rss = residentBytes()
        if elapsed >= warmupSeconds { minimum = min(minimum, rss); maximum = max(maximum, rss) }
        if elapsed >= nextCheckpoint {
            let retained = retainedFootprintBytes()
            checkpoints.append((elapsed, retained))
            while nextCheckpoint <= elapsed { nextCheckpoint += checkpointSeconds }
            print("checkpoint seconds=\(String(format: "%.3f", elapsed)) retainedBytes=\(retained)")
        }
        databaseBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        print("seconds=\(String(format: "%.3f", elapsed)) samples=\(count) rssBytes=\(rss) cpuSeconds=\(String(format: "%.6f", cpuSeconds() - initialCPU)) databaseBytes=\(databaseBytes)")
        precondition(databaseBytes <= 16 * 1024 * 1024, "history exceeds database budget")
    }
    let remaining = Double(seconds) - (ProcessInfo.processInfo.systemUptime - start)
    if remaining > 0 { Thread.sleep(forTimeInterval: min(Double(interval), remaining)) }
}
if let minute = accumulator.finish() { try history.write(minute, now: Date()) }
databaseBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
let elapsed = ProcessInfo.processInfo.systemUptime - start
// 收尾检查点；末段不足半个窗口时跳过，避免短窗口放大噪声
if elapsed >= warmupSeconds, elapsed - (checkpoints.last?.seconds ?? 0) >= checkpointSeconds / 2 {
    checkpoints.append((elapsed, retainedFootprintBytes()))
}
let cpu = cpuSeconds() - initialCPU
let normalizedCPU = cpu / elapsed / Double(ProcessInfo.processInfo.activeProcessorCount) * 100
print("SUMMARY seconds=\(elapsed) samples=\(count) cpuSeconds=\(cpu) wholeMachineCPUPercent=\(normalizedCPU) databaseBytes=\(databaseBytes) postWarmupMinRSS=\(minimum == UInt64.max ? 0 : minimum) postWarmupMaxRSS=\(maximum) retainedCheckpointsMiB=\(checkpoints.map { String(format: "%.0fs:%.2f", $0.seconds, Double($0.bytes) / 1048576) }.joined(separator: ","))")
precondition(databaseBytes <= 16 * 1024 * 1024)
if seconds >= 1800 {
    // 泄漏判定看保留内存而非 RSS：RSS 随 malloc 是否归还空闲页跳变，闲置的泄漏页又会被移出 RSS
    //（实测注入 35 MiB 不可压缩泄漏时 RSS 仍停在约 8 MiB）。
    // 分配器或 SQLite 缓存的一次性台阶只抬高单个窗口；固定采样负载下的真实泄漏每个窗口都会累积，
    // 故以各窗口增长速率的最小值估计持续泄漏，折算到整个预热后检查期再与 20 MiB 预算比较
    precondition(checkpoints.count >= 3, "need at least two post-warmup checkpoint windows")
    let rates = zip(checkpoints.dropFirst(), checkpoints).map { (Double($0.bytes) - Double($1.bytes)) / ($0.seconds - $1.seconds) }
    let perSecond = max(0, rates.min() ?? 0)
    let span = checkpoints[checkpoints.count - 1].seconds - checkpoints[0].seconds
    let growth = perSecond * span
    print("retainedGrowthMiB=\(String(format: "%.2f", growth / 1048576)) retainedPerWindowMiB=\(rates.map { String(format: "%.2f", $0 * checkpointSeconds / 1048576) }.joined(separator: ","))")
    precondition(growth <= 20 * 1024 * 1024, "retained memory grows in every window: projected post-warmup growth=\(growth / 1048576) MiB > 20 MiB")
    print("PASS: 30-minute monitor resource budget; temporary history cleaned on exit")
} else { print("PASS: short probe only; 30-minute budget not evaluated") }
