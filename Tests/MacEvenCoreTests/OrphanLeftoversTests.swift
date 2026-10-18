import Foundation
import MacEvenCore

// 防止的问题：把已安装、正在运行或同厂商应用的数据当作残留；按名称或前缀猜测扩大范围；
// 扫描后应用重新出现仍删除；越出固定位置；跟随替换的祖先目录；同时冻结的多份卸载计划互相覆盖。
final class OrphanLeftoversTests {
    func withHome(_ body: (URL, DiskIndex, ProtectionStore) throws -> Void) throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw)
            try body(home, index, ProtectionStore(url: home.appendingPathComponent("protection.json")))
        }
    }

    func write(_ url: URL, directory: Bool) throws {
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: url.appendingPathComponent("data"))
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 2, count: 100).write(to: url)
        }
    }

    func testDiscoveryOwnershipAndScope() throws {
        try withHome { home, index, store in
            let library = home.appendingPathComponent("Library")
            let gone = "com.example.gone"
            let goneDirs = ["Caches/\(gone)", "Application Support/\(gone)", "Containers/\(gone)", "Saved Application State/\(gone).savedState", "Logs/\(gone)", "WebKit/\(gone)"]
            for relative in goneDirs { try write(library.appendingPathComponent(relative), directory: true) }
            let goneFiles = ["Preferences/\(gone).plist", "Preferences/ByHost/\(gone).\(UUID().uuidString).plist", "HTTPStorages/\(gone).binarycookies", "Cookies/\(gone).binarycookies"]
            for relative in goneFiles { try write(library.appendingPathComponent(relative), directory: false) }
            // 不属于残留范围：已安装、正在运行、同厂商、Apple、应用组、两段名称、前缀相似但不同的标识。
            for relative in ["Caches/com.example.installed", "Caches/com.example.running", "Caches/com.vendor.other", "Caches/com.apple.thing",
                             "Group Containers/group.com.example.gone", "Caches/pip", "Caches/org.short", "Caches/com.example.gone2", "Caches/org.swift.swiftpm"] {
                try write(library.appendingPathComponent(relative), directory: true)
            }
            try write(library.appendingPathComponent("Preferences/com.example.gone.other.plist"), directory: false)
            let outside = home.appendingPathComponent("Documents/\(gone)")
            try write(outside, directory: true)
            let ownership: (String) -> LeftoverOwnership = { id in
                switch id {
                case "com.example.installed": return .installed
                case "com.example.running": return .review("正在运行")
                case "com.vendor.other": return .review("同厂商应用仍已安装")
                default: return .orphan
                }
            }
            let leftovers = OrphanLeftovers(index: index, home: home, protection: store)
            let result = try leftovers.scan(token: CancellationToken(), ownership: ownership)
            XCTAssertFalse(result.truncated)
            let ids = Set(result.groups.map(\.id))
            XCTAssertEqual(ids, [gone, "com.example.running", "com.vendor.other", "com.example.gone2", "com.example.gone.other"])
            let group = result.groups.first { $0.id == gone }!
            XCTAssertEqual(group.paths.count, goneDirs.count + goneFiles.count)
            XCTAssertEqual(group.blockedReason, nil)
            XCTAssertTrue(group.allocatedSize! > 0)
            XCTAssertTrue(result.groups.first { $0.id == "com.example.running" }?.blockedReason == "正在运行")
            XCTAssertTrue(result.groups.first { $0.id == "com.vendor.other" }?.blockedReason?.contains("同厂商") == true)

            // 应用在扫描后重新出现：刷新与执行都保留。
            let reinstalled = try leftovers.refresh { $0 == gone ? .installed : ownership($0) }
            XCTAssertNotNil(reinstalled.first { $0.id == gone }?.blockedReason)
            XCTAssertTrue(leftovers.move(groupIDs: [gone], ownership: { _ in .installed }).allSatisfy { $0.destination == nil })
            // 正常移动：只移走固定位置，其他相似标识与外部目录保留。
            let moved = leftovers.move(groupIDs: [gone], ownership: ownership)
            defer { for url in moved.compactMap(\.destination) { try? FileManager.default.removeItem(at: url) } }
            XCTAssertEqual(moved.count, goneDirs.count + goneFiles.count)
            XCTAssertTrue(moved.allSatisfy { $0.destination != nil && $0.error == nil && $0.allocatedSize != nil })
            for relative in goneDirs + goneFiles.filter({ !$0.contains("ByHost") }) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(relative).path))
            }
            for url in [outside, library.appendingPathComponent("Caches/com.example.gone2"), library.appendingPathComponent("Preferences/com.example.gone.other.plist"),
                        library.appendingPathComponent("Group Containers/group.com.example.gone"), library.appendingPathComponent("Caches/com.example.installed")] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
            XCTAssertTrue(leftovers.move(groupIDs: ["com.example.running", "com.vendor.other"], ownership: ownership).allSatisfy { $0.destination == nil })
            XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Caches/com.example.running").path))
        }
    }

    func testChangesProtectionAndLinks() throws {
        try withHome { home, index, store in
            let library = home.appendingPathComponent("Library")
            for id in ["com.example.changed", "com.example.kept", "com.example.ancestor"] { try write(library.appendingPathComponent("Caches/\(id)"), directory: true) }
            let support = library.appendingPathComponent("Application Support/com.example.linked")
            let target = home.appendingPathComponent("Documents/real")
            try write(target, directory: true)
            try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: support, withDestinationURL: target)
            let leftovers = OrphanLeftovers(index: index, home: home, protection: store)
            let result = try leftovers.scan(token: CancellationToken(), ownership: { _ in .orphan })
            XCTAssertNotNil(result.groups.first { $0.id == "com.example.linked" }?.blockedReason)
            XCTAssertTrue(leftovers.move(groupIDs: ["com.example.linked"], ownership: { _ in .orphan }).allSatisfy { $0.destination == nil })
            requireTest(FileManager.default.fileExists(atPath: target.appendingPathComponent("data").path), "symlinked leftover followed")

            // 扫描后内容变化：拒绝并要求重扫。
            try Data([9]).write(to: library.appendingPathComponent("Caches/com.example.changed/new"))
            XCTAssertTrue(leftovers.move(groupIDs: ["com.example.changed"], ownership: { _ in .orphan }).allSatisfy { $0.destination == nil })
            // 扫描后加入保护：刷新与执行都拒绝。
            try store.addBundleIdentifier("com.example.kept")
            XCTAssertNotNil(try leftovers.refresh(ownership: { _ in .orphan }).first { $0.id == "com.example.kept" }?.blockedReason)
            XCTAssertTrue(leftovers.move(groupIDs: ["com.example.kept"], ownership: { _ in .orphan }).allSatisfy { $0.destination == nil && $0.error?.contains("保护列表") == true })
            // 祖先目录被替换为链接：拒绝。
            let caches = library.appendingPathComponent("Caches"), original = library.appendingPathComponent("CachesOriginal")
            try FileManager.default.moveItem(at: caches, to: original)
            try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: original)
            XCTAssertTrue(leftovers.move(groupIDs: ["com.example.ancestor"], ownership: { _ in .orphan }).allSatisfy { $0.destination == nil })
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("com.example.ancestor/data").path))
            XCTAssertEqual(leftovers.move(groupIDs: (0..<51).map { "com.example.n\($0)" }, ownership: { _ in .orphan }).first?.destination, nil)

            // 取消的扫描全部只读。
            let token = CancellationToken(); token.cancel()
            XCTAssertTrue(try leftovers.scan(token: token, ownership: { _ in .orphan }).groups.allSatisfy { $0.blockedReason != nil })
        }
    }

    func testIndependentDataPlansForBatchRemoval() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-batch-plans-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        var destinations: [URL] = []
        defer { for url in destinations { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        let first = apps.appendingPathComponent("First.app"), second = apps.appendingPathComponent("Second.app")
        try makeTestApplication(first, id: "test.batch.first"); try makeTestApplication(second, id: "test.batch.second")
        for id in ["test.batch.first", "test.batch.second"] { try write(home.appendingPathComponent("Library/Caches/\(id)"), directory: true) }
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps], protection: ProtectionStore(url: home.appendingPathComponent("protection.json")))
        _ = try remover.scan(token: CancellationToken())
        let firstPlan = try remover.prepareDataRemoval(id: first.path, token: CancellationToken(), isRunning: { _ in false })
        let secondPlan = try remover.prepareDataRemoval(id: second.path, token: CancellationToken(), isRunning: { _ in false })
        XCTAssertEqual(firstPlan.paths.count, 1)
        let firstResults = remover.moveIncludingData(plan: firstPlan, isRunning: { _ in false })
        let secondResults = remover.moveIncludingData(plan: secondPlan, isRunning: { _ in false })
        destinations += (firstResults + secondResults).compactMap(\.destination)
        requireTest(firstResults.count == 2 && secondResults.count == 2, "second plan replaced the first")
        XCTAssertTrue((firstResults + secondResults).allSatisfy { $0.destination != nil && $0.error == nil })
        XCTAssertEqual(remover.moveIncludingData(plan: firstPlan, isRunning: { _ in false }).first?.destination, nil)
    }
}
