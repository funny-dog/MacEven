import Foundation
import MacEvenCore

final class DeveloperActivityState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ reason: String?) { lock.withLock { value = reason } }
    func get(_ rule: DeveloperCleanupRule, _ path: URL) -> String? { lock.withLock { value } }
}

@main struct DeveloperCleanupModelChecks {
    @MainActor static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            precondition(Date() < deadline, "developer model did not settle")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("MacEven-developer-model-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let home = try canonicalFileURL(temporary)
        var trash: [URL] = []
        defer { for path in trash { try? fm.removeItem(at: path) }; try? fm.removeItem(at: home) }
        let sessions = home.appendingPathComponent("sessions")
        let activity = DeveloperActivityState()
        let model = DeveloperCleanupModel(home: home, cacheDirectory: sessions, activity: activity.get)
        model.otherBusy = { true }
        model.start()
        precondition(!model.scanning, "developer scan ignored another operation")
        model.otherBusy = { false }
        model.start(); model.cancel(); model.start()
        try await waitUntil { !model.busy }
        precondition(model.groups.isEmpty && model.selection.isEmpty && !model.incomplete && !model.canClean)
        precondition(model.confirmation == nil, "cancelled generation published confirmation")
        for _ in 0..<3 {
            model.start(); try await waitUntil { !model.busy }
            let contents = try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [])
            precondition(contents.filter { $0.lastPathComponent.hasPrefix("session-") }.count == 1, "developer indexes accumulated")
        }
        let hash = String(repeating: "a", count: 56)
        let metadata = home.appendingPathComponent("Library/Caches/pip/http-v2/a/a/a/a/a/" + hash)
        try fm.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cc=4,metadata".utf8).write(to: metadata)
        let body = URL(fileURLWithPath: metadata.path + ".body")
        try Data(repeating: 1, count: 8192).write(to: body)
        model.start(); try await waitUntil { !model.busy }
        precondition(model.groups.count == 1 && model.selection.isEmpty && !model.canClean)
        let broken = home.appendingPathComponent(".gradle/caches")
        try fm.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: broken, withDestinationURL: home)
        model.start(); try await waitUntil { !model.busy }
        precondition(model.incomplete && model.measuredSize > 0, "a broken cache erased statistics from valid caches")
        model.select("pip", selected: true); precondition(model.canClean)
        try fm.removeItem(at: broken)
        model.prepareCleanup(); let frozen = model.confirmation!
        model.select("pip", selected: false)
        precondition(model.confirmation == frozen, "confirmation followed live selection")
        activity.set("下载仍在运行")
        model.executeCleanup(); try await waitUntil { !model.busy }
        precondition(model.results.allSatisfy { $0.destination == nil && $0.error != nil })
        precondition(fm.fileExists(atPath: body.path))
        activity.set(nil); model.recheck(); try await waitUntil { !model.busy }
        model.select("pip", selected: true); model.prepareCleanup()
        model.start(); precondition(model.confirmation == nil && model.selection.isEmpty)
        try await waitUntil { !model.busy }
        model.select("pip", selected: true); model.prepareCleanup(); model.select("pip", selected: false)
        model.executeCleanup(); try await waitUntil { !model.busy }
        trash += model.results.compactMap(\.destination)
        precondition(model.results.count == 1 && model.results[0].destination != nil && model.results[0].error == nil)
        precondition(!fm.fileExists(atPath: body.path))

        let unknown = home.appendingPathComponent("Library/Caches/pip/unknown")
        try fm.createDirectory(at: unknown, withIntermediateDirectories: true)
        model.start(); try await waitUntil { !model.busy }
        model.select("pip", selected: true)
        precondition(model.selection.isEmpty && !model.canClean, "read-only unknown row became selectable")
        try fm.removeItem(at: home.appendingPathComponent("Library/Caches/pip"))
        for number in 0..<102 {
            let directory = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/unknown-\(number)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("kept.txt"))
        }
        model.start(); try await waitUntil { !model.busy }
        precondition(model.groups.count == 100 && model.canNext)
        model.load(offset: 100)
        precondition(model.groups.count == 2 && !model.canNext && model.selection.isEmpty)
        let error: String? = await withCheckedContinuation { continuation in
            model.shutdown { continuation.resume(returning: $0) }
        }
        precondition(error == nil)
        let remaining = try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [])
        precondition(remaining.allSatisfy { !$0.lastPathComponent.hasPrefix("session-") })
        model.start(); precondition(!model.scanning, "closed developer model restarted")

        let combined = CacheModel(home: home, applications: [], cacheDirectory: home.appendingPathComponent("combined"))
        combined.developer.start()
        precondition(combined.busy, "developer busy was not visible to other pages")
        combined.start(); precondition(!combined.scanning, "application scan overlapped developer scan")
        try await waitUntil { !combined.busy }
        combined.start(); precondition(combined.scanning)
        combined.developer.start(); precondition(!combined.developer.scanning, "developer scan overlapped application scan")
        let combinedError: String? = await withCheckedContinuation { continuation in
            combined.shutdown { continuation.resume(returning: $0) }
        }
        precondition(combinedError == nil)
        let developerDirectory = home.appendingPathComponent("combined/developer")
        let developerRemaining = try fm.contentsOfDirectory(at: developerDirectory, includingPropertiesForKeys: [])
        precondition(developerRemaining.allSatisfy { !$0.lastPathComponent.hasPrefix("session-") })
        let browserRoot = home.appendingPathComponent("Library/Caches/Google/Chrome")
        let browserData = browserRoot.appendingPathComponent("Default/Cache/data")
        try fm.createDirectory(at: browserData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: browserData)
        let browserActivity = DeveloperActivityState()
        browserActivity.set("浏览器正在运行")
        let browser = DeveloperCleanupModel(home: home, cacheDirectory: home.appendingPathComponent("browser-sessions"),
            activity: { rule, _ in rule == .chrome ? browserActivity.get(rule, browserRoot) : nil },
            browserRunning: { id in id == "com.google.Chrome" && browserActivity.get(.chrome, browserRoot) != nil },
            quitApplication: { id, url in
                guard id == "com.google.Chrome", url == nil else { return "关闭了错误的浏览器" }
                browserActivity.set(nil)
                do { try Data([1,2,3]).write(to: browserData) } catch { return error.localizedDescription }
                return nil
            })
        browser.start(); try await waitUntil { !browser.busy }
        browser.select("chrome", selected: true)
        precondition(browser.canClean && browserActivity.get(.chrome, browserRoot) != nil, "running browser cannot be selected or quit before confirmation")
        browser.prepareCleanup(); browser.executeCleanup(); try await waitUntil { !browser.busy }
        trash += browser.results.compactMap(\.destination)
        precondition(browser.results.count == 1 && browser.results[0].destination != nil && browser.results[0].error == nil, "browser close then rescan/cleanup failed: \(browser.results)")
        let browserError: String? = await withCheckedContinuation { continuation in browser.shutdown { continuation.resume(returning: $0) } }
        precondition(browserError == nil)
        print("PASS: developer missing paths, defaults, frozen selection, activity race, read-only rows, restart generations, busy coordination, index ownership and shutdown")
    }
}
