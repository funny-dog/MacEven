import Foundation
import Darwin

public struct OperationRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let batch: UUID
    public let time: Date
    public let source: String
    public let path: String
    public let destination: String?
    public let allocatedSize: Int64?
    public let error: String?
    /// destination 非空即已移入废纸篓；同时有 error 表示移动后的同步失败。
    public var moved: Bool { destination != nil }

    public init(id: UUID = UUID(), batch: UUID, time: Date, source: String, path: String, destination: String?, allocatedSize: Int64?, error: String?) {
        self.id = id; self.batch = batch; self.time = time; self.source = String(source.prefix(64))
        self.path = String(path.prefix(4096)); self.destination = destination.map { String($0.prefix(4096)) }
        self.allocatedSize = allocatedSize; self.error = error.map { String($0.prefix(1000)) }
    }

    public static func batch(_ results: [TrashResult], source: String, time: Date = Date()) -> [OperationRecord] {
        let batch = UUID()
        return results.map {
            OperationRecord(batch: batch, time: time, source: source, path: $0.path, destination: $0.destination?.path, allocatedSize: $0.allocatedSize, error: $0.error)
        }
    }
}

public struct OperationLogPage: Sendable {
    public let records: [OperationRecord]
    public let skippedLines: Int
}

// JSON Lines 追加日志；超过上限轮转为 .1，只保留一份旧文件。内部加锁，可跨队列调用。
public final class OperationLog: @unchecked Sendable {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacEven")
    public let directory: URL
    public let maxBytes: Int64
    public var fileURL: URL { directory.appendingPathComponent("operations.log") }
    public var rotatedURL: URL { directory.appendingPathComponent("operations.1.log") }
    private let lock = NSLock()

    public init(directory: URL = OperationLog.defaultDirectory, maxBytes: Int64 = 5 * 1024 * 1024) {
        self.directory = directory; self.maxBytes = max(1024, maxBytes)
    }

    public func append(_ records: [OperationRecord]) throws {
        guard !records.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records { data.append(try encoder.encode(record)); data.append(0x0A) }
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let folder = try FileIdentity.read(directory)
            guard folder.isDirectory, !folder.isSymlink else { throw MacEvenError(localized("日志目录不是实际目录：\(directory.path)")) }
            if let current = try? FileIdentity.read(fileURL) {
                guard current.isRegular else { throw MacEvenError(localized("日志文件不是普通文件：\(fileURL.path)")) }
                if current.size + Int64(data.count) > maxBytes {
                    if (try? FileIdentity.read(rotatedURL)) != nil { try FileManager.default.removeItem(at: rotatedURL) }
                    try FileManager.default.moveItem(at: fileURL, to: rotatedURL)
                }
            }
            let fd = fileURL.withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            guard fd >= 0 else { throw MacEvenError(localized("无法打开操作日志：\(String(cString: strerror(errno)))")) }
            defer { close(fd) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw MacEvenError(localized("写入操作日志失败：\(String(cString: strerror(errno)))")) }
                    offset += written
                }
            }
        }
    }

    /// 最近记录，新的在前。每个文件只读末尾 1 MiB，损坏行跳过并计数。
    public func recent(limit: Int = 100) throws -> OperationLogPage {
        let limit = max(0, min(limit, 1000))
        return try lock.withLock {
            var records: [OperationRecord] = []
            var skipped = 0
            for url in [fileURL, rotatedURL] where records.count < limit {
                let (values, bad) = try tail(url, limit: limit - records.count)
                records += values; skipped += bad
            }
            return OperationLogPage(records: records, skippedLines: skipped)
        }
    }

    private func tail(_ url: URL, limit: Int) throws -> ([OperationRecord], Int) {
        let info: FileIdentity
        do { info = try FileIdentity.read(url) } catch {
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) { return ([], 0) }
            throw error
        }
        guard info.isRegular else { throw MacEvenError(localized("日志文件不是普通文件：\(url.path)")) }
        let window: Int64 = 1024 * 1024
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = max(0, info.size - window)
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: Int(window)) ?? Data()
        // 从中间开始读时丢掉第一段不完整的行。
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var values: [OperationRecord] = []
        var skipped = 0
        for line in data.split(separator: 0x0A).reversed() where values.count < limit {
            if let record = try? decoder.decode(OperationRecord.self, from: Data(line)) { values.append(record) } else { skipped += 1 }
        }
        return (values, skipped)
    }
}
