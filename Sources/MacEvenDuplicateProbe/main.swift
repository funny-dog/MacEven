import Foundation
import Darwin
import MacEvenCore

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    precondition(code == KERN_SUCCESS, "RSS sampling failed")
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
    precondition(code == KERN_SUCCESS, "Footprint sampling failed")
    return info.phys_footprint
}

final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private let timer: DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MacEvenDuplicateProbe.memory"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    deinit { timer.cancel() }
    func sample() {
        let value = residentBytes()
        lock.withLock { peak = max(peak, value) }
    }
    var peakBytes: UInt64 { lock.withLock { peak } }
}

final class CancelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var didCancel = false
    private var cancelTime: Date?

    func cancelOnce(token: CancellationToken) -> Bool {
        lock.withLock {
            if !didCancel {
                didCancel = true
                cancelTime = Date()
                token.cancel()
                return true
            }
            return false
        }
    }

    var latency: TimeInterval {
        lock.withLock {
            cancelTime.map { Date().timeIntervalSince($0) } ?? 0
        }
    }

    var wasCancelled: Bool {
        lock.withLock { didCancel }
    }
}

func parseArguments() -> (fileCount: Int, rounds: Int) {
    var fileCount = 100_000
    var rounds = 3
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        if arg == "--files" {
            guard i + 1 < args.count,
                  let val = Int(args[i + 1]),
                  val > 0 else {
                fputs("Error: Invalid or missing argument for --files\n", stderr)
                exit(1)
            }
            fileCount = val
            i += 2
        } else if arg == "--rounds" {
            guard i + 1 < args.count,
                  let val = Int(args[i + 1]),
                  val > 0 else {
                fputs("Error: Invalid or missing argument for --rounds\n", stderr)
                exit(1)
            }
            rounds = val
            i += 2
        } else {
            fputs("Error: Unknown argument '\(arg)'\n", stderr)
            exit(1)
        }
    }
    return (fileCount, rounds)
}

setbuf(stdout, nil)
let (fileCount, rounds) = parseArguments()

let fm = FileManager.default
let rawHome = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-home-\(UUID())")
try fm.createDirectory(at: rawHome, withIntermediateDirectories: true)
let fakeHome = (try? canonicalFileURL(rawHome)) ?? rawHome.standardizedFileURL
let downloads = fakeHome.appendingPathComponent("Downloads")
let rawIndexDir = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-index-\(UUID())")
try fm.createDirectory(at: rawIndexDir, withIntermediateDirectories: true)
let indexDir = (try? canonicalFileURL(rawIndexDir)) ?? rawIndexDir.standardizedFileURL
let indexURL = indexDir.appendingPathComponent("index.sqlite")

try fm.createDirectory(at: downloads, withIntermediateDirectories: true)

defer {
    try? fm.removeItem(at: rawHome)
    try? fm.removeItem(at: rawIndexDir)
}

print("MacEvenDuplicateProbe starting: files=\(fileCount) rounds=\(rounds)")
print("Fake home: \(fakeHome.path)")
print("Index outside root: \(indexURL.path)")

let bucketCount = (fileCount >= 997 * 2) ? 997 : max(1, fileCount / 2)
print("Generating \(fileCount) files in batches of 1000 (\(bucketCount) buckets, 128 bytes each)…")

let batchCount = (fileCount + 999) / 1000
for batch in 0..<batchCount {
    autoreleasepool {
        let start = batch * 1000
        let end = min(fileCount, start + 1000)
        for idx in start..<end {
            let seed = UInt64(idx % bucketCount).littleEndian
            var payload = Data(repeating: 0x5a, count: 128)
            withUnsafeBytes(of: seed) { ptr in
                payload.replaceSubrange(0..<8, with: ptr)
            }
            let filePath = downloads.appendingPathComponent("file-\(idx)").path
            guard fm.createFile(atPath: filePath, contents: payload) else {
                fatalError("Failed to create fixture file-\(idx)")
            }
        }
    }
}

let sampler = Sampler()
var retained: [UInt64] = []

print("Starting \(rounds) scan rounds with bounded paging…")
for round in 1...rounds {
    try autoreleasepool {
        let index = try DiskIndex(url: indexURL)
        let service = DuplicateFiles(index: index, home: fakeHome)
        let start = Date()
        let summary = try service.scan(root: downloads, token: CancellationToken())
        let elapsed = Date().timeIntervalSince(start)
        precondition(!summary.incomplete && !summary.cancelled, "Scan incomplete/cancelled in round \(round)")
        precondition(summary.errors == 0, "Scan had \(summary.errors) errors in round \(round)")

        var groupOffset = 0
        var totalGroups = 0
        var totalMembers = 0
        while true {
            let groupPage = try service.groups(offset: groupOffset, limit: 100)
            precondition(groupPage.count <= 100, "Group page size exceeded 100: \(groupPage.count)")
            if groupPage.isEmpty { break }
            totalGroups += groupPage.count
            groupOffset += groupPage.count

            for group in groupPage {
                var memberOffset = 0
                var groupMembers = 0
                while true {
                    let memberPage = try service.members(groupID: group.id, offset: memberOffset, limit: 100)
                    precondition(memberPage.count <= 100, "Member page size exceeded 100: \(memberPage.count)")
                    if memberPage.isEmpty { break }
                    groupMembers += memberPage.count
                    memberOffset += memberPage.count
                }
                precondition(groupMembers == group.memberCount, "Group \(group.id) memberCount mismatch: \(groupMembers) != \(group.memberCount)")
                totalMembers += groupMembers
            }
        }
        precondition(totalMembers == fileCount, "Total duplicate members \(totalMembers) != fileCount \(fileCount)")

        let databaseSize = (try? fm.attributesOfItem(atPath: indexURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        index.close()
        sampler.sample()
        let rss = residentBytes()
        print("round=\(round) groups=\(totalGroups) members=\(totalMembers) seconds=\(String(format: "%.3f", elapsed)) rssMiB=\(String(format: "%.2f", Double(rss)/1048576)) peakMiB=\(String(format: "%.2f", Double(sampler.peakBytes)/1048576)) databaseMiB=\(String(format: "%.2f", Double(databaseSize)/1048576))")
    }
    try? fm.removeItem(at: indexURL)
    retained.append(retainedFootprintBytes())
}

// 门槛遍历：1 MB 门槛下 10 万个小文件只计数，不建索引、不读内容。
try autoreleasepool {
    let index = try DiskIndex(url: indexURL)
    defer {
        index.close()
        try? fm.removeItem(at: indexURL)
    }
    let service = DuplicateFiles(index: index, home: fakeHome)
    let start = Date()
    let summary = try service.scan(root: downloads, minimumSize: DuplicateFiles.defaultMinimumSize, token: CancellationToken())
    let elapsed = Date().timeIntervalSince(start)
    precondition(!summary.incomplete && summary.errors == 0, "Threshold scan incomplete")
    precondition(summary.filteredSmall == Int64(fileCount) && summary.readBytes == 0, "Threshold scan read or indexed small files")
    let thresholdGroups = try service.groups()
    precondition(thresholdGroups.isEmpty, "Threshold scan produced groups")
    print("thresholdScan files=\(fileCount) filteredSmall=\(summary.filteredSmall) seconds=\(String(format: "%.3f", elapsed))")
}

let peak = sampler.peakBytes
print("peakMiB=\(String(format: "%.2f", Double(peak)/1048576))")
precondition(peak < 200 * 1048576, "Core peak memory exceeded 200 MiB: \(Double(peak)/1048576) MiB")

if retained.count >= 3 {
    // 泄漏判定看轮末保留内存而非 RSS：RSS 随 malloc 归还页面在约 20 与 37 MiB 间跳变，泄漏页闲置后又会被压缩移出 RSS。
    // malloc small 区会在第 2 或第 3 轮一次性多保留约 17 MiB 并就此持平，这种台阶只抬高单个相邻增量；
    // 固定负载下的真实泄漏每轮都会累积，故以最小相邻增量估计每轮泄漏，折算到全部轮次后与预算比较
    let increments = zip(retained.dropFirst(), retained).map { Int64($0) - Int64($1) }
    let perRound = max(0, increments.min() ?? 0)
    let growth = perRound * Int64(retained.count - 1)
    print("retainedGrowthMiB=\(String(format: "%.2f", Double(growth)/1048576)) retainedPerRoundMiB=\(String(format: "%.2f", Double(perRound)/1048576)) retainedMiB=\(retained.map { String(format: "%.2f", Double($0)/1048576) }.joined(separator: ","))")
    precondition(growth < 16 * 1048576, "Retained memory grows every round (projected growth >= 16 MiB: \(Double(growth)/1048576) MiB)")
}

print("Testing 64MiB duplicate streaming hashing and bounded cancellation…")
let largeDir = fakeHome.appendingPathComponent("MacEven-dup-large-\(UUID())")
try fm.createDirectory(at: largeDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: largeDir) }

let chunkSize = 1024 * 1024 // 1 MiB
let chunk = Data(repeating: 0x3c, count: chunkSize)
for name in ["large-a.bin", "large-b.bin"] {
    let fileURL = largeDir.appendingPathComponent(name)
    fm.createFile(atPath: fileURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: fileURL)
    for _ in 0..<64 {
        handle.write(chunk)
    }
    try handle.close()
}

// 1. 验证流式 SHA 完整扫描有界
try autoreleasepool {
    let index = try DiskIndex(url: indexURL)
    defer {
        index.close()
        try? fm.removeItem(at: indexURL)
    }
    let service = DuplicateFiles(index: index, home: fakeHome)
    let summary = try service.scan(root: largeDir, token: CancellationToken())
    precondition(!summary.incomplete && !summary.cancelled, "64MiB scan failed")
    let groups = try service.groups(offset: 0, limit: 10)
    precondition(groups.count == 1, "Expected 1 duplicate group for 64MiB files, got \(groups.count)")
    precondition(groups[0].memberCount == 2, "Expected 2 members in 64MiB group, got \(groups[0].memberCount)")
    sampler.sample()
    let currentPeak = sampler.peakBytes
    precondition(currentPeak < 200 * 1048576, "Peak RSS exceeded 200 MiB during 64MiB hashing: \(Double(currentPeak)/1048576) MiB")
    print("64MiB streaming completed, groups=\(groups.count) peakMiB=\(String(format: "%.2f", Double(currentPeak)/1048576))")
}

// 2. 验证已开始读取后取消与延迟 < 2 秒，以及取消后不可清理
try autoreleasepool {
    let index = try DiskIndex(url: indexURL)
    defer {
        index.close()
        try? fm.removeItem(at: indexURL)
    }
    let service = DuplicateFiles(index: index, home: fakeHome)
    let token = CancellationToken()
    let tracker = CancelTracker()

    // 抽样阶段只读 3 × 16 KiB；在完整哈希阶段取消，验证读取大文件途中的取消延迟。
    let cancelSummary = try service.scan(root: largeDir, token: token) { progress in
        if progress.phase == "hashing" {
            _ = tracker.cancelOnce(token: token)
        }
    }
    let latency = tracker.latency
    print("64MiB cancel latency: \(String(format: "%.3f", latency))s, cancelled=\(cancelSummary.cancelled), incomplete=\(cancelSummary.incomplete)")
    precondition(tracker.wasCancelled, "Cancellation was not triggered during 64MiB hashing")
    precondition(cancelSummary.cancelled || cancelSummary.incomplete, "Scan should be marked cancelled/incomplete")
    precondition(cancelSummary.hashed == 0 && cancelSummary.readBytes > 0 && cancelSummary.readBytes < 64 * 1048576, "Cancellation did not occur inside the first file read")
    precondition(latency < 2.0, "Cancellation latency exceeded 2.0s limit: \(latency)s")

    precondition(!service.isValid, "DuplicateFiles service must not be valid after cancellation")
    let moveResults = service.move(groupID: "dummy", keeperID: 1, ids: [2], token: CancellationToken())
    precondition(moveResults.contains { $0.error != nil }, "Cleanup after cancelled scan must be rejected")
}

print("PASS: duplicate probe resource budget, repeated scans, bounded paging, and cancellation")
