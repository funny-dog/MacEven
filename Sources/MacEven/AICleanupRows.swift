import Foundation
import MacEvenCore

/// 「AI 清理与维护」会话与工作记录的分组行：
/// 按“多久没用”和“项目是否还在”把候选拆成可逐项确认的清单，避免把不可恢复的记录混在一起一把清空。
struct AICleanupRow: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case oldSessions
        case missingProjectSessions
        case recentSessions
        case snapshots
        case plans

        var title: String {
            switch self {
            case .oldSessions: localized("旧会话记录")
            case .missingProjectSessions: localized("项目已删除的会话")
            case .recentSessions: localized("近期活跃会话（不建议删除）")
            case .snapshots: localized("Claude Code 文件修改快照")
            case .plans: localized("Claude Code 任务计划记录")
            }
        }
    }

    let kind: Kind
    let detail: String
    let targets: [AIWorkCleanupTarget]

    var id: String { kind.rawValue }
    var title: String { kind.title }
    var count: Int { targets.count }
    var size: Int64 { targets.reduce(0) { $0 + $1.allocatedSize } }
    /// 会话文件移走后可能留下空的日期目录；行内如实说明。
    var leavesEmptyDirectories: Bool { targets.contains { $0.rule.isSessionFile } }
}

enum AICleanupRows {
    /// 「多久没用」的可选阈值（天）；默认 90 天，与常见工具自身的保留策略接近。
    static let ageOptions = [30, 90, 180, 365]

    /// 组装展示行：旧会话 → 项目已删除 → 其他会话 → 快照 → 计划；空行不出现。
    static func rows(groups: [AIWorkCleanupGroup], ageDays: Int, now: Date = Date()) -> [AICleanupRow] {
        let targets = groups.flatMap(\.targets)
        let sessions = targets.filter { $0.rule.isSessionFile }
        let cutoff = now.addingTimeInterval(-Double(ageDays) * 86_400)
        let old = sessions.filter { ($0.modifiedAt ?? now) < cutoff }
            .sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
        let oldIDs = Set(old.map(\.id))
        let missing = sessions.filter { !oldIDs.contains($0.id) && $0.projectMissing }
            .sorted { ($0.projectName ?? "", $0.url.path) < ($1.projectName ?? "", $1.url.path) }
        let missingIDs = Set(missing.map(\.id))
        let recent = sessions.filter { !oldIDs.contains($0.id) && !missingIDs.contains($0.id) }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }

        var rows: [AICleanupRow] = []
        if !old.isEmpty {
            var detail = localized("\(old.count) 个会话超过 \(ageDays) 天未修改")
            if old.contains(where: { $0.rule == .codexArchivedSessions }) { detail += localized("（含已归档）") }
            detail += provenance(old, prefix: localized("，主要来自 "))
            rows.append(AICleanupRow(kind: .oldSessions, detail: detail, targets: old))
        }
        if !missing.isEmpty {
            let detail = localized("\(missing.count) 个会话对应的项目文件夹已不存在") + provenance(missing, prefix: localized("，涉及 "))
            rows.append(AICleanupRow(kind: .missingProjectSessions, detail: detail, targets: missing))
        }
        if !recent.isEmpty {
            rows.append(AICleanupRow(kind: .recentSessions,
                detail: localized("\(recent.count) 个近期活跃会话，项目仍在维护，不建议删除"), targets: recent))
        }
        if let snapshots = groups.first(where: { $0.rule == .claudeFileHistory }), !snapshots.targets.isEmpty {
            rows.append(AICleanupRow(kind: .snapshots,
                detail: localized("用于恢复编辑前的文件内容；清除后无法再通过快照回滚"), targets: snapshots.targets))
        }
        if let plans = groups.first(where: { $0.rule == .claudePlans }), !plans.targets.isEmpty {
            rows.append(AICleanupRow(kind: .plans, detail: localized("任务计划与规划记录；清除后无法回顾历史任务"), targets: plans.targets))
        }
        return rows
    }

    /// 会话记录来源说明：最多列两个记录最多的项目名。
    private static func provenance(_ targets: [AIWorkCleanupTarget], prefix: String) -> String {
        var counts: [String: Int] = [:]
        for target in targets {
            guard let name = target.projectName else { continue }
            counts[name, default: 0] += 1
        }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(2).map(\.key)
        guard !top.isEmpty else { return "" }
        return prefix + top.joined(separator: localized("、")) + (counts.count > top.count ? localized(" 等") : "")
    }
}
