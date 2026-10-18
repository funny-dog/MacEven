import Foundation
import MacEvenCore

// 防止的问题：智能扫描默认替用户选择、合并确认与各类冻结内容不一致、取消后仍执行、其他任务进行中仍开始扫描。
@main struct SmartScanModelChecks {
    @MainActor static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() { precondition(Date() < deadline, "smart scan did not settle"); try await Task.sleep(for: .milliseconds(20)) }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let home = try canonicalFileURL(fm.temporaryDirectory).appendingPathComponent("MacEven-smart-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        var trash: [URL] = []
        defer { for url in trash { try? fm.removeItem(at: url) }; try? fm.removeItem(at: home) }
        func write(_ relative: String, _ data: Data = Data(repeating: 3, count: 8192)) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try write("Library/Caches/test.smart/data")
        try write("Library/Caches/go-build/README", Data("This directory holds cached build artifacts from the Go build system.\n".utf8))
        try write("Library/Caches/go-build/00/0011-a")
        try write("Library/Caches/com.example.smartgone/data")
        try write("Library/Developer/Xcode/Archives/2026/App.xcarchive")
        try fm.createDirectory(at: home.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        let cache = CacheModel(home: home, applications: [CacheApplication(id: "test.smart", name: "Smart")], cacheDirectory: home.appendingPathComponent("cache-sessions"),
            isRunning: { _ in false }, developerActivity: { _, _ in nil })
        let snapshot: @Sendable () -> LeftoverOwnershipSnapshot = {
            LeftoverOwnershipSnapshot(check: { $0 == "com.example.smartgone" ? .orphan : .installed }, incomplete: false, errors: [])
        }
        let removal = ApplicationRemovalModel(home: home, roots: [home.appendingPathComponent("Applications")], cacheDirectory: home.appendingPathComponent("app-sessions"),
            isRunning: { _ in false }, dock: nil, leftoverSnapshot: snapshot)
        let suite = "MacEven.smart-history-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try write(".codex/sessions/keep.jsonl")
        // 足够多的会话文件让“第 4 步 · AI 工作资料扫描”有可采样的窗口，用于守住进度不回退。
        for index in 0..<200 { try write(".codex/sessions/old-\(index).jsonl", Data("{\"cwd\":\"/tmp/maceven-smart-\(index)\"}\n".utf8)) }
        let backup = OtherStorage.locations(home: home).first { $0.name == "iPhone / iPad 备份" }!
        try fm.createDirectory(at: backup.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: backup.url, withDestinationURL: home.appendingPathComponent("Library/Developer/Xcode/Archives"))
        let smart = SmartScanModel(cache: cache, removal: removal, home: home, historyDefaults: defaults)
        final class OtherBox: @unchecked Sendable { var value = true }
        let otherBox = OtherBox()
        smart.otherBusy = { otherBox.value }
        precondition(!smart.canScan); smart.scanAll(); precondition(smart.phase == .idle, "scan started while another task was busy")
        otherBox.value = false

        smart.scanAll(); smart.cancel()
        try await wait { !smart.busy && !cache.busy && !removal.busy }
        precondition(smart.phase == .idle && smart.summary?.contains("取消") == true, "cancelled scan reported ready")

        smart.scanAll()
        var fractions: [Double] = []
        var aiSamples = 0
        let progressDeadline = Date().addingTimeInterval(20)
        while smart.phase != .ready {
            precondition(Date() < progressDeadline, "smart scan did not settle")
            if let value = smart.progressEstimate.fraction { fractions.append(value) }
            // 第 4 步的位置统计完成后仍在扫描 AI 工作资料：进度必须停满，不能退回步首。
            if smart.measuringAI { aiSamples += 1; precondition(smart.progressEstimate.fraction ?? 0 >= 0.99, "progress fell back during the AI work scan: \(smart.progressEstimate)") }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(aiSamples > 0, "AI work scan window was never sampled")
        precondition(!fractions.isEmpty && fractions.allSatisfy { $0 <= 0.99 }, "smart scan progress missing or reached 100% early: \(fractions.suffix(5))")
        precondition(zip(fractions, fractions.dropFirst()).allSatisfy { $0.0 <= $0.1 + 1e-9 }, "smart scan progress went backwards: \(zip(fractions, fractions.dropFirst()).filter { $0.0 > $0.1 + 1e-9 })")
        precondition(smart.progressEstimate == .unknown && smart.measuring == nil && smart.progressCaption.isEmpty, "progress left after scan")
        precondition(cache.selectableCount == 1 && smart.developer.selectableCount == 1 && smart.leftovers.selectableCount == 1,
            "categories: \(cache.selectableCount) \(smart.developer.selectableCount) \(smart.leftovers.selectableCount) \(cache.status) \(smart.developer.status) \(smart.leftovers.status)")
        precondition(smart.storage.filter { !$0.skipped }.map(\.location.name) == ["Xcode 归档"] && smart.storage[0].allocatedSize > 0)
        precondition(smart.selectedCount == 0 && !smart.canClean, "smart scan selected items by default")
        // 分类卡的最大几项：只含可清理项，不改变选择。
        precondition(cache.largestItems.map(\.name) == ["Smart"] && smart.leftovers.largestItems.map(\.name) == ["com.example.smartgone"]
            && smart.developer.largestItems.count == 1 && smart.selectedCount == 0, "largest items")
        let rows: [(String, Int64?, Bool)] = [("a", 10, false), ("b", 50, false), ("c", nil, false), ("d", 90, true), ("e", 30, false), ("f", 20, false)]
        let largest = largestCleanupItems(rows, id: \.0, name: \.0, size: \.1, blocked: \.2)
        precondition(largest.map(\.name) == ["b", "e", "f"], "largest items must skip blocked / unmeasured and sort descending")

        precondition(smart.lastAnalysis != nil && smart.aiStorage.map(\.location.name) == ["Codex 会话"])
        precondition(smart.storage.first { $0.location.name == "iPhone / iPad 备份" }?.skipped == true)
        precondition(smart.lastAnalysis?.summary.contains("扫描完成") == true && smart.lastAnalysis?.summary.contains("按规则跳过") == true,
            "intentional symlink skip was reported as a failed scan")
        let archives = OtherStorage.locations(home: home).first { $0.name == "Xcode 归档" }!
        precondition(OtherStorage.measure(archives, token: CancellationToken(), limit: 0)?.incomplete == true, "real measurement limits were hidden")
        let restrictions = cleanupRestrictions(rows, reason: { $0.2 ? "保护策略" : nil }, size: \.1)
        precondition(restrictions.count == 2 && restrictions.allSatisfy { $0.count == 1 }, "restriction aggregation lost unmeasured or protected items")
        precondition(!cache.restrictions.isEmpty, "unowned application caches had no explanation")
        let restoredCache = CacheModel(home: home, applications: [], cacheDirectory: home.appendingPathComponent("restored-cache"))
        let restoredRemoval = ApplicationRemovalModel(home: home, roots: [], cacheDirectory: home.appendingPathComponent("restored-apps"), dock: nil)
        let restored = SmartScanModel(cache: restoredCache, removal: restoredRemoval, home: home, historyDefaults: defaults)
        precondition(restored.lastAnalysis == nil && restored.phase == .idle && restored.selectedCount == 0 && !restored.canClean,
            "new app session must start fresh without restoring previous scan results")
        let limitedCache = CacheModel(home: home, applications: Array(repeating: CacheApplication(id: "test.smart", name: "Smart"), count: 2049),
            cacheDirectory: home.appendingPathComponent("limited-cache"), isRunning: { _ in false })
        limitedCache.start(); try await wait { !limitedCache.busy }
        precondition(limitedCache.incomplete)
        limitedCache.selectLargest()
        precondition(limitedCache.selection.isEmpty || limitedCache.selection == ["test.smart"])
        limitedCache.selection = ["test.smart"]; limitedCache.prepareCleanup()
        precondition(limitedCache.confirmation != nil || !limitedCache.canClean)
        let badDirectory = home.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: badDirectory)
        let failedCache = CacheModel(home: home, applications: [], cacheDirectory: badDirectory)
        let failed = SmartScanModel(cache: failedCache, removal: restoredRemoval, home: home, historyDefaults: defaults)
        failed.scanAll(); try await wait { !failed.busy && !failedCache.busy && !restoredRemoval.busy }
        precondition(failedCache.scanFailed && failed.lastAnalysis == nil && AnalysisReport.load("cleanup", defaults: defaults) == nil,
            "failed rescan restored the discarded report")
        smart.selectAllSafe(); smart.prepareCleanup()
        precondition(smart.selectedCount > 0 && smart.confirmation != nil)
        smart.scanAll()
        precondition(smart.lastAnalysis == nil && AnalysisReport.load("cleanup", defaults: defaults) == nil)
        precondition(cache.groups.isEmpty && smart.developer.groups.isEmpty && smart.leftovers.groups.isEmpty,
            "rescan kept results from categories not scanned yet")
        precondition(smart.selectedCount == 0 && smart.confirmation == nil && cache.confirmation == nil && smart.developer.confirmation == nil && smart.leftovers.confirmation == nil)
        precondition(cache.selectableSize == 0 && smart.developer.selectableSize == 0 && smart.leftovers.selectableSize == 0)
        smart.cancel()
        try await wait { !smart.busy && !cache.busy && !removal.busy }
        precondition(smart.lastAnalysis == nil && AnalysisReport.load("cleanup", defaults: defaults) == nil, "cancelled rescan restored old history")
        smart.developer.recheck(); try await wait { !cache.busy }
        cache.recheck(); try await wait { !cache.busy }
        smart.leftovers.recheck(); try await wait { !removal.busy }
        precondition(cache.groups.isEmpty && smart.developer.groups.isEmpty && smart.leftovers.groups.isEmpty, "recheck revived discarded indexes")
        smart.scanAll(); try await wait { smart.phase == .ready }
        smart.selectAllSafe()
        precondition(smart.selectedCount == 3 && smart.canClean)
        smart.prepareCleanup()
        precondition(smart.confirmation?.count == 3 && smart.confirmation?.paths.count == 3)
        precondition(cache.confirmation != nil && smart.developer.confirmation != nil && smart.leftovers.confirmation != nil)
        smart.dismissConfirmation()
        precondition(smart.confirmation == nil && cache.confirmation == nil && smart.developer.confirmation == nil && smart.leftovers.confirmation == nil)
        // 一键清理：选择全部可清理项并生成同样的合并确认。
        smart.clearSelection(); smart.cleanAllSafe()
        precondition(smart.selectedCount == 3 && smart.confirmation?.count == 3, "cleanAllSafe did not prepare a merged confirmation")
        smart.dismissConfirmation()

        // 子页面遗留的确认不能混入合并确认。
        smart.clearSelection(); smart.leftovers.select("com.example.smartgone", selected: true)
        cache.selection = ["test.smart"]; cache.prepareCleanup(); cache.selection = []
        precondition(cache.confirmation != nil)
        smart.prepareCleanup()
        precondition(smart.confirmation?.cache == nil && smart.confirmation?.leftovers != nil && cache.confirmation == nil, "stale cache confirmation merged")
        // 确认后其他任务开始工作：不执行。
        otherBox.value = true; smart.executeCleanup(); precondition(smart.phase == .ready && smart.confirmation != nil, "executed while another task was busy")
        otherBox.value = false; smart.dismissConfirmation()
        // 确认后某类确认失效：该类不执行并如实报告。
        smart.selectAllSafe(); smart.prepareCleanup()
        let replaced = smart.leftovers.confirmation!
        smart.leftovers.dismissConfirmation(); smart.leftovers.prepareCleanup()
        precondition(smart.leftovers.confirmation?.id != replaced.id)
        smart.executeCleanup()
        try await wait { smart.phase == .done }
        trash += (cache.results + smart.developer.results + smart.leftovers.results).compactMap(\.destination)
        precondition(smart.summary?.contains("2 个路径") == true && smart.summary?.contains("卸载残留的确认已失效") == true, smart.summary ?? "no summary")
        precondition(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.example.smartgone").path), "expired confirmation executed")
        smart.leftovers.dismissConfirmation(); smart.leftovers.recheck(); try await wait { !removal.busy }
        smart.leftovers.select("com.example.smartgone", selected: true)
        smart.prepareCleanup(); smart.executeCleanup()
        try await wait { smart.phase == .done }
        trash += (cache.results + smart.developer.results + smart.leftovers.results).compactMap(\.destination)
        precondition(smart.summary?.contains("1 个路径") == true, smart.summary ?? "no summary")
        for relative in ["Library/Caches/test.smart", "Library/Caches/go-build", "Library/Caches/com.example.smartgone"] {
            precondition(!fm.fileExists(atPath: home.appendingPathComponent(relative).path), "\(relative) not moved")
        }
        precondition(fm.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/Archives/2026/App.xcarchive").path), "other storage touched")

        // 验证 AI 工作资料有独立的清理入口且不混入一键清理：默认不勾选，逐项/整行勾选后才可确认
        precondition(!smart.canCleanAIWork, "AI work records must start unselected")
        smart.prepareAIWorkCleanup()
        precondition(smart.aiWorkConfirmation == nil, "unselected AI records must not produce a confirmation")
        smart.selectAllAIWork()
        precondition(smart.canCleanAIWork, "AI work sessions should have independent cleanup entry")
        smart.prepareAIWorkCleanup()
        precondition(smart.aiWorkConfirmation != nil && smart.confirmation == nil, "AI work confirmation must be independent from smart confirmation")
        smart.aiWorkActivity = { _, _ in nil }
        smart.executeAIWorkCleanup()
        try await wait { !smart.aiWorkCleaning }
        trash += smart.aiWorkResults.compactMap(\.destination)
        precondition(!fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions/keep.jsonl").path), "AI session cleaned via independent entry")
        precondition(smart.aiWorkSelectedCount == 0 && !smart.canCleanAIWork, "executed selection must be cleared")

        let validReport = AnalysisReport(summary: "历史可清理", details: [])
        validReport.save("cleanup", defaults: defaults)
        let freshModel = SmartScanModel(cache: cache, removal: removal, home: home, historyDefaults: defaults)
        precondition(freshModel.lastAnalysis == nil, "new app session must not restore previous scan results")
        precondition(AnalysisReport.load("cleanup", defaults: defaults) == nil, "history key should be removed")
        defaults.set(Data("broken".utf8), forKey: "analysisReport.cleanup")
        precondition(AnalysisReport.load("cleanup", defaults: defaults) == nil)
        for close in [{ (done: @escaping @MainActor @Sendable (String?) -> Void) in cache.shutdown(done) }, { done in removal.shutdown(done) }, { done in restoredCache.shutdown(done) }, { done in restoredRemoval.shutdown(done) }, { done in failedCache.shutdown(done) }, { done in limitedCache.shutdown(done) }] {
            let error: String? = await withCheckedContinuation { c in close { c.resume(returning: $0) } }
            precondition(error == nil)
        }
        print("PASS: smart scan sequential scans, nothing selected by default, combined frozen confirmation, sequential cleanup, cancel and busy gating, read-only other storage")
    }
}
