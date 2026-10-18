import Foundation
import MacEvenCore

// Breaks caught: broad Library scope, guessed app ownership, stale nested files,
// running apps becoming deletable, and resetting hard-link ownership per root.
final class CacheTests {
    func testMetadataDiscoveryWithoutAppRegistry() throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw), fm = FileManager.default
            let bundle = home.appendingPathComponent("Applications/Atlas Desktop.app")
            try fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "com.example.unregistered-atlas", "CFBundleName": "Atlas Engine",
                "CFBundleDisplayName": "星图", "CFBundleExecutable": "Electron"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            let discovered = CacheApplication(bundleURL: bundle)!
            precondition(discovered.id == info["CFBundleIdentifier"] && Set(discovered.directoryNames) == ["Atlas Desktop", "Atlas Engine", "星图"])
            let app = CacheApplication(id: discovered.id, name: discovered.name, directoryNames: discovered.directoryNames,
                applicationGroups: ["group.com.example.atlas"])
            let own = ["Library/Caches/atlas engine", "Library/Application Support/Atlas Desktop/Code Cache", ".cache/星图"]
            let shared = "Library/Group Containers/group.com.example.atlas/Library/Caches"
            let readonly = ["Library/Caches/Electron", "Library/Caches/Firefox", "Library/Application Support/Electron/Cache",
                "Library/Application Support/Atlas Desktop/Session Storage", "Library/Application Support/Atlas Desktop/Dawn..Cache", ".cache/unrelated"]
            for relative in own + readonly + [shared] {
                let path = home.appendingPathComponent(relative)
                try fm.createDirectory(at: path, withIntermediateDirectories: true)
                try Data([7]).write(to: path.appendingPathComponent("data"))
            }
            let cleaner = CacheCleanup(index: index, home: home, applications: [app,
                CacheApplication(id: "org.mozilla.firefox", name: "Firefox", directoryNames: ["Firefox"]),
                CacheApplication(id: "test.generic", name: "Electron", directoryNames: ["Electron", "../Atlas Desktop", "Atlas Desktop/..", "Shared"])])
            let result = try cleaner.scan(token: CancellationToken())
            let group = result.groups.first { $0.id == app.id }!
            precondition(Set(group.paths.map(\.path)) == Set(own.map { home.appendingPathComponent($0).path }))
            precondition(group.logicalSize == 3 && group.blockedReason == nil, "shared cache blocked private roots")
            let sharedGroup = result.groups.first { $0.paths.contains(home.appendingPathComponent(shared)) }!
            precondition(sharedGroup.blockedReason != nil && sharedGroup.logicalSize == 1)
            precondition(result.groups.filter { $0.id != app.id }.allSatisfy { $0.blockedReason != nil }, "generic name or browser overlap became selectable")
            let service = TrashService(index: index, home: home, cacheApplications: [app])
            for relative in readonly + [shared, "Library/Application Support/Atlas Desktop", ".cache"] {
                precondition(service.reasonBlocked(home.appendingPathComponent(relative)) != nil, "metadata opened unrelated data: \(relative)")
            }
            let conflict = CacheCleanup(index: index, home: home, applications: [app,
                CacheApplication(id: "test.collision", name: "Other", directoryNames: ["ATLAS ENGINE", "Atlas Desktop", "星图"])])
            let conflicted = try conflict.scan(token: CancellationToken())
            let ownURLs = Set(own.map { home.appendingPathComponent($0) })
            let collisions = conflicted.groups.filter { !$0.paths.filter { ownURLs.contains($0) }.isEmpty }
            precondition(collisions.count == own.count && collisions.allSatisfy { $0.blockedReason != nil })
            let ambiguous = TrashService(index: index, home: home, cacheApplications: [app,
                CacheApplication(id: "test.collision", name: "Other", directoryNames: ["Atlas Desktop"])])
            precondition(ambiguous.reasonBlocked(home.appendingPathComponent("Library/Application Support/Atlas Desktop/Code Cache")) != nil)
            _ = try cleaner.scan(token: CancellationToken())
            let moved = cleaner.move(groupIDs: [app.id], isRunning: { _ in false })
            defer { for value in moved { if let path = value.destination { try? fm.removeItem(at: path) } } }
            precondition(moved.count == own.count && moved.allSatisfy { $0.destination != nil && $0.error == nil })
            for relative in readonly + [shared] { precondition(fm.fileExists(atPath: home.appendingPathComponent(relative + "/data").path)) }
        }
    }

    func testNamedAndApplicationSupportCaches() throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw), fm = FileManager.default
            let id = "com.anthropic.claudefordesktop"
            let caches = ["Library/Caches/\(id)", "Library/Caches/Claude", "Library/Containers/\(id)/Data/Library/Caches"] +
                ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "ShaderCache"].map { "Library/Application Support/Claude/\($0)" }
            let retained = ["Library/Application Support/Claude/IndexedDB", "Library/Application Support/Claude/Session Storage",
                "Library/Application Support/Claude/Local Storage", "Library/Application Support/Claude/Service Worker",
                "Library/Application Support/Claude/Cache-backup", "Library/Application Support/ClaudeOther/Cache"]
            for relative in caches + retained {
                let path = home.appendingPathComponent(relative + "/data")
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: path)
            }
            let store = ProtectionStore(url: home.appendingPathComponent("protection.json"))
            let cleaner = CacheCleanup(index: index, home: home, applications: [CacheApplication(id: id, name: "Claude", directoryNames: ["Claude"])], protection: store)
            let result = try cleaner.scan(token: CancellationToken())
            precondition(result.summary.errors == 0 && !result.truncated)
            let group = result.groups.first { $0.id == id }!
            precondition(Set(group.paths.map(\.path)) == Set(caches.map { home.appendingPathComponent($0).path }))
            precondition(group.logicalSize == Int64(caches.count * 3) && group.blockedReason == nil)
            let service = TrashService(index: index, home: home, cacheApplications: [CacheApplication(id: id, name: "Claude", directoryNames: ["Claude"])], protection: store)
            for relative in retained + ["Library", "Library/Caches", "Library/Application Support/Claude", "Library/Application Support"] {
                precondition(service.reasonBlocked(home.appendingPathComponent(relative)) != nil, "cache allowlist escaped: \(relative)")
            }
            precondition(cleaner.move(groupIDs: [id], isRunning: { _ in true }).allSatisfy { $0.destination == nil && $0.error != nil })
            _ = try store.addBundleIdentifier(id)
            precondition(cleaner.move(groupIDs: [id], isRunning: { _ in false }).allSatisfy { $0.destination == nil && $0.error != nil }, "late bundle protection missed named caches")
            precondition(service.reasonBlocked(home.appendingPathComponent("Library/Caches/Claude")) != nil)
            precondition(service.reasonBlocked(home.appendingPathComponent("Library/Application Support/Claude/Cache")) != nil)
            try store.remove(id: store.entries()[0].id)
            let moved = cleaner.move(groupIDs: [id], isRunning: { _ in false })
            defer { for value in moved { if let path = value.destination { try? fm.removeItem(at: path) } } }
            precondition(moved.count == caches.count && moved.allSatisfy { $0.destination != nil && $0.error == nil })
            for relative in retained { precondition(fm.fileExists(atPath: home.appendingPathComponent(relative + "/data").path)) }
        }
    }

    func testCacheAliasOwnershipAndIsolation() throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw), fm = FileManager.default
            let aliases = [("com.openai.codex", "Codex"), ("com.bot.pc.doubao", "Doubao"), ("com.electron.lark", "LarkShell"),
                ("com.valvesoftware.steam", "Steam"), ("com.bitwarden.desktop", "bitwarden-updater"), ("dev.zed.Zed", "Zed")]
            for (_, name) in aliases + [("", "Firefox"), ("", "Google"), ("", "ClaudeOther")] {
                let path = home.appendingPathComponent("Library/Caches/\(name)")
                try fm.createDirectory(at: path, withIntermediateDirectories: true)
                try Data([1]).write(to: path.appendingPathComponent("data"))
            }
            let products = home.appendingPathComponent("Library/Application Support/Codex/Cache")
            try fm.createDirectory(at: products, withIntermediateDirectories: true)
            try Data([2]).write(to: products.appendingPathComponent("data"))
            let applications = aliases.map { CacheApplication(id: $0.0, name: "Unrelated display name", directoryNames: [$0.1]) }
            let cleaner = CacheCleanup(index: index, home: home, applications: applications)
            let result = try cleaner.scan(token: CancellationToken())
            for (id, name) in aliases {
                let group = result.groups.first { $0.id == id }!
                precondition(group.blockedReason == nil && group.paths.contains(home.appendingPathComponent("Library/Caches/\(name)")))
                precondition(group.paths.count == (id == "com.openai.codex" ? 2 : 1), "duplicate cache root")
            }
            precondition(result.groups.filter { $0.id.hasPrefix("unknown:") }.count == 3)
            precondition(result.groups.filter { $0.id.hasPrefix("unknown:") }.allSatisfy { $0.blockedReason != nil })
            let absent = CacheCleanup(index: index, home: home, applications: [CacheApplication(id: "test.impostor", name: "Codex")])
            let absentResult = try absent.scan(token: CancellationToken())
            precondition(absentResult.groups.allSatisfy { $0.blockedReason != nil }, "display name granted ownership")
            precondition(!absentResult.groups.flatMap(\.paths).contains(products), "uninstalled product gained support cache ownership")
            let conflict = CacheCleanup(index: index, home: home, applications: applications + [CacheApplication(id: "Codex", name: "Different app")])
            let conflictResult = try conflict.scan(token: CancellationToken())
            precondition(conflictResult.groups.first { $0.paths.contains(home.appendingPathComponent("Library/Caches/Codex")) }?.blockedReason != nil, "ambiguous alias was deletable")
        }
    }

    func testNamedCacheLinksAndChanges() throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw), fm = FileManager.default
            let cache = home.appendingPathComponent("Library/Application Support/Claude/Cache")
            try fm.createDirectory(at: cache.appendingPathComponent("deep"), withIntermediateDirectories: true)
            let file = cache.appendingPathComponent("deep/data")
            try Data([1]).write(to: file)
            let id = "com.anthropic.claudefordesktop"
            let cleaner = CacheCleanup(index: index, home: home, applications: [CacheApplication(id: id, name: "Claude", directoryNames: ["Claude"])])
            _ = try cleaner.scan(token: CancellationToken())
            try Data([1, 2]).write(to: file)
            precondition(cleaner.move(groupIDs: [id], isRunning: { _ in false }).allSatisfy { $0.destination == nil && $0.error != nil })
            _ = try cleaner.scan(token: CancellationToken())
            let product = cache.deletingLastPathComponent(), movedProduct = home.appendingPathComponent("saved-product")
            try fm.moveItem(at: product, to: movedProduct)
            try fm.createSymbolicLink(at: product, withDestinationURL: movedProduct)
            precondition(cleaner.move(groupIDs: [id], isRunning: { _ in false }).allSatisfy { $0.destination == nil && $0.error != nil })
            let linked = try cleaner.scan(token: CancellationToken())
            precondition(linked.summary.errors > 0 && linked.groups.allSatisfy { $0.blockedReason != nil })
            precondition(fm.fileExists(atPath: movedProduct.appendingPathComponent("Cache/deep/data").path))
        }
    }

    func withCache(_ body: (URL, DiskIndex, CacheCleanup) throws -> Void) throws {
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw)
            for suffix in ["Library/Caches/test.closed", "Library/Containers/test.closed/Data/Library/Caches", "Library/Caches/unknown", "Library/Caches/com.apple.test", "Library/Caches/COM.APPLE.upper", "Library/Caches/MacEven"] {
                let path = home.appendingPathComponent(suffix)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try Data(repeating: 1, count: 5).write(to: path.appendingPathComponent("data"))
            }
            let apps = [CacheApplication(id: "test.closed", name: "Closed"), CacheApplication(id: "com.apple.test", name: "System"), CacheApplication(id: "COM.APPLE.upper", name: "System Case"), CacheApplication(id: "../escape", name: "Bad")]
            try body(home, index, CacheCleanup(index: index, home: home, applications: apps))
        }
    }

    func testGroupingAndScope() throws {
        try withCache { home, index, cleanup in
            let result = try cleanup.scan(token: CancellationToken())
            let closed = result.groups.first { $0.id == "test.closed" }!
            precondition(closed.paths.count == 2 && closed.logicalSize == 10)
            precondition(closed.blockedReason == nil)
            precondition(result.groups.filter { $0.id != "test.closed" }.allSatisfy { $0.blockedReason != nil })
            precondition(result.groups.allSatisfy { $0.logicalSize != nil && $0.allocatedSize != nil }, "read-only cache sizes were skipped")
            let cache = home.appendingPathComponent("Library/Caches/test.closed")
            precondition(TrashService(index: index, home: home).reasonBlocked(cache) != nil, "ordinary disk scope opened Library")
            let scoped = TrashService(index: index, home: home, cacheBundleIdentifiers: ["test.closed"])
            precondition(scoped.reasonBlocked(cache) == nil)
            precondition(scoped.reasonBlocked(home.appendingPathComponent("Library/Caches")) != nil)
            precondition(scoped.reasonBlocked(home.appendingPathComponent("Library/Application Support/test.closed")) != nil)
            precondition(scoped.reasonBlocked(home.appendingPathComponent("Library/Caches/test.closed.extra")) != nil)
            let ordinary = home.appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
            precondition(TrashService(index: index, home: home, cacheBundleIdentifiers: ["../bad"]).reasonBlocked(ordinary) != nil, "invalid cache scope fell back to ordinary file access")
            let running = try cleanup.refresh(isRunning: { $0 == "test.closed" })
            precondition(running.first { $0.id == "test.closed" }?.blockedReason != nil)
            let stopped = try cleanup.refresh(isRunning: { _ in false })
            precondition(stopped.first { $0.id == "test.closed" }?.blockedReason == nil)
            precondition(cleanup.move(groupIDs: ["unknown"], isRunning: { _ in false }).allSatisfy { $0.error != nil })
        }
    }

    func testOwnCacheIndexDoesNotInvalidateOtherCaches() throws {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent("MacEven-cache-index-\(UUID())")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let home = try canonicalFileURL(raw)
        defer { try? fm.removeItem(at: home) }
        for name in ["MacEven", "test.closed"] {
            try fm.createDirectory(at: home.appendingPathComponent("Library/Caches/" + name), withIntermediateDirectories: true)
        }
        try Data([1, 2, 3]).write(to: home.appendingPathComponent("Library/Caches/test.closed/data"))
        let index = try DiskIndex(url: home.appendingPathComponent("Library/Caches/MacEven/index.sqlite"))
        defer { index.close() }
        let cleaner = CacheCleanup(index: index, home: home, applications: [CacheApplication(id: "test.closed", name: "Closed")])
        let result = try cleaner.scan(token: CancellationToken())
        precondition(result.summary.errors == 0 && result.groups.first { $0.id == "test.closed" }?.blockedReason == nil)
    }

    func testNestedChangeAndLinkAncestor() throws {
        try withCache { home, _, cleanup in
            let nested = home.appendingPathComponent("Library/Caches/test.closed/deep")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let file = nested.appendingPathComponent("child")
            try Data([1]).write(to: file)
            _ = try cleanup.scan(token: CancellationToken())
            try Data([1,2]).write(to: file)
            let result = cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in false })
            // Group preflight validates both roots before any move.
            precondition(result.allSatisfy { $0.destination == nil && $0.error != nil })
            precondition(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Containers/test.closed/Data/Library/Caches/data").path))
        }
        try withCache { home, _, cleanup in
            _ = try cleanup.scan(token: CancellationToken())
            let library = home.appendingPathComponent("Library")
            let moved = home.appendingPathComponent("saved-library")
            try FileManager.default.moveItem(at: library, to: moved)
            try FileManager.default.createSymbolicLink(at: library, withDestinationURL: moved)
            let result = cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in false })
            precondition(result.allSatisfy { $0.destination == nil && $0.error != nil })
        }
    }

    func testRescanAfterQuitKeepsScopeAndIdentity() throws {
        try withCache { home, _, cleanup in
            _ = try cleanup.scan(token: CancellationToken())
            let file = home.appendingPathComponent("Library/Caches/test.closed/data")
            try Data([1,2,3,4,5,6]).write(to: file)
            try cleanup.rescanAfterQuit(groupID: "test.closed", token: CancellationToken(), isRunning: { _ in false })
            let refreshed = try cleanup.refresh(isRunning: { _ in false }).first { $0.id == "test.closed" }!
            precondition(refreshed.logicalSize == 11, "post-quit rescan retained stale hard-link identities")
            let result = cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in false })
            defer { for value in result { if let path = value.destination { try? FileManager.default.removeItem(at: path) } } }
            precondition(result.count == 2 && result.allSatisfy { $0.destination != nil && $0.error == nil })
            precondition(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/unknown/data").path))
        }
        try withCache { home, _, cleanup in
            _ = try cleanup.scan(token: CancellationToken())
            let root = home.appendingPathComponent("Library/Caches/test.closed")
            try FileManager.default.moveItem(at: root, to: home.appendingPathComponent("original"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do { try cleanup.rescanAfterQuit(groupID: "test.closed", token: CancellationToken(), isRunning: { _ in false }); preconditionFailure("replaced cache root accepted") } catch { }
            precondition(cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in false }).allSatisfy { $0.destination == nil })
        }
    }

    func testTrashNamedCacheDescendantsAreValidated() throws {
        for name in [".Trash", ".Trashes"] {
            try withCache { home, _, cleanup in
                let root = home.appendingPathComponent("Library/Caches/test.closed")
                let deep = root.appendingPathComponent(name + "/deep")
                try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
                let file = deep.appendingPathComponent("data")
                try Data([1, 2, 3]).write(to: file)
                let result = try cleanup.scan(token: CancellationToken())
                precondition(result.groups.first { $0.id == "test.closed" }?.logicalSize == 13,
                    "trash-named cache subtree silently skipped")
                let before = try FileIdentity.read(root)
                try Data([1, 2, 3, 4]).write(to: file)
                let after = try FileIdentity.read(root)
                precondition(after == before)
                let moved = cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in false })
                defer { for value in moved { if let path = value.destination { try? FileManager.default.removeItem(at: path) } } }
                precondition(moved.allSatisfy { $0.destination == nil && $0.error != nil })
            }
        }
    }

    func testHardLinksCancellationAndNativeTrash() throws {
        try withCache { home, _, cleanup in
            let fm = FileManager.default
            let first = home.appendingPathComponent("Library/Caches/test.closed/data")
            let second = home.appendingPathComponent("Library/Containers/test.closed/Data/Library/Caches/data")
            try fm.removeItem(at: second); try fm.linkItem(at: first, to: second)
            let result = try cleanup.scan(token: CancellationToken())
            precondition(result.groups.first { $0.id == "test.closed" }?.logicalSize == 5, "cross-root hard link counted twice")
            let blocked = cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in true })
            precondition(blocked.allSatisfy { $0.destination == nil && $0.error != nil })
            let moved = cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in false })
            defer { for value in moved { if let path = value.destination { try? fm.removeItem(at: path) } } }
            precondition(moved.count == 2 && moved.allSatisfy { $0.destination != nil && $0.error == nil })
            precondition(!fm.fileExists(atPath: first.path) && !fm.fileExists(atPath: second.path))
            precondition(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/unknown/data").path))
        }
        try withCache { _, _, cleanup in
            let token = CancellationToken(); token.cancel()
            let result = try cleanup.scan(token: token)
            precondition(result.summary.cancelled)
            precondition(result.groups.allSatisfy { $0.blockedReason != nil })
        }
    }

    func testRunningRecheckedAfterValidation() throws {
        try withCache { home, _, cleanup in
            try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Containers/test.closed"))
            _ = try cleanup.scan(token: CancellationToken())
            var checks = 0
            // First two reads are stopped; the final read must observe startup.
            let moved = cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in checks += 1; return checks >= 3 })
            defer { for value in moved { if let path = value.destination { try? FileManager.default.removeItem(at: path) } } }
            precondition(moved.allSatisfy { $0.destination == nil && $0.error != nil },
                "running state not rechecked after subtree validation")
            precondition(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/test.closed/data").path))
        }
    }

    func testRunningBetweenRootsAndBounds() throws {
        try withCache { home, _, cleanup in
            _ = try cleanup.scan(token: CancellationToken())
            var checks = 0
            let moved = cleanup.move(groupIDs: ["test.closed"], isRunning: { _ in checks += 1; return checks >= 4 })
            defer { for value in moved { if let path = value.destination { try? FileManager.default.removeItem(at: path) } } }
            precondition(moved.filter { $0.destination != nil }.count == 1)
            precondition(moved.filter { $0.error != nil }.count == 1)
            let paths = ["Library/Caches/test.closed", "Library/Containers/test.closed/Data/Library/Caches"]
            precondition(paths.filter { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }.count == 1)
            precondition(cleanup.move(groupIDs: (0..<51).map(String.init), isRunning: { _ in false }).allSatisfy { $0.error != nil })
        }
        try CoreTests().withTree { raw, index in
            let home = try canonicalFileURL(raw)
            let dir = home.appendingPathComponent("Library/Caches")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in 0..<4100 { try FileManager.default.createDirectory(at: dir.appendingPathComponent("unknown-\(n)"), withIntermediateDirectories: false) }
            let result = try CacheCleanup(index: index, home: home, applications: []).scan(token: CancellationToken())
            precondition(result.truncated && result.groups.count <= 4096)
        }
    }

    func testInaccessibleSandboxDoesNotBecomePartialEligibleGroup() throws {
        try withCache { home, _, cleanup in
            let parent = home.appendingPathComponent("Library/Containers/test.closed/Data")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
            let result = try cleanup.scan(token: CancellationToken())
            precondition(result.groups.first { $0.id == "test.closed" }?.blockedReason != nil, "inaccessible sandbox silently vanished from eligible group")
            precondition(result.summary.errors > 0)
        }
    }
}
