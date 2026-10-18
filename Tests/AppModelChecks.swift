import Foundation
import AppKit
import Darwin
import MacEvenCore
import SQLite3

@main struct ModelChecks {
    @MainActor static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            precondition(Date() < deadline, "model did not settle in 10 seconds")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        precondition(bytes(0) == "0 KB", "zero disk usage should use a digit")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-model-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let a = base.appendingPathComponent("first")
        let b = base.appendingPathComponent("second")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        for i in 0..<2000 { try Data([1]).write(to: a.appendingPathComponent("file-\(i)")) }
        for (name, size) in [("small",3),("large",7)] {
            let dir = b.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: dir.appendingPathComponent("file"))
        }
        let cache = base.appendingPathComponent("cache")
        let model = AppModel(cacheDirectory: cache)
        precondition(model.browseMode == .purposes, "disk analysis should open in purpose mode")
        model.setBrowseMode(.directory)
        model.start(root: a)
        model.cancel()
        model.start(root: b)
        try await waitUntil { !model.scanning && !model.loading }
        precondition(model.rootEntry?.logicalSize == 10, "old scan overwrote new result")
        precondition(model.progress?.allocatedSize == model.rootEntry?.allocatedSize, "progress differs from disk usage total")
        precondition(model.summary?.cancelled == false, "new scan inherited cancellation")
        precondition(model.entries.count == 2)
        // 进度估算：完成的扫描记住条目数作为下次分母；结束后不再显示进度。
        precondition(model.estimates.expected("disk:" + b.standardizedFileURL.path) == model.summary?.visited, "completed scan did not record estimate")
        precondition(model.progressEstimate == .unknown, "progress shown after scan finished")
        let small = model.entries.first { $0.name == "small" }!
        let large = model.entries.first { $0.name == "large" }!
        model.selection = [large.id]
        precondition(model.selectedSize == large.allocatedSize, "selection uses logical size instead of disk usage")
        model.load(directory: small.id)
        model.load(directory: large.id)
        try await waitUntil { !model.loading }
        precondition(model.breadcrumbs.last?.id == large.id, "old query overwrote latest page")
        precondition(model.entries.first?.logicalSize == 7)
        model.showLargeFiles(true)
        try await waitUntil { !model.loading }
        precondition(model.largeFilesScope == .cleanable, "large files should open in cleanable scope")
        precondition(model.entries.isEmpty, "temporary scan root is outside the real home and must not list cleanable files")
        model.setLargeFilesScope(.all)
        try await waitUntil { !model.loading }
        precondition(model.entries.map(\.logicalSize) == [7,3])
        precondition(model.largeFilesScope == .all, "scope switch must survive the current run")
        // 端到端：扫描一个充当主目录的测试根，默认只列出可清理文件，全部范围跳到包内文件并解释锁。
        let scopedHome = base.appendingPathComponent("cleanable-home")
        try fm.createDirectory(at: scopedHome.appendingPathComponent("Downloads/Foo.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: scopedHome.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 20).write(to: scopedHome.appendingPathComponent("Downloads/keep.bin"))
        try Data(repeating: 1, count: 30).write(to: scopedHome.appendingPathComponent("Library/locked.bin"))
        try Data(repeating: 1, count: 40).write(to: scopedHome.appendingPathComponent("Downloads/Foo.app/Contents/bundle.bin"))
        let scoped = AppModel(cacheDirectory: base.appendingPathComponent("scoped-cache"), home: scopedHome)
        scoped.setBrowseMode(.largeFiles)
        scoped.start(root: scopedHome)
        try await waitUntil { !scoped.scanning && !scoped.loading }
        precondition(scoped.entries.map(\.name) == ["keep.bin"], "cleanable scope must exclude Library and app bundle files")
        scoped.setLargeFilesScope(.all)
        try await waitUntil { !scoped.loading }
        precondition(scoped.entries.map(\.name) == ["locked.bin", "keep.bin"], "all scope must still skip bundle-internal files")
        precondition(scoped.largeFilesSkippedBundleCount == 1, "bundle skip count should describe this ranking window")
        precondition(scoped.blocked.values.contains(BlockKind.libraryOrHidden), "Library entry keeps an honest lock with a structured reason")
        let active = try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: []).filter { $0.lastPathComponent.hasPrefix("session-") }
        precondition(active.count == 1)
        let estimating = AppModel(cacheDirectory: base.appendingPathComponent("estimate-cache"))
        estimating.start(root: a); estimating.cancel()
        try await waitUntil { !estimating.scanning && !estimating.loading }
        precondition(estimating.summary?.cancelled == true && estimating.estimates.expected("disk:" + a.standardizedFileURL.path) == nil, "cancelled scan recorded estimate")
        estimating.start(root: a)
        try await waitUntil { !estimating.scanning && !estimating.loading }
        precondition(estimating.estimates.expected("disk:" + a.standardizedFileURL.path) == 2000, "estimate should count the 2000 scanned files")
        let competing = AppModel(cacheDirectory: cache)
        competing.start(root: a)
        try await waitUntil { !competing.scanning }
        precondition(competing.rootEntry == nil, "second instance acquired active index cache")
        precondition(fm.fileExists(atPath: active[0].path), "second instance deleted first session")
        let competingError: String? = await withCheckedContinuation { continuation in
            competing.shutdown { continuation.resume(returning: $0) }
        }
        precondition(competingError == nil)
        let error: String? = await withCheckedContinuation { continuation in
            model.shutdown { error in continuation.resume(returning: error) }
        }
        precondition(error == nil, "session cleanup failed")
        let stale = cache.appendingPathComponent("session-\(UUID())")
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        let launcher = AppModel(cacheDirectory: cache)
        launcher.prepareSessions()
        try await waitUntil { !fm.fileExists(atPath: stale.path) }
        let launcherError: String? = await withCheckedContinuation { continuation in
            launcher.shutdown { continuation.resume(returning: $0) }
        }
        precondition(launcherError == nil)
        let partial = AppModel(cacheDirectory: cache)
        partial.start(root: a)
        partial.cancel()
        try await waitUntil { !partial.scanning && !partial.loading }
        precondition(partial.summary?.cancelled == true)
        partial.status = "文件操作完成"
        precondition(partial.incompleteResultNotice != nil, "operation message erased incomplete scan notice")
        partial.showSpaceInsights()
        try await waitUntil { !partial.loading }
        precondition(partial.incompleteResultNotice != nil && partial.categoryStats.count == 7, "cancelled scan could not browse partial categories with a fresh query token")
        let removed = try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: []).first { $0.lastPathComponent.hasPrefix("session-") }!
        try fm.removeItem(at: removed)
        partial.start(root: b)
        try await waitUntil { !partial.scanning && !partial.loading }
        precondition(partial.rootEntry?.logicalSize == 10, "missing old session prevented recovery scan")
        let partialError: String? = await withCheckedContinuation { continuation in
            partial.shutdown { continuation.resume(returning: $0) }
        }
        precondition(partialError == nil)
        let permissionRoot = base.appendingPathComponent("permission-root")
        let locked = permissionRoot.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data([1]).write(to: locked.appendingPathComponent("file"))
        precondition(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o700) }
        let permissionModel = AppModel(cacheDirectory: cache)
        permissionModel.start(root: permissionRoot)
        try await waitUntil { !permissionModel.scanning && !permissionModel.loading }
        precondition(permissionModel.summary?.failedPathCount == 1 && permissionModel.summary?.issues.count == 1)
        precondition(permissionModel.summary?.issues.first?.path == locked.path && !permissionModel.errorExamples.isEmpty)
        precondition(permissionModel.incompleteResultNotice == "部分路径未能完成扫描，当前结果不完整")
        permissionModel.start(root: b)
        precondition(permissionModel.summary == nil && permissionModel.errorExamples.isEmpty, "rescan retained old diagnostics")
        try await waitUntil { !permissionModel.scanning && !permissionModel.loading }
        precondition(permissionModel.summary?.errors == 0 && permissionModel.summary?.issues.isEmpty == true)
        let permissionError: String? = await withCheckedContinuation { continuation in
            permissionModel.shutdown { continuation.resume(returning: $0) }
        }
        precondition(permissionError == nil)
        let spaceRoot = base.appendingPathComponent("space")
        let docs = spaceRoot.appendingPathComponent("Documents")
        let pictures = spaceRoot.appendingPathComponent("Pictures")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try fm.createDirectory(at: pictures, withIntermediateDirectories: true)
        for i in 0..<105 { try Data([1]).write(to: docs.appendingPathComponent("file-\(i).PDF")) }
        try Data([2]).write(to: pictures.appendingPathComponent("photo.JPG"))
        let space = AppModel(cacheDirectory: cache)
        space.setBrowseMode(.directory)
        space.start(root: spaceRoot)
        try await waitUntil { !space.scanning && !space.loading }
        let docID = space.entries.first { $0.name == "Documents" }!.id
        space.load(directory: docID)
        try await waitUntil { !space.loading }
        space.showSpaceInsights()
        try await waitUntil { !space.loading }
        precondition(space.browseMode == .spaceInsights && space.breadcrumbs.last?.id == docID, "browse switch lost directory context")
        precondition(space.filteredCount == 105 && space.entries.count == 100 && space.canNext)
        precondition(space.categoryStats.first { $0.category == .document }?.count == 105)
        space.load(offset: 100)
        try await waitUntil { !space.loading }
        precondition(space.entries.count == 5 && !space.canNext)
        space.selection = [space.entries[0].id]
        space.applySpaceFilter(try SpaceFilter(category: .image))
        space.applySpaceFilter(try SpaceFilter(category: .document))
        try await waitUntil { !space.loading }
        precondition(space.filteredCount == 105 && space.offset == 0 && space.selection.isEmpty, "late filter result or stale selection")
        space.applySpaceFilter(try SpaceFilter(minAllocated: 1_048_576))
        try await waitUntil { !space.loading }
        precondition(space.filteredCount == 0 && space.categoryStats.first { $0.category == .document }?.count == 105, "filter changed whole-scope category statistics")
        space.clearSpaceFilter()
        space.load(directory: 1)
        try await waitUntil { !space.loading }
        precondition(space.filteredCount == 106 && space.selection.isEmpty && space.offset == 0)
        space.applySpaceFilter(try SpaceFilter(notModifiedSince: 1))
        try await waitUntil { !space.loading }
        precondition(space.entries.isEmpty, "new files passed old-file condition")
        space.clearSpaceFilter()
        space.cancel()
        try await waitUntil { !space.loading }
        space.showSpaceInsights()
        try await waitUntil { !space.loading }
        precondition(space.filteredCount == 106, "cancelled query prevented recovery")
        space.applySpaceFilter(try SpaceFilter(category: .image))
        let spaceError: String? = await withCheckedContinuation { continuation in
            space.shutdown { continuation.resume(returning: $0) }
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(spaceError == nil && !space.loading && !space.busy && space.entries.isEmpty, "shutdown published late query or left busy state")
        space.start(root: spaceRoot)
        precondition(!space.scanning, "closed model restarted")
        let trashRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/MacEven-space-check-\(UUID())")
        try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: trashRoot) }
        let targetURL = trashRoot.appendingPathComponent("target-\(UUID()).txt")
        let keepURL = trashRoot.appendingPathComponent("keep-\(UUID()).jpg")
        try Data([1]).write(to: targetURL); try Data([2]).write(to: keepURL)
        let trashModel = AppModel(cacheDirectory: cache)
        trashModel.start(root: trashRoot)
        try await waitUntil { !trashModel.scanning && !trashModel.loading }
        trashModel.showSpaceInsights()
        try await waitUntil { !trashModel.loading }
        let target = trashModel.entries.first { $0.url.lastPathComponent == targetURL.lastPathComponent }!
        let kept = trashModel.entries.first { $0.url.lastPathComponent == keepURL.lastPathComponent }!
        trashModel.selection = [target.id]; trashModel.prepareTrash()
        precondition(trashModel.trashConfirmation?.entries.map(\.id) == [target.id])
        trashModel.selection = [kept.id]
        precondition(trashModel.trashConfirmation?.entries.map(\.id) == [target.id], "selection replaced frozen confirmation")
        trashModel.applySpaceFilter(try SpaceFilter(category: .image))
        precondition(trashModel.trashConfirmation == nil, "filter left stale confirmation")
        try await waitUntil { !trashModel.loading }
        trashModel.clearSpaceFilter()
        try await waitUntil { !trashModel.loading }
        trashModel.selection = [target.id]; trashModel.prepareTrash(); trashModel.selection = [kept.id]
        trashModel.trashSelected()
        try await waitUntil { !trashModel.operating && !trashModel.loading }
        precondition(!fm.fileExists(atPath: targetURL.path) && fm.fileExists(atPath: keepURL.path), "trash used live selection instead of fixed target")
        precondition(trashModel.filteredCount == 1 && trashModel.categoryStats.reduce(0) { $0 + $1.count } == 1, "trash left stale space statistics")
        precondition(trashModel.trashResults.count == 1 && trashModel.trashResults[0].error == nil)
        guard let destination = trashModel.trashResults[0].destination else { throw MacEvenError("fixture did not move") }
        try fm.removeItem(at: destination)
        try Data([3,4]).write(to: keepURL)
        trashModel.selection = [kept.id]; trashModel.prepareTrash(); trashModel.trashSelected()
        try await waitUntil { !trashModel.operating && !trashModel.loading }
        precondition(fm.fileExists(atPath: keepURL.path) && trashModel.trashResults[0].destination == nil && trashModel.trashResults[0].error != nil, "changed file identity was accepted")
        trashModel.start(root: trashRoot)
        try await waitUntil { !trashModel.scanning && !trashModel.loading }
        let fresh = trashModel.entries.first!
        let session = try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: []).first { $0.lastPathComponent.hasPrefix("session-") }!
        var db: OpaquePointer?
        precondition(sqlite3_open(session.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK)
        precondition(sqlite3_exec(db, "CREATE TRIGGER fixture_failure BEFORE DELETE ON nodes BEGIN SELECT RAISE(FAIL,'fixture'); END", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        trashModel.selection = [fresh.id]; trashModel.prepareTrash(); trashModel.trashSelected()
        try await waitUntil { !trashModel.operating && !trashModel.loading }
        precondition(trashModel.rootEntry == nil && trashModel.entries.isEmpty && trashModel.categoryStats.isEmpty && trashModel.filteredCount == 0, "index failure exposed stale actionable statistics")
        precondition(trashModel.trashResults[0].destination != nil && trashModel.trashResults[0].error != nil && !fm.fileExists(atPath: keepURL.path), "actual move outcome was lost on index failure")
        try fm.removeItem(at: trashModel.trashResults[0].destination!)
        let trashError: String? = await withCheckedContinuation { continuation in trashModel.shutdown { continuation.resume(returning: $0) } }
        precondition(trashError == nil)
        // 用途标签：只做解释，应用目录在后台注入；不改变选择与可删性。
        let project = base.appendingPathComponent("purpose/web")
        try fm.createDirectory(at: project.appendingPathComponent("node_modules/react"), withIntermediateDirectories: true)
        try Data([1]).write(to: project.appendingPathComponent("package.json"))
        try Data([1]).write(to: project.appendingPathComponent("node_modules/react/index.js"))
        let purposeModel = AppModel(cacheDirectory: base.appendingPathComponent("purpose-cache"))
        purposeModel.applicationCatalog = { [CacheApplication(id: "com.example.web", name: "Web")] }
        purposeModel.start(root: project)
        try await waitUntil { !purposeModel.scanning && !purposeModel.loading }
        precondition(purposeModel.browseMode == .purposes && purposeModel.purposeSummary != nil &&
            purposeModel.purposeCategory == purposeModel.purposeSummary?.groups.first?.category, "initial scan did not show purpose summary")
        purposeModel.setBrowseMode(.directory)
        try await waitUntil { !purposeModel.loading }
        let modules = purposeModel.entries.first { $0.name == "node_modules" }!
        precondition(purposeModel.labels[modules.id]?.ruleID == "proj.node_modules", "node_modules was not labelled")
        precondition(purposeModel.labels[modules.id]?.inherited == false)
        purposeModel.selection = [modules.id]
        // 夹具在主目录外，现有保护会拦住；“可重建”标签不能解除它。
        precondition(purposeModel.labels[modules.id]?.safety == .regenerable && purposeModel.blocked[modules.id] != nil && !purposeModel.canTrash, "purpose label lifted existing protection")
        // 全盘按用途汇总：默认选占用最多的用途，合计与根一致；列表带归属字节与标签；可跳到目录浏览。
        purposeModel.showPurpose(nil)
        try await waitUntil { !purposeModel.loading }
        let purposeSummary = purposeModel.purposeSummary!
        precondition(purposeModel.browseMode == .purposes && purposeModel.purposeCategory == purposeSummary.groups.first?.category, "default purpose not selected")
        precondition(purposeSummary.total == purposeModel.rootEntry!.allocatedSize && purposeSummary.labeled + purposeSummary.unlabeled == purposeSummary.total, "purpose totals inconsistent")
        precondition(purposeSummary.groups.contains { $0.category == .buildArtifact && $0.bytes > 0 }, "build artifacts missing from summary")
        purposeModel.showPurpose(.buildArtifact)
        try await waitUntil { !purposeModel.loading }
        precondition(purposeModel.purposeCategory == .buildArtifact && purposeModel.entries.map(\.id) == [modules.id], "purpose page wrong")
        precondition((purposeModel.purposeBytes[modules.id] ?? 0) > 0 && purposeModel.listedSize(modules) == purposeModel.purposeBytes[modules.id], "purpose bytes missing")
        precondition(purposeModel.labels[modules.id]?.ruleID == "proj.node_modules" && !purposeModel.showsBreadcrumbs && purposeModel.directoryLabel == nil)
        purposeModel.browse(directory: modules.id)
        try await waitUntil { !purposeModel.loading }
        precondition(purposeModel.browseMode == .directory && purposeModel.purposeBytes.isEmpty, "browse did not return to directory mode")
        precondition(purposeModel.directoryLabel?.ruleID == "proj.node_modules" && purposeModel.labels.values.allSatisfy { $0.inherited }, "directory purpose missing")
        let purposeError: String? = await withCheckedContinuation { continuation in purposeModel.shutdown { continuation.resume(returning: $0) } }
        precondition(purposeError == nil && purposeModel.labels.isEmpty && purposeModel.directoryLabel == nil && purposeModel.purposeSummary == nil)
        // 重复文件是磁盘分析的浏览方式：无独立页面，进入不触发磁盘索引查询，切回目录会重新加载。
        let navigation = AppModel(cacheDirectory: base.appendingPathComponent("nav-cache"))
        navigation.start(root: b)
        try await waitUntil { !navigation.scanning && !navigation.loading }
        navigation.setBrowseMode(.duplicates)
        precondition(navigation.browseMode == .duplicates && !navigation.loading)
        navigation.setBrowseMode(.directory)
        try await waitUntil { !navigation.loading }
        precondition(navigation.browseMode == .directory && navigation.rootEntry != nil)
        let navigationError: String? = await withCheckedContinuation { continuation in navigation.shutdown { continuation.resume(returning: $0) } }
        precondition(navigationError == nil)
        // 简洁模式归一由 ContentView 负责；模型层允许直接设置任意浏览方式。

        // 历史摘要：隔离 UserDefaults suite 跨实例恢复、无清理权限、取消和失败不覆盖
        let historySuite = "MacEven.app-history-test." + UUID().uuidString
        let historyDefaults = UserDefaults(suiteName: historySuite)!
        defer { historyDefaults.removePersistentDomain(forName: historySuite) }
        let historyCache = base.appendingPathComponent("history-cache")
        let historyModel = AppModel(cacheDirectory: historyCache, historyDefaults: historyDefaults)
        precondition(historyModel.lastAnalysis == nil)
        historyModel.start(root: b)
        try await waitUntil { !historyModel.scanning && !historyModel.loading }
        precondition(historyModel.lastAnalysis != nil)
        let savedReport = historyModel.lastAnalysis!
        // 跨实例不恢复，退出后重新开始，仅在当前运行轮次生效
        let restoredModel = AppModel(cacheDirectory: base.appendingPathComponent("history-restored"), historyDefaults: historyDefaults)
        precondition(restoredModel.lastAnalysis == nil, "new app session must not restore previous scan results")
        precondition(restoredModel.selection.isEmpty && !restoredModel.canTrash && restoredModel.rootEntry == nil && restoredModel.entries.isEmpty)
        precondition(AnalysisReport.load("disk", defaults: historyDefaults) == nil)
        let restoredError: String? = await withCheckedContinuation { c in restoredModel.shutdown { c.resume(returning: $0) } }
        precondition(restoredError == nil)
        // 取消不影响当前会话内存中的已有报告
        historyModel.start(root: a); historyModel.cancel()
        try await waitUntil { !historyModel.scanning && !historyModel.loading }
        precondition(historyModel.summary?.cancelled == true)
        precondition(historyModel.lastAnalysis == savedReport, "cancelled scan overwrote lastAnalysis")
        precondition(AnalysisReport.load("disk", defaults: historyDefaults) == nil)
        // 失败新实例不会读取历史报告
        let failingModel = AppModel(cacheDirectory: historyCache, historyDefaults: historyDefaults)
        failingModel.start(root: b) // historyCache 锁仍由 historyModel 持有
        try await waitUntil { !failingModel.scanning }
        precondition(failingModel.status == "扫描失败" && failingModel.lastAnalysis == nil, "new failing session must start fresh without history")
        precondition(AnalysisReport.load("disk", defaults: historyDefaults) == nil)
        let failingError: String? = await withCheckedContinuation { c in failingModel.shutdown { c.resume(returning: $0) } }
        precondition(failingError == nil)
        let historyError: String? = await withCheckedContinuation { c in historyModel.shutdown { c.resume(returning: $0) } }
        precondition(historyError == nil)

        // 验证系统保护判定与用途展开状态
        let checkModel = AppModel(cacheDirectory: base.appendingPathComponent("check-model"))
        precondition(!checkModel.expandPurposeFiles, "expandPurposeFiles should default to false")
        checkModel.showPurpose(.cache)
        precondition(checkModel.expandPurposeFiles, "showPurpose with category should set expandPurposeFiles to true")
        let dummySystemProtected = ScanIssue(path: "/usr/sbin/authserver", category: .systemProtected, message: "保护")
        let dummySummary = ScanSummary(rootID: 1, visited: 10, cancelled: false, errors: 1, errorExamples: [dummySystemProtected.formattedText], elapsed: 0.1, unpathedErrors: 0, issues: [dummySystemProtected])
        checkModel.summary = dummySummary
        precondition(checkModel.hasOnlySystemProtectedIssues, "should detect hasOnlySystemProtectedIssues")
        precondition(checkModel.incompleteResultNotice == nil, "system protected only issues should not show incomplete banner")
        let _ = await withCheckedContinuation { c in checkModel.shutdown { c.resume(returning: $0) } }

        print("PASS: model cancellation/restart, space filters/paging, fixed trash targets, identity refusal, retained outcomes on index failure, latest-query ownership, cross-instance isolation, shutdown, purpose labels, purpose summary, disk tab memory, history retention")
    }
}
