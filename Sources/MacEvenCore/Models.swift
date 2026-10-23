import Foundation
import Darwin

public func canonicalFileURL(_ url: URL) throws -> URL {
    guard let resolved = url.withUnsafeFileSystemRepresentation({ realpath($0, nil) }) else {
        throw MacEvenError(localized("无法解析路径：\(url.path)"))
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}

public struct MacEvenError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.withLock { value = true } }
    public var isCancelled: Bool { lock.withLock { value } }
}

public struct FileIdentity: Equatable, Sendable {
    public let device: Int64
    public let inode: Int64
    public let mode: Int64
    public let size: Int64
    public let modified: Int64
    public let changed: Int64
    public let allocated: Int64
    public var isDirectory: Bool { mode & Int64(S_IFMT) == Int64(S_IFDIR) }
    public var isRegular: Bool { mode & Int64(S_IFMT) == Int64(S_IFREG) }
    public var isSymlink: Bool { mode & Int64(S_IFMT) == Int64(S_IFLNK) }
    public static func read(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0, &info) }) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(url.path)：\(String(cString: strerror(code)))", NSFilePathErrorKey: url.path])
        }
        return FileIdentity(device: Int64(info.st_dev), inode: Int64(bitPattern: UInt64(info.st_ino)),
            mode: Int64(info.st_mode), size: info.st_size,
            modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
            allocated: Int64(info.st_blocks) * 512)
    }
}

public struct DiskEntry: Identifiable, Sendable {
    public let id: Int64
    public let parentID: Int64
    public let url: URL
    public let identity: FileIdentity
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let duplicate: Bool
    public var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    public var isDirectory: Bool { identity.isDirectory }
}

public struct ScanProgress: Sendable {
    public let visited: Int
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let currentPath: String
    public let elapsed: TimeInterval
    public let errors: Int
    public var unpathedErrors: Int = 0
    /// 候选列表类扫描（缓存、开发缓存、残留、应用）的当前单元与总数；单一目录扫描为 nil。
    public var completedUnits: Int? = nil
    public var totalUnits: Int? = nil

    /// 带上候选单元位置的副本。
    public func units(_ done: Int, of total: Int) -> ScanProgress {
        var value = self; value.completedUnits = done; value.totalUnits = total; return value
    }

    public var failedPathCount: Int {
        errors - unpathedErrors
    }

    public var errorCountDescription: String {
        unpathedErrors > 0 ? localized("\(failedPathCount) 个失败路径 · \(unpathedErrors) 个未定位错误") : localized("\(failedPathCount) 个失败路径")
    }
}

public struct ScanSummary: Sendable {
    public let rootID: Int64
    public let visited: Int
    public let cancelled: Bool
    public let errors: Int
    public let errorExamples: [String]
    public let elapsed: TimeInterval
    public var unpathedErrors: Int = 0
    public var issues: [ScanIssue] = []
    /// 重复文件扫描的遍历过滤计数：小于门槛、共享数据块（硬链接或 APFS 克隆）。
    public var filteredSmall: Int = 0
    public var filteredShared: Int = 0

    public var failedPathCount: Int {
        errors - unpathedErrors
    }

    public var errorCountDescription: String {
        unpathedErrors > 0 ? localized("\(failedPathCount) 个失败路径 · \(unpathedErrors) 个未定位错误") : localized("\(failedPathCount) 个失败路径")
    }

    public init(
        rootID: Int64,
        visited: Int,
        cancelled: Bool,
        errors: Int,
        errorExamples: [String],
        elapsed: TimeInterval,
        unpathedErrors: Int = 0,
        issues: [ScanIssue] = [],
        filteredSmall: Int = 0,
        filteredShared: Int = 0
    ) {
        self.rootID = rootID
        self.visited = visited
        self.cancelled = cancelled
        self.errors = errors
        self.errorExamples = errorExamples
        self.elapsed = elapsed
        self.unpathedErrors = unpathedErrors
        self.issues = issues
        self.filteredSmall = filteredSmall
        self.filteredShared = filteredShared
    }
}

/// 清理组「查看构成」的直接子项：聚合大小背后装了什么，两步内可见。只读，不引入新的扫描。
public struct CleanupCompositionEntry: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let allocatedSize: Int64
    public let isDirectory: Bool
    public let modifiedAt: Date?
    public init(url: URL, allocatedSize: Int64, isDirectory: Bool, modifiedAt: Date?) {
        self.url = url; self.allocatedSize = allocatedSize; self.isDirectory = isDirectory; self.modifiedAt = modifiedAt
    }
    public var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

/// 某个清理入口的直接子项构成：来自扫描索引快照，或打开弹层时的实时统计。
public struct CleanupComposition: Sendable, Equatable {
    public let root: URL
    public let entries: [CleanupCompositionEntry]
    /// 根目录的直接子项总数；entries 是按占用排序的前若干项。
    public let totalChildren: Int
    /// true 表示实时统计（父级没有扫描索引可用）；false 表示取自本次扫描的索引快照。
    public let measuredLive: Bool
    /// 统计中断或部分失败的原因；为 nil 时 entries 完整可信。
    public let issue: String?
    public init(root: URL, entries: [CleanupCompositionEntry], totalChildren: Int, measuredLive: Bool, issue: String? = nil) {
        self.root = root; self.entries = entries; self.totalChildren = totalChildren; self.measuredLive = measuredLive; self.issue = issue
    }
}
