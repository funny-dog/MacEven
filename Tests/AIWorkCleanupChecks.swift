import Foundation
import MacEvenCore

@main struct AIWorkCleanupChecks {
    @MainActor static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            precondition(Date() < deadline, "AI work cleanup condition did not settle")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let home = try canonicalFileURL(fm.temporaryDirectory).appendingPathComponent("MacEven-aiwork-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        var trash: [URL] = []
        defer {
            for url in trash { try? fm.removeItem(at: url) }
            try? fm.removeItem(at: home)
        }

        func write(_ relative: String, _ data: Data = Data(repeating: 5, count: 1024), modified: Date? = nil) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }

        func session(_ cwd: String) -> Data { Data("{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"\(cwd)\"}}\n".utf8) }

        let liveProject = home.appendingPathComponent("projects/live-project")
        try fm.createDirectory(at: liveProject, withIntermediateDirectories: true)
        let goneProject = home.appendingPathComponent("projects/deleted-project").path

        // ==========================================
        // 1. 创建受保护的记忆、配置、凭据与源码/工作树
        // ==========================================
        try write(".codex/memories/memory_1.json")
        try write(".codex/memories_v2/context.txt")
        try write(".codex/config.toml", Data("model = \"gpt-4\"\n".utf8))
        try write(".codex/credentials.json", Data("token = \"secret\"\n".utf8))
        try write(".codex/worktrees/my-repo/main.swift", Data("print(\"hello\")\n".utf8))

        try write(".claude/projects/project-alpha/memory.md", Data("# Project Memory\n".utf8))
        try write(".claude/projects/project-alpha/memory/detail.txt")
        try write(".claude/projects/project-alpha/config.json", Data("{\"version\": 1}".utf8))
        try write(".claude/projects/project-alpha/settings.json", Data("{\"theme\": \"dark\"}".utf8))
        try write(".claude/config.json", Data("{\"auth\": true}".utf8))
        try write(".claude.json", Data("{\"user\": \"tester\"}".utf8))

        // ==========================================
        // 2. 创建可清理的会话与快照临时 fixture
        // ==========================================
        let old = Date(timeIntervalSinceNow: -200 * 86_400)
        let recent = Date(timeIntervalSinceNow: -3 * 86_400)
        try write(".codex/sessions/2026/01/02/rollout-old.jsonl", session(liveProject.path), modified: old)
        try write(".codex/sessions/2026/09/30/rollout-fresh.jsonl", session(liveProject.path), modified: recent)
        try write(".codex/archived_sessions/archived_session.jsonl", session(goneProject), modified: recent.addingTimeInterval(2 * 86_400))
        // 非会话格式与目录本身都不是候选，必须原样保留。
        try write(".codex/sessions/2026/01/02/notes.txt")
        try write(".codex/sessions/legacy.json")
        try write(".claude/projects/project-alpha/session_1.jsonl", Data("{\"cwd\":\"\(goneProject)\",\"role\":\"user\"}\n".utf8), modified: recent.addingTimeInterval(4 * 86_400))
        try write(".claude/projects/project-alpha/subagents/agent_1.jsonl", Data("{\"cwd\":\"\(liveProject.path)\",\"sub\":\"agent\"}\n".utf8), modified: recent)
        try write(".claude/file-history/snapshot_1.txt")
        try write(".claude/plans/plan_1.md")

        let protection = ProtectionStore(url: home.appendingPathComponent("protection.json"))
        let cleanup = AIWorkCleanup(home: home, protection: protection)

        let oldCodex = home.appendingPathComponent(".codex/sessions/2026/01/02/rollout-old.jsonl")
        let freshCodex = home.appendingPathComponent(".codex/sessions/2026/09/30/rollout-fresh.jsonl")
        let archivedCodex = home.appendingPathComponent(".codex/archived_sessions/archived_session.jsonl")
        let claudeSession = home.appendingPathComponent(".claude/projects/project-alpha/session_1.jsonl")
        let claudeSubagent = home.appendingPathComponent(".claude/projects/project-alpha/subagents/agent_1.jsonl")

        // 验证白名单扫描与记忆/配置保留
        let scanned = try cleanup.scan()
        let scannedPaths = scanned.flatMap(\.paths).map(\.path)

        // 断言：可清理 fixture 必须全部被扫描到，且粒度是单个会话文件
        precondition(scannedPaths.contains(oldCodex.path))
        precondition(scannedPaths.contains(freshCodex.path))
        precondition(scannedPaths.contains(archivedCodex.path))
        precondition(scannedPaths.contains(claudeSession.path))
        precondition(scannedPaths.contains(claudeSubagent.path))
        precondition(scannedPaths.contains(home.appendingPathComponent(".claude/file-history").path))
        precondition(scannedPaths.contains(home.appendingPathComponent(".claude/plans").path))

        // 断言：会话目录本身、非 .jsonl 文件、混合根目录都不是候选
        for forbidden in [".codex/sessions", ".codex/archived_sessions", ".claude/projects", ".claude/projects/project-alpha",
                          ".claude", ".codex", ".codex/sessions/2026/01/02/notes.txt", ".codex/sessions/legacy.json"] {
            precondition(!scannedPaths.contains(home.appendingPathComponent(forbidden).path), "\(forbidden) must not be a candidate")
        }

        // 断言：长期记忆、配置、凭据与源码/工作树绝不包含在扫描结果中
        precondition(!scannedPaths.contains(where: { $0.contains("memory") }))
        precondition(!scannedPaths.contains(where: { $0.contains("memories") }))
        precondition(!scannedPaths.contains(where: { $0.contains("worktrees") }))
        precondition(!scannedPaths.contains(where: { $0.contains("config") }))
        precondition(!scannedPaths.contains(where: { $0.contains("credentials") }))
        precondition(!scannedPaths.contains(where: { $0.contains(".claude.json") }))

        // 验证各 Group 的 impact 影响说明不为空且中文明确
        for group in scanned {
            precondition(!group.impact.isEmpty, "Group \(group.title) missing impact description")
            precondition(!group.paths.isEmpty)
        }

        // ==========================================
        // 3. 会话元数据：最后修改时间、项目来源与项目是否已删除
        // ==========================================
        let targets = scanned.flatMap(\.targets)
        guard let oldTarget = targets.first(where: { $0.url == oldCodex }), let freshTarget = targets.first(where: { $0.url == freshCodex }),
              let archivedTarget = targets.first(where: { $0.url == archivedCodex }), let claudeTarget = targets.first(where: { $0.url == claudeSession }) else {
            fatalError("session targets missing")
        }
        precondition(oldTarget.projectPath == liveProject.path && oldTarget.projectName == "live-project" && !oldTarget.projectMissing,
                     "live project must be recognized")
        precondition(archivedTarget.projectMissing && archivedTarget.projectName == "deleted-project", "missing project must be flagged")
        precondition(claudeTarget.projectMissing, "claude session with removed project must be flagged")
        precondition(oldTarget.modifiedAt.map { abs($0.timeIntervalSince(old)) < 5 } == true, "modification date must reflect the file")
        precondition(freshTarget.modifiedAt.map { abs($0.timeIntervalSince(recent)) < 5 } == true)

        // 分组行：旧会话 / 项目已删除 / 其他会话 / 快照 / 计划；同一记录只出现在一行
        let rows = AICleanupRows.rows(groups: scanned, ageDays: 90, now: Date())
        precondition(rows.map(\.kind) == [.oldSessions, .missingProjectSessions, .recentSessions, .snapshots, .plans], "unexpected row order: \(rows.map(\.kind))")
        precondition(rows[0].targets.map(\.url) == [oldCodex], "old row must only contain sessions older than the threshold")
        precondition(rows[0].detail.contains("90 天"), rows[0].detail)
        let missingProjectURLs: [URL] = rows[1].targets.map(\.url).sorted { $0.path < $1.path }
        let expectedMissingProjectURLs: [URL] = [archivedCodex, claudeSession].sorted { $0.path < $1.path }
        precondition(missingProjectURLs == expectedMissingProjectURLs, "missing-project row must only contain removed projects")
        let recentURLs: [URL] = rows[2].targets.map(\.url).sorted { $0.path < $1.path }
        let expectedRecentURLs: [URL] = [freshCodex, claudeSubagent].sorted { $0.path < $1.path }
        precondition(recentURLs == expectedRecentURLs)
        precondition(Set(rows.flatMap { $0.targets.map(\.id) }).count == rows.flatMap(\.targets).count, "rows must not overlap")
        // 阈值放宽后旧会话并入“其他会话”，勾选仍然有效
        let widened = AICleanupRows.rows(groups: scanned, ageDays: 365, now: Date())
        precondition(widened.first(where: { $0.kind == .oldSessions }) == nil, "old row must disappear with a wider threshold")
        precondition(widened.first(where: { $0.kind == .recentSessions })?.targets.count == 3)
        // 无法解析元数据的会话保持保守：不进入“项目已删除”，仍属于普通会话行
        let unparsable = home.appendingPathComponent(".codex/sessions/2026/09/30/rollout-broken.jsonl")
        try write(".codex/sessions/2026/09/30/rollout-broken.jsonl", Data("not json at all\n".utf8), modified: recent)
        let reprobe = try cleanup.scan().flatMap(\.targets).first(where: { $0.url == unparsable })
        precondition(reprobe?.projectPath == nil && reprobe?.projectMissing == false, "unparsable session must stay conservative")
        try? fm.removeItem(at: unparsable)

        // ==========================================
        // 4. 拒绝符号链接（symlink）测试
        // ==========================================
        let symlinkSession = home.appendingPathComponent(".claude/projects/project-alpha/symlink_session.jsonl")
        try fm.createSymbolicLink(at: symlinkSession, withDestinationURL: home.appendingPathComponent(".claude/config.json"))

        // 扫描时自动过滤 symlink
        let scannedAfterSymlink = try cleanup.scan()
        precondition(!scannedAfterSymlink.flatMap(\.paths).contains(symlinkSession), "Scan should skip symlinks")

        // 验证 ancestors 逐级校验对 symlink 直接拒绝抛出错误
        do {
            _ = try cleanup.ancestors(of: symlinkSession)
            preconditionFailure("ancestors of symlink must throw error")
        } catch {
            precondition(error.localizedDescription.contains("符号链接"))
        }

        // 手动构造指向 symlink 的 Target 并执行 move，必须报错拒绝移动
        let symlinkIdentity = try FileIdentity.read(symlinkSession)
        let symlinkAncestors = try cleanup.ancestors(of: symlinkSession.deletingLastPathComponent())
        let symlinkTarget = AIWorkCleanupTarget(
            rule: .claudeProjectSessions,
            url: symlinkSession,
            allocatedSize: 0,
            identity: symlinkIdentity,
            ancestors: symlinkAncestors,
            impact: "test"
        )
        let symlinkMoveResults = cleanup.move(targets: [symlinkTarget])
        precondition(symlinkMoveResults.count == 1)
        precondition(symlinkMoveResults[0].destination == nil && symlinkMoveResults[0].error?.contains("符号链接") == true,
                     "Symlink move must fail with protection error")
        precondition(fm.fileExists(atPath: symlinkSession.path), "Symlink must be preserved")
        try? fm.removeItem(at: symlinkSession)

        // ==========================================
        // 5. 拒绝文件变化（FileIdentity 变化）测试
        // ==========================================
        let changingIdentity = try FileIdentity.read(claudeSession)
        let changingAncestors = try cleanup.ancestors(of: claudeSession)
        let changingTarget = AIWorkCleanupTarget(
            rule: .claudeProjectSessions,
            url: claudeSession,
            allocatedSize: changingIdentity.allocated,
            identity: changingIdentity,
            ancestors: changingAncestors,
            impact: "test"
        )

        // 在移动前修改文件内容，导致 fresh != target.identity
        try Data("new content added after scan\n".utf8).write(to: claudeSession)
        let changeMoveResults = cleanup.move(targets: [changingTarget])
        precondition(changeMoveResults.count == 1)
        precondition(changeMoveResults[0].destination == nil && changeMoveResults[0].error?.contains("修改或替换") == true,
                     "Modified file must be rejected from trashing")
        precondition(fm.fileExists(atPath: claudeSession.path), "Modified file must be preserved")

        // 恢复内容与 identity 以便后续测试
        try Data("{\"cwd\":\"\(goneProject)\",\"role\":\"user\"}\n".utf8).write(to: claudeSession)

        // ==========================================
        // 6. 拒绝工具占用 / 进程运行测试
        // ==========================================
        guard let busyTarget = (try cleanup.scan()).first(where: { $0.rule == .codexSessions })?.targets.first else {
            fatalError("Missing codexSessions target")
        }
        let busyActivity: AIWorkActivityChecker = { tool, url in
            return tool == .codex ? "检测到相关工具正在运行，已保留" : nil
        }
        let busyResults = cleanup.move(targets: [busyTarget], activity: busyActivity)
        precondition(busyResults.count == 1)
        precondition(busyResults[0].destination == nil && busyResults[0].error?.contains("正在运行") == true,
                     "Busy target must be rejected with process error")
        precondition(fm.fileExists(atPath: busyTarget.url.path), "Busy item must be preserved")

        // 目录里其他文件发生变化不影响本文件候选：每个会话文件都按自身身份校验。
        let nestedSibling = home.appendingPathComponent(".codex/sessions/2026/09/30/rollout-fresh.jsonl")
        let siblingGroups = try cleanup.scan()
        guard let siblingTarget = siblingGroups.flatMap(\.targets).first(where: { $0.url == nestedSibling }) else {
            fatalError("sibling target missing")
        }
        let siblingMove = cleanup.move(targets: [siblingTarget], activity: { _, _ in nil })
        precondition(siblingMove.count == 1 && siblingMove[0].destination != nil,
                     "each session file must be validated on its own identity")
        trash += siblingMove.compactMap(\.destination)

        let probeGroups = try cleanup.scan()
        guard let probeTarget = probeGroups.flatMap(\.targets).first(where: { $0.url == oldCodex }) else {
            fatalError("probe target missing")
        }
        let probeResult = cleanup.move(targets: [probeTarget], activity: { _, _ in
            try! Data("changed during occupancy check".utf8).write(to: oldCodex)
            return nil
        })
        precondition(probeResult.count == 1 && probeResult[0].destination == nil && probeResult[0].error != nil, "occupancy-check race escaped validation")
        let protected = try protection.addPath(oldCodex)
        let protectedGroups = try cleanup.scan()
        precondition(protectedGroups.allSatisfy { $0.rule != .codexSessions }, "protected work records became selectable")
        try protection.remove(id: protected.id)

        // ==========================================
        // 7. 正常移动临时 fixture 到废纸篓并记录日志
        // ==========================================
        final class ResultBox: @unchecked Sendable {
            var items: [TrashResult] = []
            private let lock = NSLock()
            func append(_ results: [TrashResult]) {
                lock.withLock { items.append(contentsOf: results) }
            }
            var count: Int { lock.withLock { items.count } }
        }
        let box = ResultBox()
        let recorder: @Sendable ([TrashResult]) -> Void = { results in
            box.append(results)
        }

        // 重新扫描最新有效 targets
        let freshGroups = try cleanup.scan()
        let moveResults = cleanup.move(groups: freshGroups, activity: { _, _ in nil }, recordOperation: recorder)
        precondition(!moveResults.isEmpty)
        precondition(moveResults.allSatisfy { $0.destination != nil && $0.error == nil }, "All valid fixtures should be moved successfully")
        trash += moveResults.compactMap(\.destination)
        precondition(box.count == moveResults.count, "Operation log recorder should receive all results")

        // 验证被清理的会话文件已被移走，而会话目录本身按白名单保留
        precondition(!fm.fileExists(atPath: oldCodex.path))
        precondition(!fm.fileExists(atPath: archivedCodex.path))
        precondition(!fm.fileExists(atPath: claudeSession.path))
        precondition(!fm.fileExists(atPath: claudeSubagent.path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions").path), "session directory itself must be preserved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions/2026/01/02/notes.txt").path), "non-session files must be preserved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions/legacy.json").path), "non-jsonl files must be preserved")
        precondition(!fm.fileExists(atPath: home.appendingPathComponent(".claude/file-history").path))
        precondition(!fm.fileExists(atPath: home.appendingPathComponent(".claude/plans").path))

        // 验证受保护的记忆、配置与源码/工作树完好无损！
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/memories/memory_1.json").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/memories_v2/context.txt").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/credentials.json").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/worktrees/my-repo/main.swift").path))

        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects/project-alpha/memory.md").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects/project-alpha/memory/detail.txt").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects/project-alpha/config.json").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects/project-alpha/settings.json").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude/config.json").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude.json").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects/project-alpha").path))

        // ==========================================
        // 8. SmartScanModel 独立确认、逐项勾选与一键清理隔离
        // ==========================================
        // 为 SmartScanModel 重新准备一份临时 fixture
        let modelOld = Date(timeIntervalSinceNow: -150 * 86_400)
        try write(".codex/sessions/2026/03/01/model_old.jsonl", session(liveProject.path), modified: modelOld)
        try write(".codex/sessions/2026/09/29/model_new.jsonl", session(liveProject.path), modified: recent)
        try write(".claude/projects/project-beta/session_m.jsonl", Data("{\"cwd\":\"\(goneProject)\"}\n".utf8), modified: recent)
        try write(".claude/projects/project-beta/memory.md")

        let cache = CacheModel(home: home, applications: [], cacheDirectory: home.appendingPathComponent("cache-dir"))
        let removal = ApplicationRemovalModel(home: home, roots: [], cacheDirectory: home.appendingPathComponent("rem-dir"), dock: nil)
        let smart = SmartScanModel(cache: cache, removal: removal, home: home)
        smart.aiWorkActivity = { _, _ in nil }

        smart.scanAll()
        try await wait { smart.phase == .ready }

        // 断言：默认不勾选任何记录；AI 会话不混入一键缓存清理！
        precondition(smart.selectedCount == 0 && !smart.canClean, "Default should not select anything")
        precondition(smart.aiWorkSelectedCount == 0 && !smart.canCleanAIWork, "AI records must start unselected")
        smart.selectAllSafe()
        precondition(smart.confirmation == nil)
        // 一键清理准备合并确认，不包含 AI 工作资料
        smart.prepareCleanup()
        precondition(smart.confirmation?.paths.contains(where: { $0.path.contains("Codex 会话") || $0.path.contains("Claude Code") }) != true,
                     "Merged cleanup confirmation must not include AI work sessions")
        smart.dismissConfirmation()
        precondition(smart.aiWorkRows.map(\.kind) == [.oldSessions, .missingProjectSessions, .recentSessions], "unexpected rows: \(smart.aiWorkRows.map(\.kind))")

        // 逐行勾选：旧会话行只包含超过阈值的记录
        guard let oldRow = smart.aiWorkRows.first(where: { $0.kind == .oldSessions }),
              let recentRow = smart.aiWorkRows.first(where: { $0.kind == .recentSessions }) else { fatalError("session rows missing") }
        smart.setAIWorkRow(oldRow, selected: true)
        precondition(smart.aiWorkSelectedCount == oldRow.count)
        precondition(oldRow.targets.allSatisfy { smart.isAIWorkSelected($0) })
        precondition(!smart.isAIWorkSelected(recentRow.targets[0]), "row selection leaked")

        // 独立确认入口：确认内容只包含已勾选的记录
        smart.prepareAIWorkCleanup()
        guard let confirmation = smart.aiWorkConfirmation else {
            fatalError("prepareAIWorkCleanup did not set aiWorkConfirmation")
        }
        precondition(confirmation.count == oldRow.count)
        precondition(confirmation.paths.allSatisfy { $0.path.contains("Codex 会话记录") }, confirmation.paths.map(\.path).joined(separator: ","))
        precondition(confirmation.notes.contains(where: { $0.contains("长期记忆") && $0.contains("严格保留") }))
        precondition(confirmation.notes.contains(where: { $0.contains("空的日期目录") }), "session rows must disclose empty directories")

        // 阈值变化后勾选保持有效，取消选择生效
        smart.aiWorkAgeDays = 365
        precondition(smart.aiWorkSelectedCount == oldRow.count && smart.canCleanAIWork, "selection must survive threshold changes")
        smart.aiWorkAgeDays = 90
        smart.setAIWorkRow(oldRow, selected: false)
        precondition(smart.aiWorkSelectedCount == 0 && !smart.canCleanAIWork)
        smart.selectAllAIWork()
        precondition(smart.aiWorkSelectedCount == smart.aiWorkSelectableTargets.count && smart.canCleanAIWork)
        smart.aiWorkAgeDays = 180
        precondition(smart.aiWorkSelectedCount == smart.aiWorkSelectableTargets.count, "select all must stay consistent across thresholds")
        smart.clearAIWorkSelection()
        precondition(smart.aiWorkSelectedCount == 0)
        smart.aiWorkAgeDays = 90
        guard let reRow = smart.aiWorkRows.first(where: { $0.kind == .oldSessions }) else { fatalError("old row missing after threshold reset") }
        smart.setAIWorkRow(reRow, selected: true)
        precondition(smart.canCleanAIWork)

        // 防重入测试 1：otherBusy == true 时拒绝准备与执行
        final class BusyBox: @unchecked Sendable { var value = true }
        let busyBox = BusyBox()
        smart.otherBusy = { busyBox.value }
        smart.dismissAIWorkConfirmation()
        smart.prepareAIWorkCleanup()
        precondition(smart.aiWorkConfirmation == nil, "prepare must refuse while another task is busy")
        smart.executeAIWorkCleanup()
        precondition(!smart.aiWorkCleaning && smart.aiWorkConfirmation == nil, "execute must refuse while another task is busy")
        busyBox.value = false

        // 防重入测试 2：dismissAIWorkConfirmation 后确认置空，调用 executeAIWorkCleanup 不执行
        smart.dismissAIWorkConfirmation()
        precondition(smart.aiWorkConfirmation == nil)
        smart.executeAIWorkCleanup()
        precondition(!smart.aiWorkCleaning)
        precondition(smart.aiWorkSelectedCount > 0, "selection must survive a refused execute")

        // 无关位置在扫描后新增内容，清理会话时不应重新扫描它。
        let unrelatedID = home.appendingPathComponent(".codex/generated_images").path
        let unrelatedBefore = smart.aiStorage.first { $0.id == unrelatedID }
        try write(".codex/generated_images/new.bin")

        // 正常执行独立清理
        smart.prepareAIWorkCleanup()
        precondition(smart.aiWorkConfirmation != nil)
        smart.executeAIWorkCleanup()
        // 验证执行后 confirmation 立即置空（防二次点击）
        precondition(smart.aiWorkConfirmation == nil, "Confirmation should be cleared immediately upon execution")
        try await wait { !smart.aiWorkCleaning }

        precondition(smart.aiWorkSummary?.contains("已移到废纸篓") == true, smart.aiWorkSummary ?? "No summary")
        trash += smart.aiWorkResults.compactMap(\.destination)
        // 只移走勾选的旧会话；其他记录与会话目录保留
        precondition(!fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions/2026/03/01/model_old.jsonl").path), "selected old session must be moved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions/2026/09/29/model_new.jsonl").path), "unselected recent session must be preserved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects/project-beta/session_m.jsonl").path), "unselected missing-project session must be preserved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects/project-beta/memory.md").path), "Beta project memory must be preserved")
        precondition(smart.aiWorkSelectedCount == 0, "executed selection must be pruned to what remains")
        precondition(smart.aiStorage.first { $0.id == unrelatedID } == unrelatedBefore, "cleanup refreshed an unrelated storage tree")

        try write(".codex/sessions/shutdown.jsonl")
        smart.scanAll(); try await wait { smart.phase == .ready }
        smart.selectAllAIWork()
        precondition(smart.canCleanAIWork)
        final class CleanupGate: @unchecked Sendable {
            private let lock = NSLock()
            private var started = false
            let release = DispatchSemaphore(value: 0)
            var entered: Bool { lock.withLock { started } }
            func enter() {
                lock.withLock { started = true }
                _ = release.wait(timeout: .now() + 5)
            }
        }
        let gate = CleanupGate()
        smart.aiWorkActivity = { _, _ in
            gate.enter()
            return nil
        }
        smart.prepareAIWorkCleanup(); smart.executeAIWorkCleanup()
        try await wait { gate.entered }
        precondition(smart.busy && !smart.canScan)
        var shutDown = false
        smart.shutdown { shutDown = true }
        try await Task.sleep(for: .milliseconds(20))
        precondition(!shutDown, "shutdown did not wait for the running cleanup")
        gate.release.signal()
        try await wait { shutDown }
        trash += smart.aiWorkResults.compactMap(\.destination)
        precondition(!smart.canScan && !smart.canCleanAIWork, "closed model accepted more work")

        for close in [{ (done: @escaping @MainActor @Sendable (String?) -> Void) in cache.shutdown(done) }, { done in removal.shutdown(done) }] {
            let error: String? = await withCheckedContinuation { c in close { c.resume(returning: $0) } }
            precondition(error == nil)
        }

        precondition(AIWorkActivity.blockedReason(.codex, home.appendingPathComponent("missing-occupancy-target")) != nil,
                     "an incomplete occupancy query must retain the target")

        let batchHome = home.appendingPathComponent("batch-home")
        let batchRoot = batchHome.appendingPathComponent(".codex/sessions")
        try fm.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        for number in 0..<501 { try Data("{}\n".utf8).write(to: batchRoot.appendingPathComponent("\(number).jsonl")) }
        let batched = AIWorkCleanup(home: batchHome, protection: ProtectionStore(url: batchHome.appendingPathComponent("protection.json")))
        for _ in 0..<2 {
            let batch = try batched.scan()
            precondition(batch.flatMap(\.targets).count == 501 && batch.reduce(0, { $0 + $1.allocatedSize }) > 0, "transaction boundary lost sessions or retained stale identities")
        }

        let linkedA = batchRoot.appendingPathComponent("linked-a.jsonl")
        let linkedB = batchRoot.appendingPathComponent("linked-b.jsonl")
        try Data("linked\n".utf8).write(to: linkedA)
        try fm.linkItem(at: linkedA, to: linkedB)
        let linkedGroups = try batched.scan()
        let inode = try FileIdentity.read(linkedA).inode
        let owner = linkedGroups.flatMap(\.targets).first { $0.identity.inode == inode && $0.allocatedSize > 0 }!
        let movedLink = batched.move(targets: [owner], activity: { _, _ in nil })
        trash += movedLink.compactMap(\.destination)
        precondition(movedLink.first?.error == nil)
        let retainedLink = try batched.remainingGroups(linkedGroups).flatMap(\.targets).filter { $0.identity.inode == inode }
        precondition(retainedLink.count == 1 && retainedLink[0].allocatedSize > 0, "incremental cleanup lost surviving hard-link allocation")

        print("PASS: AI work session files are grouped by age and missing projects, per-item selection, directories and non-jsonl preserved, memory and worktrees protected, model reentrancy prevented")
    }
}
