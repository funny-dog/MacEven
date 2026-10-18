import Foundation

public enum FileCategory: Int, CaseIterable, Sendable, Hashable {
    case other = 0, image, video, audio, document, archive, source

    public static func classify(_ url: URL) -> FileCategory {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp", "svg", "avif":
            return .image
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "mpeg", "mpg":
            return .video
        case "mp3", "wav", "flac", "m4a", "aac", "ogg", "aif", "aiff", "alac":
            return .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt", "md", "epub":
            return .document
        case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst", "dmg", "iso", "pkg":
            return .archive
        case "swift", "py", "js", "ts", "tsx", "jsx", "vue", "html", "css", "scss", "json", "yaml", "yml", "toml", "sql", "go", "rs", "c", "cpp", "h", "hpp", "java", "sh":
            return .source
        default:
            return .other
        }
    }
}

public struct SpaceFilter: Sendable, Equatable {
    public let category: FileCategory?
    public let minAllocated: Int64?
    public let maxAllocated: Int64?
    public let notModifiedSince: Int64? // epoch nanoseconds

    public init(
        category: FileCategory? = nil,
        minAllocated: Int64? = nil,
        maxAllocated: Int64? = nil,
        notModifiedSince: Int64? = nil
    ) throws {
        if let minAllocated, minAllocated < 0 {
            throw MacEvenError(localized("最小占用大小不能为负数"))
        }
        if let maxAllocated, maxAllocated < 0 {
            throw MacEvenError(localized("最大占用大小不能为负数"))
        }
        if let minAllocated, let maxAllocated, minAllocated > maxAllocated {
            throw MacEvenError(localized("最小占用大小不能大于最大占用大小"))
        }
        if let notModifiedSince, notModifiedSince < 0 {
            throw MacEvenError(localized("修改时间截止不能为负数"))
        }
        self.category = category
        self.minAllocated = minAllocated
        self.maxAllocated = maxAllocated
        self.notModifiedSince = notModifiedSince
    }
}

public struct SpaceCategoryStat: Sendable, Identifiable {
    public let category: FileCategory
    public var id: FileCategory { category }
    public let count: Int64
    public let allocatedSize: Int64

    public init(category: FileCategory, count: Int64, allocatedSize: Int64) {
        self.category = category
        self.count = count
        self.allocatedSize = allocatedSize
    }
}

public struct SpacePage: Sendable {
    public let entries: [DiskEntry]
    public let hasNext: Bool
    public let totalCount: Int64
    public let allocatedSize: Int64

    public init(entries: [DiskEntry], hasNext: Bool, totalCount: Int64, allocatedSize: Int64) {
        self.entries = entries
        self.hasNext = hasNext
        self.totalCount = totalCount
        self.allocatedSize = allocatedSize
    }
}
