import Foundation
import Combine
import MacEvenCore

@main struct MonitorModelChecks {
    @MainActor static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            precondition(Date() < deadline, "monitor did not settle")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func main() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MacEven-monitor-model-\(UUID())")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let model = MonitorModel(historyURL: temp.appendingPathComponent("history.sqlite"))
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<3000 {
            model.accept(SystemSnapshot(timestamp: epoch.addingTimeInterval(Double(i * 2)), uptime: Double(i * 2), cpuPercent: 20))
        }
        precondition(model.recent.count == 300, "real-time buffer grows with lifetime")
        precondition(model.recent.first?.uptime == 5400)
        model.accept(SystemSnapshot(timestamp: epoch.addingTimeInterval(10000), uptime: 10000))
        precondition(model.recent.count == 1, "old points survived long gap")
        var times: [TimeInterval] = []
        let observation = model.$snapshot.compactMap { $0 }.sink {
            if $0.timestamp > epoch.addingTimeInterval(20000) { times.append($0.uptime) }
        }
        for i in 0..<3000 { model.accept(SystemSnapshot(timestamp: epoch.addingTimeInterval(20000 + Double(i)), uptime: Double(i))) }
        precondition(model.recent.count == 600, "one-second buffer exceeded bound")
        times.removeAll()
        model.start(); model.start()
        try await waitUntil { model.snapshot?.cpuPercent != nil && model.hardware != nil }
        try await Task.sleep(for: .seconds(3))
        precondition(times.count >= 2 && times.count <= 4, "duplicate sampling lifecycle")
        model.setProcessPageVisible(true)
        try await waitUntil { model.processList != nil }
        precondition(model.processList!.entries.count <= 200)
        if let entry = model.processList!.entries.first { model.selectProcess(entry.id) }
        model.selectProcess(ProcessIdentity(pid: .max, startTime: 1))
        try await waitUntil { model.processError != nil }
        precondition(model.processDetail == nil, "old process detail overwrote new selection")
        model.setProcessPageVisible(false)
        try await Task.sleep(for: .seconds(6))
        precondition(model.processList == nil && model.processDetail == nil, "hidden page kept publishing processes")
        model.setProcessPageVisible(true)
        try await waitUntil { model.processList != nil }
        precondition(model.processList!.entries.allSatisfy { $0.cpuPercent == nil }, "reopened page reused stale CPU baseline")
        model.setProcessPageVisible(false)
        model.setPopoverVisible(true)
        try await waitUntil { model.processList != nil }
        let menuUpdate = model.processList!.updatedAt
        try await waitUntil { model.processList?.updatedAt != menuUpdate }
        model.setProcessPageVisible(true)
        model.setProcessPageVisible(false)
        precondition(model.processList != nil, "closing main page stopped visible menu processes")
        model.setPopoverVisible(false)
        precondition(model.processList == nil, "hidden menu kept process data")
        model.prepareForSleep()
        try await Task.sleep(for: .milliseconds(200))
        let sleepTime = model.snapshot?.uptime
        try await Task.sleep(for: .seconds(3))
        precondition(model.snapshot?.uptime == sleepTime && model.hardware == nil, "sleep kept publishing samples")
        let beforeWake = model.snapshot?.uptime
        model.resetAfterWake()
        try await waitUntil { model.snapshot?.uptime != beforeWake && model.snapshot?.cpuPercent == nil }
        precondition(model.snapshot?.networkRate == nil, "wake retained network baseline")
        try await waitUntil { model.snapshot?.cpuPercent != nil }
        let block = DispatchSemaphore(value: 0)
        model.historyWorker.queue.async { block.wait() }
        let latestMinute = Int64(Date().timeIntervalSince1970 / 60) * 60
        for i in 0..<10000 {
            model.historyWorker.offer(MinuteAggregate(minuteUTC: latestMinute - Int64((10000 - i) * 60),
                cpu: AggregateValue(value: 20, seconds: 2)), generation: 0)
        }
        let timeWhileBlocked = model.snapshot?.uptime
        try await waitUntil { model.snapshot?.uptime != timeWhileBlocked }
        model.loadHistory(hours: 168)
        block.signal()
        try await waitUntil { !model.historyLoading }
        precondition(!model.history.isEmpty && model.history.count <= 3, "slow storage accumulated unbounded pending minutes")
        precondition(model.history.contains { $0.hasGap } && model.historyError != nil, "dropped history was hidden")
        let clearBlock = DispatchSemaphore(value: 0)
        model.historyWorker.queue.async { clearBlock.wait() }
        model.loadHistory(hours: 168)
        model.clearHistory()
        model.loadHistory(hours: 168)
        clearBlock.signal()
        try await waitUntil { !model.historyLoading }
        precondition(model.history.isEmpty && model.historyError == nil, "old query restored cleared history")
        for _ in 0..<2 {
            let oldTime = model.snapshot?.uptime
            try await waitUntil { model.snapshot?.uptime != oldTime }
        }
        let error: String? = await withCheckedContinuation { continuation in
            model.shutdown { continuation.resume(returning: $0) }
        }
        precondition(error == nil)
        let stoppedTime = model.snapshot?.uptime
        let stoppedHardwareTime = model.hardware?.sampledAt
        model.start(); model.resetAfterWake(); model.refreshDisk()
        model.accept(SystemSnapshot(timestamp: Date(), uptime: 999999999, cpuPercent: 90))
        try await Task.sleep(for: .seconds(3))
        precondition(model.hardware?.sampledAt == stoppedHardwareTime, "hardware published after shutdown")
        precondition(model.snapshot?.uptime == stoppedTime, "closed model accepted late publication")
        let repeatedError: String? = await withCheckedContinuation { continuation in
            model.shutdown { continuation.resume(returning: $0) }
        }
        precondition(repeatedError == nil)
        let recorded = try MonitorHistory(url: temp.appendingPathComponent("history.sqlite"))
        let saved = try recorded.query(from: Date().addingTimeInterval(-3600), to: Date())
        precondition(!saved.isEmpty, "shutdown lost current minute")
        recorded.close()
        observation.cancel()
        let early = MonitorModel(historyURL: temp.appendingPathComponent("early.sqlite"))
        early.start()
        await withCheckedContinuation { continuation in early.shutdown { _ in continuation.resume() } }
        try await Task.sleep(for: .milliseconds(200))
        precondition(early.snapshot == nil, "startup result published after shutdown")
        let corruptURL = temp.appendingPathComponent("corrupt.sqlite")
        try Data(repeating: 0xFF, count: 4096).write(to: corruptURL)
        let recovering = MonitorModel(historyURL: corruptURL)
        recovering.start()
        try await waitUntil { recovering.historyError != nil && recovering.snapshot?.cpuPercent != nil }
        recovering.loadHistory(hours: 168)
        try await waitUntil { !recovering.historyLoading }
        precondition(recovering.history.isEmpty, "corrupt history returned values")
        recovering.clearHistory()
        try await waitUntil { !recovering.historyLoading && recovering.historyError == nil }
        let recoveredError: String? = await withCheckedContinuation { continuation in
            recovering.shutdown { continuation.resume(returning: $0) }
        }
        precondition(recoveredError == nil, "clear did not repair corrupt database")
        print("PASS: bounded recent buffer, time pruning, single sampler, repeated shutdown, late publication")
    }
}
