import Foundation
import SQLite3
import MacEvenCore

@main struct HardwareHistoryChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-hardware-history-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        var db: OpaquePointer?; precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        let oldFields = ["cpu","memory","compressed","swap","download","upload"]
        let columns = oldFields.map { "\($0)Sum REAL,\($0)Seconds REAL,\($0)Peak REAL,\($0)Count INTEGER" }.joined(separator: ",")
        precondition(sqlite3_exec(db, "CREATE TABLE minutes(minute INTEGER PRIMARY KEY,\(columns),interface TEXT,gap INTEGER NOT NULL)", nil, nil, nil) == SQLITE_OK)
        let minute = Int64(Date().timeIntervalSince1970 / 60) * 60 - 120
        precondition(sqlite3_exec(db, "INSERT INTO minutes(minute,cpuSum,cpuSeconds,cpuPeak,cpuCount,gap) VALUES(\(minute),600,60,10,1,0)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let history = try MonitorHistory(url: url)
        var buckets = try history.query(from: Date(timeIntervalSince1970: Double(minute)), to: Date())
        precondition(buckets.count == 1 && buckets[0].cpu?.mean == 10 && buckets[0].gpu == nil)
        var value = MinuteAggregate(minuteUTC: minute + 60)
        value.gpu = AggregateValue(value: 25, seconds: 10)
        value.pressure = AggregateValue(value: 2, seconds: 10)
        value.cpuTemperature = AggregateValue(value: 55, seconds: 10)
        value.gpuTemperature = AggregateValue(value: 45, seconds: 10)
        value.fan = AggregateValue(value: 1200, seconds: 10)
        try history.write(value, now: Date())
        buckets = try history.query(from: Date(timeIntervalSince1970: Double(minute)), to: Date())
        precondition(buckets.count == 2 && buckets[1].gpu?.mean == 25 && buckets[1].fan?.peak == 1200 && buckets[1].pressure?.mean == 2)
        precondition(buckets[0].gpu == nil && buckets[0].cpu?.mean == 10)
        history.close()
        let reopened = try MonitorHistory(url: url)
        let reopenedBuckets = try reopened.query(from: Date(timeIntervalSince1970: Double(minute)), to: Date())
        precondition(reopenedBuckets.count == 2)
        reopened.close()
        print("PASS: 旧历史无损迁移，新硬件字段均值/峰值，重复打开迁移幂等")
    }
}
