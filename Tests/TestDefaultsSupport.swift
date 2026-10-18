import Darwin
import Foundation

// 检查程序专用的一次性偏好域。
// 进程内 removePersistentDomain 之后，cfprefsd 仍会在 ~/Library/Preferences 写回空 plist，
// 所以创建前先把域名登记到 MACEVEN_TEST_DEFAULTS_LOG 指向的文件，由脚本在进程退出后
// 通过 scripts/clean-test-defaults.sh 精确删除这些域，不用通配符。
func makeTestDefaults(prefix: String) -> (defaults: UserDefaults, suite: String) {
    let suite = "\(prefix).\(UUID().uuidString)"
    recordTestDefaultsSuite(suite)
    guard let defaults = UserDefaults(suiteName: suite) else {
        fputs("FAIL: 无法创建临时偏好域 \(suite)\n", stderr)
        exit(EXIT_FAILURE)
    }
    return (defaults, suite)
}

private func recordTestDefaultsSuite(_ suite: String) {
    guard let path = ProcessInfo.processInfo.environment["MACEVEN_TEST_DEFAULTS_LOG"], !path.isEmpty else {
        // 手动直接运行检查程序时没有登记文件，提示退出后的清理命令。
        fputs("提示：未设置 MACEVEN_TEST_DEFAULTS_LOG，检查进程退出后请执行 defaults delete \(suite); rm -f ~/Library/Preferences/\(suite).plist\n", stderr)
        return
    }
    // 追加写入：同一次脚本运行中的多个检查程序共用一个登记文件。
    let line = suite + "\n"
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0, line.withCString({ write(fd, $0, strlen($0)) }) == line.utf8.count else {
        fputs("FAIL: 无法登记临时偏好域 \(suite) 到 \(path)\n", stderr)
        exit(EXIT_FAILURE)
    }
    close(fd)
}
