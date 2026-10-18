import SwiftUI
import MacEvenCore

enum StatusTone {
    case good, warning, critical, neutral
    var color: Color {
        switch self { case .good: Theme.dataCPU; case .warning: Theme.warning; case .critical: Theme.dangerText; case .neutral: Theme.muted }
    }
    var symbol: String {
        switch self { case .good: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .critical: "xmark.octagon.fill"; case .neutral: "info.circle.fill" }
    }
}

// 圆角胶囊，无圆点；颜色只是辅助，文字必须存在。
struct StatusChip: View {
    let text: String
    var tone: StatusTone = .neutral
    var body: some View {
        Text(text).lineLimit(1)
            .font(.caption.weight(.medium)).foregroundStyle(tone.color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(tone == .neutral ? Theme.inset : tone.color.opacity(0.16), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

// 不可操作原因：高级模式显示完整原因；简洁模式只显示“运行中 / 受保护”短标签，完整原因在悬停说明。
struct ReasonChip: View {
    let reason: String
    @Environment(\.advancedMode) private var advanced
    private var running: Bool { reason.hasPrefix(localized("应用正在运行")) }
    var body: some View {
        StatusChip(text: advanced ? reason : running ? localized("运行中") : localized("受保护"), tone: advanced && running ? .warning : .neutral)
            .help(reason).accessibilityLabel(reason)
    }
}

// 提示条：浅底色，无描边。
struct InlineNotice<Actions: View>: View {
    let title: String
    var message: String?
    var tone: StatusTone = .warning
    @ViewBuilder var actions: () -> Actions

    init(_ title: String, message: String? = nil, tone: StatusTone = .warning, @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title; self.message = message; self.tone = tone; self.actions = actions
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: tone.symbol).foregroundStyle(tone.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(3)
                if let message { Text(message).font(.caption).foregroundStyle(Theme.muted).lineLimit(4) }
            }
            Spacer(minLength: 8)
            actions().fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .neutral ? Theme.surface : tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension InlineNotice where Actions == EmptyView {
    init(_ title: String, message: String? = nil, tone: StatusTone = .warning) {
        self.init(title, message: message, tone: tone) { EmptyView() }
    }
}

// 高占用进程：CPU 以单核心 100% 计，达到阈值即标记。标记与加粗数值同时出现，不单靠颜色。
enum ProcessHeat {
    static let cpuThreshold: Double = 30
    static func isHot(_ cpu: Double?) -> Bool { (cpu ?? 0) >= cpuThreshold }
}

// 行首 data-heat 竖条；不高占用时保留等宽空位，列不跳动。
struct HeatMarker: View {
    let hot: Bool
    var height: CGFloat = 16
    var body: some View {
        Capsule().fill(hot ? Theme.dataHeat : Color.clear).frame(width: 3, height: height)
            .accessibilityElement().accessibilityLabel(hot ? localized("高占用") : "").accessibilityHidden(!hot)
            .help(hot ? localized("CPU 占用不低于 \(Int(ProcessHeat.cpuThreshold))%（单核心计）") : "")
    }
}

// 进程 CPU 数值：高占用时加粗。
struct ProcessCPUText: View {
    let value: Double?
    var body: some View {
        Text(value.map { String(format: "%.1f%%", $0) } ?? localized("不可用")).monospacedDigit().fontWeight(ProcessHeat.isHot(value) ? .bold : .regular)
    }
}
