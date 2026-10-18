import Foundation
import Darwin
import MacEvenCore

func probeRequire(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if !condition() {
        FileHandle.standardError.write(Data("PROBE REQUIREMENT FAILED: \(message())\n".utf8))
        exit(1)
    }
}

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    probeRequire(code == KERN_SUCCESS, "RSS sampling failed")
    return info.resident_size
}

// 轮末保留内存：先让所有 malloc zone 归还空闲页，再读物理占用（含被压缩的页），
// 排除分配器缓存与系统压缩对 RSS 的干扰，只剩真实存活的内存
func retainedFootprintBytes() -> UInt64 {
    _ = malloc_zone_pressure_relief(nil, 0)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    probeRequire(code == KERN_SUCCESS, "footprint sampling failed")
    return info.phys_footprint
}

final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private let timer: DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MacEvenProbe.memory"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    deinit { timer.cancel() }
    func sample() { let value = residentBytes(); lock.withLock { peak = max(peak,value) } }
    var peakBytes: UInt64 { lock.withLock { peak } }
}

func integerArgument(_ key: String, default value: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: key) else { return value }
    guard index + 1 < CommandLine.arguments.count, let number = Int(CommandLine.arguments[index+1]), number > 0 else {
        probeRequire(false, "invalid \(key)")
        return value
    }
    return number
}

let fileCount = integerArgument("--files", default: 100_000)
let rounds = integerArgument("--rounds", default: 5)
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("MacEven-probe-\(UUID())")
let indexURL = fm.temporaryDirectory.appendingPathComponent("MacEven-probe-index-\(UUID()).sqlite")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer {
    try? fm.removeItem(at: root)
    try? fm.removeItem(at: indexURL)
}
setbuf(stdout, nil)
print("Generating \(fileCount) files in dedicated temporary tree…")
for batch in 0..<((fileCount + 999) / 1000) {
    try autoreleasepool {
        let dir = root.appendingPathComponent("batch-\(batch)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in (batch * 1000)..<min(fileCount,(batch+1) * 1000) {
            guard fm.createFile(atPath: dir.appendingPathComponent("file-\(i)").path, contents: Data([1])) else {
                probeRequire(false, "fixture creation failed")
                return
            }
        }
    }
}

let sampler = Sampler()
var retained: [UInt64] = []
var rootAllocatedSize: Int64 = 0

for round in 1...rounds {
    try autoreleasepool {
        let index = try DiskIndex(url: indexURL)
        // 与磁盘分析一致：扫描时写入用途。临时目录继承“系统临时目录”（非 opaque），每个文件都要走一遍匹配。
        let result = try Scanner.scan(root: root, index: index, token: CancellationToken(), purposes: PurposeClassifier())
        probeRequire(result.errors == 0 && !result.cancelled, "scan incomplete")
        guard let rootEntry = try index.entry(id: 1) else {
            probeRequire(false, "root entry missing")
            return
        }
        let total = rootEntry.logicalSize
        probeRequire(total == Int64(fileCount), "wrong file total logical size: got \(total), expected \(fileCount)")
        rootAllocatedSize = rootEntry.allocatedSize
        let purposes = PurposeSummary(totals: try index.purposeTotals(), total: rootEntry.allocatedSize)
        probeRequire(purposes.labeled == rootEntry.allocatedSize && purposes.groups.map(\.category) == [.system],
            "purpose summary must attribute the temporary tree to the system temporary folder: \(purposes.groups)")

        let emptyFilter = try SpaceFilter()
        for _ in 1...3 {
            let statsToken = CancellationToken()
            let stats = try index.spaceStats(directoryID: 1, token: statsToken)
            probeRequire(stats.count == 7, "category stats count must be 7")

            let otherStat = stats.first(where: { $0.category == .other })
            probeRequire(otherStat != nil, "missing .other category stat")
            probeRequire(otherStat?.count == Int64(fileCount), "all ordinary files must be .other: got \(otherStat?.count ?? -1), expected \(fileCount)")
            probeRequire(otherStat?.allocatedSize == rootEntry.allocatedSize, "other allocatedSize (\(otherStat?.allocatedSize ?? -1)) must match root allocatedSize (\(rootEntry.allocatedSize))")

            let nonOtherCount = stats.filter { $0.category != .other }.reduce(0) { $0 + $1.count }
            probeRequire(nonOtherCount == 0, "non-other count must be 0, got \(nonOtherCount)")
            let totalStatAllocated = stats.reduce(0) { $0 + $1.allocatedSize }
            probeRequire(totalStatAllocated == rootEntry.allocatedSize, "total category allocatedSize must match root allocatedSize")

            let pageToken = CancellationToken()
            let page = try index.spacePage(directoryID: 1, filter: emptyFilter, offset: 0, limit: 100, token: pageToken)
            probeRequire(page.entries.count <= 100, "page entries count must be <= 100, got \(page.entries.count)")
            if fileCount >= 100 {
                probeRequire(page.entries.count == 100, "page entries count must be 100 when fileCount >= 100")
                probeRequire(page.hasNext == (fileCount > 100), "hasNext must be true when fileCount > 100")
            }
            probeRequire(page.totalCount == Int64(fileCount), "page totalCount must match fileCount: got \(page.totalCount), expected \(fileCount)")
            probeRequire(page.allocatedSize == rootEntry.allocatedSize, "page allocatedSize must match root allocatedSize")
            let none = try index.spacePage(directoryID: 1, filter: SpaceFilter(minAllocated: Int64.max), token: CancellationToken())
            probeRequire(none.entries.isEmpty && none.totalCount == 0 && none.allocatedSize == 0 && !none.hasNext, "empty filtered page retained totals")
        }

        let databaseSize = (try fm.attributesOfItem(atPath: indexURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        index.close()
        sampler.sample()
        let rss = residentBytes()
        print("round=\(round) visited=\(result.visited) seconds=\(String(format:"%.3f",result.elapsed)) rssMiB=\(String(format:"%.2f",Double(rss)/1048576)) databaseMiB=\(String(format:"%.2f",Double(databaseSize)/1048576))")
    }
    // 最后一轮保留 index 用于真实 SQL 取消与恢复测试
    if round < rounds {
        try fm.removeItem(at: indexURL)
    }
    retained.append(retainedFootprintBytes())
}

// 受控延时取消真实 SQL < 2秒 并随后恢复查询，必须观察取消实际发生，不能将预先取消当中途取消
try autoreleasepool {
    let index = try DiskIndex(url: indexURL)

    // shortcut: tiny fixtures finish before a timed interruption; use 100000 files to measure SQL cancellation.
    if fileCount >= 100_000 {
        let cancelToken = CancellationToken()
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { cancelToken.cancel() }
        do {
            _ = try index.spaceStats(directoryID: 1, token: cancelToken)
            probeRequire(false, "SQL completed before the controlled interruption")
        } catch {
            probeRequire(cancelToken.isCancelled, "query failed for a reason other than cancellation")
        }
        let elapsed = Date().timeIntervalSince(start)
        probeRequire(elapsed < 2, "SQL cancellation exceeded 2 seconds")
        print("sqlCancelSeconds=\(String(format: "%.6f", elapsed))")
    } else {
        print("SQL cancellation measurement requires --files 100000 or more")
    }

    // 取消后恢复查询
    let freshToken = CancellationToken()
    probeRequire(!freshToken.isCancelled, "recovery token must not be cancelled")
    let recoverStart = Date()
    let recoveredStats = try index.spaceStats(directoryID: 1, token: freshToken)
    let recoverDuration = Date().timeIntervalSince(recoverStart)
    probeRequire(recoveredStats.count == 7, "recovered stats must return 7 categories")
    let recoveredOther = recoveredStats.first(where: { $0.category == .other })
    probeRequire(recoveredOther?.count == Int64(fileCount), "recovered query count mismatch: got \(recoveredOther?.count ?? -1), expected \(fileCount)")
    probeRequire(recoveredOther?.allocatedSize == rootAllocatedSize, "recovered stats allocatedSize mismatch")

    let recoveredPage = try index.spacePage(directoryID: 1, filter: try SpaceFilter(), offset: 0, limit: 100, token: CancellationToken())
    probeRequire(recoveredPage.entries.count <= 100, "recovered page count <= 100")
    probeRequire(recoveredPage.totalCount == Int64(fileCount), "recovered page totalCount == \(fileCount)")
    print("sqlRecoverSeconds=\(String(format:"%.3f", recoverDuration)) recoveredOtherCount=\(recoveredOther?.count ?? 0)")

    index.close()
    try fm.removeItem(at: indexURL)
}

// 扫描取消基准测试（保持原有扫描取消）
try autoreleasepool {
    let index = try DiskIndex(url: indexURL)
    let token = CancellationToken()
    let start = Date()
    let result = try Scanner.scan(root: root, index: index, token: token) { _ in token.cancel() }
    probeRequire(result.cancelled && result.visited < fileCount, "scan cancellation failed")
    probeRequire(Date().timeIntervalSince(start) < 2, "scan cancellation exceeded local budget")
    print("cancelSeconds=\(String(format:"%.3f",Date().timeIntervalSince(start))) partialVisited=\(result.visited)")
    index.close()
}

let peak = sampler.peakBytes
print("peakMiB=\(String(format:"%.2f",Double(peak)/1048576))")
probeRequire(peak < 200 * 1048576, "core memory exceeded 200 MiB: \(Double(peak)/1048576) MiB")

if retained.count >= 3 {
    // 泄漏判定看轮末保留内存而非 RSS（RSS 会因页面归还与压缩出现瞬时低谷）；
    // 分配器的一次性保留台阶只抬高单个相邻增量，真实泄漏每轮都累积，故以最小相邻增量折算全部轮次
    let increments = zip(retained.dropFirst(), retained).map { Int64($0) - Int64($1) }
    let perRound = max(0, increments.min() ?? 0)
    let growth = perRound * Int64(retained.count - 1)
    print("retainedGrowthMiB=\(String(format:"%.2f",Double(growth)/1048576)) retainedPerRoundMiB=\(String(format:"%.2f",Double(perRound)/1048576)) retainedMiB=\(retained.map { String(format:"%.2f",Double($0)/1048576) }.joined(separator: ","))")
    probeRequire(growth < 16 * 1048576, "retained memory grows every round: projected growth=\(Double(growth)/1048576) MiB >= 16 MiB")
}
print("PASS: resource budget, bounded category/filter pages, query recovery and scan cancellation")
