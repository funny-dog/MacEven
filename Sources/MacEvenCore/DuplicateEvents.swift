import Foundation
import Darwin
import CoreServices

/// 每个扫描根使用 per-device 历史，游标与该设备的事件日志 UUID 配对。
final class DuplicateEvents {
    struct Event: Sendable {
        let path: String
        let flags: UInt32
        let id: UInt64
    }
    static let fullScanFlags = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
        kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped |
        kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)

    final class Buffer: @unchecked Sendable {
        let lock = NSLock()
        let rootPath: String
        let relativeRoot: String
        var events: [Event] = []
        var historyDone = false
        var overflow = false
        private var maxSeenID: UInt64 = 0
        init(rootPath: String, relativeRoot: String) { self.rootPath = rootPath; self.relativeRoot = relativeRoot }
        func append(count: Int, raw: UnsafeMutableRawPointer, flags: UnsafePointer<UInt32>, ids: UnsafePointer<UInt64>) {
            let paths = raw.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            lock.withLock {
                for i in 0..<count {
                    maxSeenID = max(maxSeenID, ids[i])
                    let history = flags[i] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0
                    if history { historyDone = true }
                    guard events.count < 100_000 else { overflow = true; continue }
                    if flags[i] & DuplicateEvents.fullScanFlags != 0 {
                        events.append(Event(path: rootPath, flags: flags[i], id: ids[i])); continue
                    }
                    if history { continue }
                    let rawPath = String(cString: paths[i])
                    let relative = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
                    // APFS firmlink 路径（/Users、/private/var）不含 Data 卷挂载前缀。
                    guard relativeRoot == "/" || relative == relativeRoot || relative.hasPrefix(relativeRoot + "/") else { continue }
                    let suffix = relativeRoot == "/" ? (relative == "/" ? "" : relative) : String(relative.dropFirst(relativeRoot.count))
                    let path = rootPath + suffix
                    events.append(Event(path: path, flags: flags[i], id: ids[i]))
                }
            }
        }
        func take() -> (events: [Event], cursor: UInt64) {
            lock.withLock { defer { events.removeAll(keepingCapacity: true) }; return (events,maxSeenID) }
        }
        var ready: Bool { lock.withLock { historyDone } }
        var lost: Bool { lock.withLock { overflow } }
    }
    private let buffer: Buffer
    private let queue = DispatchQueue(label: "MacEven.duplicate.events")
    private var stream: FSEventStreamRef?
    let root: URL
    private(set) var cursor: UInt64

    static func logIdentity(root: URL) throws -> String {
        let identity = try FileIdentity.read(root)
        guard let uuid = FSEventsCopyUUIDForDevice(dev_t(identity.device)) else {
            throw MacEvenError(localized("磁盘没有可恢复的文件事件日志。"))
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    init(root: URL, since: UInt64) throws {
        self.root = root
        cursor = since
        var info = statfs()
        guard statfs(root.path, &info) == 0 else { throw MacEvenError(localized("无法读取扫描磁盘。")) }
        let mount = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let relative = mount != "/" && (root.path == mount || root.path.hasPrefix(mount + "/"))
            ? String(root.path.dropFirst(mount.count)) : root.path
        buffer = Buffer(rootPath: root.path, relativeRoot: relative.isEmpty ? "/" : relative)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(buffer).toOpaque(), retain: { raw in
            guard let raw else { return nil }; _ = Unmanaged<Buffer>.fromOpaque(raw).retain(); return raw
        }, release: { raw in
            if let raw { Unmanaged<Buffer>.fromOpaque(raw).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreateRelativeToDevice(nil, { _, info, count, raw, flags, ids in
            guard let info else { return }
            Unmanaged<Buffer>.fromOpaque(info).takeUnretainedValue().append(count: count, raw: raw, flags: flags, ids: ids)
        }, &context, dev_t(try FileIdentity.read(root).device), [relative.isEmpty ? "/" : relative] as CFArray,
            since, 0.05, flags) else { throw MacEvenError(localized("无法创建文件事件监听。")) }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else { stop(); throw MacEvenError(localized("无法启动文件事件监听。")) }
    }

    /// FlushSync 之后再过回调队列屏障；历史未结束时绝不使用旧快照。
    func collect(history: Bool, token: CancellationToken) throws -> [Event] {
        guard let stream else { throw MacEvenError(localized("文件事件监听已关闭。")) }
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if token.isCancelled { throw MacEvenError(localized("扫描已取消。")) }
            FSEventStreamFlushSync(stream)
            queue.sync {}
            if !history || buffer.ready { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        guard !history || buffer.ready, !buffer.lost else { throw MacEvenError(localized("文件事件历史不完整，改用完整扫描。")) }
        let batch = buffer.take()
        cursor = max(cursor, batch.cursor)
        return batch.events
    }
    static func needsFullScan(_ events: [Event]) -> Bool {
        events.contains { $0.flags & fullScanFlags != 0 }
    }
    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
            queue.sync {}
            FSEventStreamRelease(stream); self.stream = nil
        }
    }
    deinit { stop() }
}
