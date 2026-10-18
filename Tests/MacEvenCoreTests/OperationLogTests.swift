import Foundation
import MacEvenCore

// 防止的问题：日志无界增长、轮转丢掉最近记录、损坏行导致整个记录不可读、跟随符号链接写到别处。
final class OperationLogTests {
    func testAppendRotateAndRecent() throws {
        try CoreTests().withTree { raw, _ in
            let home = try canonicalFileURL(raw)
            let log = OperationLog(directory: home.appendingPathComponent("Logs"), maxBytes: 4096)
            XCTAssertEqual(try log.recent().records.count, 0)
            let results = [
                TrashResult(id: 1, path: "/tmp/a", destination: URL(fileURLWithPath: "/trash/a"), error: nil, allocatedSize: 4096),
                TrashResult(id: 2, path: "/tmp/b", destination: nil, error: "已在保护列表中：/tmp"),
                TrashResult(id: 3, path: "/tmp/c", destination: URL(fileURLWithPath: "/trash/c"), error: "索引同步失败")
            ]
            let batch = OperationRecord.batch(results, source: "disk")
            XCTAssertEqual(Set(batch.map(\.batch)).count, 1)
            try log.append(batch)
            let first = try log.recent()
            XCTAssertEqual(first.records.map(\.path), ["/tmp/c", "/tmp/b", "/tmp/a"])
            XCTAssertEqual(first.records.map(\.moved), [true, false, true])
            XCTAssertEqual(first.records.last?.allocatedSize, 4096)
            let mode = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)

            // 写满触发轮转，最近记录跨两个文件读取，旧轮转文件只保留一份。
            for n in 0..<60 {
                try log.append(OperationRecord.batch([TrashResult(id: Int64(n), path: "/tmp/n\(n)", destination: nil, error: String(repeating: "x", count: 40))], source: "cache"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: log.rotatedURL.path))
            XCTAssertTrue(try FileIdentity.read(log.fileURL).size <= 4096)
            let recent = try log.recent(limit: 10)
            XCTAssertEqual(recent.records.first?.path, "/tmp/n59")
            XCTAssertEqual(recent.records.count, 10)
            let numbers = try log.recent(limit: 1000).records.compactMap { $0.path.hasPrefix("/tmp/n") ? Int($0.path.dropFirst(6)) : nil }
            XCTAssertEqual(numbers, Array((60 - numbers.count)..<60).reversed())

            // 损坏行跳过并计数，其余照常读出。
            let handle = try FileHandle(forWritingTo: log.fileURL)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("not json\n".utf8)); try handle.close()
            try log.append(OperationRecord.batch([TrashResult(id: 99, path: "/tmp/last", destination: nil, error: "x")], source: "duplicates"))
            let damaged = try log.recent(limit: 5)
            XCTAssertEqual(damaged.records.first?.path, "/tmp/last")
            XCTAssertEqual(damaged.skippedLines, 1)
        }
    }

    func testRejectsLinkedLocations() throws {
        try CoreTests().withTree { raw, _ in
            let home = try canonicalFileURL(raw)
            let elsewhere = home.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let linkedDirectory = home.appendingPathComponent("LinkedLogs")
            try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: elsewhere)
            let record = OperationRecord.batch([TrashResult(id: 1, path: "/tmp/a", destination: nil, error: "x")], source: "disk")
            XCTAssertThrowsError(try OperationLog(directory: linkedDirectory).append(record))
            let log = OperationLog(directory: home.appendingPathComponent("Logs"))
            try FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: log.fileURL, withDestinationURL: elsewhere.appendingPathComponent("target.log"))
            XCTAssertThrowsError(try log.append(record))
            XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("target.log").path))
        }
    }
}
