import Foundation
import Combine
import MacEvenCore

@MainActor final class MonitorModel: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var recent: [SystemSnapshot] = []
    @Published private(set) var hardware: HardwareSnapshot?
    @Published private(set) var hardwareRecent: [HardwareSnapshot] = []
    @Published private(set) var historyError: String?
    @Published private(set) var history: [HistoryBucket] = []
    @Published private(set) var historyLoading = false
    @Published private(set) var processList: ProcessList?
    @Published private(set) var processDetail: ProcessDetail?
    @Published private(set) var processError: String?
    @Published private(set) var processActionMessage: String?
    @Published private(set) var processActionBusy = false
    private var actionID = UUID()
    private var hardwareEpoch: TimeInterval = 0
    @Published var processOrder: ProcessOrder = .cpu { didSet { updateProcessState() } }
    let historyURL: URL
    let historyWorker: HistoryWorker
    private let backend: Backend
    private var generation: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private var queryID = UUID()
    private var detailID = UUID()
    private var pinnedPaths: Set<String> = []
    private var processVisible = false
    @Published private(set) var pageVisible = false
    @Published private(set) var popoverVisible = false
    private var processGeneration: UInt64 = 0
    private var started = false
    private var stopped = false

    // Both fields are protected by lock; one pending delivery owns the mailbox.
    private struct Delivery: Sendable {
        let generation: UInt64
        var snapshot: SystemSnapshot?
        var hardware: HardwareSnapshot?
        var processes: ProcessList?
        var processGeneration: UInt64
    }
    private final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Delivery?
        private var pending = false
        func put(_ snapshot: SystemSnapshot?, hardware: HardwareSnapshot? = nil, processes: ProcessList?, processGeneration: UInt64, generation: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if value?.generation != generation {
                value = Delivery(generation: generation, snapshot: snapshot, hardware: hardware, processes: processes, processGeneration: processGeneration)
            } else {
                if let snapshot { value?.snapshot = snapshot }
                if let hardware { value?.hardware = hardware }
                if let processes { value?.processes = processes; value?.processGeneration = processGeneration }
            }
            guard !pending else { return false }
            pending = true; return true
        }
        func take() -> Delivery? {
            lock.lock(); defer { lock.unlock() }
            let result = value; value = nil; pending = false; return result
        }
    }
    // Mutable fields are owned exclusively by queue; mailbox uses its own lock.
    private final class Backend: @unchecked Sendable {
        let queue = DispatchQueue(label: "MacEven.monitor", qos: .utility)
        let mailbox = Mailbox()
        let monitor = SystemMonitor()
        let hardwareQueue = DispatchQueue(label: "MacEven.hardware", qos: .utility)
        let hardwareSampler = SystemHardware()
        private var latestHardware: HardwareSnapshot?
        private var hardwarePending = false
        private var hardwareGeneration: UInt64 = 0
        private var nextHardware = -Double.infinity
        let history: HistoryWorker
        private var accumulator = HistoryAccumulator()
        var historyGeneration: UInt64 = 0
        private var timer: DispatchSourceTimer?
        private var nextSample = -Double.infinity
        private var forceDisk = false
        private var sleeping = false
        private var visible = false
        private var order: ProcessOrder = .cpu
        private var pinnedPaths: Set<String> = []
        private var processGeneration: UInt64 = 0
        private var nextProcess = -Double.infinity
        var deliver: (@Sendable (SystemSnapshot?, HardwareSnapshot?, ProcessList?, UInt64) -> Void)?
        init(history: HistoryWorker) { self.history = history }
        func start(deliver: @escaping @Sendable (SystemSnapshot?, HardwareSnapshot?, ProcessList?, UInt64) -> Void) {
            guard timer == nil else { return }
            self.deliver = deliver
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
        private func tick() {
            guard !sleeping else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now + 0.1 >= nextSample {
                let interval = visible ? 1.0 : 2.0
                nextSample = now + interval
                let sample = monitor.sample(refreshDisk: forceDisk)
                forceDisk = false
                for minute in accumulator.append(sample, hardware: latestHardware) { history.offer(minute, generation: historyGeneration) }
                deliver?(sample, nil, nil, processGeneration)
            }
            if !hardwarePending, now + 0.1 >= nextHardware {
                hardwarePending = true; nextHardware = now + (visible ? 1 : 10)
                let current = hardwareGeneration
                hardwareQueue.async { [weak self] in
                    guard let self else { return }
                    let reading = autoreleasepool { self.hardwareSampler.sample() }
                    self.queue.async {
                        self.hardwarePending = false
                        guard self.timer != nil, !self.sleeping, self.hardwareGeneration == current else { return }
                        self.latestHardware = reading
                        self.deliver?(nil, reading, nil, self.processGeneration)
                    }
                }
            }
            if visible, now + 0.1 >= nextProcess {
                nextProcess = now + 1
                deliver?(nil, nil, monitor.processes(order: order, limit: 200, pinnedPaths: pinnedPaths), processGeneration)
            }
        }
        func refreshDisk() { forceDisk = true; nextSample = -Double.infinity }
        func sleep() {
            sleeping = true; latestHardware = nil; hardwareGeneration &+= 1
            if var last = accumulator.finish() { last.hasGap = true; history.offer(last, generation: historyGeneration) }
        }
        func wake() { sleeping = false; latestHardware = nil; hardwareQueue.async { self.hardwareSampler.resetBaselines() }; hardwareGeneration &+= 1; nextHardware = -Double.infinity; monitor.resetBaselines(); nextSample = -Double.infinity; nextProcess = -Double.infinity; forceDisk = true }
        func processState(visible: Bool, order: ProcessOrder, generation: UInt64, pinnedPaths: Set<String>) {
            if !visible || self.visible != visible { monitor.resetProcessBaselines() }
            self.visible = visible; nextHardware = -Double.infinity; self.order = order; self.pinnedPaths = pinnedPaths; processGeneration = generation; nextProcess = -Double.infinity
        }
        func clearHistory(generation: UInt64) { historyGeneration = generation; accumulator.reset() }
        func stop() {
            hardwareGeneration &+= 1
            timer?.setEventHandler {}; timer?.cancel(); timer = nil; deliver = nil
            if let last = accumulator.finish() { history.offer(last, generation: historyGeneration) }
            _ = mailbox.take()
        }
        deinit { timer?.cancel() }
    }

    init(historyURL: URL? = nil) {
        self.historyURL = historyURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacEven/monitor.sqlite")
        historyWorker = HistoryWorker(url: self.historyURL)
        backend = Backend(history: historyWorker)
    }
    func start() {
        guard !started, !stopped else { return }
        started = true; generation &+= 1; snapshot = nil; recent.removeAll(keepingCapacity: true)
        historyWorker.prepare { [weak self] generation, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.historyGeneration == generation else { return }
                self.historyError = error
            }
        }
        let currentGeneration = generation; let backend = backend; let mailbox = backend.mailbox
        backend.queue.async { [weak self] in
            backend.start { [weak self] sample, hardware, processes, processGeneration in
                if mailbox.put(sample, hardware: hardware, processes: processes, processGeneration: processGeneration, generation: currentGeneration) {
                    DispatchQueue.main.async { [weak self] in self?.consume() }
                }
            }
        }
    }
    private func consume() {
        guard let delivery = backend.mailbox.take(), delivery.generation == generation, !stopped else { return }
        if let sample = delivery.snapshot { accept(sample) }
        if let reading = delivery.hardware, reading.sampledUptime >= hardwareEpoch {
            hardware = reading
            hardwareRecent.removeAll { reading.sampledAt.timeIntervalSince($0.sampledAt) >= 600 || $0.sampledAt > reading.sampledAt }
            if hardwareRecent.count >= 600 { hardwareRecent.removeFirst(hardwareRecent.count - 599) }
            hardwareRecent.append(reading)
        }
        if processVisible, delivery.processGeneration == processGeneration, let processes = delivery.processes { processList = processes }
    }
    func accept(_ value: SystemSnapshot) {
        guard !stopped else { return }
        snapshot = value
        recent.removeAll { value.timestamp.timeIntervalSince($0.timestamp) >= 600 || $0.timestamp > value.timestamp }
        if recent.count >= 600 { recent.removeFirst(recent.count - 599) }
        recent.append(value)
    }
    func setProcessPageVisible(_ visible: Bool) {
        guard !stopped, pageVisible != visible else { return }
        pageVisible = visible
        updateVisibility()
    }
    func setPopoverVisible(_ visible: Bool) {
        guard !stopped, popoverVisible != visible else { return }
        popoverVisible = visible
        updateVisibility()
    }
    private func updateVisibility() {
        let visible = pageVisible || popoverVisible
        guard processVisible != visible else { return }
        processVisible = visible
        if !visible { clearProcessSelection() }
        updateProcessState()
    }
    func setPinnedPaths(_ paths: Set<String>) {
        guard pinnedPaths != paths else { return }; pinnedPaths = paths; updateProcessState()
    }
    private func updateProcessState() {
        guard !stopped else { return }
        processList = nil; processGeneration &+= 1
        let current = processGeneration; let visible = processVisible; let order = processOrder; let paths = pinnedPaths; let backend = backend
        backend.queue.async { backend.processState(visible: visible, order: order, generation: current, pinnedPaths: paths) }
    }
    func selectProcess(_ identity: ProcessIdentity) {
        guard !stopped, processVisible else { return }
        clearProcessSelection()
        detailID = UUID(); let request = detailID
        processDetail = nil; processError = nil
        let backend = backend
        backend.queue.async { [weak self] in
            let details = backend.monitor.details(for: identity)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.processVisible, self.detailID == request else { return }
                self.processDetail = details
                self.processError = details == nil ? localized("进程已退出，或无法读取其信息。") : nil
            }
        }
    }
    func requestProcessExit(_ detail: ProcessDetail, force: Bool, allowDirectForce: Bool = true) {
        guard !stopped, !processActionBusy, let path = detail.path else { return }
        processActionBusy = true; processActionMessage = localized("正在复核进程身份…")
        actionID = UUID(); let request = actionID; let backend = backend
        backend.queue.async { [weak self] in
            let result = force
                ? backend.monitor.forceKillProcess(detail.entry.id, expectedPath: path, allowDirect: allowDirectForce)
                : backend.monitor.terminateProcess(detail.entry.id, expectedPath: path)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.actionID == request else { return }
                self.processActionBusy = false
                switch result.outcome {
                case .signalSent, .exitRequested:
                    self.processActionMessage = localized("已请求\(force ? localized("强制结束") : localized("正常退出"))，正在确认实际状态…")
                    self.observeExit(detail.entry.id, request: request, attempts: 12)
                case .processAlreadyExited: self.processActionMessage = localized("目标进程已退出。")
                case .failed(let reason): self.processActionMessage = localized("操作失败：\(reason)")
                case .rejected(let reason):
                    switch reason {
                    case .selfTarget, .systemProcess: self.processActionMessage = localized("系统进程与 MacEven 自身受到保护。")
                    case .identityMismatch: self.processActionMessage = localized("进程身份已变化，操作被拒绝。")
                    case .uidMismatch: self.processActionMessage = localized("只能操作当前用户拥有的进程。")
                    case .pathMismatch: self.processActionMessage = localized("可执行路径已变化，操作被拒绝。")
                    case .forceKillRequiresPriorTermination(let remainingSeconds): self.processActionMessage = localized("请先请求正常退出，再等待至少 \(Int(ceil(remainingSeconds))) 秒。")
                    }
                }
            }
        }
    }
    private func observeExit(_ identity: ProcessIdentity, request: UUID, attempts: Int) {
        let backend = backend
        backend.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let alive = backend.monitor.isProcessAlive(identity)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.actionID == request else { return }
                if !alive { self.processActionMessage = localized("已确认原目标进程退出。") }
                else if attempts > 1 { self.observeExit(identity, request: request, attempts: attempts - 1) }
                else { self.processActionMessage = localized("目标仍在运行；可在再次确认后强制结束。") }
            }
        }
    }
    func clearProcessSelection() {
        detailID = UUID(); actionID = UUID(); processDetail = nil; processError = nil
        processActionMessage = nil; processActionBusy = false
    }
    func refreshDisk() {
        guard !stopped else { return }
        let backend = backend; backend.queue.async { backend.refreshDisk() }
    }
    func prepareForSleep() {
        guard !stopped else { return }
        hardware = nil; hardwareEpoch = ProcessInfo.processInfo.systemUptime
        let backend = backend; backend.queue.async { backend.sleep() }
    }
    func resetAfterWake() {
        guard !stopped else { return }
        hardware = nil; hardwareEpoch = ProcessInfo.processInfo.systemUptime
        let backend = backend; backend.queue.async { backend.wake() }
    }
    func loadHistory(hours: Int) {
        guard !stopped else { return }
        guard [1,24,168].contains(hours) else { historyError = localized("历史范围仅支持 1 小时、24 小时或 7 天。"); return }
        queryID = UUID(); let currentQuery = queryID
        historyLoading = true
        let end = Date()
        historyWorker.load(from: end.addingTimeInterval(-Double(hours * 3600)), to: end, generation: historyGeneration) { [weak self] generation, values, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.historyGeneration == generation, self.queryID == currentQuery else { return }
                self.history = values; self.historyError = error; self.historyLoading = false
            }
        }
    }
    func clearHistory() {
        guard !stopped else { return }
        queryID = UUID(); history = []; historyLoading = true
        let newGeneration = historyWorker.beginClear { [weak self] generation, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.historyGeneration == generation else { return }
                self.historyError = error; self.historyLoading = false
            }
        }
        historyGeneration = newGeneration
        let backend = backend; backend.queue.async { backend.clearHistory(generation: newGeneration) }
    }
    func shutdown(completion: @escaping @MainActor (String?) -> Void) {
        if !stopped { stopped = true; generation &+= 1 }
        let backend = backend; let history = historyWorker
        backend.queue.async {
            backend.stop()
            history.close { error in DispatchQueue.main.async { completion(error) } }
        }
    }
}

// Connection and paused/error state belong to queue; generation and pending slot use lock.
final class HistoryWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "MacEven.history", qos: .utility)
    private let url: URL
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending: MinuteAggregate?
    private var scheduled = false
    private var dropped = false
    private var store: MonitorHistory?
    private var paused = false
    private var closed = false
    private var lastError: String?
    private var publish: (@Sendable (UInt64, String?) -> Void)?
    init(url: URL) { self.url = url }
    private func isCurrent(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == value
    }
    func prepare(publish: @escaping @Sendable (UInt64, String?) -> Void) {
        queue.async {
            guard !self.closed else { return }
            self.publish = publish
            do { self.store = try MonitorHistory(url: self.url) }
            catch { self.paused = true; self.lastError = error.localizedDescription }
            self.publish?(0, self.lastError)
        }
    }
    func offer(_ value: MinuteAggregate, generation: UInt64) {
        lock.lock()
        guard self.generation == generation else { lock.unlock(); return }
        if let old = pending, old.minuteUTC == value.minuteUTC { pending?.merge(value) }
        else {
            if pending != nil { dropped = true }
            pending = value
        }
        let enqueue = !scheduled; scheduled = true; lock.unlock()
        if enqueue { queue.async { self.drain(generation: generation) } }
    }
    private func drain(generation: UInt64) {
        lock.lock()
        guard self.generation == generation else { lock.unlock(); return }
        var value = pending; let lost = dropped
        pending = nil; scheduled = false; dropped = false; lock.unlock()
        guard !closed, !paused, let minute = value else { return }
        if lost { value?.hasGap = true }
        do {
            guard let store else { throw MacEvenError(localized("历史存储尚未就绪。")) }
            try store.write(value ?? minute, now: Date())
            if lost { lastError = localized("历史写入跟不上，部分分钟未保存。"); publish?(generation, lastError) }
        } catch { paused = true; lastError = error.localizedDescription; publish?(generation, lastError) }
    }
    func load(from: Date, to: Date, generation: UInt64,
        completion: @escaping @Sendable (UInt64, [HistoryBucket], String?) -> Void) {
        queue.async {
            guard self.isCurrent(generation), !self.closed else { return }
            do {
                guard let store = self.store else { throw MacEvenError(self.lastError ?? localized("历史存储尚未就绪。")) }
                completion(generation, try store.query(from: from, to: to), self.lastError)
            } catch { completion(generation, [], error.localizedDescription) }
        }
    }
    func beginClear(completion: @escaping @Sendable (UInt64, String?) -> Void) -> UInt64 {
        lock.lock(); generation &+= 1; let current = generation
        pending = nil; scheduled = false; dropped = false; lock.unlock()
        queue.async {
            guard !self.closed else { completion(current, localized("历史存储已关闭。")); return }
            do {
                if let store = self.store { try store.clear() }
                else {
                    if FileManager.default.fileExists(atPath: self.url.path) { try FileManager.default.removeItem(at: self.url) }
                    self.store = try MonitorHistory(url: self.url)
                }
                self.paused = false; self.lastError = nil; completion(current, nil)
            } catch { self.paused = true; self.lastError = error.localizedDescription; completion(current, self.lastError) }
        }
        return current
    }
    func close(completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            self.closed = true; self.store?.close(); self.store = nil; self.publish = nil
            self.lock.lock(); self.generation &+= 1; self.pending = nil; self.scheduled = false; self.lock.unlock()
            completion(self.lastError)
        }
    }
}
