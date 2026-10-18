import Foundation
import MacEvenCore

// 防止的问题：百分比越界或未完成就显示 100%；候选列表扫描的最后一次进度没有走到总数；
// 重复文件抽样 / 哈希阶段的已完成量超过总量或结束时没有到达总量。
final class ProgressLog<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

final class ProgressTests {
    func testEstimateBoundaries() throws {
        XCTAssertNil(ProgressEstimate.units(3, of: 0).fraction)
        XCTAssertEqual(ProgressEstimate.units(0, of: 4).percentText, "0%")
        XCTAssertEqual(ProgressEstimate.units(2, of: 4).percentText, "50%")
        XCTAssertEqual(ProgressEstimate.units(9, of: 4).fraction, 1)
        XCTAssertEqual(ProgressEstimate.units(-1, of: 4).fraction, 0)
        // 估算值超出分母时停在 99%，并标注“约”。
        XCTAssertEqual(ProgressEstimate.expected(150, of: 100).percentText, "约 99%")
        XCTAssertEqual(ProgressEstimate.expected(25, of: 100).percentText, "约 25%")
        XCTAssertNil(ProgressEstimate.expected(1, of: 0).fraction)
        XCTAssertNil(ProgressEstimate.expected(.nan, of: 10).fraction)
        // 分段：第 2 段（权重 1/4）过半 → 2/4 + 1/8。
        let phased = ProgressEstimate.phases([1, 1, 1, 1], index: 2, inner: .units(1, of: 2))
        XCTAssertEqual(phased.fraction, 0.625)
        XCTAssertTrue(phased.estimated)
        // 段内未知时停在段起点；精确分段全部完成可到 100%。
        XCTAssertEqual(ProgressEstimate.phases([1, 1], index: 1, inner: .unknown).fraction, 0.5)
        XCTAssertEqual(ProgressEstimate.phases([1, 1], index: 1, inner: .units(1, of: 1), exact: true).percentText, "100%")
        XCTAssertNil(ProgressEstimate.phases([1, 1], index: 5, inner: .unknown).fraction)
        XCTAssertNil(ProgressEstimate.unknown.percentText)
    }

    private func checkUnits(_ log: ProgressLog<ScanProgress>, expected: Int, _ label: String) {
        let unitized = log.values.filter { $0.totalUnits != nil }
        requireTest(!unitized.isEmpty, "\(label): 没有带单元的进度")
        requireTest(unitized.allSatisfy { $0.totalUnits == expected && ($0.completedUnits ?? -1) <= expected }, "\(label): 单元越界")
        requireTest(zip(unitized, unitized.dropFirst()).allSatisfy { ($0.0.completedUnits ?? 0) <= ($0.1.completedUnits ?? 0) }, "\(label): 单元倒退")
        requireTest(unitized.last?.completedUnits == expected, "\(label): 最后一次进度未到总数")
    }

    func testCandidateScansReportUnits() throws {
        try CacheTests().withCache { _, _, cleanup in
            let log = ProgressLog<ScanProgress>()
            _ = try cleanup.scan(token: CancellationToken()) { log.append($0) }
            // test.closed 普通与沙盒、unknown、两个 com.apple、MacEven：共 6 个缓存入口。
            checkUnits(log, expected: 6, "应用缓存")
        }
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw)
            for rule in [DeveloperCleanupRule.pip, .npm] {
                let path = home.appendingPathComponent(rule.relativePath)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try Data(repeating: 1, count: 10).write(to: path.appendingPathComponent("data"))
            }
            let log = ProgressLog<ScanProgress>()
            _ = try DeveloperCleanup(index: index, home: home, protection: ProtectionStore(url: home.appendingPathComponent("p.json")))
                .scan(token: CancellationToken()) { log.append($0) }
            checkUnits(log, expected: DeveloperCleanupRule.allCases.count, "开发缓存")
        }
        try OrphanLeftoversTests().withHome { home, index, store in
            for id in ["com.example.one", "com.example.two"] {
                let path = home.appendingPathComponent("Library/Caches/\(id)")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try Data(repeating: 1, count: 10).write(to: path.appendingPathComponent("data"))
            }
            let log = ProgressLog<ScanProgress>()
            _ = try OrphanLeftovers(index: index, home: home, protection: store).scan(token: CancellationToken(), ownership: { _ in .orphan }) { log.append($0) }
            checkUnits(log, expected: 2, "卸载残留")
        }
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw)
            let apps = home.appendingPathComponent("Applications")
            for name in ["One", "Two", "Three"] { try makeTestApplication(apps.appendingPathComponent("\(name).app"), id: "test.progress.\(name.lowercased())") }
            let log = ProgressLog<ScanProgress>()
            _ = try ApplicationRemoval(index: index, home: home, roots: [apps]).scan(token: CancellationToken()) { log.append($0) }
            checkUnits(log, expected: 3, "应用扫描")
        }
    }

    func testDuplicatePhasesReportBoundedProgress() throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw)
            let dir = home.appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let big = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            for name in ["a", "b", "c"] { try big.write(to: dir.appendingPathComponent("\(name).bin")) }
            let small = Data(repeating: 7, count: 2_000)
            for name in ["s1", "s2"] { try small.write(to: dir.appendingPathComponent("\(name).bin")) }
            let log = ProgressLog<DuplicateProgress>()
            let summary = try DuplicateFiles(index: index, home: home).scan(root: dir, token: CancellationToken()) { log.append($0) }
            XCTAssertFalse(summary.incomplete)
            for phase in ["sampling", "hashing"] {
                let values = log.values.filter { $0.phase == phase && $0.phaseTotal != nil }
                requireTest(!values.isEmpty, "\(phase): 没有阶段进度")
                requireTest(values.allSatisfy { ($0.phaseDone ?? -1) >= 0 && $0.phaseDone! <= $0.phaseTotal! }, "\(phase): 阶段进度越界")
                requireTest(values.last.map { $0.phaseDone == $0.phaseTotal } == true, "\(phase): 结束时未到达总量")
            }
            // 抽样候选 5 个；完整哈希只剩 3 个大文件。
            XCTAssertEqual(log.values.last { $0.phase == "sampling" }?.phaseTotal, 5)
            XCTAssertEqual(log.values.last { $0.phase == "hashing" }?.phaseTotal, 900_000)
        }
    }
}
