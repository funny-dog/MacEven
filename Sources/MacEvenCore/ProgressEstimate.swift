import Foundation

/// 扫描进度的展示值：fraction 为 nil 表示总数未知；estimated 表示分母来自估算（显示“约”，未完成时不超过 99%）。
public struct ProgressEstimate: Sendable, Equatable {
    public let fraction: Double?
    public let estimated: Bool

    public init(fraction: Double?, estimated: Bool) {
        self.fraction = fraction.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        self.estimated = estimated
    }

    public static let unknown = ProgressEstimate(fraction: nil, estimated: false)

    /// 已知总数：第 done/total 项。分母为 0 视为未知。
    public static func units(_ done: Int, of total: Int) -> ProgressEstimate {
        guard total > 0 else { return .unknown }
        return ProgressEstimate(fraction: Double(min(max(done, 0), total)) / Double(total), estimated: false)
    }

    /// 估算总数：实际可能超过估算，未完成时封顶 99%。
    public static func expected(_ current: Double, of total: Double) -> ProgressEstimate {
        guard total > 0, current.isFinite, total.isFinite else { return .unknown }
        return ProgressEstimate(fraction: min(max(current, 0) / total, 0.99), estimated: true)
    }

    /// 分段加权：第 index 段（从 0 开始）在 weights 中的区间内按 inner 前进。
    /// inner 未知时停在该段起点；结果总是估算值，除非全部段都是精确值且 exact 为 true。
    public static func phases(_ weights: [Double], index: Int, inner: ProgressEstimate, exact: Bool = false) -> ProgressEstimate {
        let total = weights.reduce(0) { $0 + max($1, 0) }
        guard total > 0, weights.indices.contains(index) else { return .unknown }
        let before = weights.prefix(index).reduce(0) { $0 + max($1, 0) }
        let within = max(weights[index], 0) * (inner.fraction ?? 0)
        let value = (before + within) / total
        let estimated = !exact || inner.estimated
        return ProgressEstimate(fraction: estimated ? min(value, 0.99) : value, estimated: estimated)
    }

    /// 0–100 的整数百分比；未知时为 nil。
    public var percent: Int? {
        fraction.map { Int(($0 * 100).rounded(.down)) }
    }

    /// “45%” 或 “约 45%”；未知时为 nil。
    public var percentText: String? {
        percent.map { estimated ? localized("约 \($0)%") : "\($0)%" }
    }
}
