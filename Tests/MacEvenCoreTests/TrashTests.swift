import Foundation
import SQLite3
@testable import MacEvenCore

final class TrashTests {
    func testLocalMaintenanceAndQueryPlans() throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw).appendingPathComponent("home"), fm = FileManager.default
            let classifier = PurposeClassifier(home: home)
            for relative in ["Downloads/delete/a", "Documents/keep/b", "Downloads/plain"] {
                let url = home.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 7, count: 4096).write(to: url)
            }
            try fm.linkItem(at: home.appendingPathComponent("Downloads/delete/a"), to: home.appendingPathComponent("Documents/keep/link"))
            _ = try Scanner.scan(root: home, index: index, token: CancellationToken(), purposes: classifier)
            var db: OpaquePointer?
            precondition(sqlite3_open(index.url.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            func queryIndexes() -> Set<String> {
                var statement: OpaquePointer?
                precondition(sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='index' AND name IN ('file_ranking','file_paths')", -1, &statement, nil) == SQLITE_OK)
                defer { sqlite3_finalize(statement) }
                var names = Set<String>()
                while sqlite3_step(statement) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(statement, 0))) }
                return names
            }
            XCTAssertEqual(queryIndexes(), [])
            let downloads = try index.children(of: 1).first { $0.name == "Downloads" }!
            let deleting = try index.children(of: downloads.id).first { $0.name == "delete" }!
            let keep = try index.largestFiles().first { $0.name == "b" }!
            XCTAssertEqual(queryIndexes(), ["file_ranking"])
            let trigger = "CREATE TRIGGER untouched BEFORE UPDATE ON nodes WHEN OLD.id=\(keep.id) BEGIN SELECT RAISE(ABORT,'unrelated row rewritten'); END"
            precondition(sqlite3_exec(db, trigger, nil, nil, nil) == SQLITE_OK)
            try fm.removeItem(at: deleting.url)
            try index.removeSubtree(id: deleting.id)
            precondition(sqlite3_exec(db, "DROP TRIGGER untouched", nil, nil, nil) == SQLITE_OK)
            let fresh = try DiskIndex(url: raw.appendingPathComponent("fresh.sqlite"))
            defer { fresh.close() }
            _ = try Scanner.scan(root: home, index: fresh, token: CancellationToken(), purposes: classifier)
            XCTAssertEqual(try index.entry(id: 1)?.logicalSize, 12288)
            XCTAssertEqual(try index.largestFiles().filter { $0.name == "a" || $0.name == "link" }.count, 1)
            let before = try index.purposeTotals().map { "\($0.tag.rawValue):\($0.bytes)" }.sorted()
            let after = try fresh.purposeTotals().map { "\($0.tag.rawValue):\($0.bytes)" }.sorted()
            XCTAssertEqual(before, after)
            func plan(_ sql: String) -> String {
                var statement: OpaquePointer?
                precondition(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil) == SQLITE_OK)
                defer { sqlite3_finalize(statement) }
                var result = ""
                while sqlite3_step(statement) == SQLITE_ROW { result += String(cString: sqlite3_column_text(statement, 3)) }
                return result
            }
            let ranking = plan("SELECT id FROM nodes WHERE (mode & 61440)=32768 AND duplicate=0 ORDER BY allocated DESC,logical DESC,id LIMIT 100")
            precondition(ranking.contains("file_ranking") && !ranking.contains("TEMP B-TREE"), ranking)
            _ = try index.spaceStats(directoryID: 1, token: CancellationToken())
            XCTAssertEqual(queryIndexes(), ["file_ranking", "file_paths"])
            let paths = plan("SELECT category,SUM(allocated) FROM nodes WHERE (mode & 61440)=32768 AND duplicate=0 AND path>='/x/' AND path<'/x0' GROUP BY category")
            precondition(paths.contains("file_paths"), paths)
            _ = try Scanner.scan(root: home, index: index, token: CancellationToken(), purposes: classifier)
            XCTAssertEqual(queryIndexes(), [])
            let cancelled = CancellationToken(); cancelled.cancel()
            XCTAssertThrowsError(try index.spaceStats(directoryID: 1, token: cancelled))
            XCTAssertThrowsError(try index.spacePage(directoryID: 1, filter: try SpaceFilter(), token: cancelled))
            XCTAssertEqual(queryIndexes(), [])
            XCTAssertEqual(try index.largestCleanableFiles(homePath: home.path).count, 3)
            XCTAssertEqual(queryIndexes(), ["file_ranking"])
            XCTAssertEqual(try index.spacePage(directoryID: 1, filter: try SpaceFilter(), token: CancellationToken()).totalCount, 3)
            XCTAssertEqual(queryIndexes(), ["file_ranking", "file_paths"])
        }
    }

    func testProtectionAndReplacement() throws {
        try CoreTests().withTree { rawHome, index in
            let home = try canonicalFileURL(rawHome)
            let folder = home.appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("a")
            try Data([1]).write(to: file)
            _ = try Scanner.scan(root: home, index: index, token: CancellationToken())
            let service = TrashService(index: index, home: home)
            XCTAssertNotNil(service.reasonBlocked(home))
            XCTAssertNotNil(service.reasonBlocked(home.appendingPathComponent("Library/a")))
            XCTAssertNotNil(service.reasonBlocked(home.appendingPathComponent(".ssh/key")))
            XCTAssertNotNil(service.reasonBlocked(URL(fileURLWithPath: "/System")))
            XCTAssertEqual(service.reasonBlocked(file), nil)
            let entry = try index.largestFiles().first!
            try FileManager.default.removeItem(at: file)
            try Data([1,2,3]).write(to: file)
            let result = service.move(ids: [entry.id])
            XCTAssertEqual(result.count, 1)
            XCTAssertNotNil(result[0].error)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            let link = home.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
            XCTAssertNotNil(service.reasonBlocked(link.appendingPathComponent("a")))
        }
    }

    func testBlockKindMirrorsCleanupRules() throws {
        try CoreTests().withTree { rawHome, index in
            let home = try canonicalFileURL(rawHome)
            let downloads = home.appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let file = downloads.appendingPathComponent("keep")
            try Data([1]).write(to: file)
            let hidden = home.appendingPathComponent(".cache")
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            try Data([1]).write(to: hidden.appendingPathComponent("big"))
            let link = home.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: downloads)
            let store = ProtectionStore(url: home.appendingPathComponent("Library/Application Support/MacEven/protection.json"))
            let protected = home.appendingPathComponent("Projects/Keep")
            try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
            _ = try store.addPath(protected)
            _ = try Scanner.scan(root: home, index: index, token: CancellationToken())
            let service = TrashService(index: index, home: home, protection: store)

            XCTAssertEqual(service.blockKind(home.appendingPathComponent("Library/x")), BlockKind.libraryOrHidden)
            XCTAssertEqual(service.blockKind(hidden.appendingPathComponent("big")), BlockKind.libraryOrHidden)
            XCTAssertEqual(service.blockKind(URL(fileURLWithPath: "/System")), BlockKind.outsideHome)
            XCTAssertEqual(service.blockKind(home), BlockKind.outsideHome)
            XCTAssertEqual(service.blockKind(index.url), BlockKind.macevenSelf)
            let protectedFile = protected.appendingPathComponent("doc")
            if case .userProtected(let reason)? = service.blockKind(protectedFile) {
                XCTAssertEqual(reason, store.reason(for: protectedFile))
            } else { XCTFail("user-protected path should carry its reason") }
            if case .pathInvalid? = service.blockKind(link.appendingPathComponent("keep")) {} else {
                XCTFail("symlinked ancestor should be reported as invalid")
            }
            XCTAssertNil(service.blockKind(file))

            // 结构化原因与既有清理文案必须同源，避免两套规则分叉。
            for url in [home, home.appendingPathComponent("Library/x"), hidden.appendingPathComponent("big"),
                        index.url, protectedFile, link.appendingPathComponent("keep"), file] {
                XCTAssertEqual(service.blockKind(url)?.blockedMessage, service.reasonBlocked(url))
            }
        }
    }

    func testNativeTrashAndHardlinkReassignment() throws {
        try CoreTests().withTree { rawHome, index in
            let home = try canonicalFileURL(rawHome)
            let a = home.appendingPathComponent("MacEven-check-\(UUID())")
            try Data(repeating: 1, count: 10).write(to: a)
            try FileManager.default.linkItem(at: a, to: home.appendingPathComponent("survivor"))
            _ = try Scanner.scan(root: home, index: index, token: CancellationToken())
            let entry = try index.largestFiles().first!
            let results = TrashService(index: index, home: home).move(ids: [entry.id])
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[0].error, nil)
            if let destination = results[0].destination { try FileManager.default.removeItem(at: destination) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
            XCTAssertEqual(try index.entry(id: entry.id)?.id, nil)
            XCTAssertEqual(try index.entry(id: 1)?.logicalSize, 10)
            XCTAssertEqual(try index.entry(id: 1)?.allocatedSize, entry.allocatedSize)
            XCTAssertEqual(try index.largestFiles().count, 1)
        }
    }

    func testParentChildAndPartialFailure() throws {
        try CoreTests().withTree { rawHome, index in
            let home = try canonicalFileURL(rawHome)
            let folder = home.appendingPathComponent("MacEven-check-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("中文'%_\n")
            try Data([1,2,3]).write(to: file)
            let bad = home.appendingPathComponent("bad")
            try Data([1]).write(to: bad)
            _ = try Scanner.scan(root: home, index: index, token: CancellationToken())
            let parent = try index.children(of: 1).first { $0.isDirectory }!
            let child = try index.children(of: parent.id).first!
            let stale = try index.children(of: 1).first { $0.url.lastPathComponent == "bad" }!
            try FileManager.default.removeItem(at: bad)
            let result = TrashService(index: index, home: home).move(ids: [parent.id,child.id,stale.id])
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result.filter { $0.error == nil }.count, 1)
            for item in result { if let url = item.destination { try FileManager.default.removeItem(at: url) } }
            XCTAssertEqual(try index.entry(id: child.id)?.id, nil)
            XCTAssertEqual(try index.entry(id: stale.id)?.logicalSize, 1)
        }
    }
}
