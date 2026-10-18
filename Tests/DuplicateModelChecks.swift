import Foundation
import MacEvenCore
import SQLite3
import Darwin

@main struct DuplicateModelChecks {
    @MainActor static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() { precondition(Date() < deadline, "duplicate model did not settle"); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacEven-duplicate-model-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let home = try canonicalFileURL(base), tree = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        var trash: [URL] = []
        defer { for path in trash { try? fm.removeItem(at: path) }; try? fm.removeItem(at: home) }
        for n in 0..<105 { try Data([1,2,3]).write(to: tree.appendingPathComponent("file-\(n)")) }
        for n in 0..<2 { try Data([4]).write(to: tree.appendingPathComponent("other-\(n)")) }
        let sessions = home.appendingPathComponent("sessions")
        var model = DuplicateModel(home: home, cacheDirectory: sessions)
        precondition(model.minimumSize == DuplicateFiles.defaultMinimumSize)
        // 夹具是几字节的小文件：文件夹流程按“全部大小”扫描。
        model.minimumSize = 1
        model.start(scope: .folder(tree)); model.cancel()
        try await wait { !model.busy }
        precondition(model.summary?.cancelled == true && model.incomplete)
        model.loadGroups(offset: 0); try await wait { !model.busy }
        precondition(model.message == nil && model.summary != nil, "cancelled scan could not be queried")
        model.start(scope: .folder(tree))
        try await wait { !model.busy }
        precondition(model.groups.count == 2 && !model.incomplete, "groups=\(model.groups.count), errors=\(model.summary?.errorExamples ?? []), message=\(model.message ?? "none")")
        precondition(model.liveStats == nil, "interim candidate statistics must be cleared once the final result is published")
        let estimateKey = DuplicateModel.estimateKey(.folder(tree), minimumSize: 1)
        precondition(model.summary?.incremental == true || model.estimates.expected(estimateKey) == Int(model.summary!.visited), "full duplicate scan did not record estimate")
        precondition(model.progressEstimate == .unknown, "duplicate progress shown after scan")
        let group = model.groups.first { $0.memberCount == 105 }!
        model.loadMembers(groupID: group.id, offset: 0); try await wait { !model.busy }
        precondition(model.members.count == 100 && model.canNextMembers)
        let keeper = model.members[0], copy = model.members[1]
        model.keep(id: keeper.id); model.selectedIDs = [keeper.id]
        precondition(!model.canClean, "keeper became a cleanup target")
        model.selectedIDs = [copy.id]; model.prepareCleanup()
        let frozen = model.confirmation!
        model.selectedIDs = []
        precondition(model.confirmation?.id == frozen.id && model.confirmation?.targetIDs == [copy.id])
        model.dismissConfirmation()
        model.loadMembers(groupID: group.id, offset: 100); try await wait { !model.busy }
        precondition(model.members.count == 5 && !model.canNextMembers && model.keeperID == keeper.id && model.selectedIDs.isEmpty)
        let other = model.groups.first { $0.id != group.id }!
        model.loadMembers(groupID: other.id, offset: 0); try await wait { !model.busy }
        // 换组后默认保留最早的一份并勾选其余副本，保留文件不在勾选中。
        let earliest = model.members.min { ($0.identity.modified, $0.url.path) < ($1.identity.modified, $1.url.path) }!
        precondition(model.keeperID == earliest.id && model.keeperPath == earliest.url.path, "default keeper is not the earliest file")
        precondition(model.selectedIDs == Set(model.members.filter { $0.id != earliest.id }.prefix(50).map(\.id)) && !model.selectedIDs.contains(earliest.id))
        precondition(model.canClean, "default selection is not cleanable")
        model.loadMembers(groupID: group.id, offset: 0); try await wait { !model.busy }
        model.keep(id: keeper.id); model.selectedIDs = [copy.id]; model.prepareCleanup()
        model.selectedIDs = []; model.executeCleanup(); try await wait { !model.busy }
        trash += model.results.compactMap(\.destination)
        precondition(trash.count == 1 && model.results[0].error == nil && fm.fileExists(atPath: keeper.url.path))
        precondition(!fm.fileExists(atPath: copy.url.path))
        for _ in 0..<12 {
            model.start(scope: .folder(tree)); try await wait { !model.busy }
            let folders = try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [])
            precondition(folders.filter { $0.lastPathComponent.hasPrefix("session-") }.isEmpty)
            precondition(fm.fileExists(atPath: sessions.appendingPathComponent("duplicate-index.sqlite").path))
        }
        precondition(model.summary?.readBytes == 0 && model.summary?.incremental == true)
        let stopped: String? = await withCheckedContinuation { c in model.shutdown { c.resume(returning: $0) } }
        precondition(stopped == nil && fm.fileExists(atPath: sessions.appendingPathComponent("duplicate-index.sqlite").path))
        model = DuplicateModel(home: home, cacheDirectory: sessions)
        model.minimumSize = 1; model.start(scope: .folder(tree)); try await wait { !model.busy }
        precondition(model.summary?.readBytes == 0 && model.summary?.visited == 0 && model.summary?.incremental == true,
                     "reopened model did not reuse persistent metadata and hashes")
        // 按磁盘扫描：启动磁盘扫描（测试）主目录；默认 1 MB 门槛过滤全部小文件，改为全部大小后与文件夹模式一致。
        precondition(DuplicateFiles.startupVolume(home: home).isStartup, "startup volume missing")
        model.minimumSize = DuplicateFiles.defaultMinimumSize
        model.start()
        try await wait { !model.busy }
        precondition(!model.incomplete && model.groups.isEmpty && (model.summary?.filteredSmall ?? 0) >= 106, "threshold scan groups=\(model.groups.count)")
        if case .volumes(let scanned) = model.lastScope { precondition(scanned.count == 1 && scanned[0].isStartup) } else { preconditionFailure("volume scope not recorded") }
        model.minimumSize = 1; model.start()
        try await wait { !model.busy }
        precondition(!model.incomplete && model.groups.count == 2, "volume scan groups=\(model.groups.count), errors=\(model.summary?.errorExamples ?? [])")
        // Queue successive queries without yielding: the older reply must never publish last.
        model.loadMembers(groupID: group.id, offset: 0)
        model.loadMembers(groupID: group.id, offset: 100)
        try await wait { !model.busy }
        precondition(model.memberOffset == 100 && model.members.count == 4)
        var db: OpaquePointer?
        precondition(sqlite3_open(sessions.appendingPathComponent("duplicate-index.sqlite").path, &db) == SQLITE_OK)
        let sql = """
            BEGIN;
            WITH RECURSIVE ids(id) AS (VALUES(1000) UNION ALL SELECT id+1 FROM ids WHERE id<501000)
            INSERT INTO nodes(id,parent,path,device,inode,mode,size,modified,changed,blocks,ownLogical,ownAllocated,logical,allocated,duplicate) SELECT id,0,'/fixture/'||id,1,id,32768,128,0,0,4096,128,4096,128,4096,0 FROM ids;
            INSERT INTO duplicate_files(node_id,size,digest) SELECT id,128,zeroblob(32) FROM nodes WHERE id>=1000;
            COMMIT;
            """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        model.loadGroups(offset: 0)
        try await Task.sleep(for: .milliseconds(2))
        model.cancel(); try await wait { !model.busy }
        guard model.message?.contains("interrupted") == true else { fputs("FAIL: paging SQL did not observe cancellation\n", stderr); exit(EXIT_FAILURE) }
        model.loadGroups(offset: 0)
        let shutdownStart = Date()
        let error: String? = await withCheckedContinuation { c in model.shutdown { c.resume(returning: $0) } }
        precondition(error == nil && Date().timeIntervalSince(shutdownStart) < 2)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!model.busy && !model.canClean)
        model.start(scope: .folder(tree)); precondition(!model.scanning)
        let remaining = try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [])
        precondition(remaining.filter { $0.lastPathComponent.hasPrefix("session-") }.isEmpty)
        // 历史摘要：隔离 UserDefaults suite 跨实例恢复、无清理权限、取消和失败不覆盖
        let dupHistorySuite = "MacEven.dup-history-test." + UUID().uuidString
        let dupHistoryDefaults = UserDefaults(suiteName: dupHistorySuite)!
        defer { dupHistoryDefaults.removePersistentDomain(forName: dupHistorySuite) }
        let dupHistorySessions = home.appendingPathComponent("dup-history-sessions")
        let dupHistoryModel = DuplicateModel(home: home, cacheDirectory: dupHistorySessions, historyDefaults: dupHistoryDefaults)
        dupHistoryModel.minimumSize = 1
        precondition(dupHistoryModel.lastAnalysis == nil)
        dupHistoryModel.start(scope: .folder(tree))
        try await wait { !dupHistoryModel.busy }
        precondition(dupHistoryModel.lastAnalysis != nil && !dupHistoryModel.incomplete)
        let dupReport = dupHistoryModel.lastAnalysis!
        // 跨实例不恢复，退出后重新开始，仅在当前运行轮次生效
        let restoredDup = DuplicateModel(home: home, cacheDirectory: home.appendingPathComponent("dup-restored-sessions"), historyDefaults: dupHistoryDefaults)
        precondition(restoredDup.lastAnalysis == nil, "new app session must not restore previous scan results")
        precondition(restoredDup.selectedIDs.isEmpty && !restoredDup.canClean && restoredDup.groups.isEmpty && restoredDup.members.isEmpty && restoredDup.activeGroupID == nil && restoredDup.keeperID == nil)
        precondition(AnalysisReport.load("duplicates", defaults: dupHistoryDefaults) == nil)
        let restoredDupErr: String? = await withCheckedContinuation { c in restoredDup.shutdown { c.resume(returning: $0) } }
        precondition(restoredDupErr == nil)
        // 取消不影响当前会话内存中的已有报告
        dupHistoryModel.start(scope: .folder(tree)); dupHistoryModel.cancel()
        try await wait { !dupHistoryModel.busy }
        precondition(dupHistoryModel.summary?.cancelled == true)
        precondition(dupHistoryModel.lastAnalysis == dupReport, "current session retains lastAnalysis across cancelled scan")
        precondition(AnalysisReport.load("duplicates", defaults: dupHistoryDefaults) == nil)
        // 失败新实例不会读取历史报告
        let lockedDup = DuplicateModel(home: home, cacheDirectory: dupHistorySessions, historyDefaults: dupHistoryDefaults)
        lockedDup.start(scope: .folder(tree))
        try await wait { !lockedDup.busy }
        precondition(lockedDup.status.contains("失败") && lockedDup.lastAnalysis == nil, "new failing session must start fresh without history")
        precondition(AnalysisReport.load("duplicates", defaults: dupHistoryDefaults) == nil)
        let lockedDupErr: String? = await withCheckedContinuation { c in lockedDup.shutdown { c.resume(returning: $0) } }
        precondition(lockedDupErr == nil)
        let dupHistoryErr: String? = await withCheckedContinuation { c in dupHistoryModel.shutdown { c.resume(returning: $0) } }
        precondition(dupHistoryErr == nil)
        print("PASS: duplicate model frozen cleanup, retain protection, paging, stale queries, restart, 12 bounded rescans and persistent cache across shutdown, incomplete browsing, SQL cancellation and shutdown, startup volume scope and size threshold, history retention")
    }
}
