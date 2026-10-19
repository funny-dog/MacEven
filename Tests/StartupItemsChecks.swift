import Foundation
import MacEvenCore

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
    let result = try condition()
    if !result {
        fatalError("Check failed: \(message)")
    }
}

final class MockRunner: @unchecked Sendable {
    let lock = NSLock()
    var disabledMap: [String: Bool] = [:] // true = disabled, false = enabled
    var loadedSet: Set<String> = []
    var runningPids: [String: Int] = [:]
    var recordedCalls: [[String]] = []

    // Injected behaviors for failure testing
    var malformedPrintDisabled = false
    var malformedList = false
    var disableCommandSucceedsButStateStuck = false
    var bootstrapFails = false
    var queryFailure = false

    func run(executable: URL, args: [String]) throws -> SoftwareCommandResult {
        lock.lock()
        defer { lock.unlock() }
        recordedCalls.append(args)

        guard let subcmd = args.first else {
            return SoftwareCommandResult(status: 1, output: "", error: "Missing subcommand")
        }

        switch subcmd {
        case "print-disabled":
            if queryFailure {
                return SoftwareCommandResult(status: 1, output: "", error: "Failed to query print-disabled")
            }
            if malformedPrintDisabled {
                return SoftwareCommandResult(status: 0, output: "Unexpected garbled output from launchctl", error: "")
            }
            var lines = ["\tdisabled services = {"]
            for (label, disabled) in disabledMap {
                lines.append("\t\t\"\(label)\" => \(disabled ? "disabled" : "enabled")")
            }
            lines.append("\t}")
            return SoftwareCommandResult(status: 0, output: lines.joined(separator: "\n"), error: "")

        case "print":
            // args: ["print", "gui/<uid>/<label>"]
            if queryFailure {
                return SoftwareCommandResult(status: 1, output: "", error: "Failed to query print")
            }
            let target = args.count > 1 ? args[1] : ""
            let label = target.split(separator: "/").last.map(String.init) ?? target
            if loadedSet.contains(label) {
                return SoftwareCommandResult(status: 0, output: "service properties dummy", error: "")
            } else {
                return SoftwareCommandResult(status: 113, output: "", error: "Could not find service \"\(label)\"")
            }

        case "list":
            if malformedList {
                return SoftwareCommandResult(status: 0, output: "GARBAGE NOT THREE COLUMNS", error: "")
            }
            var lines = ["PID\tStatus\tLabel"]
            for label in loadedSet {
                if let pid = runningPids[label] {
                    lines.append("\(pid)\t0\t\(label)")
                } else {
                    lines.append("-\t0\t\(label)")
                }
            }
            return SoftwareCommandResult(status: 0, output: lines.joined(separator: "\n"), error: "")

        case "disable":
            let target = args.count > 1 ? args[1] : ""
            let label = target.split(separator: "/").last.map(String.init) ?? target
            if !disableCommandSucceedsButStateStuck {
                disabledMap[label] = true
            }
            return SoftwareCommandResult(status: 0, output: "", error: "")

        case "bootout":
            let target = args.count > 1 ? args[1] : ""
            let label = target.split(separator: "/").last.map(String.init) ?? target
            loadedSet.remove(label)
            runningPids.removeValue(forKey: label)
            return SoftwareCommandResult(status: 0, output: "", error: "")

        case "enable":
            let target = args.count > 1 ? args[1] : ""
            let label = target.split(separator: "/").last.map(String.init) ?? target
            disabledMap[label] = false
            return SoftwareCommandResult(status: 0, output: "", error: "")

        case "bootstrap":
            if bootstrapFails {
                return SoftwareCommandResult(status: 1, output: "", error: "Bootstrap failed: service corrupted")
            }
            // args: ["bootstrap", "gui/<uid>", plistPath]
            let path = args.count > 2 ? args[2] : ""
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url),
               let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
               let label = plist["Label"] as? String {
                loadedSet.insert(label)
                disabledMap[label] = false
            }
            return SoftwareCommandResult(status: 0, output: "", error: "")

        case "-e":
            let script = args.count > 1 ? args[1] : ""
            if script.contains("make new login item") {
                return SoftwareCommandResult(status: 0, output: "login item MockApp", error: "")
            }
            if script.contains("delete") {
                return SoftwareCommandResult(status: 0, output: "", error: "")
            }
            if script.contains("every login item") {
                return SoftwareCommandResult(status: 0, output: "MockApp\t/Applications/MockApp.app\tfalse\n", error: "")
            }
            return SoftwareCommandResult(status: 0, output: "", error: "")

        default:
            return SoftwareCommandResult(status: 1, output: "", error: "Unknown command \(subcmd)")
        }
    }
}

func createPlist(at url: URL, label: String, programArgs: [String]? = ["/bin/echo"], extra: [String: Any] = [:]) throws {
    var dict: [String: Any] = [
        "Label": label
    ]
    if let programArgs {
        dict["ProgramArguments"] = programArgs
    }
    for (k, v) in extra {
        dict[k] = v
    }
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try data.write(to: url)
}

@main struct StartupItemsChecks {
    static func main() async throws {
        print("--- Running StartupItemsChecks ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-StartupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let home = tempDir.appendingPathComponent("UserHome")
        let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let sysAgentsDir = tempDir.appendingPathComponent("Library/LaunchAgents")
        let sysDaemonsDir = tempDir.appendingPathComponent("Library/LaunchDaemons")
        try FileManager.default.createDirectory(at: sysAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sysDaemonsDir, withIntermediateDirectories: true)

        let systemRoots: [(URL, StartupKind)] = [
            (sysAgentsDir, .systemAgent),
            (sysDaemonsDir, .systemDaemon)
        ]

        // ==========================================
        // 1. 启停状态正常流程 (Start/Stop lifecycle)
        // ==========================================
        print("Checking 1: Normal Enable/Disable Lifecycle...")
        let samplePlistURL = agentsDir.appendingPathComponent("com.sample.agent.plist")
        try createPlist(at: samplePlistURL, label: "com.sample.agent", programArgs: ["/bin/echo", "hello"])

        let mockRunner = MockRunner()
        mockRunner.disabledMap["com.sample.agent"] = false
        mockRunner.loadedSet.insert("com.sample.agent")
        mockRunner.runningPids["com.sample.agent"] = 4321

        let manager = StartupItems(home: home, systemRoots: systemRoots, runner: { exec, args in
            try mockRunner.run(executable: exec, args: args)
        })

        let scan1 = try manager.scan(token: CancellationToken())
        require(!scan1.items.isEmpty, "Scan must find user agent")
        let item1 = scan1.items.first { $0.label == "com.sample.agent" }
        require(item1 != nil, "com.sample.agent must be found")
        guard let item1 else { fatalError() }
        require(item1.kind == .userAgent, "Kind must be userAgent")
        require(item1.enabled == true, "Must be initially enabled")
        require(item1.loaded == true, "Must be initially loaded")
        require(item1.running == true, "Must be initially running")
        require(item1.blockedReason == nil, "Must not be blocked")
        require(item1.program?.path == "/bin/echo", "Program must resolve to /bin/echo")

        let originalPlist = try Data(contentsOf: samplePlistURL)
        // Disable
        let disabledItem = try manager.setEnabled(item1, enabled: false)
        require(disabledItem.enabled == false, "Must report disabled after disable")
        require(disabledItem.loaded == false, "Must report unloaded after disable")
        require(disabledItem.running == false, "Must report not running after disable")
        require(mockRunner.disabledMap["com.sample.agent"] == true, "Mock runner state must be disabled")
        require(!mockRunner.loadedSet.contains("com.sample.agent"), "Mock runner state must be unloaded")

        // Re-enable
        let enabledItem = try manager.setEnabled(disabledItem, enabled: true)
        require(enabledItem.enabled == true, "Must report enabled after enable")
        require(enabledItem.loaded == true, "Must report loaded after bootstrap")
        require(mockRunner.disabledMap["com.sample.agent"] == false, "Mock runner state must be enabled")
        require(mockRunner.loadedSet.contains("com.sample.agent"), "Mock runner state must be loaded")
        try require(Data(contentsOf: samplePlistURL) == originalPlist, "startup changes must preserve the original plist")
        print("  -> Passed 1: Normal Enable/Disable Lifecycle")

        // ==========================================
        // 2. 失败复读与回滚 (Failure reread and rollback)
        // ==========================================
        print("Checking 2: Failure Reread and Rollback...")
        // 2a: Command exits 0, but reread shows state stuck
        mockRunner.disableCommandSucceedsButStateStuck = true
        do {
            _ = try manager.setEnabled(enabledItem, enabled: false)
            fatalError("Must fail when reread state indicates disable did not take effect")
        } catch {
            // expected failure because reread detected discrepancy
        }
        mockRunner.disableCommandSucceedsButStateStuck = false

        // 2b: Bootstrap fails during enable -> must rollback to disabled
        let currentlyDisabled = try manager.setEnabled(enabledItem, enabled: false)
        mockRunner.bootstrapFails = true
        do {
            _ = try manager.setEnabled(currentlyDisabled, enabled: true)
            fatalError("Must fail when bootstrap fails")
        } catch {
            // expected failure; check rollback: must have restored disable permit
            require(mockRunner.disabledMap["com.sample.agent"] == true, "Must rollback to disabled when bootstrap fails")
        }
        mockRunner.bootstrapFails = false
        print("  -> Passed 2: Failure Reread and Rollback")

        // ==========================================
        // 3. 文件替换防护 (File replacement / TOCTOU)
        // ==========================================
        print("Checking 3: File Replacement / TOCTOU Protection...")
        let freshScan = try manager.scan(token: CancellationToken())
        guard let validItem = freshScan.items.first(where: { $0.label == "com.sample.agent" }) else { fatalError() }

        // Replace the file content with different label
        try FileManager.default.removeItem(at: samplePlistURL)
        try createPlist(at: samplePlistURL, label: "com.malicious.hijack", programArgs: ["/bin/sh"])
        do {
            _ = try manager.setEnabled(validItem, enabled: true)
            fatalError("Must reject when plist file was replaced/modified")
        } catch {
            // expected
        }
        // Restore correct plist for subsequent checks
        try? FileManager.default.removeItem(at: samplePlistURL)
        try createPlist(at: samplePlistURL, label: "com.sample.agent", programArgs: ["/bin/echo"])
        print("  -> Passed 3: File Replacement Protection")

        // ==========================================
        // 4. 符号链接与祖先路径替换防护 (Symlink Protection)
        // ==========================================
        print("Checking 4: Symlink Protection...")
        let symlinkPlistURL = agentsDir.appendingPathComponent("com.symlink.agent.plist")
        try FileManager.default.createSymbolicLink(at: symlinkPlistURL, withDestinationURL: samplePlistURL)
        let symScan = try manager.scan(token: CancellationToken())
        if let symItem = symScan.items.first(where: { $0.url.lastPathComponent == "com.symlink.agent.plist" }) {
            require(symItem.blockedReason != nil, "Symlink item must have blockedReason")
            do {
                _ = try manager.setEnabled(symItem, enabled: false)
                fatalError("Must reject symlink plist in setEnabled")
            } catch {}
        }
        try? FileManager.default.removeItem(at: symlinkPlistURL)
        print("  -> Passed 4: Symlink Protection")

        // ==========================================
        // 5. 重复 Label 冲突保护 (Duplicate Label Conflict)
        // ==========================================
        print("Checking 5: Duplicate Label Conflict Protection...")
        let dup1 = agentsDir.appendingPathComponent("com.duplicate.1.plist")
        let dup2 = agentsDir.appendingPathComponent("com.duplicate.2.plist")
        try createPlist(at: dup1, label: "com.duplicate.shared")
        try createPlist(at: dup2, label: "com.duplicate.shared")
        defer {
            try? FileManager.default.removeItem(at: dup1)
            try? FileManager.default.removeItem(at: dup2)
        }
        let dupScan = try manager.scan(token: CancellationToken())
        let dupItems = dupScan.items.filter { $0.label == "com.duplicate.shared" }
        require(dupItems.count >= 2, "Both duplicate label items should be listed")
        for d in dupItems {
            require(d.blockedReason != nil, "Conflicting label items must have blockedReason")
            do {
                _ = try manager.setEnabled(d, enabled: false)
                fatalError("Must refuse to toggle conflicting label item")
            } catch {}
        }
        print("  -> Passed 5: Duplicate Label Conflict Protection")

        // ==========================================
        // 6. 未知状态防护 (Unknown State Protection)
        // ==========================================
        print("Checking 6: Unknown State Protection...")
        mockRunner.malformedPrintDisabled = true
        let unknownScan = try manager.scan(token: CancellationToken())
        let unknownItem = unknownScan.items.first { $0.label == "com.sample.agent" }
        require(unknownItem?.enabled == nil, "Malformed print-disabled must cause enabled == nil")
        require(unknownScan.incomplete == true, "Malformed query must set incomplete = true")
        if let unknownItem {
            do {
                _ = try manager.setEnabled(unknownItem, enabled: false)
                fatalError("Must refuse to change when current state is unknown/query fails")
            } catch {}
        }
        mockRunner.malformedPrintDisabled = false

        mockRunner.malformedList = true
        let listMalformedScan = try manager.scan(token: CancellationToken())
        let listMalformedItem = listMalformedScan.items.first { $0.label == "com.sample.agent" }
        require(listMalformedItem?.running == nil, "Malformed list must set running == nil")
        mockRunner.malformedList = false
        print("  -> Passed 6: Unknown State Protection")

        // ==========================================
        // 7. 系统保护 (System Protection)
        // ==========================================
        print("Checking 7: System Protection...")
        // 7a: System Agent
        let sysAgentPlist = sysAgentsDir.appendingPathComponent("com.system.agent.plist")
        try createPlist(at: sysAgentPlist, label: "com.system.agent")
        // 7b: System Daemon
        let sysDaemonPlist = sysDaemonsDir.appendingPathComponent("com.system.daemon.plist")
        try createPlist(at: sysDaemonPlist, label: "com.system.daemon")
        // 7c: Apple Agent
        let appleAgentPlist = agentsDir.appendingPathComponent("com.apple.custom.plist")
        try createPlist(at: appleAgentPlist, label: "com.apple.custom")
        // 7d: MacEven Agent
        let macevenAgentPlist = agentsDir.appendingPathComponent("com.maceven.helper.plist")
        try createPlist(at: macevenAgentPlist, label: "com.maceven.helper")
        // 7e: Plist without program
        let noProgPlist = agentsDir.appendingPathComponent("com.noprogram.plist")
        try createPlist(at: noProgPlist, label: "com.noprogram", programArgs: nil)

        defer {
            try? FileManager.default.removeItem(at: sysAgentPlist)
            try? FileManager.default.removeItem(at: sysDaemonPlist)
            try? FileManager.default.removeItem(at: appleAgentPlist)
            try? FileManager.default.removeItem(at: macevenAgentPlist)
            try? FileManager.default.removeItem(at: noProgPlist)
        }

        let sysScan = try manager.scan(token: CancellationToken())
        let sysAgentItem = sysScan.items.first { $0.label == "com.system.agent" }
        require(sysAgentItem?.kind == .systemAgent, "Must be systemAgent")
        require(sysAgentItem?.blockedReason != nil, "System agent must be blocked")
        if let sysAgentItem {
            do { _ = try manager.setEnabled(sysAgentItem, enabled: false); fatalError("Must not modify system agent") } catch {}
        }

        let sysDaemonItem = sysScan.items.first { $0.label == "com.system.daemon" }
        require(sysDaemonItem?.kind == .systemDaemon, "Must be systemDaemon")
        require(sysDaemonItem?.blockedReason != nil, "System daemon must be blocked")
        if let sysDaemonItem {
            do { _ = try manager.setEnabled(sysDaemonItem, enabled: false); fatalError("Must not modify system daemon") } catch {}
        }

        let appleItem = sysScan.items.first { $0.label == "com.apple.custom" }
        require(appleItem?.blockedReason != nil, "Apple item must be blocked")
        if let appleItem {
            do { _ = try manager.setEnabled(appleItem, enabled: false); fatalError("Must not modify Apple item") } catch {}
        }

        let macevenItem = sysScan.items.first { $0.label == "com.maceven.helper" }
        require(macevenItem?.blockedReason != nil, "MacEven item must be blocked")
        if let macevenItem {
            do { _ = try manager.setEnabled(macevenItem, enabled: false); fatalError("Must not modify MacEven item") } catch {}
        }

        let noProgItem = sysScan.items.first { $0.label == "com.noprogram" }
        require(noProgItem?.blockedReason != nil, "No program item must be blocked")
        if let noProgItem {
            do { _ = try manager.setEnabled(noProgItem, enabled: false); fatalError("Must not modify no-program item") } catch {}
        }
        print("  -> Passed 7: System Protection")

        // ==========================================
        // 8. 边界限制与取消标记 (Bounds & Cancellation)
        // ==========================================
        print("Checking 8: Bounds & Cancellation...")
        // 8a: Oversized plist (> 1 MiB)
        let bigPlist = agentsDir.appendingPathComponent("com.big.agent.plist")
        let bigPadding = String(repeating: "A", count: 1024 * 1024 + 100)
        try createPlist(at: bigPlist, label: "com.big.agent", extra: ["Padding": bigPadding])
        defer { try? FileManager.default.removeItem(at: bigPlist) }

        let bigScan = try manager.scan(token: CancellationToken())
        require(bigScan.incomplete == true, "Scan must report incomplete for > 1 MiB plist")
        require(!bigScan.items.contains { $0.label == "com.big.agent" }, "Oversized plist must not be imported")

        // 8b: Cancellation token
        let cancelledToken = CancellationToken()
        cancelledToken.cancel()
        let cancelScan = try manager.scan(token: cancelledToken)
        require(cancelScan.incomplete == true || cancelScan.items.isEmpty, "Cancelled scan must halt")
        print("  -> Passed 8: Bounds & Cancellation")

        // ==========================================
        // 9. 应用与图标名称识别及登录项管理 (App Resolution & Login Items)
        // ==========================================
        print("Checking 9: App Resolution & Login Items...")
        let loginScan = try manager.scan(token: CancellationToken())
        let mockLogin = loginScan.items.first { $0.kind == .loginItem }
        require(mockLogin != nil, "Must include login items from osascript")
        require(mockLogin?.appName == "MockApp", "Login item appName must match")
        require(mockLogin?.displayName == "MockApp", "displayName must fall back to appName")
        require(mockLogin?.enabled == true, "Login item must be enabled")

        if let mockLogin {
            try manager.removeLoginItem(mockLogin)
        }
        let nonLoginItem = StartupItem(id: "test", url: URL(fileURLWithPath: "/tmp/test.plist"), label: "test", kind: .userAgent)
        do {
            try manager.removeLoginItem(nonLoginItem)
            fatalError("Must reject non-loginItem in removeLoginItem")
        } catch {}

        // Test addLoginItem
        let mockAppURL = tempDir.appendingPathComponent("MockApp.app")
        try FileManager.default.createDirectory(at: mockAppURL, withIntermediateDirectories: true)
        try manager.addLoginItem(at: mockAppURL)
        require(mockRunner.recordedCalls.contains { $0.contains { $0.contains("make new login item") } }, "addLoginItem must invoke osascript make new login item")

        let nonExistentURL = tempDir.appendingPathComponent("DoesNotExist.app")
        do {
            try manager.addLoginItem(at: nonExistentURL)
            fatalError("addLoginItem must reject non-existent file")
        } catch {}
        print("  -> Passed 9: App Resolution & Login Items")

        // ==========================================
        // 10. 只读扫描即时取消与操作隔离 (Cancellation & Mutation Immunity)
        // ==========================================
        print("Checking 10: Read-only Token Cancellation & Mutation Immunity...")
        final class TokenTrackingRunner: @unchecked Sendable {
            let lock = NSLock()
            var passedTokens: [Bool] = []
            func run(executable: URL, args: [String], token: CancellationToken?) throws -> SoftwareCommandResult {
                lock.lock()
                passedTokens.append(token != nil)
                let cancelled = token?.isCancelled == true
                lock.unlock()
                if cancelled {
                    throw MacEvenError("检查已取消。")
                }
                if args.first == "-e" {
                    return SoftwareCommandResult(status: 0, output: "MockApp\t/Applications/MockApp.app\tfalse\n", error: "")
                }
                return SoftwareCommandResult(status: 0, output: "", error: "")
            }
        }
        let tracker = TokenTrackingRunner()
        let trackingManager = StartupItems(home: home, systemRoots: systemRoots, cancellableRunner: tracker.run)
        let activeToken = CancellationToken()
        let preScan = try trackingManager.scan(token: activeToken, includeServices: false)
        require(!preScan.items.isEmpty, "Scan with active token must succeed")
        require(tracker.passedTokens.contains(true), "Scan must pass cancellation token to runner")

        // 即时取消
        let cancelToken = CancellationToken()
        cancelToken.cancel()
        let stoppedScan = try trackingManager.scan(token: cancelToken, includeServices: false)
        require(stoppedScan.incomplete, "Cancelled scan must report incomplete")

        // 增删操作不传取消令牌，不中断
        tracker.passedTokens.removeAll()
        let mockItem = StartupItem(id: "loginItem:MockApp:/Applications/MockApp.app", url: mockAppURL, label: "MockApp", kind: .loginItem)
        try trackingManager.removeLoginItem(mockItem)
        require(tracker.passedTokens.last == false, "removeLoginItem must pass nil token to protect mutation")
        try trackingManager.addLoginItem(at: mockAppURL)
        require(tracker.passedTokens.last == false, "addLoginItem must pass nil token to protect mutation")
        print("  -> Passed 10: Read-only Token Cancellation & Mutation Immunity")

        print("All StartupItemsChecks passed successfully!")
    }
}
