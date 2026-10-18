import Foundation
import Darwin
import MacEvenCore

// 防止的问题：跟随链接把外部目录算进来、权限不足时静默给出偏小合计、无上限遍历、取消后继续统计。
final class OtherStorageTests {
    func testMeasurementBoundsAndIssues() throws {
        try CoreTests().withTree { raw, _ in
            let home = try canonicalFileURL(raw), fm = FileManager.default
            let locations = OtherStorage.locations(home: home)
            XCTAssertTrue(locations.allSatisfy { $0.url.path.hasPrefix(home.path + "/") })
            let archives = locations.first { $0.name == "Xcode 归档" }!
            try fm.createDirectory(at: archives.url.appendingPathComponent("2026-10-11"), withIntermediateDirectories: true)
            let file = archives.url.appendingPathComponent("2026-10-11/App.xcarchive")
            try Data(repeating: 1, count: 65536).write(to: file)
            let outside = home.appendingPathComponent("outside")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data(repeating: 2, count: 1_048_576).write(to: outside.appendingPathComponent("big"))
            try fm.createSymbolicLink(at: archives.url.appendingPathComponent("link"), withDestinationURL: outside)
            let measured = OtherStorage.measure(archives, token: CancellationToken())!
            XCTAssertEqual(measured.issue, nil)
            XCTAssertTrue(measured.allocatedSize >= 65536 && measured.allocatedSize < 1_048_576, file: #file, line: #line)
            XCTAssertEqual(measured.items, 3)
            XCTAssertEqual(OtherStorage.measure(locations.first { $0.name == "Ollama 模型" }!, token: CancellationToken()), nil)
            XCTAssertNotNil(OtherStorage.measure(archives, token: CancellationToken(), limit: 1)?.issue)
            let cancelled = CancellationToken(); cancelled.cancel()
            XCTAssertNotNil(OtherStorage.measure(archives, token: cancelled)?.issue)
            if geteuid() != 0 {
                let locked = archives.url.appendingPathComponent("2026-10-11")
                chmod(locked.path, 0)
                defer { chmod(locked.path, 0o755) }
                XCTAssertNotNil(OtherStorage.measure(archives, token: CancellationToken())?.issue)
            }
            let linkedRoot = locations.first { $0.name == "Parallels 虚拟机" }!
            try fm.createSymbolicLink(at: linkedRoot.url, withDestinationURL: outside)
            XCTAssertEqual(OtherStorage.measure(linkedRoot, token: CancellationToken())?.allocatedSize, 0)
        }
    }
}
