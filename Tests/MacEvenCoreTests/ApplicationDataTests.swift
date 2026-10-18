import Foundation
import Darwin
import MacEvenCore

final class ApplicationDataTests {
    func testCompleteRemovalAndSafety() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-app-data-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        var destinations: [URL] = []
        defer { for url in destinations { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        let app = apps.appendingPathComponent("Target.app"), identifier = "test.removal"
        try makeTestApplication(app, id: identifier)
        let cache = home.appendingPathComponent("Library/Caches/\(identifier)")
        let support = home.appendingPathComponent("Library/Application Support/\(identifier)")
        let container = home.appendingPathComponent("Library/Containers/\(identifier)")
        let preferences = home.appendingPathComponent("Library/Preferences/\(identifier).plist")
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost/\(identifier).\(UUID()).plist")
        for url in [cache, support, container.appendingPathComponent("Data/Documents")] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1]).write(to: url.appendingPathComponent("data"))
        }
        for url in [preferences, byHost] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([2]).write(to: url)
        }
        let unrelated = home.appendingPathComponent("Library/Caches/\(identifier).other.deep")
        let suffixed = home.appendingPathComponent("Library/Caches/\(identifier).BundleMigration")
        let shared = home.appendingPathComponent("Library/Group Containers/\(identifier)")
        let userDocument = home.appendingPathComponent("Documents/Target.txt")
        for url in [unrelated, suffixed, shared, userDocument.deletingLastPathComponent()] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data([3]).write(to: userDocument)
        // A container's link to external documents must be moved as a link, never followed.
        try fm.createSymbolicLink(at: container.appendingPathComponent("Data/External"), withDestinationURL: userDocument.deletingLastPathComponent())
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        _ = try remover.scan(token: CancellationToken())
        func prepare() throws -> ApplicationDataPlan {
            try remover.prepareDataRemoval(id: app.path, token: CancellationToken(), isRunning: { _ in false })
        }
        var plan = try prepare()
        precondition(Set(plan.paths.map(\.path)) == Set([cache, support, container, preferences, byHost, suffixed].map(\.path)), "incorrect data scope")
        try Data([7,8]).write(to: support.appendingPathComponent("data"))
        var results = remover.moveIncludingData(plan: plan, isRunning: { _ in false })
        precondition(results.allSatisfy { $0.destination == nil && $0.error != nil } && fm.fileExists(atPath: app.path), "deep data change accepted")
        plan = try prepare()
        let logs = home.appendingPathComponent("Library/Logs/\(identifier)")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        results = remover.moveIncludingData(plan: plan, isRunning: { _ in false })
        precondition(results[0].destination == nil && fm.fileExists(atPath: app.path), "new data path ignored")
        try fm.removeItem(at: logs)
        plan = try prepare()
        let damaged = apps.appendingPathComponent("Damaged.app")
        try fm.createDirectory(at: damaged.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let copy = apps.appendingPathComponent("NewCopy.app")
        try makeTestApplication(copy, id: identifier)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "AAPL"], format: .xml, options: 0).write(to: copy.appendingPathComponent("Contents/Info.plist"))
        results = remover.moveIncludingData(plan: plan, isRunning: { _ in false })
        precondition(results[0].destination == nil && results[0].error?.contains("同标识") == true && fm.fileExists(atPath: app.path) && fm.fileExists(atPath: support.path), "damaged app hid a new copy's shared data")
        try fm.removeItem(at: copy)
        plan = try prepare()
        precondition(Set(plan.paths.map(\.path)) == Set([cache, support, container, preferences, byHost, suffixed].map(\.path)), "damaged app changed data scope")
        try fm.removeItem(at: damaged)
        let cancelled = CancellationToken(); cancelled.cancel()
        do { _ = try remover.prepareDataRemoval(id: app.path, token: cancelled, isRunning: { _ in false }); preconditionFailure("cancelled preparation accepted") }
        catch { }
        plan = try prepare()
        try Data([9,8,7]).write(to: support.appendingPathComponent("data"))
        try Data([4,5]).write(to: preferences, options: .atomic)
        plan = try remover.rescanDataAfterQuit(plan: plan, token: CancellationToken(), isRunning: { _ in false })
        results = remover.moveIncludingData(plan: plan, isRunning: { _ in false })
        destinations += results.compactMap(\.destination)
        precondition(results.count == 7 && results.allSatisfy { $0.destination != nil && $0.error == nil }, "full removal failed: \(results)")
        precondition(!fm.fileExists(atPath: app.path) && plan.paths.allSatisfy { !fm.fileExists(atPath: $0.path) })
        precondition(fm.fileExists(atPath: unrelated.path) && fm.fileExists(atPath: shared.path) && fm.fileExists(atPath: userDocument.path), "unrelated data removed")
        precondition(remover.moveIncludingData(plan: plan, isRunning: { _ in false })[0].destination == nil, "replayed plan accepted")
    }

    func testLinksCopiesAndPartialFailure() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-app-data-guard-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        var destinations: [URL] = []
        defer { for url in destinations { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        let app = apps.appendingPathComponent("Target.app"), copy = apps.appendingPathComponent("Copy.app"), identifier = "test.guard"
        try makeTestApplication(app, id: identifier); try makeTestApplication(copy, id: identifier)
        let cache = home.appendingPathComponent("Library/Caches/\(identifier)")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        _ = try remover.scan(token: CancellationToken())
        func prepare() throws -> ApplicationDataPlan {
            try remover.prepareDataRemoval(id: app.path, token: CancellationToken(), isRunning: { _ in false })
        }
        let sharedPlan = try prepare()
        precondition(sharedPlan.paths.isEmpty && !sharedPlan.retainedReasons.isEmpty, "shared data must be retained without blocking app removal")
        try fm.removeItem(at: copy); _ = try remover.scan(token: CancellationToken())
        let backup = home.appendingPathComponent("backup")
        try fm.moveItem(at: cache, to: backup)
        try fm.createSymbolicLink(at: cache, withDestinationURL: backup)
        let linkedPlan = try prepare()
        precondition(linkedPlan.paths.isEmpty && !linkedPlan.retainedReasons.isEmpty, "symlink data must be retained without blocking app removal")
        try fm.removeItem(at: cache); try fm.moveItem(at: backup, to: cache)
        chmod(cache.path, 0)
        let unreadablePlan = try prepare()
        precondition(unreadablePlan.paths.isEmpty && !unreadablePlan.retainedReasons.isEmpty, "unreadable data must be retained without blocking app removal")
        chmod(cache.path, 0o700)
        var plan = try prepare()
        let library = home.appendingPathComponent("Library"), original = home.appendingPathComponent("OriginalLibrary")
        try fm.moveItem(at: library, to: original)
        try fm.createSymbolicLink(at: library, withDestinationURL: original)
        precondition(remover.moveIncludingData(plan: plan, isRunning: { _ in false })[0].destination == nil, "replaced ancestor accepted")
        try fm.removeItem(at: library); try fm.moveItem(at: original, to: library)
        plan = try prepare()
        // A launch observed only after the app move stops data cleanup and reports partial results.
        let results = remover.moveIncludingData(plan: plan, isRunning: { _ in !fm.fileExists(atPath: app.path) })
        destinations += results.compactMap(\.destination)
        precondition(results.count == 2 && results[0].destination != nil && results[1].error != nil && fm.fileExists(atPath: cache.path), "partial failure was hidden")
    }

    // 主目录数据与标识加后缀目录：隐藏目录进入确认范围、可见同名目录保留、产品名全名匹配不串应用，并单独统计将清理/保留。
    func testHomeLevelAndIdentifierSuffixData() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-app-home-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        var destinations: [URL] = []
        defer { for url in destinations { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        let app = apps.appendingPathComponent("Target.app"), identifier = "test.home"
        let aiApp = apps.appendingPathComponent("Target AI.app"), aiIdentifier = "test.home.ai"
        try makeTestApplication(app, id: identifier)
        try makeTestApplication(aiApp, id: aiIdentifier)
        let hidden = home.appendingPathComponent(".target"), hiddenAI = home.appendingPathComponent(".target-ai")
        let unrelated = home.appendingPathComponent(".target-other"), visible = home.appendingPathComponent("Target")
        for url in [hidden, hiddenAI, unrelated, visible] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1]).write(to: url.appendingPathComponent("data"))
        }
        let suffixed = home.appendingPathComponent("Library/Caches/\(identifier).BundleMigration")
        let deep = home.appendingPathComponent("Library/Caches/\(identifier).other.deep")
        for url in [suffixed, deep] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1]).write(to: url.appendingPathComponent("data"))
        }
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        _ = try remover.scan(token: CancellationToken())
        let preview = try remover.inspectRelatedData(id: app.path, token: CancellationToken())
        let paths = Set(preview.items.map(\.url.path))
        precondition(paths.contains(hidden.path) && paths.contains(visible.path) && paths.contains(suffixed.path) && paths.contains(deep.path), "home-level or suffix candidate missing: \(paths)")
        precondition(!paths.contains(hiddenAI.path) && !paths.contains(unrelated.path), "product names crossed applications")
        precondition(preview.items.first { $0.url.path == hidden.path }?.includedInRemoval == true, "hidden home directory not included")
        precondition(preview.items.first { $0.url.path == visible.path }?.includedInRemoval == false, "visible home directory must be retained")
        precondition(preview.items.first { $0.url.path == suffixed.path }?.includedInRemoval == true, "identifier suffix data not included")
        precondition(preview.items.first { $0.url.path == deep.path }?.includedInRemoval == false, "multi-component suffix data must be retained")
        precondition(preview.includedSize > 0 && preview.retainedSize > 0 && preview.allocatedSize == preview.includedSize + preview.retainedSize, "size split incorrect: \(preview)")
        let plan = try remover.prepareDataRemoval(id: app.path, token: CancellationToken(), isRunning: { _ in false })
        precondition(Set(plan.paths.map(\.path)) == Set([hidden.path, suffixed.path]), "unexpected removal scope: \(plan.paths)")
        let results = remover.moveIncludingData(plan: plan, isRunning: { _ in false })
        destinations += results.compactMap(\.destination)
        precondition(results.count == 3 && results.allSatisfy { $0.destination != nil && $0.error == nil }, "home-level removal failed: \(results)")
        precondition(!fm.fileExists(atPath: hidden.path) && !fm.fileExists(atPath: suffixed.path) && fm.fileExists(atPath: visible.path) && fm.fileExists(atPath: deep.path), "home-level removal scope wrong")
    }

    func testRetainedDataDoesNotBlockRemoval() throws {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent("MacEven-partial-uninstall-\(UUID())")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let home = try canonicalFileURL(raw), apps = home.appendingPathComponent("Applications")
        let app = apps.appendingPathComponent("Target.app"), identifier = "test.partial"
        var destinations: [URL] = []
        defer { for url in destinations { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        try makeTestApplication(app, id: identifier)
        let support = home.appendingPathComponent("Library/Application Support/Target")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: support.appendingPathComponent("data"))
        let external = home.appendingPathComponent("Documents/keep")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let cache = home.appendingPathComponent("Library/Caches/\(identifier)")
        try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cache, withDestinationURL: external)
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        _ = try remover.scan(token: CancellationToken())
        let plan = try remover.prepareDataRemoval(id: app.path, token: CancellationToken(), isRunning: { _ in false })
        precondition(plan.paths.map(\.path) == [support.path] && plan.retainedReasons.contains { $0.contains(cache.path) }, "unexpected partial removal plan: \(plan)")
        let results = remover.moveIncludingData(plan: plan, isRunning: { _ in false })
        destinations += results.compactMap(\.destination)
        precondition(results.count == 2 && results.allSatisfy { $0.destination != nil && $0.error == nil })
        precondition(fm.fileExists(atPath: external.path) && (try? FileIdentity.read(cache).isSymlink) == true)

        try makeTestApplication(app, id: identifier)
        let copy = apps.appendingPathComponent("Copy.app")
        try makeTestApplication(copy, id: identifier)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        _ = try remover.scan(token: CancellationToken())
        let sharedPlan = try remover.prepareDataRemoval(id: app.path, token: CancellationToken(), isRunning: { _ in false })
        precondition(sharedPlan.paths.isEmpty && !sharedPlan.retainedReasons.isEmpty)
        let sharedResults = remover.moveIncludingData(plan: sharedPlan, isRunning: { _ in false })
        destinations += sharedResults.compactMap(\.destination)
        precondition(sharedResults.count == 1 && sharedResults[0].destination != nil && sharedResults[0].error == nil)
        precondition(fm.fileExists(atPath: copy.path) && fm.fileExists(atPath: support.path), "shared data blocked app removal or was removed")
    }
}
