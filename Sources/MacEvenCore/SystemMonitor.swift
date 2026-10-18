import Foundation
import Darwin
import AppKit
import SystemConfiguration

public enum ProcessSortDirection: Sendable, Hashable {
    case ascending
    case descending
}

public enum ProcessSortMetric: String, Sendable, CaseIterable {
    case name
    case pid
    case cpu
    case energy
    case memory
}

public enum ProcessOrder: Sendable, Hashable {
    case name
    case pid
    case cpu
    case energy
    case memory
    case custom(metric: Metric, direction: ProcessSortDirection)

    public typealias Metric = ProcessSortMetric
    public typealias Direction = ProcessSortDirection

    public var metric: Metric {
        switch self {
        case .name: return .name
        case .pid: return .pid
        case .cpu: return .cpu
        case .energy: return .energy
        case .memory: return .memory
        case .custom(let m, _): return m
        }
    }

    public var direction: ProcessSortDirection {
        switch self {
        case .name, .pid: return .ascending
        case .cpu, .energy, .memory: return .descending
        case .custom(_, let d): return d
        }
    }

    public init(metric: Metric, direction: ProcessSortDirection? = nil) {
        let dir = direction ?? (metric == .name || metric == .pid ? .ascending : .descending)
        self = .custom(metric: metric, direction: dir)
    }

    public static func name(_ direction: ProcessSortDirection) -> ProcessOrder {
        .custom(metric: .name, direction: direction)
    }
    public static func pid(_ direction: ProcessSortDirection) -> ProcessOrder {
        .custom(metric: .pid, direction: direction)
    }
    public static func cpu(_ direction: ProcessSortDirection) -> ProcessOrder {
        .custom(metric: .cpu, direction: direction)
    }
    public static func energy(_ direction: ProcessSortDirection) -> ProcessOrder {
        .custom(metric: .energy, direction: direction)
    }
    public static func memory(_ direction: ProcessSortDirection) -> ProcessOrder {
        .custom(metric: .memory, direction: direction)
    }

    public func reversed() -> ProcessOrder {
        let newDir: ProcessSortDirection = (direction == .ascending ? .descending : .ascending)
        return .custom(metric: metric, direction: newDir)
    }

    public static func == (lhs: ProcessOrder, rhs: ProcessOrder) -> Bool {
        return lhs.metric == rhs.metric && lhs.direction == rhs.direction
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(metric)
        hasher.combine(direction)
    }
}

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startTime: UInt64
    public init(pid: Int32, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}

public struct ProcessReading: Sendable {
    public let identity: ProcessIdentity
    public let cpuNanoseconds: UInt64
    public let uptime: TimeInterval
    public init(identity: ProcessIdentity, cpuNanoseconds: UInt64, uptime: TimeInterval) {
        self.identity = identity; self.cpuNanoseconds = cpuNanoseconds; self.uptime = uptime
    }
}

public enum ProcessUsage {
    public static func percent(previous: ProcessReading?, current: ProcessReading, maxSeconds: Double = 15) -> Double? {
        guard let previous, previous.identity == current.identity else { return nil }
        let seconds = current.uptime - previous.uptime
        let (delta, reset) = current.cpuNanoseconds.subtractingReportingOverflow(previous.cpuNanoseconds)
        guard seconds.isFinite, seconds > 0, seconds <= maxSeconds, !reset else { return nil }
        return Double(delta) / 1e9 / seconds * 100
    }
    public static func nanoseconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64? {
        guard numerator > 0, denominator > 0 else { return nil }
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        guard product.high < UInt64(denominator) else { return nil }
        return UInt64(denominator).dividingFullWidth(product).quotient
    }
}

public struct ProcessEntry: Identifiable, Sendable {
    public let id: ProcessIdentity
    public let name: String
    public let cpuPercent: Double?
    /// 过去约 60 秒的 CPU 平均占比；采集不足 60 秒时为 nil。
    public let cpuPercentAvg: Double?
    public let memoryBytes: UInt64?
    public let executablePath: String?
    public let bundleIdentifier: String?
    public let applicationPath: String?
    public let energyImpact: Double?
    public let energyUnavailableReason: String?

    public init(
        id: ProcessIdentity,
        name: String,
        cpuPercent: Double? = nil,
        cpuPercentAvg: Double? = nil,
        memoryBytes: UInt64? = nil,
        executablePath: String? = nil,
        bundleIdentifier: String? = nil,
        applicationPath: String? = nil,
        energyImpact: Double? = nil,
        energyUnavailableReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cpuPercent = cpuPercent
        self.cpuPercentAvg = cpuPercentAvg
        self.memoryBytes = memoryBytes
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.energyImpact = energyImpact
        self.energyUnavailableReason = energyUnavailableReason
    }
}

public struct ProcessList: Sendable {
    public let entries: [ProcessEntry]
    public let incomplete: Bool
    public let updatedAt: Date
    public let groups: [ProcessGroup]
    public init(entries: [ProcessEntry], incomplete: Bool, updatedAt: Date, groups: [ProcessGroup] = []) {
        self.entries = entries
        self.incomplete = incomplete
        self.updatedAt = updatedAt
        self.groups = groups
    }
}

public struct ProcessDetail: Sendable {
    public let entry: ProcessEntry
    public let path: String?
    public let unavailableReason: String?
    public init(entry: ProcessEntry, path: String?, unavailableReason: String?) {
        self.entry = entry
        self.path = path
        self.unavailableReason = unavailableReason
    }
}

public struct ProcessGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let applicationPath: String?
    public let executablePath: String?
    public let entries: [ProcessEntry]
    public let totalCPUPercent: Double?
    /// 组内所有进程过去约 60 秒 CPU 平均占比的合计；任意一个进程不足 60 秒时忽略该进程。
    public let totalCPUPercentAvg: Double?
    public let totalMemoryBytes: UInt64?
    public let processCount: Int

    public init(
        id: String,
        name: String,
        bundleIdentifier: String? = nil,
        applicationPath: String? = nil,
        executablePath: String? = nil,
        entries: [ProcessEntry]
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.executablePath = executablePath
        self.entries = entries
        self.processCount = entries.count
        let cpus = entries.compactMap(\.cpuPercent)
        self.totalCPUPercent = cpus.isEmpty ? nil : cpus.reduce(0, +)
        let cpusAvg = entries.compactMap(\.cpuPercentAvg)
        self.totalCPUPercentAvg = cpusAvg.isEmpty ? nil : cpusAvg.reduce(0, +)
        let mems = entries.compactMap(\.memoryBytes)
        self.totalMemoryBytes = mems.isEmpty ? nil : mems.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value); return overflow ? UInt64.max : sum
        }
    }
}

public enum ProcessGrouping {
    public static func groupKey(for entry: ProcessEntry) -> String {
        if let app = entry.applicationPath, !app.isEmpty { return "app:\(app)" }
        if let bundle = entry.bundleIdentifier, !bundle.isEmpty { return "bundle:\(bundle)" }
        if let exe = entry.executablePath, !exe.isEmpty {
            return "exe:\(exe)"
        }
        return "process:\(entry.id.pid):\(entry.id.startTime)"
    }

    public static func group(entries: [ProcessEntry], order: ProcessOrder = .cpu) -> [ProcessGroup] {
        var groupsMap: [String: [ProcessEntry]] = [:]
        var orderKeys: [String] = []

        for entry in entries {
            let key = groupKey(for: entry)
            if groupsMap[key] == nil {
                orderKeys.append(key)
            }
            groupsMap[key, default: []].append(entry)
        }

        var groups = orderKeys.compactMap { key -> ProcessGroup? in
            guard let groupEntries = groupsMap[key], let first = groupEntries.first else { return nil }
            return ProcessGroup(
                id: key,
                name: first.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? first.name,
                bundleIdentifier: first.bundleIdentifier,
                applicationPath: first.applicationPath,
                executablePath: first.executablePath,
                entries: groupEntries
            )
        }

        groups.sort { a, b in
            let dir = order.direction
            let ascending = (dir == .ascending)
            switch order.metric {
            case .name:
                let cmp = a.name.localizedStandardCompare(b.name)
                if cmp != .orderedSame {
                    return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
            case .cpu:
                if (a.totalCPUPercent == nil) != (b.totalCPUPercent == nil) { return a.totalCPUPercent != nil }
                let ac = a.totalCPUPercent ?? -1.0
                let bc = b.totalCPUPercent ?? -1.0
                if ac != bc { return ascending ? ac < bc : ac > bc }
            case .memory:
                if (a.totalMemoryBytes == nil) != (b.totalMemoryBytes == nil) { return a.totalMemoryBytes != nil }
                let am = a.totalMemoryBytes ?? 0
                let bm = b.totalMemoryBytes ?? 0
                if am != bm { return ascending ? am < bm : am > bm }
            case .pid:
                let ap = a.entries.map(\.id.pid).min() ?? 0, bp = b.entries.map(\.id.pid).min() ?? 0
                if ap != bp { return ascending ? ap < bp : ap > bp }
            case .energy:
                let av = a.entries.compactMap(\.energyImpact), bv = b.entries.compactMap(\.energyImpact)
                if av.isEmpty != bv.isEmpty { return !av.isEmpty }
                let ae = av.reduce(0, +), be = bv.reduce(0, +)
                if ae != be { return ascending ? ae < be : ae > be }
            }
            return a.id < b.id
        }
        return groups
    }
}

public enum ProcessPinning {
    public static func applyingPinned<T>(
        entries: [T],
        pinnedKeys: Set<String>,
        keyProvider: (T) -> String
    ) -> [T] {
        var pinned: [T] = []
        var others: [T] = []
        for item in entries {
            if pinnedKeys.contains(keyProvider(item)) {
                pinned.append(item)
            } else {
                others.append(item)
            }
        }
        return pinned + others
    }
}

struct ProcessCandidate {
    let identity: ProcessIdentity
    let name: String
    let cpuNanoseconds: UInt64?
    let memoryBytes: UInt64?
    var uptime: TimeInterval? = nil
    var executablePath: String? = nil
    var bundleIdentifier: String? = nil
    var applicationPath: String? = nil
    var energyImpact: Double? = nil
    var energyUnavailableReason: String? = nil
}

struct ProcessTracker {
    private(set) var previous: [ProcessIdentity: ProcessReading] = [:]
    /// 滑动样本窗口：每个进程保存过去约 65 秒内的读数。
    private var history: [ProcessIdentity: [ProcessReading]] = [:]

    mutating func update(_ candidates: [ProcessCandidate], uptime: TimeInterval, order: ProcessOrder, limit: Int = 20, pinnedPaths: Set<String> = []) -> ProcessList {
        var next: [ProcessIdentity: ProcessReading] = [:]
        var entries: [ProcessEntry] = []
        // shortcut: 8192 live processes; raise the ceiling if larger process tables must be sampled completely.
        for item in candidates.prefix(8192) {
            var percent: Double?
            var percentAvg: Double?
            if let nanos = item.cpuNanoseconds {
                let reading = ProcessReading(identity: item.identity, cpuNanoseconds: nanos, uptime: item.uptime ?? uptime)
                percent = ProcessUsage.percent(previous: previous[item.identity], current: reading)
                next[item.identity] = reading

                var readings = history[item.identity] ?? []
                readings.append(reading)
                let cutoff = reading.uptime - 65.0
                readings.removeAll { $0.uptime < cutoff }
                history[item.identity] = readings

                if let oldest = readings.first, readings.count >= 2 {
                    let span = reading.uptime - oldest.uptime
                    if span >= 3.0 {
                        percentAvg = ProcessUsage.percent(previous: oldest, current: reading, maxSeconds: 75)
                    } else {
                        // 预热期（< 3 秒）以当前实时读数显示，避免页面刚打开时显示不可用
                        percentAvg = percent
                    }
                } else {
                    percentAvg = percent
                }
            }
            entries.append(ProcessEntry(
                id: item.identity,
                name: item.name,
                cpuPercent: percent,
                cpuPercentAvg: percentAvg,
                memoryBytes: item.memoryBytes,
                executablePath: item.executablePath,
                bundleIdentifier: item.bundleIdentifier,
                applicationPath: item.applicationPath,
                energyImpact: item.energyImpact,
                energyUnavailableReason: item.energyUnavailableReason
            ))
        }
        previous = next
        // 清理已不在本次采集中的进程的窗口数据（进程已退出）
        let liveIdentities = Set(next.keys)
        history = history.filter { liveIdentities.contains($0.key) }
        entries.sort { first, second in
            let ascending = (order.direction == .ascending)
            switch order.metric {
            case .name:
                let compare = first.name.localizedStandardCompare(second.name)
                if compare != .orderedSame {
                    return ascending ? (compare == .orderedAscending) : (compare == .orderedDescending)
                }
            case .pid:
                if first.id.pid != second.id.pid {
                    return ascending ? (first.id.pid < second.id.pid) : (first.id.pid > second.id.pid)
                }
            case .cpu:
                if first.cpuPercent != second.cpuPercent {
                    guard let a = first.cpuPercent else { return false }
                    guard let b = second.cpuPercent else { return true }
                    return ascending ? (a < b) : (a > b)
                }
            case .memory:
                if first.memoryBytes != second.memoryBytes {
                    guard let a = first.memoryBytes else { return false }
                    guard let b = second.memoryBytes else { return true }
                    return ascending ? (a < b) : (a > b)
                }
            case .energy:
                if first.energyImpact != second.energyImpact {
                    guard let a = first.energyImpact else { return false }
                    guard let b = second.energyImpact else { return true }
                    return ascending ? (a < b) : (a > b)
                }
            }
            return first.id.pid < second.id.pid
        }
        let groups = ProcessGrouping.group(entries: entries, order: order)
        entries = ProcessPinning.applyingPinned(entries: entries, pinnedKeys: pinnedPaths) { $0.applicationPath ?? $0.executablePath ?? "" }
        let pinnedGroups = ProcessPinning.applyingPinned(entries: groups, pinnedKeys: pinnedPaths) { $0.applicationPath ?? $0.executablePath ?? "" }
        let boundedLimit = max(0, min(limit, 200))
        return ProcessList(entries: Array(entries.prefix(boundedLimit)), incomplete: candidates.count > 8192, updatedAt: Date(), groups: Array(pinnedGroups.prefix(boundedLimit)))
    }
    func percent(for item: ProcessCandidate, uptime: TimeInterval) -> Double? {
        guard let nanos = item.cpuNanoseconds else { return nil }
        return ProcessUsage.percent(previous: previous[item.identity], current: ProcessReading(identity: item.identity, cpuNanoseconds: nanos, uptime: item.uptime ?? uptime))
    }
    mutating func reset() { previous.removeAll(keepingCapacity: true); history.removeAll(keepingCapacity: true) }
}

public struct CPUCounters: Sendable {
    public let user, system, nice, idle: UInt64
    public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user; self.system = system; self.nice = nice; self.idle = idle
    }
}

public enum CPUUsage {
    public static func percent(previous: CPUCounters?, current: CPUCounters) -> Double? {
        guard let previous else { return nil }
        var total: UInt64 = 0; var busy: UInt64 = 0
        for (index, pair) in zip([current.user,current.system,current.nice,current.idle],
                               [previous.user,previous.system,previous.nice,previous.idle]).enumerated() {
            let (delta, underflow) = pair.0.subtractingReportingOverflow(pair.1)
            let (sum, overflow) = total.addingReportingOverflow(delta)
            guard !underflow, !overflow else { return nil }
            total = sum
            if index < 3 { busy = sum }
        }
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

public enum MemoryUsage {
    public static func usedBytes(internalPages: UInt64, purgeablePages: UInt64,
        wiredPages: UInt64, compressedPages: UInt64, pageSize: UInt64, physicalBytes: UInt64) -> UInt64? {
        guard pageSize > 0 else { return nil }
        let internalUsed = internalPages >= purgeablePages ? internalPages - purgeablePages : 0
        let (withWired, overflow1) = internalUsed.addingReportingOverflow(wiredPages)
        let (pages, overflow2) = withWired.addingReportingOverflow(compressedPages)
        let (bytes, overflow3) = pages.multipliedReportingOverflow(by: pageSize)
        guard !overflow1, !overflow2, !overflow3, bytes <= physicalBytes else { return nil }
        return bytes
    }
}

public struct NetworkReading: Sendable {
    public let interface: String
    public let index: UInt32
    public let received, sent: UInt64
    public let uptime: TimeInterval
    public init(interface: String, index: UInt32, received: UInt64, sent: UInt64, uptime: TimeInterval) {
        self.interface = interface; self.index = index; self.received = received; self.sent = sent; self.uptime = uptime
    }
}
public struct NetworkRate: Sendable {
    public let download, upload: Double
    public init(download: Double, upload: Double) { self.download = download; self.upload = upload }
}
public enum NetworkUsage {
    public static func rate(previous: NetworkReading?, current: NetworkReading) -> NetworkRate? {
        guard let previous, previous.interface == current.interface, previous.index == current.index else { return nil }
        let seconds = current.uptime - previous.uptime
        let (received, reset1) = current.received.subtractingReportingOverflow(previous.received)
        let (sent, reset2) = current.sent.subtractingReportingOverflow(previous.sent)
        guard seconds.isFinite, seconds > 0, seconds <= 6, !reset1, !reset2 else { return nil }
        return NetworkRate(download: Double(received) / seconds, upload: Double(sent) / seconds)
    }
}

public struct SystemSnapshot: Sendable {
    public let timestamp: Date
    public let uptime: TimeInterval
    public let cpuPercent: Double?
    public let physicalMemoryBytes: UInt64
    public let usedMemoryBytes, compressedMemoryBytes, swapUsedBytes: UInt64?
    public let diskTotalBytes, diskAvailableBytes: UInt64?
    public let networkRate: NetworkRate?
    public let networkInterface: String?
    public let networkGeneration: UInt64
    public let errors: [String: String]
    public let updatedAt: [String: Date]
    public init(timestamp: Date, uptime: TimeInterval, cpuPercent: Double? = nil,
        physicalMemoryBytes: UInt64 = 0, usedMemoryBytes: UInt64? = nil,
        compressedMemoryBytes: UInt64? = nil, swapUsedBytes: UInt64? = nil,
        diskTotalBytes: UInt64? = nil, diskAvailableBytes: UInt64? = nil,
        networkRate: NetworkRate? = nil, networkInterface: String? = nil,
        networkGeneration: UInt64 = 0, errors: [String: String] = [:], updatedAt: [String: Date] = [:]) {
        self.timestamp = timestamp; self.uptime = uptime; self.cpuPercent = cpuPercent
        self.physicalMemoryBytes = physicalMemoryBytes; self.usedMemoryBytes = usedMemoryBytes
        self.compressedMemoryBytes = compressedMemoryBytes; self.swapUsedBytes = swapUsedBytes
        self.diskTotalBytes = diskTotalBytes; self.diskAvailableBytes = diskAvailableBytes
        self.networkRate = networkRate; self.networkInterface = networkInterface; self.networkGeneration = networkGeneration
        self.errors = errors; self.updatedAt = updatedAt
    }
}

public struct ProcessTerminationResult: Sendable, Equatable {
    public let identity: ProcessIdentity
    public let signalSent: Int32?
    public let isStillAlive: Bool
    public let outcome: Outcome

    public enum Outcome: Sendable, Equatable {
        case signalSent(signal: Int32)
        case exitRequested
        case processAlreadyExited
        case rejected(RejectionReason)
        case failed(String)
    }

    public enum RejectionReason: Sendable, Equatable {
        case selfTarget
        case systemProcess
        case identityMismatch
        case uidMismatch
        case pathMismatch(expected: String, actual: String?)
        case forceKillRequiresPriorTermination(remainingSeconds: Double)
    }

    public init(
        identity: ProcessIdentity,
        signalSent: Int32?,
        isStillAlive: Bool,
        outcome: Outcome
    ) {
        self.identity = identity
        self.signalSent = signalSent
        self.isStillAlive = isStillAlive
        self.outcome = outcome
    }
}

final class ProcessTerminationTracker: @unchecked Sendable {
    static let shared = ProcessTerminationTracker()
    private let lock = NSLock()
    private var requests: [ProcessIdentity: TimeInterval] = [:]

    func recordRequest(for identity: ProcessIdentity, at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard time.isFinite else { return }
        requests = requests.filter { time >= $0.value && time - $0.value <= 300 }
        if requests.count >= 256, let oldest = requests.min(by: { $0.value < $1.value })?.key { requests.removeValue(forKey: oldest) }
        requests[identity] = time
    }

    func lastRequest(for identity: ProcessIdentity) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return requests[identity]
    }

    func clear(for identity: ProcessIdentity) {
        lock.lock(); defer { lock.unlock() }
        requests.removeValue(forKey: identity)
    }
}

public enum ProcessSecurity {
    public static func validate(
        process identity: ProcessIdentity,
        expectedPath: String? = nil
    ) -> (outcome: ProcessTerminationResult.Outcome?, path: String?) {
        if identity.pid == getpid() {
            return (.rejected(.selfTarget), nil)
        }
        if identity.pid <= 1 {
            return (.rejected(.systemProcess), nil)
        }
        var bsdInfo = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdRet = proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize)
        if bsdRet != bsdSize {
            let bsdError = errno
            if bsdError == ESRCH || (kill(identity.pid, 0) != 0 && errno == ESRCH) { return (.processAlreadyExited, nil) }
            return (.failed(localized("无法核验进程用户身份。")), nil)
        }
        if bsdInfo.pbi_status == SZOMB { return (.processAlreadyExited, nil) }
        var usage = rusage_info_v2()
        let usageRet = withUnsafeMutablePointer(to: &usage) {
            proc_pid_rusage(identity.pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        if usageRet != 0 || usage.ri_proc_start_abstime != identity.startTime {
            return (.rejected(.identityMismatch), nil)
        }
        let myUID = getuid()
        let myEUID = geteuid()
        if bsdInfo.pbi_ruid == 0 || bsdInfo.pbi_uid == 0 {
            return (.rejected(.systemProcess), nil)
        }
        if bsdInfo.pbi_ruid != myUID || bsdInfo.pbi_uid != myEUID {
            return (.rejected(.uidMismatch), nil)
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(identity.pid, $0.baseAddress, UInt32($0.count)) }
        let currentPath = length > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        if let expectedPath {
            if currentPath != expectedPath {
                return (.rejected(.pathMismatch(expected: expectedPath, actual: currentPath)), currentPath)
            }
        }
        guard let currentPath else { return (.failed(localized("无法核验进程路径。")), nil) }
        if currentPath.hasPrefix("/System/"), !currentPath.hasPrefix("/System/Applications/") { return (.rejected(.systemProcess), currentPath) }
        if let own = Bundle.main.bundleURL.path as String?, own.hasSuffix(".app"), currentPath.hasPrefix(own + "/") { return (.rejected(.selfTarget), currentPath) }
        guard withUnsafeMutablePointer(to: &usage, { proc_pid_rusage(identity.pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }) == 0,
              usage.ri_proc_start_abstime == identity.startTime else { return (.rejected(.identityMismatch), currentPath) }
        return (nil, currentPath)
    }
}

// Mutable state and all native calls belong to one monitoring queue.
public final class SystemMonitor {
    private var previousCPU: CPUCounters?
    private var previousNetwork: NetworkReading?
    private var previousUptime: TimeInterval?
    private var networkGeneration: UInt64 = 0
    private var updatedAt: [String: Date] = [:]
    private var diskTotal: UInt64?
    private var diskAvailable: UInt64?
    private var lastDiskUptime = -Double.infinity
    private var diskError: String?
    private let store = SCDynamicStoreCreate(nil, "MacEven" as CFString, nil, nil)
    private var processTracker = ProcessTracker()
    private var timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t(); _ = mach_timebase_info(&value); return value
    }()
    public init() {}

    public func resetBaselines() {
        previousCPU = nil; previousNetwork = nil; previousUptime = nil; networkGeneration &+= 1
        resetProcessBaselines()
    }

    public func resetProcessBaselines() { processTracker.reset() }
    public func processes(order: ProcessOrder, limit: Int = 20, pinnedPaths: Set<String> = []) -> ProcessList {
        let requested = Int(proc_listallpids(nil, 0))
        guard requested > 0 else { return ProcessList(entries: [], incomplete: true, updatedAt: Date()) }
        var pids = [Int32](repeating: 0, count: min(8192, requested + 32))
        let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
        let copied = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        guard copied > 0 else { return ProcessList(entries: [], incomplete: true, updatedAt: Date()) }
        var candidates: [ProcessCandidate] = []; var incomplete = requested > 8192 || Int(copied) >= pids.count
        for pid in pids.prefix(min(Int(copied),pids.count)) {
            guard pid > 0 else { incomplete = true; continue }
            autoreleasepool {
                if let candidate = readProcess(pid) { candidates.append(candidate) }
                else { incomplete = true }
            }
        }
        let result = processTracker.update(candidates, uptime: ProcessInfo.processInfo.systemUptime, order: order, limit: limit, pinnedPaths: pinnedPaths)
        return ProcessList(entries: result.entries, incomplete: result.incomplete || incomplete, updatedAt: result.updatedAt, groups: result.groups)
    }
    public func details(for identity: ProcessIdentity) -> ProcessDetail? {
        guard let item = readProcess(identity.pid), item.identity == identity else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let capacity = UInt32(buffer.count)
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(identity.pid, $0.baseAddress, capacity) }
        let path = length > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        let reason = length > 0 ? nil : localized("无法读取进程路径：\(String(cString: strerror(errno)))")
        // Revalidate after the separate path call so PID reuse cannot attach a new path.
        guard readUsage(identity.pid)?.ri_proc_start_abstime == identity.startTime else { return nil }
        let entry = ProcessEntry(
            id: identity,
            name: item.name,
            cpuPercent: processTracker.percent(for: item, uptime: ProcessInfo.processInfo.systemUptime),
            memoryBytes: item.memoryBytes,
            executablePath: path ?? item.executablePath,
            bundleIdentifier: item.bundleIdentifier,
            applicationPath: item.applicationPath,
            energyImpact: item.energyImpact,
            energyUnavailableReason: item.energyUnavailableReason
        )
        return ProcessDetail(entry: entry, path: path, unavailableReason: reason)
    }
    private func readUsage(_ pid: Int32) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            // libproc expects the address of a struct cast to its opaque rusage_info_t pointer.
            proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        return result == 0 ? info : nil
    }
    private func readProcess(_ pid: Int32) -> ProcessCandidate? {
        guard let info = readUsage(pid) else { return nil }
        let sampledAt = ProcessInfo.processInfo.systemUptime
        let identity = ProcessIdentity(pid: pid, startTime: info.ri_proc_start_abstime)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = nameBuffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, 256) }
        let name = nameLength > 0 ? String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : localized("进程 \(pid)")
        let (ticks, overflow) = info.ri_user_time.addingReportingOverflow(info.ri_system_time)
        let nanos = overflow ? nil : ProcessUsage.nanoseconds(ticks: ticks, numerator: timebase.numer, denominator: timebase.denom)

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = pathBuffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let execPath = pathLength > 0 ? String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil

        var bundleID: String?
        var appPath: String?
        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            bundleID = runningApp.bundleIdentifier
            appPath = runningApp.bundleURL?.path
        }
        if let execPath, let range = execPath.range(of: ".app/") {
            appPath = String(execPath[..<range.upperBound].dropLast())
        }

        let energyImpact: Double? = nil
        let energyReason = localized("系统未向非特权进程提供独立能耗指标，不可将 CPU 冒充为能耗")

        guard readUsage(pid)?.ri_proc_start_abstime == identity.startTime else { return nil }
        return ProcessCandidate(
            identity: identity,
            name: name,
            cpuNanoseconds: nanos,
            memoryBytes: info.ri_phys_footprint,
            uptime: sampledAt,
            executablePath: execPath,
            bundleIdentifier: bundleID,
            applicationPath: appPath,
            energyImpact: energyImpact,
            energyUnavailableReason: energyReason
        )
    }

    public func terminateProcess(
        _ identity: ProcessIdentity,
        expectedPath: String? = nil,
        now: TimeInterval? = nil
    ) -> ProcessTerminationResult {
        let validation = ProcessSecurity.validate(process: identity, expectedPath: expectedPath)
        if let outcome = validation.outcome {
            let alive = isProcessAlive(identity)
            return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: alive, outcome: outcome)
        }
        let currentTime = now ?? ProcessInfo.processInfo.systemUptime
        if let app = NSRunningApplication(processIdentifier: identity.pid), app.activationPolicy == .regular {
            guard app.terminate() else {
                let alive = isProcessAlive(identity)
                if alive { ProcessTerminationTracker.shared.recordRequest(for: identity, at: currentTime) }
                return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: alive, outcome: .failed(localized("应用未接受正常退出请求；若仍无响应，等待五秒后可再次确认强制结束。")))
            }
            ProcessTerminationTracker.shared.recordRequest(for: identity, at: currentTime)
            return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: isProcessAlive(identity), outcome: .exitRequested)
        }
        let ret = kill(identity.pid, SIGTERM)
        if ret == 0 {
            ProcessTerminationTracker.shared.recordRequest(for: identity, at: currentTime)
            usleep(2000)
            let alive = isProcessAlive(identity)
            return ProcessTerminationResult(identity: identity, signalSent: SIGTERM, isStillAlive: alive, outcome: .signalSent(signal: SIGTERM))
        } else {
            let err = errno
            if err == ESRCH {
                return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: false, outcome: .processAlreadyExited)
            }
            return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: true, outcome: .failed(String(cString: strerror(err))))
        }
    }

    public func forceKillProcess(
        _ identity: ProcessIdentity,
        expectedPath: String? = nil,
        allowDirect: Bool = false,
        now: TimeInterval? = nil
    ) -> ProcessTerminationResult {
        let validation = ProcessSecurity.validate(process: identity, expectedPath: expectedPath)
        if let outcome = validation.outcome {
            let alive = isProcessAlive(identity)
            return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: alive, outcome: outcome)
        }
        let currentTime = now ?? ProcessInfo.processInfo.systemUptime
        if !allowDirect {
            guard let priorTime = ProcessTerminationTracker.shared.lastRequest(for: identity) else {
                let alive = isProcessAlive(identity)
                return ProcessTerminationResult(
                    identity: identity,
                    signalSent: nil,
                    isStillAlive: alive,
                    outcome: .rejected(.forceKillRequiresPriorTermination(remainingSeconds: 5.0))
                )
            }
            let elapsed = currentTime - priorTime
            if !elapsed.isFinite || elapsed < 0 || elapsed > 300 {
                ProcessTerminationTracker.shared.clear(for: identity)
                return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: isProcessAlive(identity), outcome: .rejected(.forceKillRequiresPriorTermination(remainingSeconds: 5)))
            }
            if elapsed < 5.0 {
                let alive = isProcessAlive(identity)
                return ProcessTerminationResult(
                    identity: identity,
                    signalSent: nil,
                    isStillAlive: alive,
                    outcome: .rejected(.forceKillRequiresPriorTermination(remainingSeconds: 5.0 - elapsed))
                )
            }
        }
        let ret = kill(identity.pid, SIGKILL)
        ProcessTerminationTracker.shared.clear(for: identity)
        if ret == 0 {
            usleep(2000)
            let alive = isProcessAlive(identity)
            return ProcessTerminationResult(identity: identity, signalSent: SIGKILL, isStillAlive: alive, outcome: .signalSent(signal: SIGKILL))
        } else {
            let err = errno
            if err == ESRCH {
                return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: false, outcome: .processAlreadyExited)
            }
            return ProcessTerminationResult(identity: identity, signalSent: nil, isStillAlive: true, outcome: .failed(String(cString: strerror(err))))
        }
    }

    public func isProcessAlive(_ identity: ProcessIdentity) -> Bool {
        guard identity.pid > 0 else { return false }
        if kill(identity.pid, 0) != 0 { return false }
        var bsdInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &bsdInfo, size) == size,
              bsdInfo.pbi_status != SZOMB else { return false }
        var usage = rusage_info_v2()
        let ret = withUnsafeMutablePointer(to: &usage) {
            proc_pid_rusage(identity.pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        return ret == 0 && usage.ri_proc_start_abstime == identity.startTime && usage.ri_proc_exit_abstime == 0
    }

    public func sample(at date: Date = Date(), refreshDisk: Bool = false) -> SystemSnapshot {
        let uptime = ProcessInfo.processInfo.systemUptime
        if let previousUptime, uptime - previousUptime > 6 || uptime <= previousUptime { resetBaselines() }
        previousUptime = uptime
        var errors: [String: String] = [:]
        var cpu: Double?
        var memory: UInt64?; var compressed: UInt64?; var swap: UInt64?
        var network: NetworkRate?; var interface: String?
        do {
            let current = try readCPU()
            cpu = CPUUsage.percent(previous: previousCPU, current: current)
            if cpu != nil { updatedAt["cpu"] = date }
            else if previousCPU != nil { errors["cpu"] = localized("CPU 计数已重置，正在重新采样。") }
            previousCPU = current
        } catch { previousCPU = nil; errors["cpu"] = error.localizedDescription }
        let physical = ProcessInfo.processInfo.physicalMemory
        do {
            let vm = try readVM()
            let nativePageSize = sysconf(_SC_PAGESIZE)
            guard nativePageSize > 0 else { throw MacEvenError(localized("系统内存页大小不可用。")) }
            let page = UInt64(nativePageSize)
            memory = MemoryUsage.usedBytes(internalPages: UInt64(vm.internal_page_count),
                purgeablePages: UInt64(vm.purgeable_count), wiredPages: UInt64(vm.wire_count),
                compressedPages: UInt64(vm.compressor_page_count), pageSize: page, physicalBytes: physical)
            let (compressedBytes, overflow) = UInt64(vm.compressor_page_count).multipliedReportingOverflow(by: page)
            guard memory != nil, !overflow else { throw MacEvenError(localized("内存计数超出有效范围。")) }
            compressed = compressedBytes
            var usage = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
            guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0,
                  size == MemoryLayout<xsw_usage>.size else { throw nativeError("Swap") }
            swap = usage.xsu_used; updatedAt["memory"] = date
        } catch { errors["memory"] = error.localizedDescription }
        if refreshDisk || uptime - lastDiskUptime >= 30 {
            lastDiskUptime = uptime
            do {
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
                guard let total = (attributes[.systemSize] as? NSNumber)?.uint64Value,
                      let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value, free <= total else {
                    throw MacEvenError(localized("启动卷容量不可用。"))
                }
                diskTotal = total; diskAvailable = free; updatedAt["disk"] = date; diskError = nil
            } catch { diskError = error.localizedDescription }
        }
        errors["disk"] = diskError
        do {
            let current = try readNetwork(uptime: uptime)
            interface = current.interface
            network = NetworkUsage.rate(previous: previousNetwork, current: current)
            if network != nil { updatedAt["network"] = date }
            else if previousNetwork != nil { networkGeneration &+= 1 }
            previousNetwork = current
        } catch {
            if previousNetwork != nil { networkGeneration &+= 1 }
            previousNetwork = nil; errors["network"] = error.localizedDescription
        }
        return SystemSnapshot(timestamp: date, uptime: uptime, cpuPercent: cpu,
            physicalMemoryBytes: physical, usedMemoryBytes: memory, compressedMemoryBytes: compressed, swapUsedBytes: swap,
            diskTotalBytes: diskTotal, diskAvailableBytes: diskAvailable, networkRate: network,
            networkInterface: interface, networkGeneration: networkGeneration, errors: errors, updatedAt: updatedAt)
    }

    private func nativeError(_ metric: String) -> MacEvenError {
        MacEvenError(localized("\(metric) 读取失败：\(String(cString: strerror(errno)))"))
    }
    private func readCPU() throws -> CPUCounters {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { throw MacEvenError(localized("CPU 读取失败：Mach \(result)。")) }
        return CPUCounters(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3), idle: UInt64(info.cpu_ticks.2))
    }
    private func readVM() throws -> vm_statistics64_data_t {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { throw MacEvenError(localized("内存读取失败：Mach \(result)。")) }
        return info
    }
    private func readNetwork(uptime: TimeInterval) throws -> NetworkReading {
        guard let store else { throw MacEvenError(localized("网络配置服务不可用。")) }
        var name: String?
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let values = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let primary = values["PrimaryInterface"] as? String { name = primary; break }
        }
        guard let name else { throw MacEvenError(localized("未连接：无主网络接口。")) }
        let index = if_nametoindex(name)
        guard index > 0 else { throw nativeError(localized("网络接口")) }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { throw nativeError(localized("网络计数")) }
        // shortcut: route data is capped at 1 MiB; raise the cap if larger interface tables must be supported.
        guard length >= 4, length <= 1_048_576 else { throw MacEvenError(localized("网络接口列表大小超出有效范围。")) }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &length, nil, 0) }
        guard result == 0, length <= data.count else { throw nativeError(localized("网络计数")) }
        return try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset + 4 <= length {
                let size = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard size >= 4, size <= length - offset else { throw MacEvenError(localized("网络接口数据不完整。")) }
                if buffer[offset + 3] == UInt8(RTM_IFINFO2) {
                    guard size >= MemoryLayout<if_msghdr2>.size else { throw MacEvenError(localized("网络计数结构不完整。")) }
                    let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(message.ifm_index) == index {
                        return NetworkReading(interface: name, index: index, received: message.ifm_data.ifi_ibytes,
                            sent: message.ifm_data.ifi_obytes, uptime: uptime)
                    }
                }
                offset += size
            }
            throw MacEvenError(localized("主网络接口计数暂不可用。"))
        }
    }
}
