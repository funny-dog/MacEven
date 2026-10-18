import Foundation
import MacEvenCore
import SQLite3
import Darwin

@main struct MonitorChecks {
    static func main() throws {
        cpuIntervalChecks()
        offlineHistoryChecks()
        switchedNetworkHistoryChecks()
        try historyChecks()
        try processChecks()
        let before = CPUCounters(user: 10, system: 10, nice: 0, idle: 80)
        let after = CPUCounters(user: 20, system: 20, nice: 0, idle: 160)
        precondition(CPUUsage.percent(previous: nil, current: after) == nil, "first CPU sample must be unavailable")
        precondition(CPUUsage.percent(previous: before, current: after) == 20, "busy CPU ratio")
        precondition(CPUUsage.percent(previous: after, current: before) == nil, "CPU counter reset")
        precondition(CPUUsage.percent(previous: after, current: after) == nil, "zero CPU interval")
        precondition(MemoryUsage.usedBytes(internalPages: 10, purgeablePages: 2,
            wiredPages: 3, compressedPages: 1, pageSize: 16384, physicalBytes: 1_048_576) == 196_608, "16KiB pages")
        precondition(MemoryUsage.usedBytes(internalPages: .max, purgeablePages: 0,
            wiredPages: 1, compressedPages: 1, pageSize: 16384, physicalBytes: 1_048_576) == nil, "memory arithmetic overflow")
        precondition(MemoryUsage.usedBytes(internalPages: 2, purgeablePages: 4,
            wiredPages: 1, compressedPages: 0, pageSize: 4096, physicalBytes: 16384) == 4096, "purgeable cannot underflow")
        let n0 = NetworkReading(interface: "en0", index: 1, received: 0, sent: 0, uptime: 10)
        let n1 = NetworkReading(interface: "en0", index: 1, received: 200, sent: 100, uptime: 12)
        let rate = NetworkUsage.rate(previous: n0, current: n1)
        precondition(rate?.download == 100 && rate?.upload == 50, "network actual interval")
        let changed = NetworkReading(interface: "en0", index: 2, received: 300, sent: 100, uptime: 14)
        precondition(NetworkUsage.rate(previous: n1, current: changed) == nil, "interface index changed")
        precondition(NetworkUsage.rate(previous: n1, current: n0) == nil, "network time rollback")
        let reset = NetworkReading(interface: "en0", index: 1, received: 1, sent: 1, uptime: 14)
        precondition(NetworkUsage.rate(previous: n1, current: reset) == nil, "network counter reset")
        precondition(NetworkUsage.rate(previous: n1, current: n1) == nil, "zero network interval")
        let monitor = SystemMonitor()
        let first = monitor.sample()
        precondition(first.physicalMemoryBytes > 0)
        precondition(first.cpuPercent == nil && first.networkRate == nil, "first native sample baseline")
        Thread.sleep(forTimeInterval: 2)
        let second = monitor.sample()
        if let cpu = second.cpuPercent { precondition(cpu.isFinite && (0...100).contains(cpu)) }
        else { precondition(second.errors["cpu"] != nil) }
        if let total = second.diskTotalBytes, let free = second.diskAvailableBytes { precondition(free <= total) }
        else { precondition(second.errors["disk"] != nil) }
        if let used = second.usedMemoryBytes { precondition(used <= second.physicalMemoryBytes) }
        else { precondition(second.errors["memory"] != nil) }
        if second.networkInterface == nil { precondition(second.errors["network"] != nil) }
        monitor.resetBaselines()
        let resetSample = monitor.sample()
        precondition(resetSample.cpuPercent == nil && resetSample.networkRate == nil)
        print("PASS: CPU deltas, checked memory pages, network reset, native metrics, baseline reset")
        print("native cpu=\(second.cpuPercent.map(String.init(describing:)) ?? "unavailable") RAM=\(second.usedMemoryBytes.map(String.init(describing:)) ?? "unavailable") interface=\(second.networkInterface ?? "none") errors=\(second.errors)")
    }

    static func processChecks() throws {
        let identity = ProcessIdentity(pid: 42, startTime: 100)
        let p0 = ProcessReading(identity: identity, cpuNanoseconds: 0, uptime: 10)
        let p1 = ProcessReading(identity: identity, cpuNanoseconds: 4_000_000_000, uptime: 12)
        precondition(ProcessUsage.percent(previous: p0, current: p1) == 200, "multicore CPU was capped")
        let reused = ProcessReading(identity: ProcessIdentity(pid: 42, startTime: 200), cpuNanoseconds: 5_000_000_000, uptime: 14)
        precondition(ProcessUsage.percent(previous: p1, current: reused) == nil, "PID reuse inherited CPU")
        precondition(ProcessUsage.nanoseconds(ticks: 3, numerator: 125, denominator: 3) == 125, "Apple silicon timebase")
        precondition(ProcessUsage.nanoseconds(ticks: .max, numerator: .max, denominator: 1) == nil, "time conversion overflow")
        precondition(ProcessUsage.nanoseconds(ticks: 1, numerator: 1, denominator: 0) == nil)
        let monitor = SystemMonitor()
        let first = monitor.processes(order: .cpu)
        precondition(first.entries.count <= 20)
        if let entry = first.entries.first {
            let details = monitor.details(for: entry.id)
            if let details { precondition(details.entry.id == entry.id) }
            let wrong = ProcessIdentity(pid: entry.id.pid, startTime: entry.id.startTime &+ 1)
            precondition(monitor.details(for: wrong) == nil, "detail selected reused identity")
        }
        precondition(monitor.details(for: ProcessIdentity(pid: .max, startTime: 1)) == nil, "missing process accepted")
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        precondition(result == 0)
        let own = ProcessIdentity(pid: getpid(), startTime: info.ri_proc_start_abstime)
        let detail = monitor.details(for: own)
        precondition(detail != nil && detail?.entry.memoryBytes != nil && detail?.path != nil, "native self detail")
        var before = rusage(); precondition(getrusage(RUSAGE_SELF, &before) == 0)
        let beforeCPU = info.ri_user_time + info.ri_system_time
        var checksum: UInt64 = 1
        let until = ProcessInfo.processInfo.systemUptime + 0.2
        while ProcessInfo.processInfo.systemUptime < until { checksum = checksum &* 1664525 &+ 1013904223 }
        var after = rusage(); precondition(getrusage(RUSAGE_SELF, &after) == 0)
        let afterResult = withUnsafeMutablePointer(to: &info) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        precondition(afterResult == 0)
        var timebase = mach_timebase_info_data_t(); precondition(mach_timebase_info(&timebase) == KERN_SUCCESS)
        let converted = ProcessUsage.nanoseconds(ticks: info.ri_user_time + info.ri_system_time - beforeCPU,
            numerator: timebase.numer, denominator: timebase.denom)!
        func nanos(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1e9 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1000
        }
        let reference = nanos(after) - nanos(before)
        precondition(reference > 50_000_000 && abs(Double(converted) - reference) / reference < 0.15, "native rusage unit conversion differs from getrusage")
        print("PASS: process CPU, PID reuse, identity detail, footprint, native timebase \(timebase.numer)/\(timebase.denom), checksum=\(checksum)")
    }

    static func cpuIntervalChecks() {
        var accumulator = HistoryAccumulator()
        _ = accumulator.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: 58), uptime: 100, cpuPercent: 0))
        _ = accumulator.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: 60), uptime: 102, cpuPercent: 100))
        let ended = accumulator.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: 62), uptime: 104, cpuPercent: 0))
        precondition(ended.count == 1 && ended[0].minuteUTC == 0 && ended[0].cpu?.peak == 100 && ended[0].cpu?.mean == 100,
            "CPU interval peak moved to next minute")
        precondition(accumulator.finish()?.cpu?.mean == 0, "latest CPU interval lost on exit")
        _ = accumulator.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: 10), uptime: 200))
        _ = accumulator.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: 12), uptime: 202, cpuPercent: 75))
        precondition(accumulator.finish()?.cpu?.mean == 75, "final valid CPU sample not saved")
        print("PASS: CPU delta interval, minute-boundary peak, final sample flush")
    }
    static func offlineHistoryChecks() {
        var accumulator = HistoryAccumulator(); var minutes: [MinuteAggregate] = []
        for index in 0...90 {
            minutes += accumulator.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: Double(index * 2)), uptime: Double(index * 2), cpuPercent: 20, usedMemoryBytes: 1024, compressedMemoryBytes: 512, swapUsedBytes: 256))
        }
        if let last = accumulator.finish() { minutes.append(last) }
        precondition(minutes.count == 3 && minutes.allSatisfy { !$0.hasGap && $0.cpu?.mean == 20 && $0.download == nil },
            "offline network disconnected valid CPU and RAM history")
        precondition(minutes.allSatisfy { $0.memory?.mean == 1024 && $0.compressed?.mean == 512 && $0.swap?.mean == 256 },
            "RAM byte counters interpreted as Double bit patterns")
        print("PASS: offline CPU and RAM history remains continuous with numeric byte values")
    }
    static func switchedNetworkHistoryChecks() {
        var accumulator = HistoryAccumulator()
        for index in 0...3 {
            let switched = index >= 2
            _ = accumulator.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: Double(index * 2)), uptime: Double(index * 2), cpuPercent: 20, usedMemoryBytes: 1024,
                networkRate: index == 2 ? nil : NetworkRate(download: 100, upload: 200), networkInterface: switched ? "B" : "A", networkGeneration: switched ? 2 : 1))
        }
        let minute = accumulator.finish()
        precondition(minute?.hasGap == false && minute?.cpu?.mean == 20 && minute?.interface == "接口切换", "network switch marked valid CPU interval as missing")
        for index in 0...3 {
            _ = accumulator.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: Double(index * 2)), uptime: Double(index * 2), cpuPercent: 20,
                networkRate: index == 2 ? nil : NetworkRate(download: 100, upload: 200), networkInterface: "reused-name", networkGeneration: index >= 2 ? 2 : 1))
        }
        let reused = accumulator.finish()
        precondition(reused?.hasGap == false && reused?.interface == "接口切换", "interface name reuse lost network discontinuity")
        print("PASS: interface changes isolate network without cutting CPU and RAM")
    }
    static func historyChecks() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("MacEven-history-\(UUID())")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let url = temp.appendingPathComponent("history.sqlite")
        let store = try MonitorHistory(url: url)
        let minute = Int64(Date().timeIntervalSince1970 / 60) * 60
        let now = Date(timeIntervalSince1970: Double(minute))
        try store.write(MinuteAggregate(minuteUTC: minute, cpu: AggregateValue(value: 20, seconds: 2)), now: now)
        try store.write(MinuteAggregate(minuteUTC: minute, cpu: AggregateValue(value: 80, seconds: 4)), now: now)
        let values = try store.query(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
        precondition(values.count == 1 && values[0].cpu?.mean == 60 && values[0].cpu?.peak == 80, "weighted minute merge")
        precondition(values[0].memory == nil, "missing metric became zero")
        store.close()
        let reopened = try MonitorHistory(url: url)
        let persisted = try reopened.query(from: now, to: now.addingTimeInterval(60))
        precondition(persisted.count == 1 && persisted[0].cpu?.mean == 60, "restart lost history")
        try reopened.clear()
        let empty = try reopened.query(from: now, to: now.addingTimeInterval(60))
        precondition(empty.isEmpty, "clear failed")
        for i in 0..<10100 {
            let t = minute + Int64(i * 60)
            try reopened.write(MinuteAggregate(minuteUTC: t, cpu: AggregateValue(value: 20, seconds: 60)),
                now: Date(timeIntervalSince1970: Double(t + 59)))
        }
        let end = Date(timeIntervalSince1970: Double(minute + 10100 * 60))
        let week = try reopened.query(from: end.addingTimeInterval(-604800), to: end, limit: 100000)
        precondition(!week.isEmpty && week.count <= 720, "unbounded UI history")
        precondition(week.first!.timestamp >= end.addingTimeInterval(-604800), "expired history returned")
        var db: OpaquePointer?
        precondition(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM minutes", -1, &stmt, nil) == SQLITE_OK)
        precondition(sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) <= 10080, "unbounded stored rows")
        sqlite3_finalize(stmt); sqlite3_close(db)
        let gaps = try MonitorHistory(url: temp.appendingPathComponent("gaps.sqlite"))
        let currentMinute = Int64(Date().timeIntervalSince1970 / 60) * 60
        for offset in [0, 600] {
            try gaps.write(MinuteAggregate(minuteUTC: currentMinute - 660 + Int64(offset), cpu: AggregateValue(value: 30, seconds: 60)), now: Date())
        }
        let discontinuous = try gaps.query(from: Date(timeIntervalSince1970: Double(currentMinute - 720)), to: Date())
        precondition(discontinuous.count == 2 && discontinuous[1].hasGap, "history bridged missing minutes between buckets")
        gaps.close()
        reopened.close()
        var accumulator = HistoryAccumulator()
        let start = Date(timeIntervalSince1970: 58)
        _ = accumulator.append(SystemSnapshot(timestamp: start, uptime: 100, cpuPercent: 20, usedMemoryBytes: 100))
        let completed = accumulator.append(SystemSnapshot(timestamp: start.addingTimeInterval(4), uptime: 104, cpuPercent: 80))
        precondition(completed.count == 1 && completed[0].cpu?.coveredSeconds == 2 && completed[0].cpu?.mean == 80, "minute split")
        let last = accumulator.finish()
        precondition(last?.cpu?.coveredSeconds == 2 && last?.cpu?.mean == 80, "minute split lost remainder")
        accumulator.reset()
        _ = accumulator.append(SystemSnapshot(timestamp: start, uptime: 100, cpuPercent: 20))
        let skipped = accumulator.append(SystemSnapshot(timestamp: start.addingTimeInterval(3600), uptime: 3700, cpuPercent: 80))
        precondition(skipped.isEmpty && accumulator.finish() == nil, "sleep filled invented samples")
        _ = accumulator.append(SystemSnapshot(timestamp: start, uptime: 100, cpuPercent: 20))
        _ = accumulator.append(SystemSnapshot(timestamp: start.addingTimeInterval(2), uptime: 102, cpuPercent: 30))
        let jump = accumulator.append(SystemSnapshot(timestamp: start.addingTimeInterval(-100), uptime: 104, cpuPercent: 40))
        precondition(jump.count == 1 && jump[0].hasGap, "clock jump joined history")
        let mixedStore = try MonitorHistory(url: temp.appendingPathComponent("mixed.sqlite"))
        let mixedMinute = Int64(Date().timeIntervalSince1970 / 60) * 60 - 60
        var firstInterface = MinuteAggregate(minuteUTC: mixedMinute, cpu: AggregateValue(value: 20, seconds: 2)); firstInterface.interface = "A"
        var secondInterface = MinuteAggregate(minuteUTC: mixedMinute, cpu: AggregateValue(value: 40, seconds: 2)); secondInterface.interface = "B"
        try mixedStore.write(firstInterface, now: Date()); try mixedStore.write(secondInterface, now: Date())
        let mixedBuckets = try mixedStore.query(from: Date(timeIntervalSince1970: Double(mixedMinute)), to: Date())
        mixedStore.close()
        precondition(mixedBuckets.count == 1 && !mixedBuckets[0].hasGap && mixedBuckets[0].cpu?.mean == 30 && mixedBuckets[0].interface == "接口切换", "SQL interface merge marked valid CPU history as missing")
        let corrupt = temp.appendingPathComponent("corrupt.sqlite")
        try Data(repeating: 0xFF, count: 4096).write(to: corrupt)
        do { let broken = try MonitorHistory(url: corrupt); broken.close(); preconditionFailure("corrupt database accepted") }
        catch { }
        let blocked = temp.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocked)
        do { let broken = try MonitorHistory(url: blocked.appendingPathComponent("db")); broken.close(); preconditionFailure("unwritable path accepted") }
        catch { }
        let oversized = temp.appendingPathComponent("oversized.sqlite")
        var largeDB: OpaquePointer?
        precondition(sqlite3_open(oversized.path, &largeDB) == SQLITE_OK)
        precondition(sqlite3_exec(largeDB, "CREATE TABLE filler(data BLOB); INSERT INTO filler VALUES(zeroblob(17825792));", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(largeDB)
        do { let broken = try MonitorHistory(url: oversized); broken.close(); preconditionFailure("database capacity limit not enforced") }
        catch { }
        print("PASS: weighted history, restart, retention, bounded query, minute split, gaps, corrupt storage")
    }
}
