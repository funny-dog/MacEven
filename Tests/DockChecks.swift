import Foundation
import CoreFoundation
import MacEvenCore

/// 跟踪 restart 调用的辅助类
private final class RestartTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var errorToReturn: String?

    var count: Int {
        lock.withLock { _count }
    }

    func invoke() -> String? {
        lock.withLock {
            _count += 1
            return errorToReturn
        }
    }

    func reset() {
        lock.withLock {
            _count = 0
            errorToReturn = nil
        }
    }
}

/// 辅助生成 Dock persistent-apps 条目字典
private func makeTile(label: String, bundleId: String? = nil, urlString: String? = nil) -> [String: Any] {
    var tileData: [String: Any] = ["file-label": label]
    if let bundleId = bundleId {
        tileData["bundle-identifier"] = bundleId
    }
    if let urlString = urlString {
        tileData["file-data"] = [
            "_CFURLString": urlString,
            "_CFURLStringType": 15
        ]
    }
    return [
        "tile-data": tileData,
        "tile-type": "file-tile"
    ]
}

@main
struct DockChecks {
    static func main() {
        checkDockTilesMatching()
        checkDockTilesRemoving()
        checkDockCleaner()
        print("PASS: DockTiles matching, removing and DockCleaner preference backup and restart handling")
    }

    // MARK: - DockTiles 匹配规则测试

    private static func checkDockTilesMatching() {
        // 1. 路径匹配：百分号编码（空格、中文）、尾部斜杠、大小写
        let tileSpace = makeTile(
            label: "Space App",
            bundleId: "com.example.space",
            urlString: "file:///Applications/Space%20App.app/"
        )
        let tileChineseEncoded = makeTile(
            label: "中文应用",
            bundleId: "com.example.cn1",
            urlString: "file:///Applications/%E4%B8%AD%E6%96%87%E5%BA%94%E7%94%A8.app/"
        )
        let tileChineseRaw = makeTile(
            label: "原生中文",
            bundleId: "com.example.cn2",
            urlString: "file:///Applications/原生中文.app/"
        )
        let tileSlash = makeTile(
            label: "Slash App",
            bundleId: "com.example.slash",
            urlString: "file:///Applications/SlashApp.app/"
        )
        let tileNoSlash = makeTile(
            label: "NoSlash App",
            bundleId: "com.example.noslash",
            urlString: "file:///Applications/NoSlashApp.app"
        )
        let tileCase = makeTile(
            label: "Case App",
            bundleId: "com.example.case",
            urlString: "file:///Applications/CaseApp.app/"
        )

        let tiles = [tileSpace, tileChineseEncoded, tileChineseRaw, tileSlash, tileNoSlash, tileCase]

        // 匹配空格应用
        let matchSpace = DockTiles.matches(
            in: tiles,
            appPaths: ["/Applications/Space App.app"],
            bundleIdentifiers: []
        )
        precondition(matchSpace.count == 1 && matchSpace[0].index == 0, "百分号编码空格路径匹配失败")

        // 匹配编码中文应用
        let matchCnEncoded = DockTiles.matches(
            in: tiles,
            appPaths: ["/Applications/中文应用.app"],
            bundleIdentifiers: []
        )
        precondition(matchCnEncoded.count == 1 && matchCnEncoded[0].index == 1, "百分号编码中文路径匹配失败")

        // 匹配未编码中文应用
        let matchCnRaw = DockTiles.matches(
            in: tiles,
            appPaths: ["/Applications/原生中文.app"],
            bundleIdentifiers: []
        )
        precondition(matchCnRaw.count == 1 && matchCnRaw[0].index == 2, "未编码中文路径匹配失败")

        // 尾部斜杠测试（tile 带斜杠，查询参数去斜杠）
        let matchSlash1 = DockTiles.matches(
            in: tiles,
            appPaths: ["/Applications/SlashApp.app"],
            bundleIdentifiers: []
        )
        precondition(matchSlash1.count == 1 && matchSlash1[0].index == 3, "带斜杠路径匹配失败")

        // 尾部斜杠测试（tile 不带斜杠，查询参数带斜杠）
        let matchSlash2 = DockTiles.matches(
            in: tiles,
            appPaths: ["/Applications/NoSlashApp.app/"],
            bundleIdentifiers: []
        )
        precondition(matchSlash2.count == 1 && matchSlash2[0].index == 4, "尾部斜杠兼容匹配失败")

        // 大小写不区分测试
        let matchCase = DockTiles.matches(
            in: tiles,
            appPaths: ["/applications/caseapp.app"],
            bundleIdentifiers: []
        )
        precondition(matchCase.count == 1 && matchCase[0].index == 5, "大小写不敏感匹配失败")

        // 2. 只按路径匹配，不误删同标识另一副本
        let copy1 = makeTile(
            label: "App Copy 1",
            bundleId: "com.example.duplicate",
            urlString: "file:///Applications/App1.app/"
        )
        let copy2 = makeTile(
            label: "App Copy 2",
            bundleId: "com.example.duplicate",
            urlString: "file:///Applications/App2.app/"
        )
        let duplicateTiles = [copy1, copy2]

        let matchOnlyCopy1 = DockTiles.matches(
            in: duplicateTiles,
            appPaths: ["/Applications/App1.app"],
            bundleIdentifiers: ["com.example.duplicate"]
        )
        precondition(
            matchOnlyCopy1.count == 1 && matchOnlyCopy1[0].index == 0,
            "同 bundleIdentifier 副本不应因标识匹配被误删"
        )

        // 3. 无路径时退而按 bundle-identifier 匹配
        let noPathTile = makeTile(
            label: "No Path App",
            bundleId: "com.example.nopath",
            urlString: nil
        )
        let noPathMatch = DockTiles.matches(
            in: [noPathTile],
            appPaths: [],
            bundleIdentifiers: ["COM.EXAMPLE.NOPATH"]
        )
        precondition(
            noPathMatch.count == 1 && noPathMatch[0].index == 0 && noPathMatch[0].path == nil,
            "无路径时按 bundle-identifier 大小写不敏感匹配失败"
        )

        // 4. 畸形条目安全跳过
        let malformedTiles: [[String: Any]] = [
            [:],                                                    // 缺 tile-data
            ["tile-data": "not a dictionary"],                      // tile-data 非字典
            ["tile-data": ["bundle-identifier": "com.foo"]],        // 缺 file-label
            ["tile-data": ["file-label": "Broken URL", "file-data": ["_CFURLString": "http://invalid"]]], // 损坏 URL 且无 bundleId
        ]
        let malformedMatches = DockTiles.matches(
            in: malformedTiles,
            appPaths: ["/Applications/Broken URL.app"],
            bundleIdentifiers: ["com.foo"]
        )
        precondition(malformedMatches.isEmpty, "畸形条目必须跳过不匹配")
    }

    // MARK: - removing 保序测试

    private static func checkDockTilesRemoving() {
        let t0 = makeTile(label: "Tile 0")
        let t1 = makeTile(label: "Tile 1")
        let t2 = makeTile(label: "Tile 2")
        let t3 = makeTile(label: "Tile 3")
        let t4 = makeTile(label: "Tile 4")
        let tiles = [t0, t1, t2, t3, t4]

        let remaining = DockTiles.removing(Set([1, 3]), from: tiles)
        precondition(remaining.count == 3, "移除后数量错误")
        let labels = remaining.compactMap { ($0["tile-data"] as? [String: Any])?["file-label"] as? String }
        precondition(labels == ["Tile 0", "Tile 2", "Tile 4"], "移除后元素未按原样保序")
    }

    // MARK: - DockCleaner 偏好与备份测试

    private static func checkDockCleaner() {
        let testUUID = UUID().uuidString
        let domain = "local.maceven.dockchecks.\(testUUID)"
        let tempBackupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-checks-\(testUUID)", isDirectory: true)

        let tracker = RestartTracker()
        let cleaner = DockCleaner(
            domain: domain,
            backupDirectory: tempBackupDir,
            restart: {
                tracker.invoke()
            }
        )

        defer {
            // 清理测试偏好域和临时目录
            // 直接删 plist 会被仍缓存该域的 cfprefsd 写回空文件；先确保域非空，再经由 defaults 删除整个测试域。
            CFPreferencesSetAppValue("cleanup" as CFString, true as CFPropertyList, domain as CFString)
            _ = CFPreferencesAppSynchronize(domain as CFString)
            let delete = Process()
            delete.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            delete.arguments = ["delete", domain]
            delete.standardOutput = FileHandle.nullDevice; delete.standardError = FileHandle.nullDevice
            if (try? delete.run()) != nil { delete.waitUntilExit() }
            let prefsURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(domain).plist")
            try? FileManager.default.removeItem(at: prefsURL)
            try? FileManager.default.removeItem(at: tempBackupDir)
        }

        let tileA = makeTile(
            label: "App A",
            bundleId: "com.test.a",
            urlString: "file:///Applications/AppA.app/"
        )
        let tileB = makeTile(
            label: "App B",
            bundleId: "com.test.b",
            urlString: "file:///Applications/AppB.app/"
        )
        let sampleTiles = [tileA, tileB]

        // 写入初始测试偏好
        CFPreferencesSetAppValue("persistent-apps" as CFString, sampleTiles as CFPropertyList, domain as CFString)
        let initialSync = CFPreferencesAppSynchronize(domain as CFString)
        precondition(initialSync, "测试域偏好写入同步失败")

        // 验证 matches
        let matchesA = cleaner.matches(appPaths: ["/Applications/AppA.app"], bundleIdentifiers: [])
        precondition(matchesA.count == 1 && matchesA[0].label == "App A", "cleaner.matches 查询失败")

        // 验证无匹配时不写入偏好且不调用 restart
        let resNoMatch = cleaner.remove(
            appPaths: ["/Applications/NonExistent.app"],
            bundleIdentifiers: ["com.nonexistent"]
        )
        switch resNoMatch {
        case .success(let count):
            precondition(count == 0, "无匹配应返回 success(0)")
            precondition(tracker.count == 0, "无匹配不应调用 restart")
            precondition(!FileManager.default.fileExists(atPath: tempBackupDir.path), "无匹配不应创建备份目录")
        case .failure(let error):
            preconditionFailure("无匹配不应失败：\(error.message)")
        }

        // 验证有匹配时的 remove
        let resRemove = cleaner.remove(
            appPaths: ["/Applications/AppA.app"],
            bundleIdentifiers: []
        )
        switch resRemove {
        case .success(let count):
            precondition(count == 1, "应成功移除 1 项")
            precondition(tracker.count == 1, "restart 必须只调用一次")

            // 检查备份目录与文件
            let backupFiles = try! FileManager.default.contentsOfDirectory(at: tempBackupDir, includingPropertiesForKeys: nil)
            precondition(backupFiles.count == 1, "备份目录中应有且仅有 1 个备份文件")
            let backupFile = backupFiles[0]

            // 检查备份文件权限 0600
            let attrs = try! FileManager.default.attributesOfItem(atPath: backupFile.path)
            let perms = attrs[.posixPermissions] as? Int
            precondition(perms == 0o600, "备份文件权限必须为 0600，实际为 \(String(describing: perms))")

            // 检查备份文件内容可读回原数组
            let backupData = try! Data(contentsOf: backupFile)
            let restored = try! PropertyListSerialization.propertyList(
                from: backupData,
                options: [],
                format: nil
            ) as? [[String: Any]]
            precondition(restored != nil && restored!.count == 2, "读回的备份数据必须与原数组一致")

            // 检查测试域中剩余数据
            guard let remainingCF = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain as CFString) as? [[String: Any]] else {
                preconditionFailure("无法读取移除后的 persistent-apps")
            }
            precondition(remainingCF.count == 1, "移除后应剩余 1 项")
            let remLabel = (remainingCF[0]["tile-data"] as? [String: Any])?["file-label"] as? String
            precondition(remLabel == "App B", "剩余项应为 App B")

        case .failure(let error):
            preconditionFailure("移除失败：\(error.message)")
        }

        // 验证 restart 返回错误时 remove 结果为 failure
        tracker.reset()
        tracker.errorToReturn = "模拟重启 Dock 错误"
        CFPreferencesSetAppValue("persistent-apps" as CFString, sampleTiles as CFPropertyList, domain as CFString)
        _ = CFPreferencesAppSynchronize(domain as CFString)

        let resRestartFail = cleaner.remove(
            appPaths: ["/Applications/AppB.app"],
            bundleIdentifiers: []
        )
        switch resRestartFail {
        case .success:
            preconditionFailure("restart 返回错误时应返回 failure")
        case .failure(let error):
            precondition(error.message.contains("模拟重启 Dock 错误"), "错误信息未包含 restart 错误详情")
            precondition(tracker.count == 1, "restart 应被调用一次")
        }

        // 验证域值不是数组时返回 failure
        CFPreferencesSetAppValue("persistent-apps" as CFString, "invalid-string" as CFPropertyList, domain as CFString)
        _ = CFPreferencesAppSynchronize(domain as CFString)
        let resNotArray = cleaner.remove(appPaths: ["/Applications/AppA.app"], bundleIdentifiers: [])
        switch resNotArray {
        case .success:
            preconditionFailure("域值非数组时应返回 failure")
        case .failure:
            break
        }

        // 验证域值不存在（未找到）时返回 failure
        CFPreferencesSetAppValue("persistent-apps" as CFString, nil, domain as CFString)
        _ = CFPreferencesAppSynchronize(domain as CFString)
        let resNil = cleaner.remove(appPaths: ["/Applications/AppA.app"], bundleIdentifiers: [])
        switch resNil {
        case .success:
            preconditionFailure("域值不存在时应返回 failure")
        case .failure:
            break
        }
    }
}
