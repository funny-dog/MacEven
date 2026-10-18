import Foundation
import SQLite3
import Darwin

public struct AggregateValue: Sendable {
    public var weightedSum, coveredSeconds, peak: Double
    public var sampleCount: Int
    public var mean: Double? { coveredSeconds > 0 ? weightedSum / coveredSeconds : nil }
    public init(value: Double, seconds: Double) {
        weightedSum = value * seconds; coveredSeconds = seconds; peak = value; sampleCount = 1
    }
    mutating func merge(_ other: AggregateValue) {
        weightedSum += other.weightedSum; coveredSeconds += other.coveredSeconds
        peak = max(peak, other.peak); sampleCount += other.sampleCount
    }
}

public struct MinuteAggregate: Sendable {
    public let minuteUTC: Int64
    public var cpu, memory, compressed, swap, download, upload: AggregateValue?
    public var gpu, pressure, cpuTemperature, gpuTemperature, fan: AggregateValue?
    public var interface: String?
    public var hasGap: Bool = false
    public init(minuteUTC: Int64, cpu: AggregateValue? = nil) { self.minuteUTC = minuteUTC; self.cpu = cpu }
    var values: [AggregateValue?] { [cpu,memory,compressed,swap,download,upload,gpu,pressure,cpuTemperature,gpuTemperature,fan] }
    private mutating func add(_ value: Double?, seconds: Double, to key: WritableKeyPath<MinuteAggregate, AggregateValue?>) {
        guard let value, value.isFinite, value >= 0 else { return }
        let added = AggregateValue(value: value, seconds: seconds)
        if self[keyPath: key] == nil { self[keyPath: key] = added }
        else { self[keyPath: key]?.merge(added) }
    }
    mutating func observe(_ previous: SystemSnapshot, current: SystemSnapshot, seconds: Double) {
        add(current.cpuPercent, seconds: seconds, to: \.cpu)
        add(previous.usedMemoryBytes.map { Double($0) }, seconds: seconds, to: \.memory)
        add(previous.compressedMemoryBytes.map { Double($0) }, seconds: seconds, to: \.compressed)
        add(previous.swapUsedBytes.map { Double($0) }, seconds: seconds, to: \.swap)
        let sameNetwork = previous.networkGeneration == current.networkGeneration && previous.networkInterface == current.networkInterface
        if sameNetwork, let rate = current.networkRate {
            add(rate.download, seconds: seconds, to: \.download); add(rate.upload, seconds: seconds, to: \.upload)
            if let old = interface, old != current.networkInterface { interface = "接口切换" }
            else { interface = current.networkInterface }
        } else if previous.networkInterface != nil || current.networkInterface != nil {
            interface = "接口切换"
        }
    }
    mutating func observeHardware(_ hardware: HardwareSnapshot, seconds: Double) {
        add(hardware.gpu.first?.deviceUtilizationPercent, seconds: seconds, to: \.gpu)
        let level = hardware.memoryPressure.rawVMPressureLevel.flatMap { [1,2,4].contains($0) ? Double($0) : nil }
        add(level, seconds: seconds, to: \.pressure)
        add(hardware.temperature(), seconds: seconds, to: \.cpuTemperature)
        add(hardware.temperature(gpu: true), seconds: seconds, to: \.gpuTemperature)
        add(hardware.smcThermal.fanSpeedsRPM.first, seconds: seconds, to: \.fan)
    }
    public mutating func merge(_ other: MinuteAggregate) {
        for key in [\MinuteAggregate.cpu, \.memory, \.compressed, \.swap, \.download, \.upload, \.gpu, \.pressure, \.cpuTemperature, \.gpuTemperature, \.fan] {
            if let added = other[keyPath: key] {
                if self[keyPath: key] == nil { self[keyPath: key] = added }
                else { self[keyPath: key]?.merge(added) }
            }
        }
        if let new = other.interface {
            if let old = interface, old != new { interface = "接口切换" }
            else { interface = new }
        }
        hasGap = hasGap || other.hasGap
    }
}

public struct HistoryBucket: Sendable {
    public let timestamp: Date
    public let cpu, memory, compressed, swap, download, upload: AggregateValue?
    public let gpu, pressure, cpuTemperature, gpuTemperature, fan: AggregateValue?
    public let interface: String?
    public let hasGap: Bool
}

public struct HistoryAccumulator {
    private var previous: SystemSnapshot?
    private var active: MinuteAggregate?
    public init() {}
    public mutating func append(_ snapshot: SystemSnapshot, hardware: HardwareSnapshot? = nil) -> [MinuteAggregate] {
        defer { previous = snapshot }
        guard let previous else { return [] }
        let seconds = snapshot.uptime - previous.uptime
        let wallSeconds = snapshot.timestamp.timeIntervalSince(previous.timestamp)
        guard seconds > 0, seconds <= 6, wallSeconds > 0, abs(wallSeconds - seconds) <= 1 else {
            if var ended = active { ended.hasGap = true; active = nil; return [ended] }
            return []
        }
        var completed: [MinuteAggregate] = []
        var start = previous.timestamp.timeIntervalSince1970
        let end = snapshot.timestamp.timeIntervalSince1970
        guard start.isFinite, end.isFinite, end > start else { active = nil; return [] }
        while start < end {
            let minute = Int64(floor(start / 60)) * 60
            if let old = active, old.minuteUTC != minute { completed.append(old); active = nil }
            if active == nil { active = MinuteAggregate(minuteUTC: minute) }
            let segmentEnd = min(end, Double(minute + 60))
            // Allocate the observed monotonic duration proportionally across UTC minute boundaries.
            let duration = seconds * (segmentEnd - start) / wallSeconds
            active?.observe(previous, current: snapshot, seconds: duration)
            if let hardware {
                let age = snapshot.timestamp.timeIntervalSince(hardware.sampledAt)
                if age >= 0, age <= 12 { active?.observeHardware(hardware, seconds: duration) }
            }
            start = segmentEnd
        }
        return completed
    }
    public mutating func finish() -> MinuteAggregate? {
        let result = active; reset(); return result
    }
    public mutating func reset() { previous = nil; active = nil }
}

// One history queue owns this connection. No disk-index session cleanup touches it.
public final class MonitorHistory {
    private var db: OpaquePointer?
    private let fields = ["cpu", "memory", "compressed", "swap", "download", "upload", "gpu", "pressure", "cpuTemperature", "gpuTemperature", "fan"]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let error = failure(); close(); throw error
        }
        do {
            guard chmod(url.path, 0o600) == 0 else { throw MacEvenError(localized("无法限制历史数据库访问权限。")) }
            sqlite3_busy_timeout(db, 1000)
            try execute("PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL;")
            let pageSize = try scalar("PRAGMA page_size")
            guard pageSize > 0 else { throw MacEvenError(localized("历史数据库页大小无效。")) }
            let pageLimit = 16 * 1024 * 1024 / pageSize
            guard try scalar("PRAGMA max_page_count=\(pageLimit)") <= pageLimit else { throw MacEvenError(localized("历史数据库超过 16 MiB 上限。")) }
            let columns = fields.map { "\($0)Sum REAL,\($0)Seconds REAL,\($0)Peak REAL,\($0)Count INTEGER" }.joined(separator: ",")
            try execute("CREATE TABLE IF NOT EXISTS minutes(minute INTEGER PRIMARY KEY,\(columns),interface TEXT,gap INTEGER NOT NULL);")
            var existing: Set<String> = []
            try statement("PRAGMA table_info(minutes)") { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW { if let name = sqlite3_column_text(stmt, 1) { existing.insert(String(cString: name)) } }
            }
            try execute("BEGIN IMMEDIATE")
            do {
                for field in fields {
                    for (suffix, type) in [("Sum","REAL"),("Seconds","REAL"),("Peak","REAL"),("Count","INTEGER")] {
                        let name = field + suffix
                        if !existing.contains(name) { try execute("ALTER TABLE minutes ADD COLUMN \(name) \(type)") }
                    }
                }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            try prune(now: Date())
        } catch { close(); throw error }
    }
    deinit { close() }
    public func close() { if let db { sqlite3_close(db) }; db = nil }
    private func failure() -> MacEvenError {
        MacEvenError(localized("监控历史：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? localized("连接已关闭"))"))
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
        defer { sqlite3_finalize(value) }
        return try body(value)
    }
    private func scalar(_ sql: String) throws -> Int64 {
        try statement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(stmt, 0)
        }
    }
    private func bind(_ value: Int64, at index: Int32, in stmt: OpaquePointer) throws {
        guard sqlite3_bind_int64(stmt, index, value) == SQLITE_OK else { throw failure() }
    }
    private func complete(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    private func prune(now: Date) throws {
        let seconds = now.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 1e15 else { throw MacEvenError(localized("历史记录时间无效。")) }
        try statement("DELETE FROM minutes WHERE minute < ? OR minute > ?") { stmt in
            try bind(Int64(seconds - 604800), at: 1, in: stmt); try bind(Int64(seconds), at: 2, in: stmt)
            try complete(stmt)
        }
        try execute("DELETE FROM minutes WHERE minute IN (SELECT minute FROM minutes ORDER BY minute DESC LIMIT -1 OFFSET 10080)")
    }
    public func write(_ aggregate: MinuteAggregate, now: Date) throws {
        guard aggregate.minuteUTC % 60 == 0 else { throw MacEvenError(localized("历史记录必须按 UTC 分钟对齐。")) }
        for value in aggregate.values.compactMap({ $0 }) {
            guard value.weightedSum.isFinite, value.coveredSeconds.isFinite, value.peak.isFinite,
                  value.weightedSum >= 0, value.coveredSeconds > 0, value.peak >= 0, value.sampleCount > 0 else {
                throw MacEvenError(localized("历史聚合值无效。"))
            }
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try prune(now: now)
            let columns = fields.flatMap { name in ["\(name)Sum", "\(name)Seconds", "\(name)Peak", "\(name)Count"] }
            var updates = fields.flatMap { name in ["Sum", "Seconds", "Count"].map { suffix in
                "\(name)\(suffix)=COALESCE(minutes.\(name)\(suffix),0)+COALESCE(excluded.\(name)\(suffix),0)"
            } + ["\(name)Peak=MAX(COALESCE(minutes.\(name)Peak,0),COALESCE(excluded.\(name)Peak,0))"] }
            updates.append("interface=CASE WHEN minutes.interface IS NULL THEN excluded.interface WHEN excluded.interface IS NULL THEN minutes.interface WHEN minutes.interface=excluded.interface THEN minutes.interface ELSE '接口切换' END")
            updates.append("gap=MAX(minutes.gap,excluded.gap)")
            let names = ["minute"] + columns + ["interface","gap"]
            let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
            try statement("INSERT INTO minutes(\(names.joined(separator: ","))) VALUES(\(placeholders)) ON CONFLICT(minute) DO UPDATE SET \(updates.joined(separator: ","))") { stmt in
                try bind(aggregate.minuteUTC, at: 1, in: stmt)
                var index: Int32 = 2
                for value in aggregate.values {
                    for number in [value?.weightedSum, value?.coveredSeconds, value?.peak, value.map { Double($0.sampleCount) }] {
                        let result = number.map { sqlite3_bind_double(stmt, index, $0) } ?? sqlite3_bind_null(stmt, index)
                        guard result == SQLITE_OK else { throw failure() }; index += 1
                    }
                }
                if let interface = aggregate.interface {
                    guard sqlite3_bind_text(stmt, index, String(interface.prefix(64)), -1, transient) == SQLITE_OK else { throw failure() }
                } else { guard sqlite3_bind_null(stmt, index) == SQLITE_OK else { throw failure() } }
                try bind(aggregate.hasGap ? 1 : 0, at: index + 1, in: stmt); try complete(stmt)
            }
            try prune(now: now)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func clear() throws { try execute("DELETE FROM minutes") }
    public func query(from: Date, to: Date, limit: Int = 720) throws -> [HistoryBucket] {
        let start = from.timeIntervalSince1970; let end = to.timeIntervalSince1970
        guard start.isFinite, end.isFinite, abs(start) < 1e15, abs(end) < 1e15, end > start else { return [] }
        let lower = Int64(floor(start / 60)) * 60
        let width = max(60, Int64(ceil((end - Double(lower)) / Double(max(1,min(limit,720))) / 60)) * 60)
        let columns = fields.flatMap { ["SUM(\($0)Sum)","SUM(\($0)Seconds)","MAX(\($0)Peak)","SUM(\($0)Count)"] }
        let sql = "SELECT CAST((minute-?)/? AS INTEGER) AS bucket,\(columns.joined(separator: ",")),MIN(minute),MAX(minute),MAX(gap),COUNT(DISTINCT interface),MIN(interface),COUNT(*) FROM minutes WHERE minute>=? AND minute<? GROUP BY bucket ORDER BY bucket LIMIT ?"
        return try statement(sql) { stmt in
            for (offset,value) in [lower,width,lower,Int64(ceil(end)),Int64(max(1,min(limit,720)))].enumerated() {
                try bind(value, at: Int32(offset + 1), in: stmt)
            }
            var result: [HistoryBucket] = []
            var previousLastMinute: Int64?
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                var values: [AggregateValue?] = []
                for offset in stride(from: 1, through: fields.count * 4 - 3, by: 4) {
                    let column = Int32(offset); let seconds = sqlite3_column_double(stmt, column + 1)
                    if seconds > 0 {
                        var value = AggregateValue(value: 0, seconds: seconds)
                        value.weightedSum = sqlite3_column_double(stmt, column)
                        value.peak = sqlite3_column_double(stmt, column + 2)
                        value.sampleCount = Int(sqlite3_column_int64(stmt, column + 3)); values.append(value)
                    } else { values.append(nil) }
                }
                let tail = Int32(fields.count * 4 + 1)
                let first = sqlite3_column_int64(stmt, tail); let last = sqlite3_column_int64(stmt, tail + 1)
                let gap = sqlite3_column_int64(stmt, tail + 2) != 0 || last - first > 60 * (sqlite3_column_int64(stmt, tail + 5) - 1) || previousLastMinute.map { first - $0 > 60 } == true
                previousLastMinute = last
                let mixed = sqlite3_column_int64(stmt, tail + 3) > 1
                let interface = mixed ? "接口切换" : sqlite3_column_text(stmt, tail + 4).map { String(cString: $0) }
                result.append(HistoryBucket(timestamp: Date(timeIntervalSince1970: Double(first)),
                    cpu: values[0], memory: values[1], compressed: values[2], swap: values[3], download: values[4], upload: values[5],
                    gpu: values[6], pressure: values[7], cpuTemperature: values[8], gpuTemperature: values[9], fan: values[10],
                    interface: interface, hasGap: gap))
            }
            return result
        }
    }
}
