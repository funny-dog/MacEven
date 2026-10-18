import AppKit
import Darwin
import Foundation

private final class LaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _app: NSRunningApplication?
    private var _error: Error?

    var app: NSRunningApplication? {
        lock.withLock { _app }
    }
    var error: Error? {
        lock.withLock { _error }
    }

    func set(app: NSRunningApplication?, error: Error?) {
        lock.withLock {
            self._app = app
            self._error = error
        }
    }
}

@main
struct ApplicationCloserChecks {

    static func main() {
        print("==> 开始 ApplicationCloser 单元检查...")

        guard CommandLine.arguments.count > 1 else {
            fputs("错误：未提供测试临时目录参数\n", stderr)
            exit(1)
        }
        let taskHome = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let helperBinaryURL = taskHome.appendingPathComponent("DummyHelper")

        guard FileManager.default.isExecutableFile(atPath: helperBinaryURL.path) else {
            fputs("错误：测试辅助二进制未找到: \(helperBinaryURL.path)\n", stderr)
            exit(1)
        }

        do {
            try checkNotRunning()
            try checkEmptyAndProtection()
            try checkNormalClose(taskHome: taskHome, helperBinary: helperBinaryURL)
            try checkPrefixHelperClose(taskHome: taskHome, helperBinary: helperBinaryURL)
            try checkUrlSpecificCloseAndIgnoreOtherCopies(taskHome: taskHome, helperBinary: helperBinaryURL)
            try checkStubbornAndTimeoutRetained(taskHome: taskHome, helperBinary: helperBinaryURL)
            print("==> ApplicationCloser 所有的安全与退出检查均 PASS！")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // 1. 未运行检查
    static func checkNotRunning() throws {
        print("-> 检查 1: 未运行进程应直接返回 nil...")
        let res1 = ApplicationCloser.close(
            identifier: "local.maceven.test.nonexistent.app.\(UUID().uuidString)",
            applicationURL: nil
        )
        precondition(res1 == nil, "未运行的 bundle ID 应直接返回 nil")

        let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).app")
        let res2 = ApplicationCloser.close(
            identifier: "local.maceven.test.nonexistent.app",
            applicationURL: fakeURL
        )
        precondition(res2 == nil, "未运行的路径应用应直接返回 nil")
        print("   PASS: 未运行场景返回 nil 验证通过")
    }

    // 2. 空标识与安全保护检查
    static func checkEmptyAndProtection() throws {
        print("-> 检查 2: 空标识、系统核心服务与自身保护...")
        // 空标识
        let empty1 = ApplicationCloser.close(identifier: "", applicationURL: nil)
        precondition(empty1 != nil && empty1!.contains("空"), "空标识必须被拒绝")
        let empty2 = ApplicationCloser.close(identifier: "   \t\n", applicationURL: nil)
        precondition(empty2 != nil && empty2!.contains("空"), "空白字符串标识必须被拒绝")

        // 系统核心服务
        let finderRes = ApplicationCloser.close(identifier: "com.apple.finder", applicationURL: nil)
        precondition(finderRes != nil && finderRes!.contains("系统保护"), "系统 Finder 必须受到保护")
        let dockRes = ApplicationCloser.close(identifier: "com.apple.dock", applicationURL: nil)
        precondition(dockRes != nil && dockRes!.contains("系统保护"), "系统 Dock 必须受到保护")
        let loginWindowRes = ApplicationCloser.close(identifier: "com.apple.loginwindow", applicationURL: nil)
        precondition(loginWindowRes != nil && loginWindowRes!.contains("系统保护"), "系统 loginwindow 必须受到保护")

        // 验证用户真实系统 Finder 依旧安全运行
        let finderAlive = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.finder" }
        precondition(finderAlive, "系统 Finder 进程必须未被影响")

        // 自身保护
        if let ownBundleID = Bundle.main.bundleIdentifier {
            let selfRes = ApplicationCloser.close(identifier: ownBundleID, applicationURL: nil)
            precondition(selfRes != nil && selfRes!.contains("自身保护"), "禁止关闭当前自身应用")
        }
        let ownURL = Bundle.main.bundleURL
        let selfURLRes = ApplicationCloser.close(identifier: "local.maceven.arbitrary", applicationURL: ownURL)
        precondition(selfURLRes != nil && selfURLRes!.contains("自身保护"), "禁止按路径关闭当前应用")

        print("   PASS: 标识校验与系统/自身防御机制验证通过")
    }

    // 3. 正常退出检查（缓存模式 URL = nil）
    static func checkNormalClose(taskHome: URL, helperBinary: URL) throws {
        print("-> 检查 3: 缓存模式正常温和退出专属测试子应用...")
        let bundleID = "local.maceven.test.normal.\(UUID().uuidString.prefix(8))"
        let appDir = taskHome.appendingPathComponent("NormalTest")
        let appURL = try createAppBundle(
            at: appDir,
            appName: "NormalApp",
            bundleIdentifier: bundleID,
            binarySourceURL: helperBinary
        )

        let app = try launchApp(at: appURL)
        let pid = app.processIdentifier
        defer { cleanupApp(app) }

        precondition(isProcessRunning(pid), "测试子应用启动后必须处于存活状态")

        // 调用 ApplicationCloser 进行温和退出
        let closeResult = ApplicationCloser.close(identifier: bundleID, applicationURL: nil, timeout: 5)
        precondition(closeResult == nil, "正常退出应返回 nil，实际返回: \(closeResult ?? "")")
        precondition(!isProcessRunning(pid), "正常退出后目标进程应当已退出")
        print("   PASS: 缓存模式正常退出成功")
    }

    // 4. 辅助进程前缀匹配退出（id加点前缀）
    static func checkPrefixHelperClose(taskHome: URL, helperBinary: URL) throws {
        print("-> 检查 4: 辅助进程前缀匹配 (id.helper) 退出...")
        let mainID = "local.maceven.test.prefix.\(UUID().uuidString.prefix(8))"
        let helperID = "\(mainID).background-service"

        let appDir = taskHome.appendingPathComponent("PrefixTest")
        let appURL = try createAppBundle(
            at: appDir,
            appName: "PrefixHelperApp",
            bundleIdentifier: helperID,
            binarySourceURL: helperBinary
        )

        let app = try launchApp(at: appURL)
        let pid = app.processIdentifier
        defer { cleanupApp(app) }

        precondition(isProcessRunning(pid), "辅助进程启动后必须处于存活状态")

        // 传入主应用 identifier，应当匹配到具有 mainID + "." 前缀的辅助进程
        let closeResult = ApplicationCloser.close(identifier: mainID, applicationURL: nil, timeout: 5)
        precondition(closeResult == nil, "辅助进程退出应返回 nil，实际返回: \(closeResult ?? "")")
        precondition(!isProcessRunning(pid), "辅助进程应当已正常退出")
        print("   PASS: 辅助进程前缀匹配退出成功")
    }

    // 5. 卸载模式路径限定与不波及同 Bundle ID 其他路径副本
    static func checkUrlSpecificCloseAndIgnoreOtherCopies(taskHome: URL, helperBinary: URL) throws {
        print("-> 检查 5: 卸载模式只退出指定实际路径应用，不关闭同 Bundle ID 其他副本...")
        let sharedID = "local.maceven.test.multicopy.\(UUID().uuidString.prefix(8))"

        let dirA = taskHome.appendingPathComponent("InstallA")
        let appAURL = try createAppBundle(
            at: dirA,
            appName: "MultiCopyApp",
            bundleIdentifier: sharedID,
            binarySourceURL: helperBinary
        )

        let dirB = taskHome.appendingPathComponent("InstallB")
        let appBURL = try createAppBundle(
            at: dirB,
            appName: "MultiCopyApp",
            bundleIdentifier: sharedID,
            binarySourceURL: helperBinary
        )

        let appA = try launchApp(at: appAURL)
        let pidA = appA.processIdentifier
        defer { cleanupApp(appA) }

        let appB = try launchApp(at: appBURL)
        let pidB = appB.processIdentifier
        defer { cleanupApp(appB) }

        precondition(isProcessRunning(pidA), "副本 A 必须在运行")
        precondition(isProcessRunning(pidB), "副本 B 必须在运行")
        precondition(pidA != pidB, "两副本必须为不同进程 PID")

        // 仅指定退出副本 A 的路径
        let closeResult = ApplicationCloser.close(identifier: sharedID, applicationURL: appAURL, timeout: 5)
        precondition(closeResult == nil, "副本 A 退出应返回 nil，实际返回: \(closeResult ?? "")")
        precondition(!isProcessRunning(pidA), "指定实际路径的副本 A 必须已成功退出")
        precondition(isProcessRunning(pidB), "非目标路径的副本 B 绝不能被退出，必须保持运行")

        print("   PASS: 卸载模式路径隔离验证通过，其他路径副本未被波及")
    }

    // 6. 拒绝退出与超时保留检查（不 forceTerminate、不 kill）
    static func checkStubbornAndTimeoutRetained(taskHome: URL, helperBinary: URL) throws {
        print("-> 检查 6: 拒绝退出子应用触发超时且保留进程（不 forceTerminate / 不 kill）...")
        let stubbornID = "local.maceven.test.stubborn.\(UUID().uuidString.prefix(8))"
        let appDir = taskHome.appendingPathComponent("StubbornTest")
        let appURL = try createAppBundle(
            at: appDir,
            appName: "StubbornApp",
            bundleIdentifier: stubbornID,
            binarySourceURL: helperBinary
        )

        let app = try launchApp(
            at: appURL,
            environment: ["TEST_STUBBORN": "1"]
        )
        let pid = app.processIdentifier
        defer { cleanupApp(app) }

        precondition(isProcessRunning(pid), "顽固测试子应用启动后必须处于存活状态")

        let helperURL = try createAppBundle(at: appDir, appName: "PendingHelper", bundleIdentifier: stubbornID + ".helper", binarySourceURL: helperBinary)
        let helper = try launchApp(at: helperURL)
        defer { cleanupApp(helper) }
        // 传入较短超时（0.6秒）
        let closeResult = ApplicationCloser.close(identifier: stubbornID, applicationURL: nil, timeout: 0.6)
        precondition(closeResult != nil, "拒绝退出或超时必须返回非 nil 错误信息")
        precondition(
            closeResult!.contains("超时") || closeResult!.contains("拒绝"),
            "返回信息必须包含超时或拒绝原因，实际为: \(closeResult!)"
        )
        // 关键点：超时保留，只调用 terminate，不 forceTerminate，不 kill，所以应用进程仍保持存活！
        precondition(isProcessRunning(pid), "超时后必须保留进程，不得执行 kill 或 forceTerminate")
        precondition(isProcessRunning(helper.processIdentifier), "主应用等待保存或拒绝退出时不能提前关闭辅助进程")
        print("   PASS: 拒绝退出检测及超时保留机制验证通过 (错误说明: \(closeResult!))")
    }

    // MARK: - 辅助方法

    private static func createAppBundle(
        at dirURL: URL,
        appName: String,
        bundleIdentifier: String,
        binarySourceURL: URL
    ) throws -> URL {
        let appURL = dirURL.appendingPathComponent("\(appName).app")
        let contentsURL = appURL.appendingPathComponent("Contents")
        let macosURL = contentsURL.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macosURL, withIntermediateDirectories: true)

        let targetBinary = macosURL.appendingPathComponent(appName)
        if FileManager.default.fileExists(atPath: targetBinary.path) {
            try FileManager.default.removeItem(at: targetBinary)
        }
        try FileManager.default.copyItem(at: binarySourceURL, to: targetBinary)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": appName,
            "CFBundleExecutable": appName,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let signProc = Process()
        signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProc.arguments = ["--force", "--sign", "-", appURL.path]
        try signProc.run()
        signProc.waitUntilExit()
        precondition(signProc.terminationStatus == 0, "codesign 签名失败: \(appURL.path)")

        return appURL
    }

    private static func launchApp(
        at appURL: URL,
        environment: [String: String] = [:]
    ) throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true
        config.environment = environment

        let sema = DispatchSemaphore(value: 0)
        let box = LaunchBox()

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            box.set(app: app, error: error)
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 5)

        if let error = box.error {
            throw error
        }
        guard let app = box.app else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法启动测试应用: \(appURL.path)"])
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !app.isTerminated && app.isFinishedLaunching {
                return app
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return app
    }

    private static func isProcessRunning(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private static func cleanupApp(_ app: NSRunningApplication?) {
        guard let app = app else { return }
        let pid = app.processIdentifier
        if isProcessRunning(pid) {
            app.terminate()
            kill(pid, SIGKILL)
        }
    }
}
