import Foundation
import Darwin
import SQLite3
import MacEvenCore

func check(_ condition: Bool, _ message: String = "check failed", file: StaticString = #file, line: UInt = #line) {
    if !condition {
        fputs("FAIL: \(file):\(line): \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    check(actual == expected, "\(message) expected \(expected), got \(actual)", file: file, line: line)
}

func checkClose(_ a: Double, _ b: Double, accuracy: Double = 1e-4, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    check(abs(a - b) <= accuracy, "\(message) expected \(b) ≈ \(a) (diff \(abs(a - b)))", file: file, line: line)
}

func executeRawSQL(dbURL: URL, sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        throw MacEvenError("Failed to open test database at \(dbURL.path)")
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        throw MacEvenError("Failed to execute SQL: \(msg)")
    }
}


struct TreemapCoreChecks {
    static func withTestTree(_ body: (URL, DiskIndex) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-treemap-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let indexURL = tempDir.appendingPathComponent("index.sqlite")
        let index = try DiskIndex(url: indexURL)
        try body(tempDir, index)
    }

    static func run() throws {
        print("--- Running TreemapCoreChecks ---")
        try testLayoutEmptyAndInvalidInputs()
        try testLayoutConservationAndBounds()
        try testLayoutDuplicateIDsAndDefense()
        try testLayoutMultiWindowSizes()
        try testEmptyDirectorySnapshot()
        try test130PlusEntriesTotalsAndOther()
        try testPagingIndependenceAndLimitClamp()
        try testZeroAndNegativeInvalidSizes()
        try testLargeInt64AndOverflowHandling()
        try testInheritedCancellationHandler()
        print("ALL PASS: TreemapCoreChecks passed successfully!")
    }

    // 1. 布局：空输入、非法/零/负/NaN/无限宽高
    static func testLayoutEmptyAndInvalidInputs() throws {
        let w = [TreemapWeight(id: 1, allocatedSize: 100)]
        check(TreemapLayout.rectangles(weights: [], width: 100, height: 100).isEmpty, "empty weights -> empty")
        check(TreemapLayout.rectangles(weights: w, width: 0, height: 100).isEmpty, "width 0 -> empty")
        check(TreemapLayout.rectangles(weights: w, width: 100, height: 0).isEmpty, "height 0 -> empty")
        check(TreemapLayout.rectangles(weights: w, width: -10, height: 100).isEmpty, "negative width -> empty")
        check(TreemapLayout.rectangles(weights: w, width: 100, height: -10).isEmpty, "negative height -> empty")
        check(TreemapLayout.rectangles(weights: w, width: Double.nan, height: 100).isEmpty, "NaN width -> empty")
        check(TreemapLayout.rectangles(weights: w, width: 100, height: Double.nan).isEmpty, "NaN height -> empty")
        check(TreemapLayout.rectangles(weights: w, width: Double.infinity, height: 100).isEmpty, "Inf width -> empty")
        check(TreemapLayout.rectangles(weights: w, width: 100, height: Double.infinity).isEmpty, "Inf height -> empty")

        // 包含 0 或负数权重
        let zeroAndNeg = [
            TreemapWeight(id: 1, allocatedSize: 0),
            TreemapWeight(id: 2, allocatedSize: -50)
        ]
        check(TreemapLayout.rectangles(weights: zeroAndNeg, width: 200, height: 200).isEmpty, "zero/neg weights -> empty")
        print("PASS: testLayoutEmptyAndInvalidInputs")
    }

    // 2. 布局：面积守恒、不重叠、不越界、确定顺序
    static func testLayoutConservationAndBounds() throws {
        let weights = [
            TreemapWeight(id: 1, allocatedSize: 5000),
            TreemapWeight(id: 2, allocatedSize: 3000),
            TreemapWeight(id: 3, allocatedSize: 1500),
            TreemapWeight(id: 4, allocatedSize: 500)
        ]
        let width: Double = 800
        let height: Double = 600
        let rects = TreemapLayout.rectangles(weights: weights, width: width, height: height)

        checkEqual(rects.count, 4, "all 4 items placed")
        checkEqual(rects.map(\.id), [1, 2, 3, 4], "deterministic order matching valid weights")

        let totalExpectedArea = width * height
        var totalActualArea: Double = 0

        for (idx, item) in rects.enumerated() {
            let r = item.rect
            check(r.minX >= -1e-6, "minX bounded: \(r.minX)")
            check(r.minY >= -1e-6, "minY bounded: \(r.minY)")
            check(r.maxX <= width + 1e-6, "maxX bounded: \(r.maxX)")
            check(r.maxY <= height + 1e-6, "maxY bounded: \(r.maxY)")
            check(r.width > 0, "width > 0")
            check(r.height > 0, "height > 0")

            let area = r.width * r.height
            totalActualArea += area

            let expectedItemArea = (Double(weights[idx].allocatedSize) / 10000.0) * totalExpectedArea
            checkClose(area, expectedItemArea, accuracy: 1.0, "item area conservation for id \(item.id)")
        }
        checkClose(totalActualArea, totalExpectedArea, accuracy: 1.0, "total area conservation")

        // 检查非重叠：任意两个矩形内部不相交
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let r1 = rects[i].rect
                let r2 = rects[j].rect
                let intersection = r1.intersection(r2)
                if !intersection.isNull && !intersection.isEmpty {
                    check(intersection.width <= 1e-5 || intersection.height <= 1e-5,
                          "rects \(rects[i].id) and \(rects[j].id) must not overlap internally: intersection=\(intersection)")
                }
            }
        }
        print("PASS: testLayoutConservationAndBounds")
    }

    // 3. 布局：重复 ID 防御与过滤
    static func testLayoutDuplicateIDsAndDefense() throws {
        let weights = [
            TreemapWeight(id: 10, allocatedSize: 400),
            TreemapWeight(id: 10, allocatedSize: 900), // 重复 ID
            TreemapWeight(id: 20, allocatedSize: -100), // 负数
            TreemapWeight(id: 30, allocatedSize: 0), // 零
            TreemapWeight(id: 40, allocatedSize: 600)
        ]
        let rects = TreemapLayout.rectangles(weights: weights, width: 500, height: 500)
        checkEqual(rects.count, 2, "only id 10 and 40 survive")
        checkEqual(rects.map(\.id), [10, 40], "order preserved for valid items")
        checkClose(rects[0].rect.width * rects[0].rect.height + rects[1].rect.width * rects[1].rect.height, 250000.0, accuracy: 1.0)
        print("PASS: testLayoutDuplicateIDsAndDefense")
    }

    // 4. 布局：多组窗口宽高（极长、极宽、正常）
    static func testLayoutMultiWindowSizes() throws {
        let weights = (1...20).map { TreemapWeight(id: Int64($0), allocatedSize: Int64($0 * 1024)) }
        let sizes: [(Double, Double)] = [
            (1920, 1080),
            (1200, 800),
            (800, 600),
            (200, 1200), // 极窄高
            (1400, 150)  // 极扁平
        ]
        for (w, h) in sizes {
            let rects = TreemapLayout.rectangles(weights: weights, width: w, height: h)
            checkEqual(rects.count, 20)
            let totalArea = rects.reduce(0.0) { $0 + ($1.rect.width * $1.rect.height) }
            checkClose(totalArea, w * h, accuracy: 1.0, "size \(w)x\(h) area conservation")
            for r in rects {
                check(r.rect.minX >= -1e-6 && r.rect.minY >= -1e-6 && r.rect.maxX <= w + 1e-6 && r.rect.maxY <= h + 1e-6,
                      "bounds check for size \(w)x\(h)")
            }
        }
        print("PASS: testLayoutMultiWindowSizes")
    }

    // 5. 空目录 Snapshot
    static func testEmptyDirectorySnapshot() throws {
        try withTestTree { root, index in
            let emptyDir = root.appendingPathComponent("emptyDir")
            try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            let summary = try Scanner.scan(root: root, index: index, token: CancellationToken())
            checkEqual(summary.errors, 0)

            // 获取 emptyDir 的 entry id
            let rootChildren = try index.children(of: 1, limit: 10)
            guard let dirEntry = rootChildren.first(where: { $0.name == "emptyDir" }) else {
                check(false, "emptyDir not found in index")
                return
            }

            let snapshot = try index.treemap(of: dirEntry.id)
            checkEqual(snapshot.entries.count, 0)
            checkEqual(snapshot.totalCount, 0)
            checkEqual(snapshot.totalAllocatedSize, 0)
            checkEqual(snapshot.totalLogicalSize, 0)
            checkEqual(snapshot.otherCount, 0)
            checkEqual(snapshot.otherAllocatedSize, 0)
            checkEqual(snapshot.otherLogicalSize, 0)
            checkEqual(snapshot.invalidSizeCount, 0)
            checkEqual(snapshot.zeroAllocatedCount, 0)
            checkEqual(snapshot.weights.count, 0)
        }
        print("PASS: testEmptyDirectorySnapshot")
    }

    // 6. 构造 130+ 文件目录，验证完整合计、other 数值、前 64 项 limit
    static func test130PlusEntriesTotalsAndOther() throws {
        try withTestTree { root, index in
            let bigDir = root.appendingPathComponent("bigDir")
            try FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)

            // 创建 135 个文件，每个文件大小不同
            var expectedTotalLogical: Int64 = 0
            for i in 1...135 {
                let size = i * 100
                expectedTotalLogical += Int64(size)
                let data = Data(repeating: UInt8(i % 250), count: size)
                try data.write(to: bigDir.appendingPathComponent(String(format: "file-%03d.bin", i)))
            }

            let summary = try Scanner.scan(root: root, index: index, token: CancellationToken())
            checkEqual(summary.errors, 0)

            let rootChildren = try index.children(of: 1, limit: 10)
            guard let dirEntry = rootChildren.first(where: { $0.name == "bigDir" }) else {
                check(false, "bigDir not found")
                return
            }

            let snapshot = try index.treemap(of: dirEntry.id, limit: 64)
            checkEqual(snapshot.totalCount, 135, "totalCount must be 135")
            checkEqual(snapshot.entries.count, 64, "bounded limit 64 entries returned")
            checkEqual(snapshot.otherCount, 71, "otherCount = 135 - 64 = 71")
            checkEqual(snapshot.totalLogicalSize, expectedTotalLogical, "totalLogicalSize matches sum of 135 files")

            // entries 是前 64 项，按 allocated DESC, logical DESC, id 排序
            check(snapshot.entries.count == 64)
            for i in 0..<(snapshot.entries.count - 1) {
                let a = snapshot.entries[i]
                let b = snapshot.entries[i + 1]
                check(a.allocatedSize >= b.allocatedSize, "entries ordered by allocated DESC")
            }

            // 验证 entries 累加 + other 累加 == total
            let entriesAllocated = snapshot.entries.reduce(0) { $0 + $1.allocatedSize }
            let entriesLogical = snapshot.entries.reduce(0) { $0 + $1.logicalSize }

            checkEqual(entriesAllocated + snapshot.otherAllocatedSize, snapshot.totalAllocatedSize,
                       "entriesAlloc + otherAlloc == totalAlloc")
            checkEqual(entriesLogical + snapshot.otherLogicalSize, snapshot.totalLogicalSize,
                       "entriesLogic + otherLogic == totalLogic")

            // 验证 weights：64 个正占用 entry + 1 个 other (id: 0)
            checkEqual(snapshot.weights.count, 65, "64 entries + 1 other")
            guard let lastWeight = snapshot.weights.last else { check(false); return }
            checkEqual(lastWeight.id, 0, "other weight id must be 0")
            checkEqual(lastWeight.allocatedSize, snapshot.otherAllocatedSize, "other weight allocatedSize matches otherAllocatedSize")

            let weightsSum = snapshot.weights.reduce(0) { $0 + $1.allocatedSize }
            checkEqual(weightsSum, snapshot.totalAllocatedSize, "weights sum matches total allocated size")
        }
        print("PASS: test130PlusEntriesTotalsAndOther")
    }

    // 7. 分页独立与 limit clamp (0...64)
    static func testPagingIndependenceAndLimitClamp() throws {
        try withTestTree { root, index in
            let dir = root.appendingPathComponent("clampDir")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 1...80 {
                try Data(repeating: 1, count: i * 10).write(to: dir.appendingPathComponent("f\(i)"))
            }
            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            let dirEntry = try index.children(of: 1).first { $0.name == "clampDir" }!

            // 1) 测试 limit clamp
            let snapClampHigh = try index.treemap(of: dirEntry.id, limit: 100)
            checkEqual(snapClampHigh.entries.count, 64, "limit 100 clamped to 64")

            let snapClampLow = try index.treemap(of: dirEntry.id, limit: -5)
            checkEqual(snapClampLow.entries.count, 0, "limit -5 clamped to 0")
            checkEqual(snapClampLow.otherCount, 80, "limit 0 -> all 80 items are other")

            let snap10 = try index.treemap(of: dirEntry.id, limit: 10)
            checkEqual(snap10.entries.count, 10, "limit 10 respected")
            checkEqual(snap10.otherCount, 70, "80 - 10 = 70")

            // 2) 测试与 children 分页完全独立
            let childrenPage1 = try index.children(of: dirEntry.id, offset: 0, limit: 15)
            checkEqual(childrenPage1.count, 15)
            // 调用 treemap 并不影响 children 的 offset/limit
            let _ = try index.treemap(of: dirEntry.id, limit: 20)
            let childrenPage2 = try index.children(of: dirEntry.id, offset: 15, limit: 15)
            checkEqual(childrenPage2.count, 15)
            // 确认 childrenPage1 和 childrenPage2 互不相同（正常分页）
            check(Set(childrenPage1.map(\.id)).isDisjoint(with: Set(childrenPage2.map(\.id))))
        }
        print("PASS: testPagingIndependenceAndLimitClamp")
    }

    // 8. 零大小与异常负数据
    static func testZeroAndNegativeInvalidSizes() throws {
        try withTestTree { root, index in
            let dir = root.appendingPathComponent("zeroDir")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 3 个零大小文件
            try Data().write(to: dir.appendingPathComponent("zero1"))
            try Data().write(to: dir.appendingPathComponent("zero2"))
            try Data().write(to: dir.appendingPathComponent("zero3"))
            // 2 个正常大小文件
            try Data(repeating: 5, count: 100).write(to: dir.appendingPathComponent("valid1"))
            try Data(repeating: 6, count: 200).write(to: dir.appendingPathComponent("valid2"))

            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            let dirEntry = try index.children(of: 1).first { $0.name == "zeroDir" }!

            // 注入异常负数据以测试防御性（直接向 SQLite nodes 表插入测试数据）
            try executeRawSQL(dbURL: index.url, sql: """
                INSERT INTO nodes(parent, path, device, inode, mode, size, modified, changed, blocks,
                    ownLogical, ownAllocated, logical, allocated, duplicate, category)
                VALUES(\(dirEntry.id), '\(dirEntry.url.path)/corrupt1', 1, 99991, 33188, -10, 0, 0, -1,
                    -10, -512, -10, -512, 0, 0);
                INSERT INTO nodes(parent, path, device, inode, mode, size, modified, changed, blocks,
                    ownLogical, ownAllocated, logical, allocated, duplicate, category)
                VALUES(\(dirEntry.id), '\(dirEntry.url.path)/corrupt2', 1, 99992, 33188, 100, 0, 0, -1,
                    100, -512, 100, -512, 0, 0);
            """)

            let snapshot = try index.treemap(of: dirEntry.id, limit: 64)
            // 总共 3(zero) + 2(valid) + 2(corrupt) = 7 项
            checkEqual(snapshot.totalCount, 7, "totalCount includes all directly attached rows")
            checkEqual(snapshot.zeroAllocatedCount, 3, "zeroAllocatedCount correctly counted 3 zero entries")
            checkEqual(snapshot.invalidSizeCount, 2, "2 corrupt entries marked invalid")

            // weights 不能画虚假面积：weights 只包含 2 个 valid entries，零大小和负数都不在 weights 中
            checkEqual(snapshot.weights.count, 2, "only 2 valid entries have positive weights")
            for w in snapshot.weights {
                check(w.allocatedSize > 0, "all weights must be positive")
            }
        }
        print("PASS: testZeroAndNegativeInvalidSizes")
    }

    // 9. Int64 大数与累加汇总溢出
    static func testLargeInt64AndOverflowHandling() throws {
        try withTestTree { root, index in
            let dir = root.appendingPathComponent("overflowDir")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("init"))
            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            let dirEntry = try index.children(of: 1).first { $0.name == "overflowDir" }!

            // 插入两个非常大的 allocated 大数，其和超过 Int64.max
            let large1: Int64 = Int64.max - 100
            let large2: Int64 = 200 // large1 + large2 溢出 Int64.max
            try executeRawSQL(dbURL: index.url, sql: """
                INSERT INTO nodes(parent, path, device, inode, mode, size, modified, changed, blocks,
                    ownLogical, ownAllocated, logical, allocated, duplicate, category)
                VALUES(\(dirEntry.id), '\(dirEntry.url.path)/huge1', 1, 88881, 33188, 100, 0, 0, 10,
                    100, 512, 100, \(large1), 0, 0);
                INSERT INTO nodes(parent, path, device, inode, mode, size, modified, changed, blocks,
                    ownLogical, ownAllocated, logical, allocated, duplicate, category)
                VALUES(\(dirEntry.id), '\(dirEntry.url.path)/huge2', 1, 88882, 33188, 100, 0, 0, 10,
                    100, 512, 100, \(large2), 0, 0);
            """)

            // 不应崩溃，应标记为异常 invalidSizeCount > 0
            let snapshot = try index.treemap(of: dirEntry.id, limit: 64)
            check(snapshot.invalidSizeCount > 0, "overflow must be marked as invalidSizeCount > 0")
        }
        print("PASS: testLargeInt64AndOverflowHandling")
    }

    // 10. 继承调用方 progress handler 取消处理，不重置它
    static func testInheritedCancellationHandler() throws {
        try withTestTree { root, index in
            let dir = root.appendingPathComponent("cancelDir")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 1...20 {
                try Data(repeating: 1, count: i * 50).write(to: dir.appendingPathComponent("f\(i)"))
            }
            _ = try Scanner.scan(root: root, index: index, token: CancellationToken())
            let dirEntry = try index.children(of: 1).first { $0.name == "cancelDir" }!

            let token = CancellationToken()
            token.cancel() // 预先取消
            index.setCancelHandler(token: token)

            var didCatch = false
            do {
                _ = try index.treemap(of: dirEntry.id)
            } catch {
                didCatch = true
            }
            check(didCatch, "cancellation handler must abort treemap query")

            // 再次验证：progress handler 没有被 treemap 重置为 nil
            var stillCancelled = false
            do {
                _ = try index.children(of: dirEntry.id)
            } catch {
                stillCancelled = true
            }
            check(stillCancelled, "progress handler must NOT have been reset by treemap")

            // 清理 cancel handler
            index.setCancelHandler(token: nil)
        }
        print("PASS: testInheritedCancellationHandler")
    }
}


@main struct TreemapChecks {
    @MainActor static func settle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.busy {
            precondition(Date() < deadline, "Treemap model did not settle")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        try TreemapCoreChecks.run()
        let largeTiles = TreemapLayout.rectangles(weights: [
            TreemapWeight(id: 1, allocatedSize: Int64.max), TreemapWeight(id: 2, allocatedSize: Int64.max)
        ], width: 100, height: 100)
        precondition(largeTiles.count == 2 && largeTiles.allSatisfy { abs($0.rect.width * $0.rect.height - 5000) < 1e-6 }, "layout dropped valid large weights on integer overflow")
        let tinyTiles = TreemapLayout.rectangles(weights: [
            TreemapWeight(id: 1, allocatedSize: Int64.max - 1), TreemapWeight(id: 2, allocatedSize: 1)
        ], width: 100, height: 100)
        precondition(tinyTiles.count == 2 && tinyTiles[1].rect.width * tinyTiles[1].rect.height < 1e-10, "layout invented area for tiny entries")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-treemap-model-\(UUID())")
        let root = base.appendingPathComponent("sample")
        let many = root.appendingPathComponent("many")
        let empty = root.appendingPathComponent("empty")
        let cache = base.appendingPathComponent("cache")
        for directory in [many, empty] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: base) }
        for i in 0..<131 { try Data(repeating: UInt8(i), count: 8192).write(to: many.appendingPathComponent("file-\(i).txt")) }
        let model = AppModel(cacheDirectory: cache)
        model.setBrowseMode(.directory)
        precondition(model.treemapSnapshot == nil, "unscanned model has a space map")
        model.start(root: root)
        try await settle(model)
        let manyID = model.entries.first { $0.name == "many" }!.id
        let emptyID = model.entries.first { $0.name == "empty" }!.id
        model.load(directory: manyID, offset: 100)
        try await settle(model)
        precondition(model.entries.count == 31)
        model.setBrowseMode(.treemap)
        try await settle(model)
        precondition(model.breadcrumbs.last?.id == manyID && model.offset == 0 && !model.canNext)
        precondition(model.treemapSnapshot?.totalCount == 131 && model.entries.count == 64)
        precondition(model.treemapSnapshot?.otherCount == 67)
        let oldTotal = model.treemapSnapshot!.totalAllocatedSize
        let selected = model.entries[0]
        model.selectTreemapEntry(selected.id)
        precondition(model.selectedEntries.map(\.id) == [selected.id] && model.selectedSize == selected.allocatedSize)
        precondition(!model.canTrash && model.blocked[selected.id] != nil, "Treemap bypassed protected-path rules")
        model.selectTreemapEntry(0)
        precondition(model.selection == [selected.id], "other tile entered selection")
        model.selection = [0]
        precondition(!model.canTrash, "synthetic other became actionable")
        model.prepareTrash()
        precondition(model.trashConfirmation == nil)
        model.load(directory: Int64.max)
        try await settle(model)
        precondition(model.treemapSnapshot == nil && model.message != nil, "missing index directory was shown as empty")
        model.message = nil
        model.load(directory: emptyID)
        model.load(directory: manyID)
        try await settle(model)
        precondition(model.treemapSnapshot?.totalCount == 131 && model.selection.isEmpty, "late directory query overwrote map")
        model.load(directory: emptyID)
        try await settle(model)
        precondition(model.treemapSnapshot?.totalCount == 0 && model.treemapEmptyNotice.contains("空"))
        model.load(directory: 1)
        try await settle(model)
        precondition(model.breadcrumbs.count == 1 && model.treemapSnapshot?.totalCount == 2, "parent navigation failed")
        model.load(directory: manyID)
        model.cancel()
        try await settle(model)
        precondition(model.treemapSnapshot == nil && model.entries.isEmpty, "cancelled query published actionable map")
        precondition(model.status == "查询已取消", "cancelled map kept a stopping status")
        model.load(directory: manyID)
        try await settle(model)
        precondition(model.treemapSnapshot?.totalCount == 131, "map query could not recover")
        precondition(model.status == "查询完成", "recovered map kept a cancelled status")
        model.showLargeFiles(true)
        try await settle(model)
        precondition(model.largeFilesScope == .cleanable && model.treemapSnapshot == nil && model.entries.isEmpty, "mode switch retained map or listed non-cleanable fixture files")
        model.setLargeFilesScope(.all)
        try await settle(model)
        precondition(model.entries.count == 100, "all scope must rank the fixture")
        model.showSpaceInsights()
        try await settle(model)
        precondition(model.filteredCount == 131 && model.canNext, "map broke category filters")
        model.setBrowseMode(.treemap)
        model.start(root: empty)
        precondition(model.treemapSnapshot == nil && model.entries.isEmpty)
        try await settle(model)
        precondition(model.rootEntry?.url.lastPathComponent == "empty" && model.treemapSnapshot?.totalCount == 0, "old map overwrote rescan")
        model.start(root: root)
        try await settle(model)
        let newManyID = model.entries.first { $0.name == "many" }!.id
        model.load(directory: newManyID)
        try await settle(model)
        // Simulate completed index deletion in this test-owned database, without touching the user's Trash.
        let session = try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: []).first { $0.lastPathComponent.hasPrefix("session-") }!
        var db: OpaquePointer?
        precondition(sqlite3_open(session.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK)
        let victim = model.entries[0]
        precondition(sqlite3_exec(db, "DELETE FROM nodes WHERE id=\(victim.id)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        model.load(directory: newManyID)
        try await settle(model)
        precondition(model.treemapSnapshot?.totalCount == 130 && model.treemapSnapshot?.totalAllocatedSize == oldTotal - victim.allocatedSize, "reload retained deleted space map totals")
        precondition(sqlite3_open(session.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK)
        precondition(sqlite3_exec(db, "UPDATE nodes SET allocated=NULL WHERE id=\(model.entries[0].id)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        model.load(directory: newManyID)
        try await settle(model)
        precondition(model.treemapSnapshot?.invalidSizeCount == 1, "missing size was falsely reported as zero")
        model.selectTreemapEntry(model.entries[0].id)
        precondition(model.selection.isEmpty && !model.canTrash, "invalid map remained actionable")
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data([1]).write(to: locked.appendingPathComponent("hidden"))
        precondition(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o700) }
        model.start(root: root)
        try await settle(model)
        let lockedID = model.entries.first { $0.name == "locked" }!.id
        model.load(directory: lockedID)
        try await settle(model)
        precondition(model.incompleteResultNotice != nil && model.treemapDirectoryNotice != nil)
        precondition(model.treemapEmptyNotice.contains("不能确认"), "denied directory was called empty")
        model.start(root: many)
        model.cancel()
        try await settle(model)
        precondition(model.summary?.cancelled == true && model.incompleteResultNotice != nil)
        model.load()
        let error: String? = await withCheckedContinuation { continuation in model.shutdown { continuation.resume(returning: $0) } }
        try await Task.sleep(for: .milliseconds(100))
        precondition(error == nil && model.treemapSnapshot == nil && model.entries.isEmpty && !model.busy, "shutdown accepted late map result")
        print("PASS: Treemap model bounded totals, selection, navigation, cancellation, rescan, filters, deletion refresh, denied/partial scan, shutdown")
    }
}
