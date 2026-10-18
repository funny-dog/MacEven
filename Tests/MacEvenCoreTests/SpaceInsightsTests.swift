import Foundation
import MacEvenCore
import SQLite3

final class SpaceInsightsTests {
    func withTree(_ body: (URL, DiskIndex) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-space-insights-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try DiskIndex(url: root.appendingPathComponent("index.sqlite"))
        try body(root, index)
    }

    func testCategoryClassification() {
        // Spec 7 类映射与扩展名大小写
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "A.MP4")), .video)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "movie.MOV")), .video)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "photo.jpg")), .image)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "PHOTO.JPEG")), .image)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "image.png")), .image)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "vector.svg")), .image)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "track.mp3")), .audio)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "song.FLAC")), .audio)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "paper.pdf")), .document)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "notes.md")), .document)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "archive.zip")), .archive)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "bundle.tar.gz")), .archive)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "disk.dmg")), .archive)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "main.swift")), .source)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "script.py")), .source)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "config.yaml")), .source)

        // 无扩展名或未知扩展名 -> other
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "LICENSE")), .other)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "Makefile")), .other)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "unknown.xyz123")), .other)
        XCTAssertEqual(FileCategory.classify(URL(fileURLWithPath: "")), .other)
    }

    func testSpaceFilterValidation() throws {
        // 非法参数测试：负数或 min > max 必须 throws
        XCTAssertThrowsError(try SpaceFilter(minAllocated: -1))
        XCTAssertThrowsError(try SpaceFilter(maxAllocated: -10))
        XCTAssertThrowsError(try SpaceFilter(notModifiedSince: -5))
        XCTAssertThrowsError(try SpaceFilter(minAllocated: 500, maxAllocated: 100))

        // 正常参数构造
        let filter1 = try SpaceFilter()
        XCTAssertEqual(filter1.category, nil)
        XCTAssertEqual(filter1.minAllocated, nil)
        XCTAssertEqual(filter1.maxAllocated, nil)
        XCTAssertEqual(filter1.notModifiedSince, nil)

        let filter2 = try SpaceFilter(category: .video, minAllocated: 100, maxAllocated: 500, notModifiedSince: 1_000_000)
        XCTAssertEqual(filter2.category, .video)
        XCTAssertEqual(filter2.minAllocated, 100)
        XCTAssertEqual(filter2.maxAllocated, 500)
        XCTAssertEqual(filter2.notModifiedSince, 1_000_000)

        // min == max 合法
        _ = try SpaceFilter(minAllocated: 100, maxAllocated: 100)
    }

    func testDirectoryBoundaryAndScope() throws {
        try withTree { root, index in
            let fm = FileManager.default
            let downloads = root.appendingPathComponent("Downloads")
            let downloadsBackup = root.appendingPathComponent("Downloads-backup")
            let downloads2 = root.appendingPathComponent("Downloads2")
            let downloadsBak = root.appendingPathComponent("Downloads_bak")
            let specialDir = root.appendingPathComponent("下载'测试%目录_特殊")

            for dir in [downloads, downloadsBackup, downloads2, downloadsBak, specialDir] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            // 在 Downloads 放入文件
            try Data([1, 2, 3]).write(to: downloads.appendingPathComponent("test.pdf"))
            let subDownloads = downloads.appendingPathComponent("sub")
            try fm.createDirectory(at: subDownloads, withIntermediateDirectories: true)
            try Data([4, 5]).write(to: subDownloads.appendingPathComponent("sub.mp4"))

            // 在兄弟目录放入文件
            try Data([6, 7]).write(to: downloadsBackup.appendingPathComponent("backup.pdf"))
            try Data([8]).write(to: downloads2.appendingPathComponent("two.pdf"))
            try Data([9]).write(to: downloadsBak.appendingPathComponent("bak.pdf"))

            // 在特殊目录放入文件
            try Data([10]).write(to: specialDir.appendingPathComponent("special'file%1.swift"))

            let summary = try Scanner.scan(root: root, index: index, token: CancellationToken())
            XCTAssertFalse(summary.cancelled)

            // 获取 Downloads 节点的 ID
            let children = try index.children(of: 1, offset: 0, limit: 100)
            guard let dlEntry = children.first(where: { $0.url.lastPathComponent == "Downloads" }) else {
                XCTFail("Downloads folder not found")
                return
            }

            // 测试 Downloads 统计
            let stats = try index.spaceStats(directoryID: dlEntry.id, token: CancellationToken())
            XCTAssertEqual(stats.count, 7)
            let docStat = stats.first(where: { $0.category == .document })!
            let videoStat = stats.first(where: { $0.category == .video })!
            let otherStats = stats.filter { $0.category != .document && $0.category != .video }
            XCTAssertEqual(docStat.count, 1)
            XCTAssertEqual(videoStat.count, 1)
            for s in otherStats {
                XCTAssertEqual(s.count, 0)
            }

            // 测试 Downloads 分页查询：不应包含 downloads-backup、downloads2 等兄弟目录
            let page = try index.spacePage(directoryID: dlEntry.id, filter: try SpaceFilter(), offset: 0, limit: 100, token: CancellationToken())
            XCTAssertEqual(page.totalCount, 2)
            XCTAssertEqual(page.entries.count, 2)
            let names = Set(page.entries.map { $0.url.lastPathComponent })
            XCTAssertTrue(names.contains("test.pdf"))
            XCTAssertTrue(names.contains("sub.mp4"))
            XCTAssertFalse(names.contains("backup.pdf"))
            XCTAssertFalse(names.contains("two.pdf"))
            XCTAssertFalse(names.contains("bak.pdf"))

            // 特殊目录查询
            guard let spEntry = children.first(where: { $0.url.lastPathComponent == "下载'测试%目录_特殊" }) else {
                XCTFail("special folder not found")
                return
            }
            let spStats = try index.spaceStats(directoryID: spEntry.id, token: CancellationToken())
            let spSourceStat = spStats.first(where: { $0.category == .source })!
            XCTAssertEqual(spSourceStat.count, 1)
            let spPage = try index.spacePage(directoryID: spEntry.id, filter: try SpaceFilter(), offset: 0, limit: 100, token: CancellationToken())
            XCTAssertEqual(spPage.totalCount, 1)
            XCTAssertEqual(spPage.entries.first?.url.lastPathComponent, "special'file%1.swift")
        }
    }

    func testSpaceStatsAndPage100Paging() throws {
        try withTree { root, index in
            let fm = FileManager.default
            let dir = root.appendingPathComponent("ScopeDir")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // 105 份 .pdf + 1 份未知扩展
            for i in 0..<105 {
                try Data(repeating: UInt8(i % 100), count: (i + 1) * 10).write(to: dir.appendingPathComponent("file-\(i).pdf"))
            }
            try Data([99]).write(to: dir.appendingPathComponent("unknown.strange"))

            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            let children = try index.children(of: 1, offset: 0, limit: 100)
            let scopeEntry = children.first(where: { $0.url.lastPathComponent == "ScopeDir" })!

            let stats = try index.spaceStats(directoryID: scopeEntry.id, token: CancellationToken())
            XCTAssertEqual(stats.count, 7)
            let docStat = stats.first(where: { $0.category == .document })!
            let otherStat = stats.first(where: { $0.category == .other })!
            XCTAssertEqual(docStat.count, 105)
            XCTAssertEqual(otherStat.count, 1)

            // 分页 0..100
            let p1 = try index.spacePage(directoryID: scopeEntry.id, filter: try SpaceFilter(), offset: 0, limit: 100, token: CancellationToken())
            XCTAssertEqual(p1.totalCount, 106)
            XCTAssertEqual(p1.entries.count, 100)
            XCTAssertTrue(p1.hasNext)

            // 分页 100..100
            let p2 = try index.spacePage(directoryID: scopeEntry.id, filter: try SpaceFilter(), offset: 100, limit: 100, token: CancellationToken())
            XCTAssertEqual(p2.totalCount, 106)
            XCTAssertEqual(p2.entries.count, 6)
            XCTAssertFalse(p2.hasNext)

            // 验证排序：allocated DESC, logical DESC, id ASC
            for i in 0..<(p1.entries.count - 1) {
                let curr = p1.entries[i]
                let next = p1.entries[i + 1]
                if curr.allocatedSize == next.allocatedSize {
                    if curr.logicalSize == next.logicalSize {
                        XCTAssertTrue(curr.id <= next.id)
                    } else {
                        XCTAssertGreaterThan(curr.logicalSize, next.logicalSize)
                    }
                } else {
                    XCTAssertGreaterThan(curr.allocatedSize, next.allocatedSize)
                }
            }
        }
    }

    func testDuplicateAndSparseAndFilterConditions() throws {
        try withTree { root, index in
            let fm = FileManager.default
            let dir = root.appendingPathComponent("TestDir")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // 1. 硬链接
            let original = dir.appendingPathComponent("orig.pdf")
            try Data(repeating: 1, count: 1024).write(to: original)
            let link = dir.appendingPathComponent("link.pdf")
            try fm.linkItem(at: original, to: link)

            // 2. 稀疏文件
            let sparse = dir.appendingPathComponent("sparse.zip")
            XCTAssertTrue(fm.createFile(atPath: sparse.path, contents: nil))
            let handle = try FileHandle(forWritingTo: sparse)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 16 * 1024 * 1024)

            // 3. 普通文件带时间
            let fileA = dir.appendingPathComponent("a.png")
            try Data(repeating: 2, count: 500).write(to: fileA)

            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            let children = try index.children(of: 1, offset: 0, limit: 100)
            let dirEntry = children.first(where: { $0.url.lastPathComponent == "TestDir" })!

            // 硬链接只计 1 次
            let stats = try index.spaceStats(directoryID: dirEntry.id, token: CancellationToken())
            let docStat = stats.first(where: { $0.category == .document })!
            XCTAssertEqual(docStat.count, 1)

            // 过滤 category
            let imgFilter = try SpaceFilter(category: .image)
            let imgPage = try index.spacePage(directoryID: dirEntry.id, filter: imgFilter, offset: 0, limit: 100, token: CancellationToken())
            XCTAssertEqual(imgPage.totalCount, 1)
            XCTAssertEqual(imgPage.entries.first?.url.lastPathComponent, "a.png")

            // 过滤大小 min / max
            let sizeFilter = try SpaceFilter(minAllocated: 1, maxAllocated: 10000)
            let sizePage = try index.spacePage(directoryID: dirEntry.id, filter: sizeFilter, offset: 0, limit: 100, token: CancellationToken())
            XCTAssertTrue(sizePage.entries.allSatisfy { $0.allocatedSize >= 1 && $0.allocatedSize <= 10000 })

            // 过滤修改时间 notModifiedSince
            let nowNano = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            let mtimeFilter = try SpaceFilter(notModifiedSince: nowNano)
            let mtimePage = try index.spacePage(directoryID: dirEntry.id, filter: mtimeFilter, offset: 0, limit: 100, token: CancellationToken())
            XCTAssertEqual(mtimePage.totalCount, 3) // orig.pdf, sparse.zip, a.png (link.pdf is duplicate=1)

            // 时间在过去的 filter（比如 1 秒前）
            let pastFilter = try SpaceFilter(notModifiedSince: 1000)
            let pastPage = try index.spacePage(directoryID: dirEntry.id, filter: pastFilter, offset: 0, limit: 100, token: CancellationToken())
            XCTAssertEqual(pastPage.totalCount, 0)
            XCTAssertEqual(pastPage.entries.count, 0)
            XCTAssertFalse(pastPage.hasNext)
        }
    }

    func testExactBoundariesAndBinaryRootScope() throws {
        try withTree { _, index in
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(index.url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let sql = """
                INSERT INTO nodes(id,parent,path,mode,modified,logical,allocated,duplicate,category) VALUES
                (1,0,'/',16877,0,0,0,0,0),
                (2,1,'/Scope',16877,0,0,0,0,0),
                (3,2,'/Scope/equal.pdf',32768,1000,10,4096,0,4),
                (4,2,'/Scope/unknown.pdf',32768,0,20,4096,0,4),
                (5,2,'/Scope/negative.pdf',32768,-1,30,4096,0,4),
                (6,2,'/Scope/future.pdf',32768,2000,40,8192,0,4),
                (7,2,'/Scope/zero.zip',32768,1000,16777216,0,0,5),
                (8,2,'/Scope/duplicate.pdf',32768,1000,10,4096,1,4),
                (9,1,'/scope/outside.pdf',32768,1000,10,4096,0,4),
                (10,1,'/Scope-backup/outside.pdf',32768,1000,10,4096,0,4),
                (11,2,'/Scope/link.pdf',41471,1000,10,4096,0,4);
                """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            let old = try index.spacePage(directoryID: 2, filter: try SpaceFilter(notModifiedSince: 1000), token: CancellationToken())
            XCTAssertEqual(old.entries.map(\.id), [3,7])
            let equal = try index.spacePage(directoryID: 2, filter: try SpaceFilter(minAllocated: 4096, maxAllocated: 4096), token: CancellationToken())
            XCTAssertEqual(equal.totalCount, 3)
            XCTAssertEqual(equal.allocatedSize, 12288)
            let zero = try index.spacePage(directoryID: 2, filter: try SpaceFilter(maxAllocated: 0), token: CancellationToken())
            XCTAssertEqual(zero.entries.map(\.id), [7])
            XCTAssertEqual(zero.entries[0].logicalSize, 16777216)
            let all = try index.spacePage(directoryID: 1, filter: try SpaceFilter(), token: CancellationToken())
            XCTAssertEqual(all.totalCount, 7)
            let scoped = try index.spaceStats(directoryID: 2, token: CancellationToken())
            XCTAssertEqual(scoped.reduce(0) { $0 + $1.count }, 5)
            XCTAssertEqual(scoped.reduce(0) { $0 + $1.allocatedSize }, 20480)
            let end = try index.spacePage(directoryID: 2, filter: try SpaceFilter(), offset: Int.max, token: CancellationToken())
            XCTAssertTrue(end.entries.isEmpty)
            XCTAssertFalse(end.hasNext)
        }
    }

    func testSmallQueryHonorsAlreadyCancelledToken() throws {
        try withTree { root, index in
            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            let token = CancellationToken(); token.cancel()
            XCTAssertThrowsError(try index.spaceStats(directoryID: 1, token: token))
            XCTAssertThrowsError(try index.spacePage(directoryID: 1, filter: try SpaceFilter(), token: token))
        }
    }

    func testSQLCancellationAndRecovery() throws {
        try withTree { root, index in
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(index.url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }

            // 插入合成数据 200,000 条
            let sql = """
                BEGIN;
                INSERT INTO nodes(id,parent,path,device,inode,mode,size,modified,changed,blocks,ownLogical,ownAllocated,logical,allocated,duplicate,category)
                VALUES(1, 0, '/fixture', 1, 1, 16877, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                WITH RECURSIVE ids(id) AS (VALUES(2) UNION ALL SELECT id+1 FROM ids WHERE id<=200000)
                INSERT INTO nodes(id,parent,path,device,inode,mode,size,modified,changed,blocks,ownLogical,ownAllocated,logical,allocated,duplicate,category)
                SELECT id, 1, '/fixture/file_' || id || '.pdf', 1, id, 32768, 100, 1000, 1000, 4096, 100, 4096, 100, 4096, 0, 4 FROM ids;
                COMMIT;
                """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

            // 取消测试
            let token = CancellationToken()
            XCTAssertFalse(token.isCancelled)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { token.cancel() }
            XCTAssertThrowsError(try index.spaceStats(directoryID: 1, token: token))
            XCTAssertTrue(token.isCancelled)

            // 取消后恢复查询
            let freshToken = CancellationToken()
            let recoveredStats = try index.spaceStats(directoryID: 1, token: freshToken)
            XCTAssertEqual(recoveredStats.count, 7)
            let docStat = recoveredStats.first(where: { $0.category == .document })!
            XCTAssertEqual(docStat.count, 200000)

            // 分页查询取消与恢复
            let pageCancelToken = CancellationToken()
            pageCancelToken.cancel()
            XCTAssertThrowsError(try index.spacePage(directoryID: 1, filter: try SpaceFilter(), offset: 0, limit: 100, token: pageCancelToken))

            let pageRecoverToken = CancellationToken()
            let recoveredPage = try index.spacePage(directoryID: 1, filter: try SpaceFilter(), offset: 0, limit: 100, token: pageRecoverToken)
            XCTAssertEqual(recoveredPage.entries.count, 100)
            XCTAssertTrue(recoveredPage.hasNext)
            XCTAssertEqual(recoveredPage.totalCount, 200000)
        }
    }
}

func XCTFail(_ message: String, file: StaticString = #file, line: UInt = #line) {
    requireTest(false, message, file: file, line: line)
}
