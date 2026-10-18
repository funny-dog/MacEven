import AppKit
import MacEvenCore
import Darwin
import Foundation

// 在后台队列请求正常退出；保存提示由应用自己处理，拒绝或超时都不强制结束。
enum ApplicationCloser {
    static func close(identifier: String, applicationURL: URL?, timeout: TimeInterval = 15) -> String? {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return localized("应用标识不能为空。") }
        guard timeout.isFinite, timeout >= 0 else { return localized("退出等待时间无效。") }
        guard !identifier.lowercased().hasPrefix("com.apple.") else { return localized("系统保护：禁止关闭系统应用。") }
        let ownPath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let targetPath = applicationURL?.resolvingSymlinksInPath().path
        guard identifier != Bundle.main.bundleIdentifier, targetPath != ownPath else { return localized("自身保护：禁止关闭当前应用。") }

        func matches() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { app in
                guard !app.isTerminated else { return false }
                if let targetPath {
                    let bundle = app.bundleURL?.resolvingSymlinksInPath().path
                    let executable = app.executableURL?.resolvingSymlinksInPath().path
                    return bundle == targetPath || bundle?.hasPrefix(targetPath + "/") == true || executable?.hasPrefix(targetPath + "/") == true
                }
                guard let id = app.bundleIdentifier else { return false }
                return id == identifier || id.hasPrefix(identifier + ".")
            }
        }

        let applications = matches()
        for app in applications {
            let bundlePath = app.bundleURL?.resolvingSymlinksInPath().path
            guard app.processIdentifier != getpid(), app.processIdentifier > 1,
                bundlePath != ownPath, bundlePath?.hasPrefix(ownPath + "/") != true else { return localized("自身保护：禁止关闭当前应用及其辅助进程。") }
            guard app.bundleIdentifier?.lowercased().hasPrefix("com.apple.") != true,
                app.executableURL?.path.hasPrefix("/System/") != true else { return localized("系统保护：禁止关闭系统组件。") }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size else {
                if app.isTerminated { continue }
                return localized("无法核验应用进程身份，已保留。")
            }
            guard info.pbi_uid != 0, info.pbi_uid == geteuid(), info.pbi_ruid == getuid() else { return localized("权限保护：不能关闭其他用户或系统的应用。") }
        }
        var rejected = false
        for app in applications where app.bundleIdentifier == identifier && !app.isTerminated {
            if !app.terminate() && !app.isTerminated { rejected = true }
        }
        var helpersRequested = false
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            // 重读匹配集合，应用自动重启或新辅助进程也不能被当成已退出。
            let alive = matches().filter { kill($0.processIdentifier, 0) == 0 || errno != ESRCH }
            if alive.isEmpty { return nil }
            // 主应用可能仍在等待保存；退出前不提前结束它的辅助进程。
            if !helpersRequested, !alive.contains(where: { $0.bundleIdentifier == identifier }) {
                for app in applications where app.bundleIdentifier != identifier && !app.isTerminated {
                    if !app.terminate() && !app.isTerminated { rejected = true }
                }
                helpersRequested = true
                continue
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            guard elapsed < timeout else {
                return rejected ? localized("应用未接受正常退出请求，内容已保留。") : localized("等待应用退出超时，内容已保留；请完成应用中的保存提示后重试。")
            }
            Thread.sleep(forTimeInterval: min(0.05, timeout - elapsed))
        }
    }
}
