import Foundation
import MacEvenCore

// 防止的问题：保护列表被某个删除入口绕过、损坏文件被当作空列表、确认后新增的保护不生效、
// 保护保留项反而阻止删除其他重复副本。
final class ProtectionTests {
    func withStore(_ body: (URL, DiskIndex, ProtectionStore) throws -> Void) throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw)
            let store = ProtectionStore(url: home.appendingPathComponent("Library/Application Support/MacEven/protection.json"))
            try body(home, index, store)
        }
    }

    func testStoreMatchingAndFailClosed() throws {
        try withStore { home, _, store in
            XCTAssertEqual(try store.entries().count, 0)
            let folder = home.appendingPathComponent("Projects/Keep")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let entry = try store.addPath(folder)
            XCTAssertEqual(try store.addPath(folder).id, entry.id)
            XCTAssertNotNil(store.reason(for: folder))
            XCTAssertNotNil(store.reason(for: folder.appendingPathComponent("a/b")))
            XCTAssertNotNil(store.reason(for: home.appendingPathComponent("Projects")))
            XCTAssertNotNil(store.reason(for: home.appendingPathComponent("projects/KEEP/x")))
            XCTAssertEqual(store.reason(for: home.appendingPathComponent("Projects/Keeper")), nil)
            XCTAssertThrowsError(try store.addPath(URL(fileURLWithPath: "/")))
            XCTAssertThrowsError(try store.addPath(FileManager.default.homeDirectoryForCurrentUser))

            XCTAssertThrowsError(try store.addBundleIdentifier("com"))
            XCTAssertThrowsError(try store.addBundleIdentifier("../x.y"))
            XCTAssertThrowsError(try store.addBundleIdentifier(".com.foo"))
            try store.addBundleIdentifier(" Com.Example.App ")
            for relative in ["Library/Caches/com.example.app", "Library/Containers/com.example.app/Data/Library/Caches",
                             "Library/Preferences/com.example.app.plist", "Library/Preferences/ByHost/com.example.app.\(UUID()).plist",
                             "Library/Application Support/com.example.app.helper/x"] {
                XCTAssertNotNil(store.reason(for: home.appendingPathComponent(relative)))
            }
            XCTAssertEqual(store.reason(for: home.appendingPathComponent("Library/Caches/com.example.application")), nil)
            XCTAssertEqual(store.reason(for: home.appendingPathComponent("Downloads/com.example.app")), nil)
            XCTAssertNotNil(store.reason(forBundleIdentifier: "com.example.app"))
            XCTAssertNotNil(store.reason(forBundleIdentifier: "COM.EXAMPLE.APP.helper"))
            XCTAssertEqual(store.reason(forBundleIdentifier: "com.example.other"), nil)
            XCTAssertNotNil(store.reason(for: home.appendingPathComponent("library/caches/COM.EXAMPLE.APP")))

            // 应用包按包内标识核对：磁盘分析等入口直接删除 .app 或其内容也会被拒绝。
            let bundle = home.appendingPathComponent("Downloads/Renamed Copy.app")
            try makeTestApplication(bundle, id: "com.example.app")
            XCTAssertNotNil(store.reason(for: bundle))
            XCTAssertNotNil(store.reason(for: bundle.appendingPathComponent("Contents/Resources/data")))
            let otherBundle = home.appendingPathComponent("Downloads/Other.app")
            try makeTestApplication(otherBundle, id: "com.example.other")
            XCTAssertEqual(store.reason(for: otherBundle), nil)
            let plainFolder = home.appendingPathComponent("Downloads/NotAnApp.app")
            try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
            XCTAssertEqual(store.reason(for: plainFolder), nil)
            try Data("not a plist".utf8).write(to: otherBundle.appendingPathComponent("Contents/Info.plist"))
            requireTest(store.reason(for: otherBundle) != nil, "unreadable bundle identifier treated as unprotected")

            // 另一个实例读取同一文件，证明落盘；移除后不再匹配。
            let reread = ProtectionStore(url: store.url)
            XCTAssertEqual(try reread.entries().count, 2)
            try reread.remove(id: entry.id)
            XCTAssertEqual(store.reason(for: folder), nil)

            // 手工编辑带尾部斜杠的路径仍保护其内容。
            let slashFolder = home.appendingPathComponent("Slash")
            try Data(#"{"version":1,"entries":[{"id":"6A0C3B8E-6E0B-4F5D-9E1A-1B2C3D4E5F61","kind":"path","value":"\#(slashFolder.path)//","added":"2026-10-10T00:00:00Z"}]}"#.utf8).write(to: store.url)
            XCTAssertNotNil(store.reason(for: slashFolder.appendingPathComponent("child")))
            XCTAssertNotNil(store.reason(for: slashFolder))
            try store.reset()

            // 损坏、未知版本、非普通文件都失败即关闭。
            for content in ["{", #"{"version":2,"entries":[]}"#, #"{"version":1,"entries":[{"id":"6A0C3B8E-6E0B-4F5D-9E1A-1B2C3D4E5F60","kind":"path","value":"/","added":"2026-10-10T00:00:00Z"}]}"#,
                            #"{"version":1,"entries":[{"id":"6A0C3B8E-6E0B-4F5D-9E1A-1B2C3D4E5F62","kind":"path","value":"///","added":"2026-10-10T00:00:00Z"}]}"#] {
                try Data(content.utf8).write(to: store.url)
                XCTAssertNotNil(store.reason(for: home.appendingPathComponent("Downloads/x")))
                XCTAssertNotNil(store.reason(forBundleIdentifier: "test.other"))
                XCTAssertThrowsError(try store.entries())
                XCTAssertThrowsError(try store.addBundleIdentifier("com.example.more"))
            }
            try store.reset()
            XCTAssertEqual(try store.entries().count, 0)
            XCTAssertEqual(store.reason(for: home.appendingPathComponent("Downloads/x")), nil)
            let backups = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path).filter { $0.hasSuffix(".json.bak") }
            XCTAssertEqual(backups.count, 2)

            for n in 0..<ProtectionStore.maxEntries { try store.addBundleIdentifier("test.limit.n\(n)") }
            XCTAssertThrowsError(try store.addBundleIdentifier("test.limit.extra"))
            XCTAssertEqual(try store.entries().count, ProtectionStore.maxEntries)
        }
    }

    func testDiskTrashHonorsProtection() throws {
        try withStore { home, index, store in
            let folder = home.appendingPathComponent("Downloads/Keep")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("a")
            try Data([1, 2]).write(to: file)
            _ = try Scanner.scan(root: home.appendingPathComponent("Downloads"), index: index, token: CancellationToken())
            let service = TrashService(index: index, home: home, protection: store)
            XCTAssertEqual(service.reasonBlocked(file), nil)
            let entry = try index.largestFiles().first!
            // 确认之后才加入保护：执行时复核最新列表。
            try store.addPath(folder)
            XCTAssertNotNil(service.reasonBlocked(file))
            XCTAssertNotNil(service.reasonBlocked(home.appendingPathComponent("Downloads")))
            XCTAssertEqual(service.reasonBlocked(file, applyingUserProtection: false), nil)
            let results = service.move(ids: [entry.id])
            XCTAssertEqual(results.count, 1)
            XCTAssertTrue(results[0].destination == nil && results[0].error?.contains("保护列表") == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(results[0].allocatedSize, entry.allocatedSize)
        }
    }

    func testCacheCleanupHonorsProtection() throws {
        try withStore { home, index, store in
            for id in ["test.keep", "test.other"] {
                let path = home.appendingPathComponent("Library/Caches/\(id)")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try Data(repeating: 1, count: 5).write(to: path.appendingPathComponent("data"))
            }
            try store.addBundleIdentifier("test.keep")
            let apps = [CacheApplication(id: "test.keep", name: "Keep"), CacheApplication(id: "test.other", name: "Other")]
            let cleanup = CacheCleanup(index: index, home: home, applications: apps, protection: store)
            let result = try cleanup.scan(token: CancellationToken())
            XCTAssertEqual(result.summary.errors, 0)
            XCTAssertTrue(result.groups.first { $0.id == "test.keep" }?.blockedReason?.contains("保护列表") == true)
            XCTAssertEqual(result.groups.first { $0.id == "test.other" }?.blockedReason, nil)
            // 扫描后才保护 test.other：刷新与执行都拒绝，文件保留。
            try store.addPath(home.appendingPathComponent("Library/Caches/test.other/data"))
            XCTAssertNotNil(try cleanup.refresh(isRunning: { _ in false }).first { $0.id == "test.other" }?.blockedReason)
            let moved = cleanup.move(groupIDs: ["test.other"], isRunning: { _ in false })
            XCTAssertTrue(moved.allSatisfy { $0.destination == nil && $0.error != nil })
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/test.other/data").path))
        }
    }

    func testApplicationRemovalHonorsProtection() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-protection-app-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        var destinations: [URL] = []
        defer { for url in destinations { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        let store = ProtectionStore(url: home.appendingPathComponent("protection.json"))
        let keep = apps.appendingPathComponent("Keep.app"), target = apps.appendingPathComponent("Target.app")
        try makeTestApplication(keep, id: "test.keep")
        try makeTestApplication(target, id: "test.target")
        let support = home.appendingPathComponent("Library/Application Support/test.target")
        let cache = home.appendingPathComponent("Library/Caches/test.target")
        for url in [support, cache] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1]).write(to: url.appendingPathComponent("data"))
        }
        try store.addBundleIdentifier("test.keep")
        try store.addPath(support)
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps], protection: store)
        let scanned = try remover.scan(token: CancellationToken())
        XCTAssertTrue(scanned.applications.first { $0.url.path == keep.path }?.blockedReason?.contains("保护列表") == true)
        XCTAssertEqual(scanned.applications.first { $0.url.path == target.path }?.blockedReason, nil)
        XCTAssertEqual(remover.move(id: keep.path, isRunning: { _ in false }).destination, nil)

        let preview = try remover.inspectRelatedData(id: target.path, token: CancellationToken())
        let supportItem = preview.items.first { $0.url.path == support.path }
        XCTAssertTrue(supportItem != nil && supportItem?.includedInRemoval == false && supportItem?.issue?.contains("保护列表") == true)
        let plan = try remover.prepareDataRemoval(id: target.path, token: CancellationToken(), isRunning: { _ in false })
        XCTAssertEqual(plan.paths.map(\.path), [cache.path])

        // 计划冻结后再保护缓存：保护生效、缓存保留；App 仍按“保留无法处理数据”的语义移走。
        try store.addPath(cache)
        let refused = remover.moveIncludingData(plan: plan, isRunning: { _ in false })
        XCTAssertTrue(refused.count == 2 && refused[0].destination != nil && refused[0].error == nil)
        XCTAssertTrue(refused[1].destination == nil && refused[1].error?.contains("保护列表") == true)
        XCTAssertTrue(fm.fileExists(atPath: cache.appendingPathComponent("data").path))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        destinations += refused.compactMap(\.destination)
        try store.remove(id: try store.entries().first { $0.value == cache.path }!.id)

        // 解除缓存保护后，重新出现的同一应用可完成完整卸载；仍受保护的 support 保留。
        try makeTestApplication(target, id: "test.target")
        _ = try remover.scan(token: CancellationToken())
        let fresh = try remover.prepareDataRemoval(id: target.path, token: CancellationToken(), isRunning: { _ in false })
        let results = remover.moveIncludingData(plan: fresh, isRunning: { _ in false })
        destinations += results.compactMap(\.destination)
        XCTAssertTrue(results.count == 2 && results.allSatisfy { $0.destination != nil && $0.error == nil && $0.allocatedSize != nil })
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("data").path))
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
    }

    func testDuplicateKeeperMayBeProtected() throws {
        try withStore { home, index, store in
            let root = home.appendingPathComponent("Dups")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("keep"), withIntermediateDirectories: true)
            let keeperURL = root.appendingPathComponent("keep/a.bin"), copy = root.appendingPathComponent("b.bin"), other = root.appendingPathComponent("c.bin")
            for url in [keeperURL, copy, other] { try Data(repeating: 7, count: 4096).write(to: url) }
            try store.addPath(root.appendingPathComponent("keep"))
            let service = DuplicateFiles(index: index, home: home, protection: store)
            _ = try service.scan(root: root, token: CancellationToken())
            let group = try service.groups().first!
            let members = try service.members(groupID: group.id)
            XCTAssertEqual(members.count, 3)
            let keeper = members.first { $0.url.path == keeperURL.path }!
            let copyEntry = members.first { $0.url.path == copy.path }!, otherEntry = members.first { $0.url.path == other.path }!
            try store.addPath(other)
            let refused = service.move(groupID: group.id, keeperID: keeper.id, ids: [otherEntry.id], token: CancellationToken())
            XCTAssertTrue(refused.allSatisfy { $0.destination == nil && $0.error?.contains("保护列表") == true })
            let moved = service.move(groupID: group.id, keeperID: keeper.id, ids: [copyEntry.id], token: CancellationToken())
            XCTAssertTrue(moved.count == 1 && moved[0].destination != nil && moved[0].error == nil)
            if let url = moved[0].destination { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: keeperURL.path) && FileManager.default.fileExists(atPath: other.path))
        }
    }
}
