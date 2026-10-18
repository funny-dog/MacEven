import Foundation
import Darwin
import AppKit
import SystemConfiguration

@main struct ProcessStatusChecks {
    static func main() {
        if CommandLine.arguments.contains("--gui-child") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared; app.setActivationPolicy(.regular)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "MacEven 专属退出测试"; window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
                withExtendedLifetime(window) { app.run() }
            }
            return
        }
        print("=== 阶段 1：ProcessOrder 与排序方向验证 ===")
        checkProcessOrderAndDirection()

        print("=== 阶段 2：有界显示上限 200 与候选 8192 上限验证 ===")
        checkBoundsAndLimit()

        print("=== 阶段 3：ProcessEntry 稳定身份辅助字段与能耗验证 ===")
        checkProcessEntryAndEnergy()

        print("=== 阶段 4：应用聚合与稳定置顶 Helper 验证 ===")
        checkGroupingAndPinning()

        print("=== 阶段 5：安全进程控制与子进程真实交互验证 ===")
        checkUnreapedChild()
        checkSafeProcessControl()

        print("ALL PASS: ProcessStatusChecks completed successfully!")
    }

    static func checkUnreapedChild() {
        var pid: pid_t = 0
        var arguments = [strdup("/bin/sleep"), strdup("0.2"), nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        precondition(arguments.withUnsafeMutableBufferPointer { posix_spawn(&pid, "/bin/sleep", nil, nil, $0.baseAddress!, nil) } == 0)
        defer { var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
        var usage = rusage_info_v2()
        precondition(withUnsafeMutablePointer(to: &usage) { proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) } == 0)
        let identity = ProcessIdentity(pid: pid, startTime: usage.ri_proc_start_abstime)
        for _ in 0..<100 {
            _ = withUnsafeMutablePointer(to: &usage) { proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }
            if usage.ri_proc_exit_abstime != 0 { break }
            usleep(10_000)
        }
        precondition(usage.ri_proc_exit_abstime != 0 && kill(pid, 0) == 0, "专属子进程应退出但暂未回收")
        let monitor = SystemMonitor()
        precondition(!monitor.isProcessAlive(identity), "僵尸进程不应显示仍在运行")
        precondition(monitor.terminateProcess(identity).outcome == .processAlreadyExited)
        print("PASS: 退出但未回收的专属子进程")
    }

    static func checkProcessOrderAndDirection() {
        // 兼容旧的 .cpu, .memory 比较与语义
        assert(ProcessOrder.cpu == .cpu)
        assert(ProcessOrder.memory == .memory)
        assert(ProcessOrder.cpu.metric == .cpu)
        assert(ProcessOrder.memory.metric == .memory)
        assert(ProcessOrder.cpu.direction == .descending)
        assert(ProcessOrder.memory.direction == .descending)

        // 扩充的指标：name, pid, energy
        assert(ProcessOrder.name.metric == .name)
        assert(ProcessOrder.pid.metric == .pid)
        assert(ProcessOrder.energy.metric == .energy)
        assert(ProcessOrder.name.direction == .ascending)
        assert(ProcessOrder.pid.direction == .ascending)
        assert(ProcessOrder.energy.direction == .descending)

        // 支持方向构造与反转
        assert(ProcessOrder.cpu(.ascending).direction == .ascending)
        assert(ProcessOrder.cpu(.descending) == .cpu)
        assert(ProcessOrder.cpu.reversed() == .cpu(.ascending))
        assert(ProcessOrder.name.reversed() == .name(.descending))

        // 排序效果测试
        var tracker = ProcessTracker()
        let c1 = ProcessCandidate(
            identity: ProcessIdentity(pid: 10, startTime: 1),
            name: "Bravo",
            cpuNanoseconds: 1_000_000_000,
            memoryBytes: 200,
            uptime: 10
        )
        let c2 = ProcessCandidate(
            identity: ProcessIdentity(pid: 20, startTime: 1),
            name: "Alpha",
            cpuNanoseconds: 3_000_000_000,
            memoryBytes: 100,
            uptime: 10
        )
        _ = tracker.update([c1, c2], uptime: 10, order: .name)

        let updateC1 = ProcessCandidate(
            identity: ProcessIdentity(pid: 10, startTime: 1),
            name: "Bravo",
            cpuNanoseconds: 2_000_000_000,
            memoryBytes: 200,
            uptime: 11
        )
        let updateC2 = ProcessCandidate(
            identity: ProcessIdentity(pid: 20, startTime: 1),
            name: "Alpha",
            cpuNanoseconds: 5_000_000_000,
            memoryBytes: 100,
            uptime: 11
        )

        // 按名称升序：Alpha (pid 20) -> Bravo (pid 10)
        let byNameAsc = tracker.update([updateC1, updateC2], uptime: 11, order: .name(.ascending))
        assert(byNameAsc.entries.map(\.name) == ["Alpha", "Bravo"])

        // 按名称降序：Bravo -> Alpha
        let byNameDesc = tracker.update([updateC1, updateC2], uptime: 11, order: .name(.descending))
        assert(byNameDesc.entries.map(\.name) == ["Bravo", "Alpha"])

        // 按 PID 升序：10 -> 20
        let byPidAsc = tracker.update([updateC1, updateC2], uptime: 11, order: .pid(.ascending))
        assert(byPidAsc.entries.map(\.id.pid) == [10, 20])

        // 按 PID 降序：20 -> 10
        let byPidDesc = tracker.update([updateC1, updateC2], uptime: 11, order: .pid(.descending))
        assert(byPidDesc.entries.map(\.id.pid) == [20, 10])

        // 按 CPU 降序：pid 20 (delta 2s -> 200%) > pid 10 (delta 1s -> 100%)
        _ = tracker.update([c1, c2], uptime: 10, order: .cpu)
        let byCpuDesc = tracker.update([updateC1, updateC2], uptime: 11, order: .cpu)
        assert(byCpuDesc.entries.map(\.id.pid) == [20, 10])

        // 按 CPU 升序：pid 10 < pid 20
        _ = tracker.update([c1, c2], uptime: 10, order: .cpu)
        let byCpuAsc = tracker.update([updateC1, updateC2], uptime: 11, order: .cpu(.ascending))
        assert(byCpuAsc.entries.map(\.id.pid) == [10, 20])

        // 按内存降序：pid 10 (200 bytes) > pid 20 (100 bytes)
        let byMemDesc = tracker.update([updateC1, updateC2], uptime: 11, order: .memory)
        assert(byMemDesc.entries.map(\.id.pid) == [10, 20])

        // 按内存升序：pid 20 (100 bytes) < pid 10 (200 bytes)
        let byMemAsc = tracker.update([updateC1, updateC2], uptime: 11, order: .memory(.ascending))
        assert(byMemAsc.entries.map(\.id.pid) == [20, 10])
    }

    static func checkBoundsAndLimit() {
        var tracker = ProcessTracker()
        let largeCandidates = (1...9000).map {
            ProcessCandidate(
                identity: ProcessIdentity(pid: Int32($0), startTime: 1),
                name: "proc-\($0)",
                cpuNanoseconds: 0,
                memoryBytes: UInt64($0)
            )
        }

        // 默认 limit 应当为 20，向后兼容
        let defaultList = tracker.update(largeCandidates, uptime: 10, order: .memory)
        assert(defaultList.entries.count == 20)
        assert(defaultList.incomplete == true)
        assert(tracker.previous.count == 8192)

        // limit 为 50 时，返回 50 条
        let list50 = tracker.update(largeCandidates, uptime: 10, order: .memory, limit: 50)
        assert(list50.entries.count == 50)

        // limit 为 200 时，返回 200 条
        let list200 = tracker.update(largeCandidates, uptime: 10, order: .memory, limit: 200)
        assert(list200.entries.count == 200)

        // limit 传入 500 时，上限被限制在 200
        let listCapped = tracker.update(largeCandidates, uptime: 10, order: .memory, limit: 500)
        assert(listCapped.entries.count == 200)
    }

    static func checkProcessEntryAndEnergy() {
        let entry = ProcessEntry(
            id: ProcessIdentity(pid: 1234, startTime: 100),
            name: "test-proc",
            cpuPercent: 45.0,
            memoryBytes: 1024 * 1024,
            executablePath: "/bin/sleep",
            bundleIdentifier: nil,
            applicationPath: nil,
            energyImpact: nil,
            energyUnavailableReason: "系统未向非特权进程提供独立 Energy Impact 指标，严禁将 CPU 冒充为能耗"
        )

        assert(entry.executablePath == "/bin/sleep")
        assert(entry.energyImpact == nil, "能耗指标不可用时必须为 nil，不能使用 CPU 冒充")
        assert(entry.energyUnavailableReason != nil, "必须提供无法读取的原因解释")

        // 真实读取验证：当前自身进程的 ProcessEntry / details
        let monitor = SystemMonitor()
        let list = monitor.processes(order: .cpu, limit: 20)
        assert(!list.entries.isEmpty)
        // 验证返回的每个条目的 energyImpact 绝不等于 cpuPercent
        for item in list.entries {
            if let cpu = item.cpuPercent, cpu > 0 {
                // 如果没有特权能耗读取，energyImpact 必须为 nil 且不伪造为 cpu
                assert(item.energyImpact == nil || item.energyImpact != cpu, "不能将 CPU 冒充为 Energy Impact")
            }
        }
    }

    static func checkGroupingAndPinning() {
        let e1 = ProcessEntry(
            id: ProcessIdentity(pid: 100, startTime: 1),
            name: "Finder",
            cpuPercent: 5.0,
            memoryBytes: 2000,
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            bundleIdentifier: "com.apple.finder",
            applicationPath: "/System/Library/CoreServices/Finder.app"
        )
        let e2 = ProcessEntry(
            id: ProcessIdentity(pid: 101, startTime: 1),
            name: "Finder QuickLook",
            cpuPercent: 10.0,
            memoryBytes: 1000,
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            bundleIdentifier: "com.apple.finder",
            applicationPath: "/System/Library/CoreServices/Finder.app"
        )
        let e3 = ProcessEntry(
            id: ProcessIdentity(pid: 200, startTime: 1),
            name: "MacEven",
            cpuPercent: 2.0,
            memoryBytes: 500,
            executablePath: "/Applications/MacEven.app/Contents/MacOS/MacEven",
            bundleIdentifier: "local.maceven.app",
            applicationPath: "/Applications/MacEven.app"
        )
        let e4 = ProcessEntry(
            id: ProcessIdentity(pid: 300, startTime: 1),
            name: "sleep",
            cpuPercent: 0.0,
            memoryBytes: 100,
            executablePath: "/bin/sleep",
            bundleIdentifier: nil,
            applicationPath: nil
        )

        let groups = ProcessGrouping.group(entries: [e1, e2, e3, e4], order: .cpu)
        assert(groups.count == 3) // finder(e1+e2), maceven(e3), sleep(e4)

        let finderGroup = groups.first { $0.id == "app:/System/Library/CoreServices/Finder.app" }
        assert(finderGroup != nil)
        assert(finderGroup!.processCount == 2)
        assert(finderGroup!.totalCPUPercent == 15.0)
        assert(finderGroup!.totalMemoryBytes == 3000)

        // 置顶测试：稳定 key 不是 PID
        let pinnedKeys: Set<String> = ["app:/Applications/MacEven.app"]
        let pinnedGroups = ProcessPinning.applyingPinned(entries: groups, pinnedKeys: pinnedKeys) { $0.id }
        assert(pinnedGroups.first?.id == "app:/Applications/MacEven.app", "被置顶的项目必须排在首位")
    }

    static func checkSafeProcessControl() {
        let monitor = SystemMonitor()

        // 1. 自身进程拒绝
        let selfID = ProcessIdentity(pid: getpid(), startTime: 1)
        let selfRes = monitor.terminateProcess(selfID)
        assert(selfRes.outcome == .rejected(.selfTarget), "向自身进程发送终止必须被拒绝")
        assert(selfRes.signalSent == nil)

        // 2. 系统进程 PID 1 拒绝
        let sysID = ProcessIdentity(pid: 1, startTime: 1)
        let sysRes = monitor.terminateProcess(sysID)
        assert(sysRes.outcome == .rejected(.systemProcess), "向系统进程发送终止必须被拒绝")

        // 3. 启动专属测试子进程 /bin/sleep 30
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        do {
            try proc.run()
        } catch {
            fatalError("无法启动测试子进程 /bin/sleep: \(error)")
        }

        let pid = proc.processIdentifier
        assert(pid > 0)
        defer {
            // 确保测试退出时子进程绝对不残留
            if proc.isRunning { proc.terminate(); proc.waitUntilExit() }
        }

        // 读取该进程真实的 startTime
        var info = rusage_info_v2()
        let ret = withUnsafeMutablePointer(to: &info) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        assert(ret == 0)
        let realIdentity = ProcessIdentity(pid: pid, startTime: info.ri_proc_start_abstime)

        // 4. PID/开始时间不符验证（防 PID 复用误杀）
        let fakeIdentity = ProcessIdentity(pid: pid, startTime: info.ri_proc_start_abstime &+ 9999)
        let mismatchRes = monitor.terminateProcess(fakeIdentity)
        assert(mismatchRes.outcome == .rejected(.identityMismatch), "开始时间不符必须被拒绝")

        // 5. 路径核验不符验证
        let pathMismatchRes = monitor.terminateProcess(realIdentity, expectedPath: "/usr/bin/not_sleep")
        if case .rejected(.pathMismatch) = pathMismatchRes.outcome {
            // 正确拦截
        } else {
            assertionFailure("路径不符必须被拒绝: \(pathMismatchRes.outcome)")
        }

        // 6. 强制结束前置约束：未先请求正常退出直接强制结束必须被拒绝
        let directForceRes = monitor.forceKillProcess(realIdentity, now: 100.0)
        if case .rejected(.forceKillRequiresPriorTermination) = directForceRes.outcome {
            // 正确拦截
        } else {
            assertionFailure("未请求正常退出就强制结束必须被拒绝: \(directForceRes.outcome)")
        }

        // 7. 正常退出请求测试（发送 SIGTERM）并报告实际存活状态
        let termRes = monitor.terminateProcess(realIdentity, expectedPath: "/bin/sleep", now: 100.0)
        assert(termRes.signalSent == SIGTERM, "必须发送 SIGTERM")
        assert(termRes.outcome == .signalSent(signal: SIGTERM))
        print("SIGTERM 已发送，即时存活状态: \(termRes.isStillAlive)")

        // 9. 观察子进程真实退出
        let exited = waitForProcessExit(pid: pid, timeoutSeconds: 3.0)
        assert(exited, "子进程收到 SIGTERM 后应当在超时前退出")
        assert(!monitor.isProcessAlive(realIdentity), "进程退出后 isProcessAlive 应当为 false")

        // 10. 进程已退出后再次调用 terminate 验证
        let alreadyExitedRes = monitor.terminateProcess(realIdentity)
        assert(alreadyExitedRes.outcome == .processAlreadyExited, "已退出的进程必须报告 processAlreadyExited")

        // 11. 测试另一个子进程验证满足 5 秒后的 forceKill
        testForceKillCooldownSuccess()
        testGUIExit()
    }

    static func testGUIExit() {
        let monitor = SystemMonitor()
        MainActor.assumeIsolated { _ = NSApplication.shared }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("MacEvenProcessStatusChild.app/Contents/MacOS/MacEvenProcessStatusChecks")
        let child = Process(); child.executableURL = executable
        child.arguments = ["--gui-child"]; try! child.run()
        let pid = child.processIdentifier
        var info = rusage_info_v2()
        for _ in 0..<50 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular, app.isFinishedLaunching { break }
            usleep(50_000)
        }
        _ = withUnsafeMutablePointer(to: &info) { proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }
        let identity = ProcessIdentity(pid: pid, startTime: info.ri_proc_start_abstime)
        defer { if monitor.isProcessAlive(identity) { _ = kill(pid, SIGKILL) }; child.waitUntilExit() }
        let result = monitor.terminateProcess(identity, expectedPath: child.executableURL!.path)
        if result.outcome != .exitRequested {
            fputs("GUI RESULT: \(result.outcome) path=\(child.executableURL!.path) policy=\(String(describing: NSRunningApplication(processIdentifier: pid)?.activationPolicy))\n", stderr)
            if monitor.isProcessAlive(identity) { _ = kill(pid, SIGKILL) }; child.waitUntilExit()
        }
        precondition(result.outcome == .exitRequested, "GUI 应用应收到原生退出请求")
        precondition(waitForProcessExit(pid: pid, timeoutSeconds: 5), "GUI 应用未实际退出")
        print("PASS: 专属 GUI 应用原生正常退出并确认存活状态")
    }

    static func testForceKillCooldownSuccess() {
        let monitor = SystemMonitor()
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        try! proc.run()
        let pid = proc.processIdentifier
        var info = rusage_info_v2()
        for _ in 0..<20 {
            _ = withUnsafeMutablePointer(to: &info) { proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }
            if monitor.details(for: .init(pid: pid, startTime: info.ri_proc_start_abstime))?.path == "/bin/sleep" { break }
            usleep(50_000)
        }
        let identity = ProcessIdentity(pid: pid, startTime: info.ri_proc_start_abstime)
        defer { if monitor.isProcessAlive(identity) { _ = kill(pid, SIGKILL) }; proc.waitUntilExit() }
        assert(monitor.terminateProcess(identity, expectedPath: "/bin/sleep", now: 200).signalSent == SIGTERM)
        if case .rejected(.forceKillRequiresPriorTermination(let remaining)) = monitor.forceKillProcess(identity, expectedPath: "/bin/sleep", now: 202).outcome { assert(remaining == 3) }
        else { assertionFailure("等待不足五秒必须拒绝") }
        if case .rejected(.forceKillRequiresPriorTermination(let remaining)) = monitor.forceKillProcess(identity, expectedPath: "/bin/sleep", now: 600).outcome { precondition(remaining == 5) }
        else { preconditionFailure("过期记录必须重新请求退出") }
        precondition(monitor.terminateProcess(identity, expectedPath: "/bin/sleep", now: 700).signalSent == SIGTERM)
        assert(monitor.forceKillProcess(identity, expectedPath: "/bin/sleep", now: 705.5).signalSent == SIGKILL)
        proc.waitUntilExit(); assert(!monitor.isProcessAlive(identity))
    }

    static func waitForProcessExit(pid: Int32, timeoutSeconds: Double) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < timeoutSeconds {
            if kill(pid, 0) != 0 {
                return true
            }
            usleep(50_000) // 50ms
        }
        return kill(pid, 0) != 0
    }
}
