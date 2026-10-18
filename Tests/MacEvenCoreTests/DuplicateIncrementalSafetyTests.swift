import Foundation
import Darwin
@testable import MacEvenCore
import SQLite3

final class DuplicateIncrementalSafetyTests {
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func fixture(_ body: (URL, URL, DiskIndex, DuplicateFiles) throws -> Void) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-inc-safety-\(UUID())")
        let dbDir = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-inc-safety-db-\(UUID())")
        let homeDir = base.appendingPathComponent("home")
        try fm.createDirectory(at: homeDir.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let home = try canonicalFileURL(homeDir)
        let folder = home.appendingPathComponent("Documents")
        let indexURL = dbDir.appendingPathComponent("index.sqlite")
        let index = try DiskIndex(url: indexURL)
        let service = DuplicateFiles(index: index, home: home)
        defer {
            index.close()
            try? fm.removeItem(at: base)
            try? fm.removeItem(at: dbDir)
        }
        try body(home, folder, index, service)
    }

    func run() throws {
        try testMtimeRestoreInvalidation()
        try testSampleCacheNotFinalDigest()
        try testMoveByteRejectionAfterCacheHit()
        try testCancelledScanForcesFullTraversal()
        try testPermissionRevokeRestoreBaselineIntegrity()
    }

    /// 1 同大小文件修改且恢复 mtime，ctime 改变仍失效，不错误成组
    func testMtimeRestoreInvalidation() throws {
        try fixture { home, folder, index, service in
            let fileA = folder.appendingPathComponent("mtime_a.bin")
            let fileB = folder.appendingPathComponent("mtime_b.bin")
            let payload = Data((0..<64_000).map { UInt8(truncatingIfNeeded: $0 &* 37) })
            try payload.write(to: fileA)
            try payload.write(to: fileB)

            let firstSummary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertFalse(firstSummary.incomplete)
            let initialGroups = try service.groups()
            XCTAssertEqual(initialGroups.count, 1)

            let statBBefore = try FileIdentity.read(fileB)
            let oldMtime = statBBefore.modified

            // 修改 fileB 内容，但大小保持一致
            var modifiedPayload = payload
            for i in 1000..<2000 {
                modifiedPayload[i] ^= 0xff
            }
            try modifiedPayload.write(to: fileB)

            // 强行恢复 fileB 的 mtime 到修改前的精确数值（保留纳秒精度）
            var times = [
                timespec(tv_sec: Int(oldMtime / 1_000_000_000), tv_nsec: Int(oldMtime % 1_000_000_000)),
                timespec(tv_sec: Int(oldMtime / 1_000_000_000), tv_nsec: Int(oldMtime % 1_000_000_000))
            ]
            XCTAssertEqual(utimensat(AT_FDCWD, fileB.path, &times, 0), 0)

            let statBAfter = try FileIdentity.read(fileB)
            XCTAssertEqual(statBAfter.modified, oldMtime)
            XCTAssertGreaterThan(statBAfter.changed, statBBefore.changed)

            Thread.sleep(forTimeInterval: 0.1)

            let secondSummary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertFalse(secondSummary.incomplete)

            let groupsAfter = try service.groups()
            XCTAssertTrue(groupsAfter.isEmpty, "修改内容并恢复 mtime 后，ctime 改变应使缓存失效，两不同文件不应成组")
        }
    }

    /// 2 只缓存 sample 的大文件次轮新加入同 sample 但未抽样部分不同的候选，不能当作最终摘要
    func testSampleCacheNotFinalDigest() throws {
        try fixture { home, folder, index, service in
            let fm = FileManager.default
            let fileA = folder.appendingPathComponent("large_a.bin")
            let fileB = folder.appendingPathComponent("large_b.bin")
            let size = 120_000 // 大于 3 * 16KB

            let dataA = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 19) })
            let dataB = Data((0..<size).map { UInt8(truncatingIfNeeded: ($0 &* 19) ^ 0xaa) })
            try dataA.write(to: fileA)
            try dataB.write(to: fileB)

            let firstSummary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertFalse(firstSummary.incomplete)
            XCTAssertTrue(try service.groups().isEmpty)

            // 验证 fileA 确实在 duplicate_hash_cache 中且 digest 为 NULL
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(index.url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT sample, digest FROM duplicate_hash_cache WHERE path = ?", -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_text(stmt, 1, fileA.path, -1, transient)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_bytes(stmt, 0), 32)
            XCTAssertEqual(sqlite3_column_type(stmt, 1), SQLITE_NULL)
            sqlite3_finalize(stmt)

            // 删除 fileB，添加 fileC（sample 相同但未抽样部分不同）
            try fm.removeItem(at: fileB)
            let fileC = folder.appendingPathComponent("large_c.bin")
            var dataC = dataA
            for i in 25_000..<30_000 {
                dataC[i] ^= 0x55
            }
            try dataC.write(to: fileC)

            Thread.sleep(forTimeInterval: 0.1)

            let secondSummary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertFalse(secondSummary.incomplete)

            let groups = try service.groups()
            XCTAssertTrue(groups.isEmpty, "只缓存 sample 的大文件不能将 sample 当作最终摘要，不同内容不可成组")
        }
    }

    /// 3 缓存命中后的 move 仍逐字节拒绝：用 SQLite3 把 duplicate_hash_cache 中不同内容的 digest/sample 改成相同 32-byte 值并重新扫描形成候选，move 必须拒绝而文件保留
    func testMoveByteRejectionAfterCacheHit() throws {
        try fixture { home, folder, index, service in
            let fm = FileManager.default
            let fileA = folder.appendingPathComponent("diff_a.bin")
            let fileB = folder.appendingPathComponent("diff_b.bin")
            let size = 16_000
            let dataA = Data(repeating: 0x11, count: size)
            let dataB = Data(repeating: 0x22, count: size)
            try dataA.write(to: fileA)
            try dataB.write(to: fileB)

            _ = try service.scan(root: folder, token: CancellationToken())
            XCTAssertTrue(try service.groups().isEmpty)

            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(index.url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let fakeHash = Data(repeating: 0x77, count: 32)
            var stmt: OpaquePointer?
            let updateSQL = "UPDATE duplicate_hash_cache SET sample = ?, digest = ? WHERE path = ?"
            XCTAssertEqual(sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }

            for file in [fileA, fileB] {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                fakeHash.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, 1, raw.baseAddress, 32, transient)
                    sqlite3_bind_blob(stmt, 2, raw.baseAddress, 32, transient)
                }
                sqlite3_bind_text(stmt, 3, file.path, -1, transient)
                XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            }

            try index.invalidateDuplicateBaseline()

            let summary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertFalse(summary.incomplete)
            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)

            let members = try service.members(groupID: groups[0].id)
            XCTAssertEqual(members.count, 2)
            guard let keeper = members.first(where: { $0.url.path == fileA.path }),
                  let target = members.first(where: { $0.url.path == fileB.path }) else {
                requireTest(false, "未能从候选组找到对应成员")
                return
            }

            let results = service.move(groupID: groups[0].id, keeperID: keeper.id, ids: [target.id], token: CancellationToken())
            XCTAssertEqual(results.count, 1)
            let result = results[0]
            XCTAssertTrue(result.destination == nil, "内容不同时 move 绝不能移动到废纸篓")
            XCTAssertNotNil(result.error, "逐字节比对失败应报错")
            XCTAssertTrue(result.error?.contains("内容不一致") == true || result.error?.contains("拒绝") == true)

            XCTAssertTrue(fm.fileExists(atPath: fileA.path), "保留项文件必须存在")
            XCTAssertTrue(fm.fileExists(atPath: fileB.path), "被拒绝的目标文件必须保留")
            XCTAssertEqual(try Data(contentsOf: fileA), dataA)
            XCTAssertEqual(try Data(contentsOf: fileB), dataB)
        }
    }

    /// 4 已取消扫描后下一轮必须完整遍历并与新文件一致
    func testCancelledScanForcesFullTraversal() throws {
        try fixture { home, folder, index, service in
            let file1 = folder.appendingPathComponent("cancel_f1.bin")
            let file2 = folder.appendingPathComponent("cancel_f2.bin")
            let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 11) })
            try payload.write(to: file1)
            try payload.write(to: file2)

            let token = CancellationToken()
            token.cancel()
            let cancelledSummary = try service.scan(root: folder, token: token)
            XCTAssertTrue(cancelledSummary.cancelled)
            XCTAssertTrue(cancelledSummary.incomplete)
            XCTAssertFalse(service.isValid)

            let file3 = folder.appendingPathComponent("cancel_f3.bin")
            try payload.write(to: file3)

            let nextSummary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertFalse(nextSummary.cancelled)
            XCTAssertFalse(nextSummary.incomplete)
            XCTAssertTrue(service.isValid)
            XCTAssertFalse(nextSummary.incremental, "已取消后下一轮扫描必须为完整遍历，不可走增量")

            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)
            let members = try service.members(groupID: groups[0].id)
            XCTAssertEqual(members.count, 3)
            let names = Set(members.map(\.name))
            XCTAssertEqual(names, ["cancel_f1.bin", "cancel_f2.bin", "cancel_f3.bin"])
        }
    }

    /// 5 权限撤销/恢复不会保留旧重复组或错误推进基线
    func testPermissionRevokeRestoreBaselineIntegrity() throws {
        try fixture { home, folder, index, service in
            let fm = FileManager.default
            let sub = folder.appendingPathComponent("restricted")
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            defer {
                chmod(sub.path, 0o755)
            }

            let file1 = sub.appendingPathComponent("perm1.bin")
            let file2 = sub.appendingPathComponent("perm2.bin")
            let payload = Data((0..<15_000).map { UInt8(truncatingIfNeeded: $0 &* 23) })
            try payload.write(to: file1)
            try payload.write(to: file2)
            Thread.sleep(forTimeInterval: 0.2)

            let firstSummary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertFalse(firstSummary.incomplete)
            XCTAssertEqual(firstSummary.errors, 0)
            XCTAssertEqual(try service.groups().count, 1)
            XCTAssertNotNil(try index.duplicateBaseline())

            XCTAssertEqual(chmod(sub.path, 0o000), 0)

            let errorSummary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertGreaterThan(errorSummary.errors, 0)

            let groupsAfterRevoke = try service.groups()
            XCTAssertTrue(groupsAfterRevoke.isEmpty, "权限撤销后不可保留旧重复组")

            let baselineAfterRevoke = try index.duplicateBaseline()
            XCTAssertTrue(baselineAfterRevoke == nil, "权限受限/存在扫描错误时不应保存或推进基线")

            XCTAssertEqual(chmod(sub.path, 0o755), 0)
            Thread.sleep(forTimeInterval: 0.1)

            let restoredSummary = try service.scan(root: folder, token: CancellationToken())
            XCTAssertFalse(restoredSummary.incomplete)
            XCTAssertEqual(restoredSummary.errors, 0)

            let restoredGroups = try service.groups()
            XCTAssertEqual(restoredGroups.count, 1)
            let restoredMembers = try service.members(groupID: restoredGroups[0].id)
            XCTAssertEqual(restoredMembers.count, 2)
            XCTAssertEqual(Set(restoredMembers.map(\.name)), ["perm1.bin", "perm2.bin"])
            XCTAssertNotNil(try index.duplicateBaseline(), "权限恢复且扫描成功后应建立有效基线")
        }
    }
}
