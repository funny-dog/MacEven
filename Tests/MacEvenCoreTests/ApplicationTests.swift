import Foundation
import Darwin
import SQLite3
import MacEvenCore

func makeTestApplication(_ path: URL, id: String) throws {
    let contents = path.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    let plist = ["CFBundleIdentifier": id, "CFBundleName": path.deletingPathExtension().lastPathComponent, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try Data([1,2,3]).write(to: contents.appendingPathComponent("Resources/data"))
}

final class ApplicationTests {
    func testRemovalScopeAndChanges() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-app-test-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        var destinations: [URL] = []
        defer { for url in destinations { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        for (name, id) in [("中文 Closed", "test.closed"), ("Copy", "test.closed"), ("System", "com.apple.test"), ("Self", "local.maceven.app")] {
            try makeTestApplication(apps.appendingPathComponent(name + ".app"), id: id)
        }
        let closed = apps.appendingPathComponent("中文 Closed.app")
        let cache = home.appendingPathComponent("Library/Caches/test.closed")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([4]).write(to: cache.appendingPathComponent("kept"))
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        let result = try remover.scan(token: CancellationToken())
        precondition(result.applications.count == 4 && !result.incomplete)
        let row = result.applications.first { $0.url == closed }!
        precondition(row.cachePaths.map(\.path) == [cache.path] && row.logicalSize! > 3 && row.blockedReason == nil, "unexpected application: \(row)")
        precondition(result.applications.filter { $0.bundleIdentifier == "test.closed" }.count == 2)
        precondition(result.applications.filter { $0.bundleIdentifier != "test.closed" }.allSatisfy { $0.blockedReason != nil })
        for app in result.applications.filter({ $0.bundleIdentifier != "test.closed" }) {
            precondition(app.allocatedSize != nil && app.logicalSize! > 3, "protected app size was skipped")
            precondition(remover.move(id: app.id, isRunning: { _ in false }).destination == nil && fm.fileExists(atPath: app.id), "size measurement allowed protected app removal")
        }
        let running = try remover.refresh(isRunning: { _ in true })
        precondition(running.allSatisfy { $0.blockedReason != nil })
        precondition(remover.move(id: row.id, isRunning: { _ in true }).destination == nil)
        precondition(remover.move(id: cache.path, isRunning: { _ in false }).destination == nil)
        try Data([8,9]).write(to: closed.appendingPathComponent("Contents/Resources/data"))
        precondition(remover.move(id: row.id, isRunning: { _ in false }).destination == nil, "deep change accepted")
        _ = try remover.scan(token: CancellationToken())
        var checks = 0
        let restarted = remover.move(id: row.id, isRunning: { app in
            guard app.id == row.id else { return false }
            checks += 1; return checks == 2
        })
        if let url = restarted.destination { destinations.append(url) }
        guard checks == 2, restarted.destination == nil, fm.fileExists(atPath: closed.path) else {
            throw MacEvenError("running check missing after complete validation of selected application")
        }
        let moved = remover.move(id: row.id, isRunning: { _ in false })
        if let url = moved.destination { destinations.append(url) }
        precondition(moved.destination != nil && moved.error == nil && !fm.fileExists(atPath: closed.path))
        precondition(fm.fileExists(atPath: cache.appendingPathComponent("kept").path), "uninstall removed user cache")
        let remaining = try remover.refresh(isRunning: { _ in false })
        precondition(remaining.count == 3)
        let token = CancellationToken(); token.cancel()
        let cancelled = try remover.scan(token: token)
        precondition(cancelled.incomplete && cancelled.applications.allSatisfy { $0.blockedReason != nil })
    }

    func testAncestryDiscoveryAndBounds() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-app-scope-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        defer { try? fm.removeItem(at: home) }
        let path = apps.appendingPathComponent("folder/Closed.app")
        try makeTestApplication(path, id: "test.closed")
        try makeTestApplication(path.appendingPathComponent("Contents/Nested.app"), id: "test.nested")
        try makeTestApplication(apps.appendingPathComponent("Invalid.app"), id: "../bad")
        try fm.createSymbolicLink(at: apps.appendingPathComponent("Alias.app"), withDestinationURL: path)
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        let scan = try remover.scan(token: CancellationToken())
        precondition(scan.applications.count == 2, "enumerated nested bundle or symlink")
        precondition(scan.applications.first { $0.url.lastPathComponent == "Invalid.app" }?.blockedReason != nil)
        let invalid = scan.applications.first { $0.url.lastPathComponent == "Invalid.app" }!
        precondition(invalid.allocatedSize != nil && invalid.logicalSize! > 3, "unrecognized app size was skipped")
        precondition(remover.move(id: invalid.id, isRunning: { _ in false }).destination == nil && fm.fileExists(atPath: invalid.id), "unrecognized app became removable")
        let folder = apps.appendingPathComponent("folder"), backup = apps.appendingPathComponent("backup")
        try fm.moveItem(at: folder, to: backup)
        try fm.createSymbolicLink(at: folder, withDestinationURL: backup)
        precondition(remover.move(id: path.path, isRunning: { _ in false }).destination == nil)
        let linked = home.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: apps)
        let bad = ApplicationRemoval(index: index, home: home, roots: [linked])
        let badResult = try bad.scan(token: CancellationToken())
        precondition(badResult.incomplete)
        try fm.removeItem(at: folder)
        try fm.moveItem(at: backup, to: folder)
        let locked = apps.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0); defer { chmod(locked.path, 0o700) }
        let incomplete = try remover.scan(token: CancellationToken())
        precondition(incomplete.incomplete && !incomplete.errors.isEmpty && incomplete.applications.allSatisfy { $0.blockedReason != nil })
    }

    func testIndexFailureAfterSuccessfulMove() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-app-failure-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), apps = home.appendingPathComponent("Applications")
        var destinations: [URL] = []
        defer { for url in destinations { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        let first = apps.appendingPathComponent("First.app"), second = apps.appendingPathComponent("Second.app")
        try makeTestApplication(first, id: "test.first"); try makeTestApplication(second, id: "test.second")
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        let remover = ApplicationRemoval(index: index, home: home, roots: [apps])
        _ = try remover.scan(token: CancellationToken())
        var database: OpaquePointer?
        guard sqlite3_open(index.url.path, &database) == SQLITE_OK else { throw MacEvenError("fixture database open failed") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TRIGGER fail_removal BEFORE DELETE ON nodes BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END", nil, nil, nil) == SQLITE_OK else { throw MacEvenError("fixture trigger failed") }
        let result = remover.move(id: first.path, isRunning: { _ in false })
        if let url = result.destination { destinations.append(url) }
        guard result.destination != nil, result.error?.contains("已移到废纸篓，但索引同步失败") == true, !fm.fileExists(atPath: first.path) else { throw MacEvenError("successful move lost index failure result") }
        let rows = try remover.refresh(isRunning: { _ in false })
        guard rows.allSatisfy({ $0.blockedReason != nil }) else { throw MacEvenError("index failure left another application eligible") }
        let next = remover.move(id: second.path, isRunning: { _ in false })
        if let url = next.destination { destinations.append(url) }
        guard next.destination == nil, next.error != nil, fm.fileExists(atPath: second.path) else { throw MacEvenError("index failure did not stop later removal") }
    }
}
