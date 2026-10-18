import AppKit
import SwiftUI
import MacEvenCore

/// 统一的更新提示与弹窗管理器（菜单栏、Popover 与设置页共用）
@MainActor
public enum UpdateAlertManager {

    /// 触发检查更新，并以模态弹窗呈现结果（参照 FinderRight 的做法）
    public static func checkForUpdates() {
        let checker = UpdateChecker.shared
        if checker.currentStatus.isInProgress {
            return
        }

        checker.check(force: true) { status in
            DispatchQueue.main.async {
                switch status {
                case .upToDate:
                    showUpToDateAlert()
                case .updateAvailable(let version, let releaseURL, let downloadURL, let checksum):
                    promptUpdate(version: version, releaseURL: releaseURL, downloadURL: downloadURL, checksum: checksum)
                case .failed(let message):
                    showUpdateFailure(title: localized("无法检查更新"), message: message)
                default:
                    break
                }
            }
        }
    }

    private static func showUpToDateAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = localized("已是最新版本")
        alert.informativeText = localized("MacEven \(UpdateChecker.shared.currentAppVersion) 是目前的最新版本。")
        alert.addButton(withTitle: localized("好"))
        alert.runModal()
    }

    private static func promptUpdate(version: String, releaseURL: URL, downloadURL: URL?, checksum: UpdateChecksum?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = localized("发现新版本 \(version)")
        let current = UpdateChecker.shared.currentAppVersion

        guard let downloadURL, checksum != nil else {
            alert.informativeText = localized("当前版本 \(current)。此版本暂不支持自动安装，请前往发布页下载。")
            alert.addButton(withTitle: localized("前往下载"))
            alert.addButton(withTitle: localized("稍后")).keyEquivalent = "\u{1b}"
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releaseURL)
            }
            return
        }

        alert.informativeText = localized("当前版本 \(current)。更新将在后台下载并验证代码签名与哈希，完成后 MacEven 会自动重启。")
        alert.addButton(withTitle: localized("立即更新"))
        alert.addButton(withTitle: localized("稍后")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: localized("查看更新说明"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum) { status in
                DispatchQueue.main.async {
                    if case .failed(let message) = status {
                        showUpdateFailure(title: localized("自动更新失败"), message: message)
                    }
                }
            }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(releaseURL)
        default:
            break
        }
    }

    private static func showUpdateFailure(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: localized("好"))
        alert.runModal()
    }
}
