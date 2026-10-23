import Foundation
import Darwin
@testable import MacEvenCore

@main struct DeveloperCleanupChecks {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("MacEven-developer-checks-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let home = try canonicalFileURL(temporary)
        var trash: [URL] = []
        defer { for path in trash { try? fm.removeItem(at: path) }; try? fm.removeItem(at: home) }
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        defer { index.close() }
        let cleaner = DeveloperCleanup(index: index, home: home)
        let absent = try cleaner.scan(token: CancellationToken())
        precondition(absent.groups.isEmpty && absent.summary.visited == 0 && absent.summary.errors == 0)
        func directory(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        func file(_ relative: String, _ data: Data = Data([1,2,3])) throws -> URL {
            let path = home.appendingPathComponent(relative)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path); return path
        }
        let project = "Example-" + String(repeating: "a", count: 26)
        let dd = "Library/Developer/Xcode/DerivedData/" + project
        _ = try directory(dd + "/Build/Products/Debug")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": "/tmp/Example.xcodeproj"], format: .binary, options: 0)
        _ = try file(dd + "/info.plist", plist)
        let binary = try file(dd + "/Build/Products/Debug/ExampleBinary", Data(repeating: 0xaa, count: 16384))
        let duplicate = home.appendingPathComponent(dd + "/Build/Products/Debug/AliasBinary")
        precondition(link(binary.path, duplicate.path) == 0)
        let pip = "Library/Caches/pip", hash = String(repeating: "a", count: 56)
        let metadata = pip + "/http-v2/a/a/a/a/a/" + hash
        _ = try file(metadata, Data("cc=4,\u{0082}".utf8))
        _ = try file(metadata + ".body", Data(repeating: 0xbb, count: 8192))
        let wheel = pip + "/wheels/aa/bb/cc/" + String(repeating: "d", count: 50)
        _ = try file(wheel + "/origin.json", Data("{\"url\":\"https://example.invalid/package.zip\"}".utf8))
        _ = try file(wheel + "/example-1.0-py3-none-any.whl", Data([0x50,0x4b,0x03,0x04,1]))
        let npm = ".npm/_cacache"
        _ = try file(npm + "/content-v2/sha512/aa/bb/" + String(repeating: "c", count: 124), Data(repeating: 0xcc, count: 4096))
        _ = try file(npm + "/index-v5/aa/bb/" + String(repeating: "d", count: 60), Data(("\n" + String(repeating: "a", count: 40) + "\t{\"key\":\"cache:https://example.invalid/pkg\",\"time\":1}").utf8))
        _ = try directory(npm + "/tmp")
        let kept = try file("project/Archives/keep.swift")
        let ddID = "derivedData:" + project
        func scan() throws -> [DeveloperCleanupGroup] {
            let result = try cleaner.scan(token: CancellationToken())
            precondition(result.summary.errors == 0 && !result.summary.cancelled)
            return try cleaner.refresh(activity: { _, _ in nil })
        }
        let groups = try scan()
        precondition(groups.count == 3 && groups.allSatisfy { $0.blockedReason == nil })
        let derived = groups.first { $0.id == ddID }!
        precondition(derived.logicalSize == Int64(plist.count + 16384), "hard links were counted twice")
        let expectedAllocated = try FileIdentity.read(binary).allocated + FileIdentity.read(home.appendingPathComponent(dd + "/info.plist")).allocated
        precondition(derived.allocatedSize == expectedAllocated)
        precondition(groups.filter { $0.rule != .derivedData }.allSatisfy { $0.rebuildCost.contains("网络重新下载") })
        precondition(TrashService(index: index, home: home).reasonBlocked(home.appendingPathComponent(pip)) != nil)
        precondition(TrashService(index: index, home: home).reasonBlocked(home.appendingPathComponent(npm)) != nil)
        precondition(TrashService(index: index, home: home, developerAllowedRoots: [home.appendingPathComponent("project")]).reasonBlocked(kept) != nil)
        print("PASS: fixed rules, absence, format evidence, physical allocation and hard-link deduplication")

        for (relative, groupID) in [(dd + "/Build/Products/Debug/nested/.git/HEAD", ddID), (dd + "/Build/Products/Debug/main.swift", ddID), (dd + "/Archives/archive", ddID), (pip + "/http-v2/project/keep", "pip"), (npm + "/content-v2/sha512/aa/bb/user.swift", "npm")] {
            let path = try file(relative)
            let rejected = try scan().first { $0.id == groupID }!
            precondition(rejected.blockedReason != nil, "unknown/source data was accepted")
            precondition(cleaner.move(groupIDs: [groupID], activity: { _, _ in nil }).allSatisfy { $0.destination == nil && $0.error != nil })
            try fm.removeItem(at: path)
            // Remove only the fixture's newly-created directories where the name itself is unknown.
            if relative.contains("nested/.git") { try fm.removeItem(at: home.appendingPathComponent(dd + "/Build/Products/Debug/nested")) }
            if relative.contains("/Archives/") { try fm.removeItem(at: home.appendingPathComponent(dd + "/Archives")) }
            if relative.contains("http-v2/project") { try fm.removeItem(at: home.appendingPathComponent(pip + "/http-v2/project")) }
        }
        let linked = home.appendingPathComponent(dd + "/Build/Products/Debug/link")
        try fm.createSymbolicLink(at: linked, withDestinationURL: kept)
        let linkedGroups = try scan()
        precondition(linkedGroups.first { $0.id == ddID }!.blockedReason != nil)
        try fm.removeItem(at: linked)
        let tmp = try file(npm + "/tmp/inflight")
        let temporaryGroups = try scan()
        precondition(temporaryGroups.first { $0.id == "npm" }!.blockedReason != nil)
        try fm.removeItem(at: tmp)
        print("PASS: reject nested source, archives, unknown layouts, links and nonempty npm tmp")

        _ = try scan()
        let xcode = home.appendingPathComponent("Library/Developer/Xcode"), backup = home.appendingPathComponent("backup")
        try fm.moveItem(at: xcode, to: backup)
        try fm.createDirectory(at: xcode, withIntermediateDirectories: true)
        try fm.moveItem(at: backup.appendingPathComponent("DerivedData"), to: xcode.appendingPathComponent("DerivedData"))
        precondition(cleaner.move(groupIDs: [ddID], activity: { _, _ in nil }).allSatisfy { $0.destination == nil && $0.error != nil })
        _ = try scan()
        _ = try file(dd + "/Build/Products/Debug/ExampleBinary", Data([9]))
        precondition(cleaner.move(groupIDs: [ddID], activity: { _, _ in nil }).allSatisfy { $0.destination == nil && $0.error != nil })
        _ = try scan()
        precondition(cleaner.move(groupIDs: [ddID], activity: { _, _ in "active build" }).allSatisfy { $0.destination == nil && $0.error != nil })
        var observations = 0
        let race = cleaner.move(groupIDs: [ddID], activity: { _, _ in observations += 1; return observations == 2 ? "now active" : nil })
        precondition(observations == 2 && race.allSatisfy { $0.destination == nil && $0.error != nil })
        observations = 0
        let changedDuringObservation = cleaner.move(groupIDs: [ddID], activity: { _, _ in
            observations += 1
            if observations == 2 { try! Data([7,8]).write(to: binary) }
            return nil
        })
        precondition(changedDuringObservation.allSatisfy { $0.destination == nil && $0.error != nil })
        precondition(fm.fileExists(atPath: binary.path) && fm.fileExists(atPath: kept.path))
        let cancelled = CancellationToken(); cancelled.cancel()
        let result = try cleaner.scan(token: cancelled)
        precondition(result.summary.cancelled)
        precondition(cleaner.move(groupIDs: ["pip"], activity: { _, _ in nil }).allSatisfy { $0.destination == nil })
        let opened = home.appendingPathComponent("occupancy-open.txt")
        try Data([1]).write(to: opened)
        let handle = try FileHandle(forReadingFrom: opened)
        let files = DeveloperCleanupActivity.openFiles(at: opened)
        precondition(files?.0 == 0 && files?.1.contains("n" + opened.path) == true, "targeted occupancy query missed an open file")
        try handle.close()
        let unrelated = DeveloperCleanupActivity.openFiles(at: home.appendingPathComponent("occupancy-closed.txt"))
        precondition(unrelated?.1.contains("n" + opened.path) != true, "targeted query returned unrelated user files")
        print("PASS: ancestor replacement, content replacement, activity, second observation and cancellation")

        // Native observation failures are also conservative, without touching real user paths.
        precondition(DeveloperCleanupActivity.processReason(.derivedData, "/usr/bin/clang\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.pip, "/usr/bin/python3.14\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.pip, "/usr/bin/Python\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.npm, "/usr/bin/node\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.codexLogs, "/usr/bin/node\n") == nil)
        precondition(DeveloperCleanupActivity.processReason(.claudeCache, "/usr/bin/bun\n") == nil)
        precondition(DeveloperCleanupActivity.processReason(.chromaCache, "/usr/bin/python3\n") == nil)
        precondition(DeveloperCleanupActivity.command("/missing-executable", []) == nil)
        precondition(DeveloperCleanupActivity.command("/bin/sh", ["-c", "printf error >&2; exit 1"]) == nil)
        precondition(DeveloperCleanupActivity.command("/bin/sh", ["-c", "printf abcdef"], maxBytes: 3) == nil)
        precondition(DeveloperCleanupActivity.command("/bin/sleep", ["1"], timeout: 0.05) == nil)
        let fd = open(binary.path, O_RDONLY)
        precondition(fd >= 0)
        precondition(DeveloperCleanupActivity.blockedReason(.derivedData, home.appendingPathComponent(dd)) != nil)
        close(fd)
        print("PASS: native process matching, stderr, missing tool, truncation, timeout and open file protection")

        // A broken root is an error, whereas ENOENT was covered by the absence check.
        let pipRoot = home.appendingPathComponent(pip), saved = home.appendingPathComponent("saved-pip")
        try fm.moveItem(at: pipRoot, to: saved)
        try fm.createSymbolicLink(at: pipRoot, withDestinationURL: saved)
        let incomplete = try cleaner.scan(token: CancellationToken())
        precondition(incomplete.summary.errors > 0)
        let blocked = try cleaner.refresh(activity: { _, _ in nil })
        precondition(blocked.first { $0.id == "pip" }?.blockedReason != nil)
        precondition(blocked.first { $0.id == ddID }?.blockedReason == nil)
        precondition(blocked.first { $0.id == ddID }?.allocatedSize != nil, "one broken root erased other cache statistics")
        precondition(cleaner.move(groupIDs: ["pip"], activity: { _, _ in nil }).allSatisfy { $0.destination == nil })
        try fm.removeItem(at: pipRoot); try fm.moveItem(at: saved, to: pipRoot)
        if geteuid() != 0 {
            precondition(chmod(pipRoot.path, 0) == 0)
            let inaccessible = try cleaner.scan(token: CancellationToken())
            precondition(chmod(pipRoot.path, 0o700) == 0)
            precondition(inaccessible.summary.errors > 0, "permission failure was treated as absent data")
            precondition(cleaner.move(groupIDs: ["pip"], activity: { _, _ in nil }).allSatisfy { $0.destination == nil })
        }
        let deep = dd + "/Build/deep/" + Array(repeating: "d", count: 65).joined(separator: "/")
        _ = try file(deep + "/artifact.bin")
        let bounded = try scan()
        precondition(bounded.first { $0.id == ddID }!.blockedReason != nil)
        try fm.removeItem(at: home.appendingPathComponent(dd + "/Build/deep"))
        let during = CancellationToken()
        let cancelledDuringScan = try cleaner.scan(token: during) { _ in during.cancel() }
        precondition(cancelledDuringScan.summary.cancelled)
        precondition(cleaner.move(groupIDs: ["npm"], activity: { _, _ in nil }).allSatisfy { $0.destination == nil })
        _ = try scan()
        let moved = cleaner.move(groupIDs: ["pip"], activity: { _, _ in nil })
        trash += moved.compactMap(\.destination)
        precondition(moved.count == 1 && moved[0].destination != nil && moved[0].error == nil)
        precondition(fm.fileExists(atPath: binary.path) && fm.fileExists(atPath: kept.path) && fm.fileExists(atPath: home.appendingPathComponent(npm).path))
        precondition(!fm.fileExists(atPath: pipRoot.path))
        let remaining = try cleaner.refresh(activity: { _, _ in nil })
        precondition(remaining.allSatisfy { $0.id != "pip" })
        print("PASS: incomplete roots stay blocked without disabling verified roots; only explicit temporary sample moved and index updated")
        try checkWholeDirectoryRules()
        try checkToolTmpLeakRules()
    }

    // 工具 tmp 泄漏规则：marker、泄漏命名白名单、内容 mtime 阈值；候选是 tmp 根下的子目录，tmp 根本身与活跃目录绝不出现。
    static func checkToolTmpLeakRules() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("MacEven-tmp-leak-checks-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let home = try canonicalFileURL(temporary)
        var trash: [URL] = []
        defer { for path in trash { try? fm.removeItem(at: path) }; try? fm.removeItem(at: home) }
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        defer { index.close() }
        @discardableResult func file(_ relative: String, _ data: Data = Data(repeating: 7, count: 1024), modified: Date? = nil) throws -> URL {
            let path = home.appendingPathComponent(relative)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path)
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path.path) }
            return path
        }
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        let fresh = Date(timeIntervalSinceNow: -1 * 86_400)
        // marker：Codex 工具根自己的 config.toml
        _ = try file(".codex/config.toml", Data("model = \"test\"\n".utf8))
        // 泄漏 fixture：git-* 老克隆、marketplace-upgrade-*、misplaced 时间戳目录
        _ = try file(".codex/.tmp/git-oldabc/HEAD", Data("ref\n".utf8), modified: old)
        _ = try file(".codex/.tmp/git-oldabc/objects/pack/pack.bin", Data(repeating: 1, count: 4096), modified: old)
        _ = try file(".codex/.tmp/git-fresh6/HEAD", Data("ref\n".utf8), modified: fresh)
        _ = try file(".codex/.tmp/git-bad/HEAD", Data("ref\n".utf8), modified: old)
        _ = try file(".codex/.tmp/marketplaces/claude-plugins-official/marker.json", modified: old)
        _ = try file(".codex/.tmp/marketplace-upgrade-abc123/plugin.bin", Data(repeating: 2, count: 8192), modified: old)
        _ = try file(".codex/tmp/core-tenantmall-misplaced-20260313-203700/app/main.py", Data(repeating: 3, count: 2048), modified: old)
        _ = try file(".codex/tmp/path/active.bin", modified: fresh)
        // 内含符号链接的泄漏目录：只读，不可清理
        _ = try file(".codex/.tmp/git-linked/HEAD", Data("ref\n".utf8), modified: old)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".codex/.tmp/git-linked/escape"), withDestinationURL: home)

        precondition(DeveloperCleanupRule.isToolTmpLeakName(.codexTmp, "git-oldabc"))
        precondition(!DeveloperCleanupRule.isToolTmpLeakName(.codexTmp, "git-abc"))
        precondition(!DeveloperCleanupRule.isToolTmpLeakName(.codexTmp, "git-oldabc/inner"))
        precondition(!DeveloperCleanupRule.isToolTmpLeakName(.codexTmp, "marketplaces"))
        precondition(!DeveloperCleanupRule.isToolTmpLeakName(.codexTmp, "git-oldabc2"))
        precondition(DeveloperCleanupRule.isToolTmpLeakName(.codexTmp, "marketplace-upgrade-abc123"))
        precondition(!DeveloperCleanupRule.isToolTmpLeakName(.codexTmpRoot, "path"))
        precondition(DeveloperCleanupRule.isToolTmpLeakName(.codexTmpRoot, "core-tenantmall-misplaced-20260313-203700"))
        precondition(!DeveloperCleanupRule.isToolTmpLeakName(.codexTmpRoot, "notes-misplaced-2026031"))
        precondition(DeveloperCleanupActivity.processReason(.codexTmp, "/usr/local/bin/codex\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.codexTmpRoot, "/usr/bin/vim\n") == nil)

        let cleaner = DeveloperCleanup(index: index, home: home)
        func scan() throws -> [DeveloperCleanupGroup] {
            let result = try cleaner.scan(token: CancellationToken())
            precondition(result.summary.errors == 0 && !result.summary.cancelled, "scan failed: \(result.summary.errorExamples)")
            return try cleaner.refresh(activity: { _, _ in nil })
        }
        let groups = try scan()
        let leakIDs = Set(groups.filter { $0.rule.isToolTmpRoot }.map(\.id))
        precondition(leakIDs == Set(["codexTmp:git-oldabc", "codexTmp:marketplace-upgrade-abc123", "codexTmpRoot:core-tenantmall-misplaced-20260313-203700", "codexTmp:git-linked"]),
            "unexpected tmp leak candidates: \(leakIDs)")
        for leak in groups.filter({ $0.rule.isToolTmpRoot && $0.id != "codexTmp:git-linked" }) {
            precondition(leak.blockedReason == nil && leak.allocatedSize! > 0, "\(leak.id): \(leak.blockedReason ?? "unmeasured")")
        }
        let linkedGroup = groups.first { $0.id == "codexTmp:git-linked" }
        precondition(linkedGroup?.blockedReason != nil, "leak with an internal link must stay read-only")
        let composition = try cleaner.composition(groupID: "codexTmp:marketplace-upgrade-abc123")
        precondition(composition?.entries.contains { $0.name == "plugin.bin" } == true, "composition must list leak contents")
        precondition(cleaner.move(groupIDs: ["codexTmp:git-linked"], activity: { _, _ in nil }).allSatisfy { $0.destination == nil && $0.error != nil })

        // 执行：泄漏目录移到废纸篓；tmp 根、活跃目录、工具根与配置全部保留
        let moved = cleaner.move(groupIDs: ["codexTmp:git-oldabc", "codexTmpRoot:core-tenantmall-misplaced-20260313-203700"], activity: { _, _ in nil })
        trash += moved.compactMap(\.destination)
        precondition(moved.count == 2 && moved.allSatisfy { $0.destination != nil && $0.error == nil }, "\(moved.map(\.error))")
        precondition(!fm.fileExists(atPath: home.appendingPathComponent(".codex/.tmp/git-oldabc").path))
        precondition(!fm.fileExists(atPath: home.appendingPathComponent(".codex/tmp/core-tenantmall-misplaced-20260313-203700").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/.tmp").path), "tmp root itself must never move")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/tmp").path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/.tmp/git-fresh6/HEAD").path), "freshly modified git scratch must be preserved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/.tmp/git-bad/HEAD").path), "unknown naming must be preserved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/.tmp/marketplaces").path), "stable tool work directory must be preserved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/tmp/path/active.bin").path), "active tmp content must be preserved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path), "tool root config must be preserved")

        // marker 缺失：没有 config.toml 的工具根完全不产生候选
        let aliasHome = home.appendingPathComponent("alias-home")
        try fm.createDirectory(at: aliasHome.appendingPathComponent(".codex/.tmp/git-oldabc/objects"), withIntermediateDirectories: true)
        try Data("ref\n".utf8).write(to: aliasHome.appendingPathComponent(".codex/.tmp/git-oldabc/HEAD"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: aliasHome.appendingPathComponent(".codex/.tmp/git-oldabc/HEAD").path)
        let aliasIndex = try DiskIndex(url: aliasHome.appendingPathComponent("index.sqlite"))
        defer { aliasIndex.close() }
        let aliasCleaner = DeveloperCleanup(index: aliasIndex, home: aliasHome)
        let aliasResult = try aliasCleaner.scan(token: CancellationToken())
        precondition(aliasResult.summary.errors == 0)
        let aliasGroups = try aliasCleaner.refresh(activity: { _, _ in nil })
        precondition(aliasGroups.allSatisfy { !$0.rule.isToolTmpRoot }, "missing tool marker must skip the whole tmp rule")
        aliasIndex.close()
        print("PASS: tool tmp leak rules with markers, naming whitelist, content mtime threshold and tmp-root protection")
    }

    // 0.15 整目录规则：有标志才可选；标志缺失、链接（Homebrew 内部链接除外）、未知 Cargo 内容只读；
    // TrashService 只放行规则根目录本身。
    static func checkWholeDirectoryRules() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("MacEven-rules-checks-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let home = try canonicalFileURL(temporary)
        var trash: [URL] = []
        defer { for path in trash { try? fm.removeItem(at: path) }; try? fm.removeItem(at: home) }
        let index = try DiskIndex(url: home.appendingPathComponent("index.sqlite"))
        defer { index.close() }
        @discardableResult func file(_ relative: String, _ data: Data = Data(repeating: 7, count: 2048)) throws -> URL {
            let path = home.appendingPathComponent(relative)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path); return path
        }
        let valid: [DeveloperCleanupRule: [String]] = [
            .claudeCache: ["changelog.md"],
            .claudeDebug: ["01234567-89ab-cdef-0123-456789abcdef.txt"],
            .codexLogs: ["codex-tui.log"],
            .copilotLogs: ["process-1789075698314-1446.log"],
            .kimiLogs: ["kimi-code.log"],
            .kimiCache: ["client-configs/estimated_cache_duration.json", "query-store/cluster.meta.json"],
            .codebuddyLogs: ["memwatch/cli-memwatch-12345.log"],
            .aiderCache: ["model_prices_and_context_window.json"],
            .workbuddyLogs: ["2026-10-18/app.log"],
            .workbuddyCache: ["update-endpoint.json"],
            .workbuddyTraces: ["10049/trace.bin"],
            .cursorLogs: ["2026-10-18/main.log"],
            .traeLogs: ["2026-10-18/main.log"],
            .windsurfLogs: ["2026-10-18/main.log"],
            .continueLogs: ["core.log"],
            .devinCache: ["telemetry_state.json"],
            .chromaCache: ["onnx_models/model.onnx"],
            .homebrew: ["downloads/abc--wget-1.0.tar.gz", "api/formula.jws.json"],
            .cocoapods: ["Pods/Release/Alamofire/5.0/data", "search_index.json"],
            .swiftpm: ["repositories/swift-argument-parser-1a2b/HEAD", "manifests/manifest.db"],
            .goBuild: ["README", "00/0011-a"],
            .yarn: ["v6/npm-left-pad-1.3.0/package.json"],
            .gradle: ["modules-2/files-2.1/org/lib.jar", "jars-9/abc.jar"],
            .cargo: ["index.crates.io-6f17d22bba15001f/serde-1.0.0.crate"],
            .deviceSupport: ["17.0 (21A329)/Symbols/dyld"],
            .simulatorCaches: ["dyld/23A344/cache.bin"],
            .chrome: ["Default/Cache/Cache_Data/data_0", "Profile 1/Code Cache/js/index"],
            .edge: ["Default/Cache/Cache_Data/data_0"],
            .firefox: ["Profiles/abc.default-release/cache2/entries/ABC"]
        ]
        for (rule, files) in valid {
            for relative in files {
                let data = relative == "README" ? Data("This directory holds cached build artifacts from the Go build system.\nRun \"go clean -cache\" if the directory is getting too large.\n".utf8) : Data(repeating: 7, count: 2048)
                try file(rule.relativePath + "/" + relative, data)
            }
        }
        // Homebrew 缓存顶层有指向自身下载目录的链接；只作为链接移动。
        try fm.createSymbolicLink(at: home.appendingPathComponent(DeveloperCleanupRule.homebrew.relativePath + "/wget--1.0.tar.gz"),
            withDestinationURL: home.appendingPathComponent(DeveloperCleanupRule.homebrew.relativePath + "/downloads/abc--wget-1.0.tar.gz"))
        let cleaner = DeveloperCleanup(index: index, home: home)
        func scan() throws -> [DeveloperCleanupGroup] {
            let result = try cleaner.scan(token: CancellationToken())
            precondition(result.summary.errors == 0 && !result.summary.cancelled, "scan failed: \(result.summary.errorExamples)")
            return try cleaner.refresh(activity: { _, _ in nil })
        }
        var groups = try scan()
        precondition(Set(groups.map(\.rule)) == Set(valid.keys), "rules missing: \(groups.map(\.id))")
        for group in groups { precondition(group.blockedReason == nil && group.allocatedSize! > 0, "\(group.id): \(group.blockedReason ?? "unmeasured")") }
        precondition(groups.filter { $0.rule.category == "浏览器" }.count == 3)
        precondition(groups.filter { $0.rule.category == "AI Agent" }.count == 17)

        // 标志缺失、非 Homebrew 的链接、Cargo 未知内容、错误的 Go README：只读，移动被拒绝。
        let blockers: [(DeveloperCleanupRule, () throws -> Void, () throws -> Void)] = [
            (.claudeCache, { try file(".claude/cache/session.jsonl") }, { try fm.removeItem(at: home.appendingPathComponent(".claude/cache/session.jsonl")) }),
            (.claudeDebug, { try file(".claude/debug/notes.txt") }, { try fm.removeItem(at: home.appendingPathComponent(".claude/debug/notes.txt")) }),
            (.codexLogs, { try file(".codex/log/session.jsonl") }, { try fm.removeItem(at: home.appendingPathComponent(".codex/log/session.jsonl")) }),
            (.claudeDebug, { try fm.createSymbolicLink(at: home.appendingPathComponent(".claude/debug/latest"), withDestinationURL: home) },
                { try fm.removeItem(at: home.appendingPathComponent(".claude/debug/latest")) }),
            // copilotLogs：将标志文件重命名为非 process-*.log 格式
            (.copilotLogs, { try fm.moveItem(at: home.appendingPathComponent(".copilot/logs/process-1789075698314-1446.log"), to: home.appendingPathComponent(".copilot/logs/unknown.log")) },
                           { try fm.moveItem(at: home.appendingPathComponent(".copilot/logs/unknown.log"), to: home.appendingPathComponent(".copilot/logs/process-1789075698314-1446.log")) }),
            // kimiLogs：将标志文件重命名为非 kimi-code.log 的文件
            (.kimiLogs, { try fm.moveItem(at: home.appendingPathComponent(".kimi-code/logs/kimi-code.log"), to: home.appendingPathComponent(".kimi-code/logs/other.log")) },
                        { try fm.moveItem(at: home.appendingPathComponent(".kimi-code/logs/other.log"), to: home.appendingPathComponent(".kimi-code/logs/kimi-code.log")) }),
            // kimiCache：移走标志子目录
            (.kimiCache, { try fm.moveItem(at: home.appendingPathComponent(".kimi-code/cache/client-configs"), to: home.appendingPathComponent(".kimi-code/cache/other"))
                           try fm.moveItem(at: home.appendingPathComponent(".kimi-code/cache/query-store"), to: home.appendingPathComponent(".kimi-code/cache/other2")) },
                         { try fm.moveItem(at: home.appendingPathComponent(".kimi-code/cache/other"), to: home.appendingPathComponent(".kimi-code/cache/client-configs"))
                           try fm.moveItem(at: home.appendingPathComponent(".kimi-code/cache/other2"), to: home.appendingPathComponent(".kimi-code/cache/query-store")) }),
            // codebuddyLogs：移走 memwatch 子目录
            (.codebuddyLogs, { try fm.moveItem(at: home.appendingPathComponent(".codebuddy/logs/memwatch"), to: home.appendingPathComponent(".codebuddy/logs/other")) },
                             { try fm.moveItem(at: home.appendingPathComponent(".codebuddy/logs/other"), to: home.appendingPathComponent(".codebuddy/logs/memwatch")) }),
            // aiderCache：移走标志文件
            (.aiderCache, { try fm.moveItem(at: home.appendingPathComponent(".aider/caches/model_prices_and_context_window.json"), to: home.appendingPathComponent(".aider/caches/other.json")) },
                          { try fm.moveItem(at: home.appendingPathComponent(".aider/caches/other.json"), to: home.appendingPathComponent(".aider/caches/model_prices_and_context_window.json")) }),
            // workbuddyLogs
            (.workbuddyLogs, { try fm.moveItem(at: home.appendingPathComponent(".workbuddy/logs/2026-10-18"), to: home.appendingPathComponent(".workbuddy/logs/temp")) },
                             { try fm.moveItem(at: home.appendingPathComponent(".workbuddy/logs/temp"), to: home.appendingPathComponent(".workbuddy/logs/2026-10-18")) }),
            // workbuddyCache
            (.workbuddyCache, { try fm.moveItem(at: home.appendingPathComponent(".workbuddy/cache/update-endpoint.json"), to: home.appendingPathComponent(".workbuddy/cache/unknown.txt")) },
                              { try fm.moveItem(at: home.appendingPathComponent(".workbuddy/cache/unknown.txt"), to: home.appendingPathComponent(".workbuddy/cache/update-endpoint.json")) }),
            // workbuddyTraces
            (.workbuddyTraces, { try fm.moveItem(at: home.appendingPathComponent(".workbuddy/traces/10049"), to: home.appendingPathComponent(".workbuddy/traces/temp_alpha")) },
                               { try fm.moveItem(at: home.appendingPathComponent(".workbuddy/traces/temp_alpha"), to: home.appendingPathComponent(".workbuddy/traces/10049")) }),
            // cursorLogs
            (.cursorLogs, { try fm.moveItem(at: home.appendingPathComponent("Library/Application Support/Cursor/logs/2026-10-18"), to: home.appendingPathComponent("Library/Application Support/Cursor/logs/temp")) },
                          { try fm.moveItem(at: home.appendingPathComponent("Library/Application Support/Cursor/logs/temp"), to: home.appendingPathComponent("Library/Application Support/Cursor/logs/2026-10-18")) }),
            // traeLogs
            (.traeLogs, { try fm.moveItem(at: home.appendingPathComponent("Library/Application Support/Trae/logs/2026-10-18"), to: home.appendingPathComponent("Library/Application Support/Trae/logs/temp")) },
                        { try fm.moveItem(at: home.appendingPathComponent("Library/Application Support/Trae/logs/temp"), to: home.appendingPathComponent("Library/Application Support/Trae/logs/2026-10-18")) }),
            // windsurfLogs
            (.windsurfLogs, { try fm.moveItem(at: home.appendingPathComponent("Library/Application Support/Windsurf/logs/2026-10-18"), to: home.appendingPathComponent("Library/Application Support/Windsurf/logs/temp")) },
                            { try fm.moveItem(at: home.appendingPathComponent("Library/Application Support/Windsurf/logs/temp"), to: home.appendingPathComponent("Library/Application Support/Windsurf/logs/2026-10-18")) }),
            // continueLogs
            (.continueLogs, { try fm.moveItem(at: home.appendingPathComponent(".continue/logs/core.log"), to: home.appendingPathComponent(".continue/logs/unknown.txt")) },
                            { try fm.moveItem(at: home.appendingPathComponent(".continue/logs/unknown.txt"), to: home.appendingPathComponent(".continue/logs/core.log")) }),
            // devinCache
            (.devinCache, { try fm.moveItem(at: home.appendingPathComponent(".cache/devin/telemetry_state.json"), to: home.appendingPathComponent(".cache/devin/unknown.txt")) },
                          { try fm.moveItem(at: home.appendingPathComponent(".cache/devin/unknown.txt"), to: home.appendingPathComponent(".cache/devin/telemetry_state.json")) }),
            // chromaCache
            (.chromaCache, { try fm.moveItem(at: home.appendingPathComponent(".cache/chroma/onnx_models"), to: home.appendingPathComponent(".cache/chroma/other_models")) },
                           { try fm.moveItem(at: home.appendingPathComponent(".cache/chroma/other_models"), to: home.appendingPathComponent(".cache/chroma/onnx_models")) }),
            (.gradle, { try fm.moveItem(at: home.appendingPathComponent(".gradle/caches/modules-2"), to: home.appendingPathComponent(".gradle/caches/other"))
                        try fm.moveItem(at: home.appendingPathComponent(".gradle/caches/jars-9"), to: home.appendingPathComponent(".gradle/caches/other2")) },
                      { try fm.moveItem(at: home.appendingPathComponent(".gradle/caches/other"), to: home.appendingPathComponent(".gradle/caches/modules-2"))
                        try fm.moveItem(at: home.appendingPathComponent(".gradle/caches/other2"), to: home.appendingPathComponent(".gradle/caches/jars-9")) }),
            (.chrome, { try fm.createSymbolicLink(at: home.appendingPathComponent(DeveloperCleanupRule.chrome.relativePath + "/Default/link"), withDestinationURL: home) },
                      { try fm.removeItem(at: home.appendingPathComponent(DeveloperCleanupRule.chrome.relativePath + "/Default/link")) }),
            (.cargo, { try file(DeveloperCleanupRule.cargo.relativePath + "/index.crates.io-6f17d22bba15001f/notes.txt") },
                     { try fm.removeItem(at: home.appendingPathComponent(DeveloperCleanupRule.cargo.relativePath + "/index.crates.io-6f17d22bba15001f/notes.txt")) }),
            (.goBuild, { try file(DeveloperCleanupRule.goBuild.relativePath + "/README", Data("my notes".utf8)) },
                       { try file(DeveloperCleanupRule.goBuild.relativePath + "/README", Data("This directory holds cached build artifacts from the Go build system.\n".utf8)) })
        ]
        for (rule, breakIt, restore) in blockers {
            try breakIt()
            let group = try scan().first { $0.rule == rule }!
            precondition(group.blockedReason != nil, "\(rule) accepted without evidence")
            precondition(cleaner.move(groupIDs: [group.id], activity: { _, _ in nil }).allSatisfy { $0.destination == nil && $0.error != nil })
            try restore()
        }
        groups = try scan()
        precondition(groups.allSatisfy { $0.blockedReason == nil })

        // 白名单：规则根目录可放行，父目录、兄弟目录与子目录都拒绝。
        let chromeRoot = home.appendingPathComponent(DeveloperCleanupRule.chrome.relativePath)
        precondition(TrashService(index: index, home: home, developerAllowedRoots: [chromeRoot]).reasonBlocked(chromeRoot) == nil)
        for other in [chromeRoot.deletingLastPathComponent(), home.appendingPathComponent("Library/Caches/Google/Other"), chromeRoot.appendingPathComponent("Default")] {
            precondition(TrashService(index: index, home: home, developerAllowedRoots: [other]).reasonBlocked(other) != nil, "allowed \(other.path)")
        }
        precondition(DeveloperCleanupActivity.processReason(.chrome, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.gradle, "/usr/bin/java\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.firefox, "/usr/bin/vim\n") == nil)

        precondition(DeveloperCleanupActivity.processReason(.claudeDebug, "/usr/local/bin/claude\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.codexLogs, "/Applications/Codex.app/Contents/MacOS/Codex\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.claudeCache, "/usr/bin/vim\n") == nil)
        precondition(DeveloperCleanupActivity.processReason(.copilotLogs, "/usr/local/bin/node\n") == nil)
        precondition(DeveloperCleanupActivity.processReason(.kimiLogs, "/usr/local/bin/kimi-code\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.codebuddyLogs, "/usr/local/bin/codebuddy\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.aiderCache, "/usr/local/bin/aider\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.aiderCache, "/usr/bin/vim\n") == nil)
        precondition(DeveloperCleanupActivity.processReason(.workbuddyLogs, "/Applications/WorkBuddy.app/Contents/MacOS/WorkBuddy\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.cursorLogs, "/Applications/Cursor.app/Contents/MacOS/Cursor\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.traeLogs, "/Applications/Trae.app/Contents/MacOS/Trae\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.windsurfLogs, "/Applications/Windsurf.app/Contents/MacOS/Windsurf\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.continueLogs, "/usr/local/bin/node\n") == nil)
        precondition(DeveloperCleanupActivity.processReason(.devinCache, "/usr/local/bin/devin\n") != nil)
        precondition(DeveloperCleanupActivity.processReason(.chromaCache, "/usr/bin/python3\n") == nil)
        for path in [".codex/sessions/session.jsonl", ".codex/memories/keep.md", ".codex/worktrees/project/main.swift", ".claude/projects/session.jsonl", ".claude/settings.json"] { try file(path) }
        let aiLocations = OtherStorage.aiLocations(home: home)
        let sessions = aiLocations.first { $0.url.path.hasSuffix("/.codex/sessions") }!
        precondition(OtherStorage.measure(sessions, token: CancellationToken())?.allocatedSize ?? 0 > 0)
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".codex/log").path }, "read-only analysis double counted cleanable logs")
        // 新增工具的可清理子目录不应出现在 aiLocations 只读列表中（会重复计算）
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".copilot/logs").path }, "copilotLogs double counted")
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".kimi-code/logs").path }, "kimiLogs double counted")
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".kimi-code/cache").path }, "kimiCache double counted")
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".codebuddy/logs").path }, "codebuddyLogs double counted")
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".aider/caches").path }, "aiderCache double counted")
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".workbuddy/logs").path }, "workbuddyLogs double counted")
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".workbuddy/cache").path }, "workbuddyCache double counted")
        precondition(!aiLocations.contains { $0.url.path == home.appendingPathComponent(".workbuddy/traces").path }, "workbuddyTraces double counted")
        let aliasHome = home.appendingPathComponent("alias-home")
        try fm.createDirectory(at: aliasHome, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: aliasHome.appendingPathComponent(".codex"), withDestinationURL: home.appendingPathComponent(".codex"))
        let aliasSession = OtherStorage.aiLocations(home: aliasHome).first { $0.name == "Codex 会话" }!
        let aliasMeasurement = OtherStorage.measure(aliasSession, token: CancellationToken())
        precondition(aliasMeasurement?.allocatedSize == 0 && aliasMeasurement?.issue != nil, "followed an AI ancestor symlink")
        precondition(cleaner.move(groupIDs: ["claudeDebug"], activity: { _, _ in "active agent" }).allSatisfy { $0.destination == nil })
        let aiMoved = cleaner.move(groupIDs: [
            "claudeCache", "claudeDebug", "codexLogs", "copilotLogs", "kimiLogs", "kimiCache", "codebuddyLogs", "aiderCache",
            "workbuddyLogs", "workbuddyCache", "workbuddyTraces", "cursorLogs", "traeLogs", "windsurfLogs", "continueLogs", "devinCache", "chromaCache"
        ], activity: { _, _ in nil })
        trash += aiMoved.compactMap(\.destination)
        precondition(aiMoved.count == 17 && aiMoved.allSatisfy { $0.destination != nil && $0.error == nil })
        for path in [".codex/sessions/session.jsonl", ".codex/memories/keep.md", ".codex/worktrees/project/main.swift", ".claude/projects/session.jsonl", ".claude/settings.json"] {
            precondition(fm.fileExists(atPath: home.appendingPathComponent(path).path), "AI work data moved: \(path)")
        }
        // 活动进程阻止执行；移走 Homebrew 时内部链接作为链接移动，链接目标随整目录一起移走。
        precondition(cleaner.move(groupIDs: ["homebrew"], activity: { _, _ in "检测到 brew" }).allSatisfy { $0.destination == nil })
        let moved = cleaner.move(groupIDs: ["homebrew", "chrome"], activity: { _, _ in nil })
        trash += moved.compactMap(\.destination)
        precondition(moved.count == 2 && moved.allSatisfy { $0.destination != nil && $0.error == nil && $0.allocatedSize != nil })
        precondition(!fm.fileExists(atPath: home.appendingPathComponent(DeveloperCleanupRule.homebrew.relativePath).path))
        precondition(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/Google").path), "parent of the Chrome cache was moved")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(DeveloperCleanupRule.edge.relativePath).path))
        print("PASS: whole-directory and AI cache/log rules with tool markers, link and content refusal, exact root allowlist, process names, homebrew internal links")
    }
}
