import Foundation

/// 一种用途标记的边界数量与归属字节（已分配块 × 512，硬链接只计一次）。
public struct PurposeTotal: Sendable, Equatable {
    public let tag: PurposeTag
    public let count: Int64
    public let bytes: Int64
    public init(tag: PurposeTag, count: Int64, bytes: Int64) { self.tag = tag; self.count = count; self.bytes = bytes }
}

public struct PurposePage: Sendable {
    public let entries: [DiskEntry]
    /// 条目 id → 归属这一用途的字节；可能小于整个文件夹的占用。
    public let bytes: [Int64: Int64]
    public let hasNext: Bool
}

/// 全盘按用途汇总。每个字节只归给离它最近的用途边界，所以各用途加上“未识别”等于扫描根的占用。
public struct PurposeSummary: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public let category: PurposeCategory
        public let bytes: Int64
        /// 有归属字节的位置数。
        public let count: Int64
        /// 用于分页查询该用途的全部标记。
        public let tags: [PurposeTag]
        public var id: PurposeCategory { category }
    }

    /// 扫描根的占用估算。
    public let total: Int64
    /// 按字节降序，只含字节数大于 0 的用途。
    public let groups: [Group]
    public let safetyBytes: [PurposeSafety: Int64]
    public var labeled: Int64 { groups.reduce(0) { $0 + $1.bytes } }
    public var unlabeled: Int64 { max(0, total - labeled) }

    public init(totals: [PurposeTotal], total: Int64, rules: [PurposeRule] = PurposeRule.builtIn) {
        self.total = total
        var bytes: [PurposeCategory: Int64] = [:], counts: [PurposeCategory: Int64] = [:], tags: [PurposeCategory: [PurposeTag]] = [:]
        var safety: [PurposeSafety: Int64] = [:]
        for item in totals where rules.indices.contains(item.tag.ruleIndex) {
            let category = rules[item.tag.ruleIndex].category
            tags[category, default: []].append(item.tag)
            guard item.bytes > 0 else { continue }
            bytes[category, default: 0] += item.bytes
            counts[category, default: 0] += item.count
            safety[item.tag.safety, default: 0] += item.bytes
        }
        groups = bytes.map { Group(category: $0.key, bytes: $0.value, count: counts[$0.key] ?? 0,
            tags: (tags[$0.key] ?? []).sorted { $0.rawValue < $1.rawValue }) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category.rawValue < $1.category.rawValue }
        safetyBytes = safety
    }
}
