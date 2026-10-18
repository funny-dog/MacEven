import Foundation

@main struct ProcessBoundsChecks {
    static func main() {
        var tracker = ProcessTracker()
        let candidates = (1...9000).map {
            ProcessCandidate(identity: ProcessIdentity(pid: Int32($0), startTime: 1),
                name: "process-\($0)", cpuNanoseconds: 0, memoryBytes: UInt64($0))
        }
        let first = tracker.update(candidates, uptime: 10, order: .memory)
        precondition(first.incomplete && first.entries.count == 20 && tracker.previous.count == 8192, "process cap not enforced")
        precondition(first.entries.first?.memoryBytes == 8192, "memory order incorrect")
        let second = tracker.update([ProcessCandidate(identity: ProcessIdentity(pid: 1, startTime: 1),
            name: "process-1", cpuNanoseconds: 4_000_000_000, memoryBytes: 1)], uptime: 12, order: .cpu)
        precondition(tracker.previous.count == 1 && second.entries.first?.cpuPercent == 200, "exited processes retained")
        let reused = tracker.update([ProcessCandidate(identity: ProcessIdentity(pid: 1, startTime: 2),
            name: "reused", cpuNanoseconds: 5_000_000_000, memoryBytes: 1)], uptime: 14, order: .cpu)
        precondition(reused.entries.first?.cpuPercent == nil, "tracker ignored PID reuse")
        tracker.reset()
        precondition(tracker.previous.isEmpty)
        _ = tracker.update([
            ProcessCandidate(identity: ProcessIdentity(pid: 1, startTime: 1), name: "a", cpuNanoseconds: 0, memoryBytes: 1, uptime: 10),
            ProcessCandidate(identity: ProcessIdentity(pid: 2, startTime: 1), name: "b", cpuNanoseconds: 0, memoryBytes: 1, uptime: 11)
        ], uptime: 11, order: .cpu)
        let spread = tracker.update([
            ProcessCandidate(identity: ProcessIdentity(pid: 1, startTime: 1), name: "a", cpuNanoseconds: 2_000_000_000, memoryBytes: 1, uptime: 12),
            ProcessCandidate(identity: ProcessIdentity(pid: 2, startTime: 1), name: "b", cpuNanoseconds: 2_000_000_000, memoryBytes: 1, uptime: 15)
        ], uptime: 15, order: .cpu)
        precondition(spread.entries.first { $0.id.pid == 1 }?.cpuPercent == 100)
        precondition(spread.entries.first { $0.id.pid == 2 }?.cpuPercent == 50, "PID sampling times mixed")
        let largeMemory = tracker.update([
            ProcessCandidate(identity: ProcessIdentity(pid: 1, startTime: 1), name: "lower", cpuNanoseconds: nil, memoryBytes: UInt64.max - 1),
            ProcessCandidate(identity: ProcessIdentity(pid: 2, startTime: 1), name: "highest", cpuNanoseconds: nil, memoryBytes: UInt64.max),
            ProcessCandidate(identity: ProcessIdentity(pid: 3, startTime: 1), name: "unknown", cpuNanoseconds: nil, memoryBytes: nil)
        ], uptime: 20, order: .memory)
        precondition(largeMemory.entries.map(\.id.pid) == [2, 1, 3], "memory rank interpreted bytes as floating-point bit patterns or lost integer precision")
        print("PASS: 9000 process inputs, baseline cap, top 20, exited cleanup, PID reuse")
    }
}
