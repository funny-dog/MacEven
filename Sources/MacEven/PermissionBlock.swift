import SwiftUI
import MacEvenCore
import AppKit

/// 权限状态块：状态图标 + 标题 + 状态说明；未授权时展开说明、跳转按钮和授权步骤。
/// 访达扩展、完全磁盘访问与辅助功能共用，设置页与首次引导都放在卡片里使用。
public struct PermissionBlock: View {
    public let title: LocalizedStringKey
    public let granted: Bool
    /// 已授权时在标题下方显示的状态（默认「已授权」）
    public var grantedDetail: String
    /// 未授权时在标题下方显示的后果说明
    public let deniedDetail: String
    public let explanation: String
    public let openTitle: String
    public var tip: String?
    public let steps: [String]
    public let onOpen: () -> Void
    public let onRecheck: () -> Void

    public init(
        title: LocalizedStringKey,
        granted: Bool,
        grantedDetail: String = localized("已授权"),
        deniedDetail: String,
        explanation: String,
        openTitle: String,
        tip: String? = nil,
        steps: [String],
        onOpen: @escaping () -> Void,
        onRecheck: @escaping () -> Void
    ) {
        self.title = title
        self.granted = granted
        self.grantedDetail = grantedDetail
        self.deniedDetail = deniedDetail
        self.explanation = explanation
        self.openTitle = openTitle
        self.tip = tip
        self.steps = steps
        self.onOpen = onOpen
        self.onRecheck = onRecheck
    }

    public init(
        title: String,
        granted: Bool,
        grantedDetail: String = localized("已授权"),
        deniedDetail: String,
        explanation: String,
        openTitle: String,
        tip: String? = nil,
        steps: [String],
        onOpen: @escaping () -> Void,
        onRecheck: @escaping () -> Void
    ) {
        self.init(
            title: LocalizedStringKey(title),
            granted: granted,
            grantedDetail: grantedDetail,
            deniedDetail: deniedDetail,
            explanation: explanation,
            openTitle: openTitle,
            tip: tip,
            steps: steps,
            onOpen: onOpen,
            onRecheck: onRecheck
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                statusIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(granted ? grantedDetail : deniedDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(granted ? ThemeHue.green.ink : ThemeHue.orange.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !granted {
                Text(explanation)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: onOpen) {
                        Text(openTitle)
                    }
                    .buttonStyle(.evenPrimary)

                    Button(action: onRecheck) {
                        Text(localized("重新检测"))
                    }
                    .buttonStyle(.evenSecondary)
                }

                if let tip, !tip.isEmpty {
                    Text(tip)
                        .font(.system(size: 12))
                        .foregroundStyle(ThemeHue.orange.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Text(step)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(localized("授权步骤说明"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .cardStyle(padding: 16)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            onRecheck()
        }
    }

    private var statusIcon: some View {
        Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(granted ? ThemeHue.green.ink : ThemeHue.orange.ink)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(granted ? ThemeHue.green.soft : ThemeHue.orange.soft)
            )
    }
}
