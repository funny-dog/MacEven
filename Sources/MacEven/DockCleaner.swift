import Foundation
import CoreFoundation
import AppKit
import MacEvenCore

/// Dock 清理器，负责卸载应用时从 Dock persistent-apps 中安全移除匹配条目并备份
struct DockCleaner: Sendable {
    /// Dock 偏好域，生产环境为 "com.apple.dock"
    let domain: String
    /// 备份目录，生产环境为 ~/Library/Application Support/MacEven/dock-backups
    let backupDirectory: URL
    /// Dock 重启回调，返回错误字符串（若成功则返回 nil）
    let restart: @Sendable () -> String?

    /// 初始化 Dock 清理器
    init(
        domain: String = "com.apple.dock",
        backupDirectory: URL,
        restart: @escaping @Sendable () -> String?
    ) {
        self.domain = domain
        self.backupDirectory = backupDirectory
        self.restart = restart
    }

    /// 生产环境实例
    static let live: DockCleaner = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        let backupDir = appSupport.appendingPathComponent("MacEven/dock-backups", isDirectory: true)

        return DockCleaner(
            domain: "com.apple.dock",
            backupDirectory: backupDir,
            restart: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                process.arguments = ["Dock"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    return localized("启动 killall 进程失败：\(error.localizedDescription)")
                }

                let deadline = Date().addingTimeInterval(10)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }

                if process.isRunning {
                    process.terminate()
                    return localized("重启 Dock 进程超时（超过 10 秒）")
                }

                if process.terminationStatus != 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errOutput = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return localized("重启 Dock 失败（退出码 \(process.terminationStatus)）: \(errOutput)")
                }
                return nil
            }
        )
    }()

    /// 读取当前 Dock 偏好并查询匹配项
    func matches(appPaths: [String], bundleIdentifiers: [String]) -> [DockTileMatch] {
        guard let cfValue = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain as CFString) else {
            return []
        }
        guard let tiles = cfValue as? [[String: Any]] else {
            return []
        }
        return DockTiles.matches(in: tiles, appPaths: appPaths, bundleIdentifiers: bundleIdentifiers)
    }

    /// 从 Dock 偏好设置中移除匹配的应用图标
    ///
    /// 执行流程：
    /// 1. 重新读取 persistent-apps，读取失败或非数组返回 failure；
    /// 2. 无匹配直接返回 .success(0)，不写入偏好且不调用 restart；
    /// 3. 有匹配时，先将原数组备份为 XML plist（权限 0600），写入失败则放弃并返回 failure；
    /// 4. 写入过滤后的新数组并同步，同步失败返回 failure；
    /// 5. 调用 restart 重启 Dock，失败返回 failure，成功返回删除条数。
    func remove(appPaths: [String], bundleIdentifiers: [String]) -> Result<Int, MacEvenError> {
        // 1. 重新读取 persistent-apps
        guard let cfValue = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain as CFString) else {
            return .failure(MacEvenError(localized("无法读取 Dock 偏好设置：未找到 persistent-apps 项")))
        }
        guard let tiles = cfValue as? [[String: Any]] else {
            return .failure(MacEvenError(localized("Dock 偏好设置中 persistent-apps 不是合法的数组格式")))
        }

        // 2. 匹配要移除的项
        let matched = DockTiles.matches(in: tiles, appPaths: appPaths, bundleIdentifiers: bundleIdentifiers)
        if matched.isEmpty {
            return .success(0)
        }

        // 3. 备份原数组为 XML plist
        do {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(MacEvenError(localized("创建 Dock 备份目录失败：\(error.localizedDescription)")))
        }

        let plistData: Data
        do {
            plistData = try PropertyListSerialization.data(fromPropertyList: tiles, format: .xml, options: 0)
        } catch {
            return .failure(MacEvenError(localized("序列化 Dock 备份数据失败：\(error.localizedDescription)")))
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let uuidFrag = UUID().uuidString.prefix(8)
        let backupFileName = "dock-backup-\(timestamp)-\(uuidFrag).plist"
        let backupFileURL = backupDirectory.appendingPathComponent(backupFileName)

        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o600
        ]
        let writeSuccess = FileManager.default.createFile(
            atPath: backupFileURL.path,
            contents: plistData,
            attributes: attributes
        )
        guard writeSuccess else {
            return .failure(MacEvenError(localized("写入 Dock 备份文件失败：\(backupFileURL.path)")))
        }

        // 4. 计算移除指定项后的数组
        let indicesToRemove = Set(matched.map(\.index))
        let newTiles = DockTiles.removing(indicesToRemove, from: tiles)

        // 5. 写入新数组并同步偏好
        CFPreferencesSetAppValue("persistent-apps" as CFString, newTiles as CFPropertyList, domain as CFString)
        let syncSuccess = CFPreferencesAppSynchronize(domain as CFString)
        guard syncSuccess else {
            return .failure(MacEvenError(localized("同步 Dock 偏好设置失败")))
        }

        // 6. 调用 restart 重启 Dock
        if let restartError = restart() {
            return .failure(MacEvenError(localized("Dock 偏好已更新，但重启 Dock 失败：\(restartError)")))
        }

        return .success(matched.count)
    }
}
