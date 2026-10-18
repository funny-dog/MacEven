import Foundation
import Darwin
import MacEvenCore

final class RunningState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var allowQuit = false
    private var requests = 0
    func set(_ value: Bool) { lock.withLock { active = value } }
    var quitRequests: Int { lock.withLock { requests } }
    func permitQuit() { lock.withLock { allowQuit = true } }
    func quit(_ id: String, _ url: URL?) -> String? {
        lock.withLock {
            guard active && id == "test.closed" else { return nil }
            requests += 1
            guard allowQuit else { return "测试应用拒绝退出，缓存保留。" }
            active = false; return nil
        }
    }
    func get(_ id: String) -> Bool { lock.withLock { active && id == "test.closed" } }
}

@main struct CacheModelChecks {
    @MainActor static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() { precondition(Date() < deadline, "cache model did not settle"); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-cache-model-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base)
        var trash: [URL] = []
        defer { for path in trash { try? fm.removeItem(at: path) }; try? fm.removeItem(at: home) }
        let fakeApps = home.appendingPathComponent("Applications")
        for (name, id) in [("中文 App", "test.closed"), ("Duplicate", "test.closed"), ("Invalid", "../bad")] {
            let contents = fakeApps.appendingPathComponent(name + ".app/Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        let catalog = CacheCatalog.discover(in: [fakeApps])
        precondition(catalog.applications.count == 1 && catalog.applications[0].id == "test.closed", "catalog guessed or duplicated ownership")
        for suffix in ["Library/Caches/test.closed", "Library/Containers/test.closed/Data/Library/Caches"] {
            let dir = home.appendingPathComponent(suffix)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1,2,3]).write(to: dir.appendingPathComponent("data"))
        }
        for n in 0..<110 { try fm.createDirectory(at: home.appendingPathComponent("Library/Caches/unknown-\(n)"), withIntermediateDirectories: false) }
        let unknownLink = home.appendingPathComponent("Library/Caches/unknown-0")
        try fm.removeItem(at: unknownLink)
        try fm.createSymbolicLink(at: unknownLink, withDestinationURL: home)
        let running = RunningState()
        let session = home.appendingPathComponent("cache-sessions")
        let model = CacheModel(home: home, applications: catalog.applications, cacheDirectory: session, isRunning: running.get, quitApplication: { id, url in
            let active = running.get(id)
            if let failure = running.quit(id, url) { return failure }
            if active {
                do { try Data([4,5,6,7]).write(to: home.appendingPathComponent("Library/Caches/test.closed/quit-write")) }
                catch { return error.localizedDescription }
            }
            return nil
        })
        model.start(); model.cancel(); model.start()
        try await waitUntil { !model.busy }
        precondition(model.groups.count == 100 && model.canNext)
        precondition(model.groups.first?.id == "test.closed")
        precondition(model.groups.first?.logicalSize == 6)
        precondition(model.incomplete && model.measuredSize > 0, "partial cache statistics disappeared")
        model.load(offset: 100)
        precondition(model.groups.count == 11 && !model.canNext && model.selection.isEmpty)
        model.load(offset: 0)
        running.set(true); model.recheck()
        try await waitUntil { !model.busy }
        model.selection = ["test.closed"]
        precondition(model.canClean, "running app should be selectable before cleanup")
        running.set(false)
        precondition(model.canClean, "running status incorrectly controls selection")
        model.recheck(); try await waitUntil { !model.busy }
        model.selection = ["test.closed"]
        precondition(model.canClean)
        model.prepareCleanup()
        let confirmation = model.confirmation!
        precondition(confirmation.groups.count == 1 && confirmation.groups[0].paths.count == 2)
        model.selection = []
        precondition(model.confirmation == confirmation, "confirmation followed mutable selection")
        precondition(running.quitRequests == 0, "preparation closed an app before confirmation")
        running.set(true); model.executeCleanup()
        try await waitUntil { !model.busy }
        precondition(model.results.allSatisfy { $0.error != nil && $0.destination == nil })
        precondition(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/test.closed/data").path))
        running.set(false); model.recheck(); try await waitUntil { !model.busy }
        model.selection = ["test.closed"]; model.prepareCleanup(); model.selection = []
        running.set(true); running.permitQuit()
        model.executeCleanup(); try await waitUntil { !model.busy }
        precondition(!running.get("test.closed") && running.quitRequests == 2, "application was not normally closed before cleanup")
        trash += model.results.compactMap(\.destination)
        precondition(model.results.count == 2 && model.results.allSatisfy { $0.destination != nil && $0.error == nil })
        var minimum = UInt64.max, maximum: UInt64 = 0
        for round in 0..<12 {
            model.start(); try await waitUntil { !model.busy }
            let contents = try fm.contentsOfDirectory(at: session, includingPropertiesForKeys: [])
            precondition(contents.filter { $0.lastPathComponent.hasPrefix("session-") }.count == 1, "cache indexes accumulated across scans")
            precondition(model.groups.count <= 100 && model.results.isEmpty)
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }
            precondition(status == 0)
            if round >= 3 { minimum = min(minimum, usage.ri_resident_size); maximum = max(maximum, usage.ri_resident_size) }
        }
        precondition(maximum - minimum <= 20 * 1024 * 1024, "cache repeated-scan memory spread exceeded 20 MiB")
        print("cacheRepeatedScans=12 minRSS=\(minimum) maxRSS=\(maximum)")
        let diskSession = home.appendingPathComponent("disk-sessions")
        let disk = AppModel(cacheDirectory: diskSession)
        let diskTree = home.appendingPathComponent("disk-tree")
        try fm.createDirectory(at: diskTree, withIntermediateDirectories: true)
        try Data([1]).write(to: diskTree.appendingPathComponent("kept"))
        disk.start(root: diskTree); try await waitUntil { !disk.scanning && !disk.loading }
        let cacheError: String? = await withCheckedContinuation { c in model.shutdown { c.resume(returning: $0) } }
        precondition(cacheError == nil && disk.rootEntry != nil)
        let diskContents = try fm.contentsOfDirectory(at: diskSession, includingPropertiesForKeys: [])
        precondition(diskContents.contains { $0.lastPathComponent.hasPrefix("session-") })
        model.start(); precondition(!model.scanning, "closed cache model restarted")
        let diskError: String? = await withCheckedContinuation { c in disk.shutdown { c.resume(returning: $0) } }
        precondition(diskError == nil)
        print("PASS: native catalog, bounded pages, cancellation/restart, running recheck, frozen confirmation, owned trash, isolated shutdown")
    }
}
