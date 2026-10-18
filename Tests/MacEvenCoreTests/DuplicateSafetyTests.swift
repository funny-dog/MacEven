import Foundation
import MacEvenCore
import SQLite3

final class DuplicateSafetyTests {
    private func fixture(_ body: (URL, DiskIndex, DuplicateFiles) throws -> Void) throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("MacEven-duplicate-safety-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        defer { index.close(); try? fm.removeItem(at: home) }
        try body(home, index, DuplicateFiles(index: index, home: home))
    }
    func testPackageAncestorAndFailedRescan() throws {
        try fixture { home, _, service in
            let root = home.appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["a", "b"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
            _ = try service.scan(root: root, token: CancellationToken())
            XCTAssertTrue(service.isValid)
            XCTAssertThrowsError(try service.scan(root: home, token: CancellationToken()))
            XCTAssertFalse(service.isValid)
            let nestedPackage = home.appendingPathComponent("Tool.app/Contents/Data")
            try FileManager.default.createDirectory(at: nestedPackage, withIntermediateDirectories: true)
            XCTAssertThrowsError(try service.scan(root: nestedPackage, token: CancellationToken()))
        }
    }
    func testRetainedAncestorReplacement() throws {
        try fixture { home, _, service in
            let fm = FileManager.default, root = home.appendingPathComponent("Downloads")
            let outer = root.appendingPathComponent("KeeperRoot"), inner = outer.appendingPathComponent("Inner")
            try fm.createDirectory(at: inner, withIntermediateDirectories: true)
            let keeperURL = inner.appendingPathComponent("keep"), copyURL = root.appendingPathComponent("copy")
            try Data([7,8,9]).write(to: keeperURL); try Data([7,8,9]).write(to: copyURL)
            _ = try service.scan(root: root, token: CancellationToken())
            let group = try service.groups()[0], members = try service.members(groupID: group.id)
            let keeper = members.first { $0.name == "keep" }!, copy = members.first { $0.name == "copy" }!
            let oldOuter = root.appendingPathComponent("old-parent")
            try fm.moveItem(at: outer, to: oldOuter)
            try fm.createDirectory(at: outer, withIntermediateDirectories: true)
            try fm.moveItem(at: oldOuter.appendingPathComponent("Inner"), to: inner)
            XCTAssertEqual(try FileIdentity.read(keeperURL), keeper.identity)
            let result = service.move(groupID: group.id, keeperID: keeper.id, ids: [copy.id], token: CancellationToken())
            // Remove only this test's own trash even if the guard unexpectedly fails.
            for destination in result.compactMap(\.destination) { try? fm.removeItem(at: destination) }
            XCTAssertTrue(result.contains { $0.error != nil && $0.destination == nil })
            XCTAssertTrue(fm.fileExists(atPath: copyURL.path))
        }
    }
    func testDuplicateQueryCancellation() throws {
        try fixture { home, index, service in
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(index.url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            // Synthetic metadata keeps this SQL regression independent of file enumeration.
            let sql = """
                BEGIN;
                WITH RECURSIVE ids(id) AS (VALUES(1) UNION ALL SELECT id+1 FROM ids WHERE id<200000)
                INSERT INTO nodes(id,parent,path,device,inode,mode,size,modified,changed,blocks,ownLogical,ownAllocated,logical,allocated,duplicate) SELECT id,0,'/fixture/'||id,1,id,32768,128,0,0,4096,128,4096,128,4096,0 FROM ids;
                INSERT INTO duplicate_files(node_id,size,digest) SELECT id,128,zeroblob(32) FROM nodes;
                COMMIT;
                """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            let token = CancellationToken(), start = Date()
            XCTAssertFalse(token.isCancelled)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { token.cancel() }
            XCTAssertThrowsError(try service.groups(token: token))
            XCTAssertTrue(token.isCancelled)
            XCTAssertTrue(Date().timeIntervalSince(start) < 2)
            let group = try service.groups()[0]
            XCTAssertEqual(group.memberCount, 200000)
            let cancelled = CancellationToken(); cancelled.cancel()
            XCTAssertThrowsError(try service.members(groupID: group.id, offset: 150000, token: cancelled))
            XCTAssertEqual(try service.members(groupID: group.id, limit: 1).count, 1)
        }
    }

}
