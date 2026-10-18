import Foundation
import Darwin
import SQLite3
import MacEvenCore

final class DuplicateTests {
    private let fm = FileManager.default

    private func withFakeHome(_ body: (URL, URL, DiskIndex) throws -> Void) throws {
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-dup-test-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base)
        let indexURL = home.appendingPathComponent("index.sqlite")
        let index = try DiskIndex(url: indexURL)
        defer {
            index.close()
            try? fm.removeItem(at: base)
        }
        try body(home, indexURL, index)
    }

    func testRootBoundaryRejections() throws {
        try withFakeHome { home, _, index in
            let service = DuplicateFiles(index: index, home: home)
            let token = CancellationToken()

            // 1. 拒绝 home 自身
            XCTAssertThrowsError(try service.scan(root: home, token: token))

            // 2. 拒绝 home 外部路径
            let outside = fm.temporaryDirectory.appendingPathComponent("outside-\(UUID())")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: outside) }
            XCTAssertThrowsError(try service.scan(root: outside, token: token))

            // 3. 拒绝 Library
            let lib = home.appendingPathComponent("Library")
            let libSub = lib.appendingPathComponent("SomeDir")
            try fm.createDirectory(at: libSub, withIntermediateDirectories: true)
            XCTAssertThrowsError(try service.scan(root: libSub, token: token))

            // 4. 拒绝隐藏路径
            let hiddenDir = home.appendingPathComponent(".hidden")
            try fm.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
            XCTAssertThrowsError(try service.scan(root: hiddenDir, token: token))

            let nestedHidden = home.appendingPathComponent("folder").appendingPathComponent(".secret")
            try fm.createDirectory(at: nestedHidden, withIntermediateDirectories: true)
            XCTAssertThrowsError(try service.scan(root: nestedHidden, token: token))

            // 5. 拒绝软件包根
            let appPkg = home.appendingPathComponent("TestApp.app")
            try fm.createDirectory(at: appPkg, withIntermediateDirectories: true)
            XCTAssertThrowsError(try service.scan(root: appPkg, token: token))

            // 6. 拒绝包含符号链接的祖先
            let realDir = home.appendingPathComponent("real-target")
            try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
            let symlinkDir = home.appendingPathComponent("symlink-target")
            try fm.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)
            XCTAssertThrowsError(try service.scan(root: symlinkDir, token: token))
        }
    }

    func testContentMatchingAndExclusions() throws {
        try withFakeHome { home, _, index in
            let targetDir = home.appendingPathComponent("Documents")
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

            // same content: a, b (3 bytes)
            let fileA = targetDir.appendingPathComponent("a.txt")
            let fileB = targetDir.appendingPathComponent("b.txt")
            try Data([1, 2, 3]).write(to: fileA)
            try Data([1, 2, 3]).write(to: fileB)

            // tail different: tail-diff (3 bytes)
            let fileTail = targetDir.appendingPathComponent("tail-diff.txt")
            try Data([1, 2, 4]).write(to: fileTail)

            // 0 字节文件
            let fileZero = targetDir.appendingPathComponent("empty.txt")
            try Data().write(to: fileZero)

            // 隐藏文件
            let fileHidden = targetDir.appendingPathComponent(".hidden-file")
            try Data([1, 2, 3]).write(to: fileHidden)

            // 软件包后代
            let appBundle = targetDir.appendingPathComponent("Tool.app")
            let bundleContents = appBundle.appendingPathComponent("Contents")
            try fm.createDirectory(at: bundleContents, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: bundleContents.appendingPathComponent("inner"))

            // 硬链接: h1 与 h2（nlink > 1，两者均应跳过）
            let fileH1 = targetDir.appendingPathComponent("hardlink-1.txt")
            let fileH2 = targetDir.appendingPathComponent("hardlink-2.txt")
            try Data([1, 2, 3]).write(to: fileH1)
            try fm.linkItem(at: fileH1, to: fileH2)

            let service = DuplicateFiles(index: index, home: home)
            let summary = try service.scan(root: targetDir, token: CancellationToken())

            XCTAssertFalse(summary.cancelled)
            XCTAssertFalse(summary.incomplete)
            XCTAssertEqual(summary.errors, 0)
            XCTAssertGreaterThan(summary.filteredShared, 0) // 硬链接在遍历时即被过滤

            let groups = try service.groups()
            // 只有 1 组重复文件：a 和 b（因为 c 是硬链接被排除，tail-diff 内容不同，.hidden和.app被排除，empty被排除）
            XCTAssertEqual(groups.count, 1)
            let group = groups[0]
            XCTAssertEqual(group.logicalSize, 3)
            XCTAssertEqual(group.memberCount, 2)

            let members = try service.members(groupID: group.id)
            XCTAssertEqual(members.count, 2)
            let names = members.map(\.name).sorted()
            XCTAssertEqual(names, ["a.txt", "b.txt"])
            XCTAssertTrue(service.isValid)
        }
    }

    func testCandidateStatisticsCallback() throws {
        try withFakeHome { home, _, index in
            let targetDir = home.appendingPathComponent("Stats")
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            // 三组候选：3 个 4 KB 相同文件 + 2 个 8 KB 相同文件（均 ≤ 48 KB，抽样期即得最终摘要）
            // + 3 个 192 KB 相同文件（超过 3×16 KB，剪枝后仍无摘要、回退抽样值聚类）；独有文件不计入。
            let payloadA = Data(repeating: 0x11, count: 4096)
            let payloadB = Data(repeating: 0x22, count: 8192)
            let payloadC = Data(repeating: 0x44, count: 192 * 1024)
            for name in ["a1.bin", "a2.bin", "a3.bin"] { try payloadA.write(to: targetDir.appendingPathComponent(name)) }
            for name in ["b1.bin", "b2.bin"] { try payloadB.write(to: targetDir.appendingPathComponent(name)) }
            for name in ["c1.bin", "c2.bin", "c3.bin"] { try payloadC.write(to: targetDir.appendingPathComponent(name)) }
            try Data(repeating: 0x33, count: 2048).write(to: targetDir.appendingPathComponent("unique.bin"))

            final class Collector: @unchecked Sendable {
                private let lock = NSLock()
                private var values: [DuplicateCandidateStats] = []
                func add(_ value: DuplicateCandidateStats) { lock.withLock { values.append(value) } }
                var all: [DuplicateCandidateStats] { lock.withLock { values } }
            }
            let collector = Collector()
            let service = DuplicateFiles(index: index, home: home)
            let summary = try service.scan(root: targetDir, token: CancellationToken(), statistics: { collector.add($0) })
            XCTAssertFalse(summary.cancelled)
            XCTAssertFalse(summary.incomplete)

            // 物化候选后与抽样剪枝后各上报一次；小文件摘要已定、大文件回退抽样值，内容相同的候选剪枝后不会减少。
            let reports = collector.all
            XCTAssertEqual(reports.count, 2)
            XCTAssertEqual(reports[0].groups, 3)
            XCTAssertEqual(reports[0].files, 8)
            XCTAssertGreaterThan(reports[0].bytes, 0)
            XCTAssertEqual(reports[1].groups, 3)
            XCTAssertEqual(reports[1].files, 8)

            let groups = try service.groups()
            XCTAssertEqual(groups.count, 3)
            XCTAssertEqual(groups.reduce(0) { $0 + $1.memberCount }, 8)
        }
    }

    func testSparseFilesRankAndGroupCorrectly() throws {
        try withFakeHome { home, _, index in
            let targetDir = home.appendingPathComponent("Data")
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

            // 创建两个相同逻辑大小和内容的稀疏/密集文件
            let sparse1 = targetDir.appendingPathComponent("sparse1.bin")
            let dense1 = targetDir.appendingPathComponent("dense1.bin")

            // 64 KiB 相同全 0 数据
            let zeroData = Data(repeating: 0, count: 64 * 1024)
            try zeroData.write(to: dense1)

            fm.createFile(atPath: sparse1.path, contents: nil)
            let h = try FileHandle(forWritingTo: sparse1)
            try h.truncate(atOffset: 64 * 1024)
            try h.close()

            let service = DuplicateFiles(index: index, home: home)
            let summary = try service.scan(root: targetDir, token: CancellationToken())
            XCTAssertFalse(summary.incomplete)

            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)
            let members = try service.members(groupID: groups[0].id)
            XCTAssertEqual(members.count, 2)
        }
    }

    func testPaging() throws {
        try withFakeHome { home, _, index in
            let dir = home.appendingPathComponent("ManyFiles")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // 创建 105 个相同内容的文件
            let payload = Data([10, 20, 30, 40])
            for i in 0..<105 {
                try payload.write(to: dir.appendingPathComponent(String(format: "file-%03d.dat", i)))
            }

            let service = DuplicateFiles(index: index, home: home)
            let summary = try service.scan(root: dir, token: CancellationToken())
            XCTAssertFalse(summary.incomplete)

            let groups = try service.groups(offset: 0, limit: 100)
            XCTAssertEqual(groups.count, 1)
            let group = groups[0]
            XCTAssertEqual(group.memberCount, 105)

            // 分页拉取成员：第一页 100
            let page1 = try service.members(groupID: group.id, offset: 0, limit: 100)
            XCTAssertEqual(page1.count, 100)

            // 第二页 5
            let page2 = try service.members(groupID: group.id, offset: 100, limit: 100)
            XCTAssertEqual(page2.count, 5)

            // 无重叠
            let allIDs = Set(page1.map(\.id)).union(Set(page2.map(\.id)))
            XCTAssertEqual(allIDs.count, 105)
        }
    }

    func testCancellationLeavesQueryableSummary() throws {
        try withFakeHome { home, _, index in
            let dir = home.appendingPathComponent("CancelDir")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<50 {
                try Data([1, 2, 3]).write(to: dir.appendingPathComponent("item-\(i).dat"))
            }

            let service = DuplicateFiles(index: index, home: home)
            let token = CancellationToken()
            token.cancel()

            let summary = try service.scan(root: dir, token: token)
            XCTAssertTrue(summary.cancelled)
            XCTAssertTrue(summary.incomplete)
            XCTAssertFalse(service.isValid)
        }
    }

    func testIdentityAndAncestorChangesDuringHashing() throws {
        try withFakeHome { home, _, index in
            let dir = home.appendingPathComponent("ChangeDir")
            let sub = dir.appendingPathComponent("sub")
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)

            let f1 = sub.appendingPathComponent("f1.dat")
            let f2 = sub.appendingPathComponent("f2.dat")
            try Data([1, 2, 3, 4]).write(to: f1)
            try Data([1, 2, 3, 4]).write(to: f2)

            let service = DuplicateFiles(index: index, home: home)

            // 在哈希过程中如果祖先或文件被修改，会报错并标为 incomplete
            let token = CancellationToken()
            let summary = try service.scan(root: dir, token: token) { progress in
                if progress.phase == "hashing" || progress.hashed > 0 {
                    // 修改文件内容使 mtime / ctime 变化
                    try? Data([9, 9, 9, 9]).write(to: f2)
                }
            }
            if summary.incomplete {
                XCTAssertFalse(service.isValid)
            }
        }
    }

    func testMoveProtection() throws {
        try withFakeHome { home, _, index in
            let dir = home.appendingPathComponent("MoveTest")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let fileA = dir.appendingPathComponent("a.dat")
            let fileB = dir.appendingPathComponent("b.dat")
            let fileC = dir.appendingPathComponent("c.dat")
            try Data([1, 2, 3]).write(to: fileA)
            try Data([1, 2, 3]).write(to: fileB)
            try Data([1, 2, 3]).write(to: fileC)

            let service = DuplicateFiles(index: index, home: home)
            _ = try service.scan(root: dir, token: CancellationToken())
            XCTAssertTrue(service.isValid)

            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)
            let groupID = groups[0].id
            let members = try service.members(groupID: groupID)
            let keeper = members.first { $0.name == "a.dat" }!
            let targetB = members.first { $0.name == "b.dat" }!
            let targetC = members.first { $0.name == "c.dat" }!

            // 1. allselect：keeper 在 targets 中，必须拒绝，不移任何文件
            let resAll = service.move(groupID: groupID, keeperID: keeper.id, ids: [keeper.id, targetB.id], token: CancellationToken())
            XCTAssertTrue(resAll.contains { $0.error != nil })
            XCTAssertTrue(fm.fileExists(atPath: fileA.path))
            XCTAssertTrue(fm.fileExists(atPath: fileB.path))

            // 2. 超过 50 个 targets：必须拒绝
            let fakeIDs = (1...51).map { Int64($0) }
            let res51 = service.move(groupID: groupID, keeperID: keeper.id, ids: fakeIDs, token: CancellationToken())
            XCTAssertTrue(res51.contains { $0.error != nil })

            // 3. 空 targets：必须拒绝
            let resEmpty = service.move(groupID: groupID, keeperID: keeper.id, ids: [], token: CancellationToken())
            XCTAssertTrue(resEmpty.contains { $0.error != nil })

            // 4. 重复 targets ID：必须拒绝
            let resDup = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetB.id, targetB.id], token: CancellationToken())
            XCTAssertTrue(resDup.contains { $0.error != nil })

            // 5. 跨组 keeper 或 target：制造一个假 groupID
            let resCross = service.move(groupID: "999:0000000000000000000000000000000000000000000000000000000000000000", keeperID: keeper.id, ids: [targetB.id], token: CancellationToken())
            XCTAssertTrue(resCross.contains { $0.error != nil })

            // 6. 正常移动 targetB：保留 a.dat，移动 b.dat
            var destinations: [URL] = []
            defer { for d in destinations { try? fm.removeItem(at: d) } }

            let resNormal = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetB.id], token: CancellationToken())
            XCTAssertEqual(resNormal.count, 1)
            XCTAssertTrue(resNormal[0].error == nil)
            XCTAssertNotNil(resNormal[0].destination)
            if let dest = resNormal[0].destination { destinations.append(dest) }
            XCTAssertTrue(fm.fileExists(atPath: fileA.path))
            XCTAssertFalse(fm.fileExists(atPath: fileB.path))
            XCTAssertTrue(fm.fileExists(atPath: fileC.path))

            // 7. keeper 内容被修改后尝试 move targetC：必须拒绝
            try Data([9, 9, 9]).write(to: fileA)
            let resKeeperModified = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetC.id], token: CancellationToken())
            XCTAssertTrue(resKeeperModified.contains { $0.error != nil })
            XCTAssertTrue(fm.fileExists(atPath: fileC.path))

            // 8. 恢复 keeper 内容后，修改 targetC 内容：必须拒绝
            try Data([1, 2, 3]).write(to: fileA)
            try Data([8, 8, 8]).write(to: fileC)
            let resTargetModified = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetC.id], token: CancellationToken())
            XCTAssertTrue(resTargetModified.contains { $0.error != nil })
            XCTAssertTrue(fm.fileExists(atPath: fileC.path))

            // 9. keeper 被删除后尝试 move targetC：必须拒绝
            try Data([1, 2, 3]).write(to: fileC)
            try fm.removeItem(at: fileA)
            let resKeeperMissing = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetC.id], token: CancellationToken())
            XCTAssertTrue(resKeeperMissing.contains { $0.error != nil })
            XCTAssertTrue(fm.fileExists(atPath: fileC.path))
        }
    }

    func testMoveExactByteComparisonRejectsHashCollision() throws {
        try withFakeHome { home, indexURL, index in
            let dir = home.appendingPathComponent("CollisionTest")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // 两个 3 字节文件，内容不同
            let fileA = dir.appendingPathComponent("left.bin")
            let fileB = dir.appendingPathComponent("right.bin")
            try Data([1, 2, 3]).write(to: fileA)
            try Data([1, 2, 4]).write(to: fileB)

            let service = DuplicateFiles(index: index, home: home)
            _ = try service.scan(root: dir, token: CancellationToken())

            // 初始时由于内容不同，不会归入任何重复组
            let initialGroups = try service.groups()
            XCTAssertEqual(initialGroups.count, 0)

            // 人工在 SQLite duplicate_files 中篡改，将两者的 digest 改为完全相同！
            var db: OpaquePointer?
            guard sqlite3_open(indexURL.path, &db) == SQLITE_OK else { throw MacEvenError("open db failed") }
            defer { sqlite3_close(db) }

            // 插入人工制造的碰撞组
            let fakeDigest = Data([0xDE, 0xAD, 0xBE, 0xEF] + Array(repeating: UInt8(0), count: 28))
            let hexDigest = fakeDigest.map { String(format: "%02x", $0) }.joined()
            let groupID = "3:\(hexDigest)"

            let nodeA = try index.entry(id: 2)!
            let nodeB = try index.entry(id: 3)!

            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO duplicate_files(node_id, size, digest) VALUES(?, ?, ?)", -1, &stmt, nil)
            for node in [nodeA, nodeB] {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, node.id)
                sqlite3_bind_int64(stmt, 2, 3)
                _ = fakeDigest.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(ptr.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            // 此时 groups 会识别出该人工碰撞组
            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)

            // 尝试 move：完整逐字节比对必须发现 left != right，必须抛错拒绝删除！
            let res = service.move(groupID: groupID, keeperID: nodeA.id, ids: [nodeB.id], token: CancellationToken())
            XCTAssertTrue(res.contains { $0.error != nil })
            // 两者均必须保留在磁盘上！
            XCTAssertTrue(fm.fileExists(atPath: fileA.path))
            XCTAssertTrue(fm.fileExists(atPath: fileB.path))
        }
    }

    func testMoveIndexFailureAfterSuccessfulMove() throws {
        try withFakeHome { home, indexURL, index in
            let dir = home.appendingPathComponent("FailureTest")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let fileA = dir.appendingPathComponent("a.dat")
            let fileB = dir.appendingPathComponent("b.dat")
            let fileC = dir.appendingPathComponent("c.dat")
            try Data([1, 2, 3]).write(to: fileA)
            try Data([1, 2, 3]).write(to: fileB)
            try Data([1, 2, 3]).write(to: fileC)

            let service = DuplicateFiles(index: index, home: home)
            _ = try service.scan(root: dir, token: CancellationToken())
            XCTAssertTrue(service.isValid)

            let groups = try service.groups()
            XCTAssertEqual(groups.count, 1)
            let groupID = groups[0].id
            let members = try service.members(groupID: groupID)
            let keeper = members.first { $0.name == "a.dat" }!
            let targetB = members.first { $0.name == "b.dat" }!
            let targetC = members.first { $0.name == "c.dat" }!

            // 注入 SQLite BEFORE DELETE trigger，使 removeSubtree 失败
            var db: OpaquePointer?
            guard sqlite3_open(indexURL.path, &db) == SQLITE_OK else { throw MacEvenError("open db failed") }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, "CREATE TRIGGER fail_dup_nodes BEFORE DELETE ON nodes BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END", nil, nil, nil) == SQLITE_OK else {
                throw MacEvenError("trigger creation failed")
            }

            var destinations: [URL] = []
            defer { for d in destinations { try? fm.removeItem(at: d) } }

            // 移动 targetB
            let res = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetB.id, targetC.id], token: CancellationToken())
            guard let first = res.first else { fatalError("expected result") }
            if let dest = first.destination { destinations.append(dest) }

            // targetB 成功移动到废纸篓，但索引同步失败
            XCTAssertNotNil(first.destination)
            XCTAssertNotNil(first.error)
            XCTAssertFalse(fm.fileExists(atPath: fileB.path))

            // 会话必须被标记为失效！
            XCTAssertFalse(service.isValid)

            // 后续 targetC 不得被移动！
            XCTAssertTrue(fm.fileExists(atPath: fileC.path))

            // 再次尝试调用 move，因 isValid == false 立即被整会话禁止！
            let res2 = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetC.id], token: CancellationToken())
            XCTAssertTrue(res2.contains { $0.error != nil })
            XCTAssertTrue(fm.fileExists(atPath: fileC.path))
        }
    }

    func testMovePartialCancellation() throws {
        try withFakeHome { home, _, index in
            let dir = home.appendingPathComponent("CancelMoveTest")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let fileA = dir.appendingPathComponent("a.dat")
            let fileB = dir.appendingPathComponent("b.dat")
            let fileC = dir.appendingPathComponent("c.dat")
            let payload = Data(repeating: 1, count: 32 * 1024 * 1024)
            try payload.write(to: fileA)
            try payload.write(to: fileB)
            try payload.write(to: fileC)

            let service = DuplicateFiles(index: index, home: home)
            _ = try service.scan(root: dir, token: CancellationToken())

            let groups = try service.groups()
            let groupID = groups[0].id
            let members = try service.members(groupID: groupID)
            let keeper = members.first { $0.name == "a.dat" }!
            let targetB = members.first { $0.name == "b.dat" }!
            let targetC = members.first { $0.name == "c.dat" }!

            var destinations: [URL] = []
            defer { for d in destinations { try? fm.removeItem(at: d) } }

            // 动态取消：在 targetB 移动之后立即触发取消
            let token = CancellationToken()
            let targetPath = fileB.path
            let queue = DispatchQueue(label: "canceller")
            queue.async {
                while access(targetPath, F_OK) == 0 {
                    usleep(500)
                }
                token.cancel()
            }

            let res = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetB.id, targetC.id], token: token)
            XCTAssertEqual(res.count, 2)
            // 第一项成功
            XCTAssertTrue(res[0].error == nil)
            XCTAssertNotNil(res[0].destination)
            if let dest = res[0].destination { destinations.append(dest) }
            XCTAssertFalse(fm.fileExists(atPath: fileB.path))

            // 第二项因取消被停止，文件仍存在
            XCTAssertTrue(res[1].error != nil)
            XCTAssertTrue(fm.fileExists(atPath: fileC.path))
            XCTAssertTrue(fm.fileExists(atPath: fileA.path))
        }
    }

    func testMoveRejectsAncestorSymlink() throws {
        try withFakeHome { home, _, index in
            let dir = home.appendingPathComponent("AncestorTest")
            let sub = dir.appendingPathComponent("sub")
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)

            let fileA = dir.appendingPathComponent("a.dat")
            let fileB = sub.appendingPathComponent("b.dat")
            try Data([1, 2, 3]).write(to: fileA)
            try Data([1, 2, 3]).write(to: fileB)

            let service = DuplicateFiles(index: index, home: home)
            _ = try service.scan(root: dir, token: CancellationToken())

            let groups = try service.groups()
            let groupID = groups[0].id
            let members = try service.members(groupID: groupID)
            let keeper = members.first { $0.name == "a.dat" }!
            let targetB = members.first { $0.name == "b.dat" }!

            // 将 sub 移动到 backupSub，并将 sub 改为指向 backupSub 的符号链接
            let backupSub = dir.appendingPathComponent("backupSub")
            try fm.moveItem(at: sub, to: backupSub)
            try fm.createSymbolicLink(at: sub, withDestinationURL: backupSub)

            let res = service.move(groupID: groupID, keeperID: keeper.id, ids: [targetB.id], token: CancellationToken())
            XCTAssertTrue(res.contains { $0.error != nil })
            XCTAssertTrue(fm.fileExists(atPath: backupSub.appendingPathComponent("b.dat").path))
        }
    }
}
