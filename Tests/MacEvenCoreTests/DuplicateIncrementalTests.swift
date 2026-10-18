import Foundation
import Darwin
@testable import MacEvenCore
import CoreServices

final class DuplicateIncrementalTests {
    func testPersistentHashReuse() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-dup-incremental-\(UUID())")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home/Documents"), withIntermediateDirectories: true)
        let home = try canonicalFileURL(base.appendingPathComponent("home")), folder = home.appendingPathComponent("Documents")
        defer { try? FileManager.default.removeItem(at: base) }
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: folder.appendingPathComponent("a"))
        try data.write(to: folder.appendingPathComponent("b"))
        let url = base.appendingPathComponent("index.sqlite")
        let first = try DiskIndex(url: url)
        let scanner = DuplicateFiles(index: first, home: home)
        let cold = try scanner.scan(root: folder, token: CancellationToken())
        XCTAssertFalse(cold.incomplete)
        XCTAssertTrue(cold.readBytes > 0)
        let expected = try scanner.groups().map(\.id)
        first.close()
        let reopened = try DiskIndex(url: url)
        defer { reopened.close() }
        let rescan = DuplicateFiles(index: reopened, home: home)
        let warm = try rescan.scan(root: folder, token: CancellationToken())
        XCTAssertFalse(warm.incomplete)
        XCTAssertEqual(warm.readBytes, 0)
        XCTAssertTrue(warm.incremental)
        XCTAssertEqual(warm.visited, 0)
        XCTAssertEqual(warm.cached, 2)
        print("duplicate cache: cold \(cold.readBytes) bytes; reopened \(warm.readBytes) bytes, \(warm.visited) enumerated, \(warm.cached) cache hits")
        XCTAssertEqual(try rescan.groups().map(\.id), expected)
    }
    func testLocalEventsAndPolicyFallback() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-events-\(UUID())")
        try fm.createDirectory(at: base.appendingPathComponent("home/Documents"), withIntermediateDirectories: true)
        let home = try canonicalFileURL(base.appendingPathComponent("home")), folder = home.appendingPathComponent("Documents")
        defer { try? fm.removeItem(at: base) }
        let payload = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        for n in 0..<8 {
            let leaf = folder.appendingPathComponent("leaf-\(n)")
            try fm.createDirectory(at: leaf, withIntermediateDirectories: true)
            for f in 0..<4 { try payload.write(to: leaf.appendingPathComponent("file-\(f)")) }
        }
        let index = try DiskIndex(url: base.appendingPathComponent("index.sqlite"))
        defer { index.close() }
        let scanner = DuplicateFiles(index: index, home: home)
        let cold = try scanner.scan(root: folder, token: CancellationToken())
        let warm = try scanner.scan(root: folder, token: CancellationToken())
        XCTAssertTrue(warm.incremental)
        XCTAssertEqual(warm.visited, 0)
        let file = folder.appendingPathComponent("leaf-0/file-0")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 50_000)
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()
        Thread.sleep(forTimeInterval: 0.2)
        let changed = try scanner.scan(root: folder, token: CancellationToken())
        XCTAssertTrue(changed.incremental)
        XCTAssertTrue(changed.visited > 0 && changed.visited < cold.visited)
        XCTAssertTrue(changed.readBytes > 0)
        print("duplicate incremental: cold \(cold.visited) entries; changed leaf \(changed.visited), \(changed.cached) cache hits, \(changed.readBytes) bytes read")
        XCTAssertEqual(try scanner.groups().first!.memberCount, 31)
        // 新增 / 删除局限在现有叶目录，更新后成员和完整扫描逐路径一致。
        try payload.write(to: folder.appendingPathComponent("leaf-1/added"))
        try fm.removeItem(at: folder.appendingPathComponent("leaf-2/file-0"))
        try fm.moveItem(at: folder.appendingPathComponent("leaf-3/file-0"), to: folder.appendingPathComponent("leaf-4/moved"))
        Thread.sleep(forTimeInterval: 0.2)
        _ = try scanner.scan(root: folder, token: CancellationToken())
        let reference = try DiskIndex(url: base.appendingPathComponent("reference.sqlite"))
        defer { reference.close() }
        let full = DuplicateFiles(index: reference, home: home)
        _ = try full.scan(root: folder, token: CancellationToken())
        let groups = try scanner.groups(), expected = try full.groups()
        XCTAssertEqual(groups.map(\.id), expected.map(\.id))
        for group in groups {
            XCTAssertEqual(try scanner.members(groupID: group.id).map { $0.url.path }.sorted(),
                           try full.members(groupID: group.id).map { $0.url.path }.sorted())
        }
        let threshold = try scanner.scan(root: folder, minimumSize: 200_000, token: CancellationToken())
        XCTAssertFalse(threshold.incremental)
        XCTAssertTrue(try scanner.groups().isEmpty)
        XCTAssertEqual(threshold.filteredSmall, 32)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    func testEventsDuringScanAndExpiredBaseline() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-during-\(UUID())")
        try fm.createDirectory(at: base.appendingPathComponent("home/Documents/leaf"), withIntermediateDirectories: true)
        let home = try canonicalFileURL(base.appendingPathComponent("home")), folder = home.appendingPathComponent("Documents")
        defer { try? fm.removeItem(at: base) }
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        for name in ["a", "b"] { try data.write(to: folder.appendingPathComponent("leaf/" + name)) }
        let index = try DiskIndex(url: base.appendingPathComponent("index.sqlite"))
        defer { index.close() }
        let scanner = DuplicateFiles(index: index, home: home), once = Once()
        let added = folder.appendingPathComponent("leaf/added")
        _ = try scanner.scan(root: folder, token: CancellationToken()) { progress in
            if progress.phase == "hashing", once.take() {
                do { try data.write(to: added) } catch { preconditionFailure("fixture write failed: \(error)") }
            }
        }
        XCTAssertTrue(fm.fileExists(atPath: added.path))
        let next = try scanner.scan(root: folder, token: CancellationToken())
        XCTAssertFalse(next.incomplete)
        XCTAssertEqual(try scanner.groups().first?.memberCount, 3)
        // 不论通知在收尾之前还是之后抵达，新文件都不会被游标跳过。
        guard let baseline = try index.duplicateBaseline() else { requireTest(false, "stable second scan has no baseline"); return }
        try index.storeDuplicateBaseline(DuplicateBaseline(signature: baseline.signature, cursors: baseline.cursors,
            fullScanTime: Date().addingTimeInterval(-86401)))
        let expired = try scanner.scan(root: folder, token: CancellationToken())
        XCTAssertFalse(expired.incremental)
        XCTAssertTrue(expired.visited > 0)
        XCTAssertEqual(expired.readBytes, 0)
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagEventIdsWrapped] {
            XCTAssertTrue(DuplicateEvents.needsFullScan([DuplicateEvents.Event(path: folder.path, flags: UInt32(flag), id: 1)]))
        }
    }

    func testHiddenEventsDoNotInvalidateBaseline() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-hidden-events-\(UUID())")
        try fm.createDirectory(at: base.appendingPathComponent("home/Documents/.hidden"), withIntermediateDirectories: true)
        let home = try canonicalFileURL(base.appendingPathComponent("home")), folder = home.appendingPathComponent("Documents")
        defer { try? fm.removeItem(at: base) }
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        for name in ["a","b"] { try data.write(to: folder.appendingPathComponent(name)) }
        let index = try DiskIndex(url: base.appendingPathComponent("index.sqlite")); defer { index.close() }
        let scanner = DuplicateFiles(index: index, home: home), once = Once()
        _ = try scanner.scan(root: folder, token: CancellationToken()) { progress in
            if progress.phase == "hashing", once.take() {
                do { try Data([1]).write(to: folder.appendingPathComponent(".hidden/log")) }
                catch { preconditionFailure("fixture write failed: \(error)") }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        XCTAssertNotNil(try index.duplicateBaseline())
        let warm = try scanner.scan(root: folder, token: CancellationToken())
        XCTAssertTrue(warm.incremental)
        XCTAssertEqual(warm.visited, 0)
        XCTAssertEqual(warm.readBytes, 0)
    }

    private func appendEvent(_ buffer: DuplicateEvents.Buffer, path: String, flags: UInt32, id: UInt64) {
        path.withCString { c in
            var paths = [c]
            let flags = [flags], ids = [id]
            paths.withUnsafeMutableBytes { raw in
                flags.withUnsafeBufferPointer { f in
                    ids.withUnsafeBufferPointer { i in buffer.append(count: 1, raw: raw.baseAddress!, flags: f.baseAddress!, ids: i.baseAddress!) }
                }
            }
        }
    }

    func testEventBufferRootFlagsAndAtomicCursor() {
        let root = DuplicateEvents.Buffer(rootPath: "/Volumes/Fixture", relativeRoot: "/")
        for path in ["/", ""] {
            appendEvent(root, path: path, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated), id: 1)
        }
        XCTAssertEqual(root.take().events.map(\.path), ["/Volumes/Fixture", "/Volumes/Fixture"])
        let buffer = DuplicateEvents.Buffer(rootPath: "/Users/fixture/Documents", relativeRoot: "/Users/fixture/Documents")
        appendEvent(buffer, path: "/Users/fixture/Downloads/ignored", flags: 0, id: 120)
        let ignored = buffer.take()
        XCTAssertTrue(ignored.events.isEmpty)
        XCTAssertEqual(ignored.cursor, 120)
        appendEvent(buffer, path: "/Users/fixture/Documents/later", flags: 0, id: 130)
        XCTAssertEqual(ignored.cursor, 120)
        let later = buffer.take()
        XCTAssertEqual(later.cursor, 130)
        XCTAssertEqual(later.events.map(\.path), ["/Users/fixture/Documents/later"])
        for flag in [kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount,
                     kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagHistoryDone] {
            appendEvent(buffer, path: "/outside", flags: UInt32(flag), id: 140)
            XCTAssertTrue(DuplicateEvents.needsFullScan(buffer.take().events))
        }
        XCTAssertTrue(buffer.ready)
    }

}
