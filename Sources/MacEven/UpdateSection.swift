import SwiftUI
import AppKit
import MacEvenCore

private typealias UpdateViewState<Value> = SwiftUI.State<Value>

/// 软件更新设置区块：检查更新、下载进度展示、签名防篡改验证与自动安装重启
public struct UpdateSection: View {
    @ObservedObject private var checker = UpdateChecker.shared
    @UpdateViewState private var lastError: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: statusIconName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(statusIconColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(statusIconBg)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("当前版本：v\(checker.currentAppVersion) (Build \(checker.currentBuildNumber))"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(statusDetailText)
                        .font(.system(size: 12))
                        .foregroundStyle(statusDetailColor)
                }

                Spacer(minLength: 12)

                actionButtons
            }

            if let lastError, !lastError.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ThemeHue.orange.ink)
                    Text(localized("上次升级失败：\(lastError)"))
                        .font(.system(size: 12))
                        .foregroundStyle(ThemeHue.orange.ink)
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            }

            if case .downloading(let progress) = checker.currentStatus {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text(localized("正在下载更新包... \(Int(progress * 100))%"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 4)
            }

            if case .updateAvailable(let version, let releaseURL, let downloadURL, let checksum) = checker.currentStatus {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("新版本 \(version) 已发布。自动安装将在后台解压、验证自签名证书与 SHA-256 完整性并安全重启。"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if let downloadURL = downloadURL, checksum != nil {
                            Button(localized("立即下载并更新")) {
                                checker.startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum) { _ in }
                            }
                            .buttonStyle(.evenPrimary)
                        }

                        Button(localized("查看更新日志")) {
                            NSWorkspace.shared.open(releaseURL)
                        }
                        .buttonStyle(.evenSecondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .cardStyle(padding: 16)
        .onAppear {
            lastError = checker.checkLastUpdateError()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch checker.currentStatus {
        case .idle, .upToDate, .failed:
            let isFailed: Bool = {
                if case .failed = checker.currentStatus { return true }
                return false
            }()
            Button(isFailed ? localized("重新检查") : localized("检查更新")) {
                checker.check(force: true) { _ in }
            }
            .buttonStyle(.evenSecondary)

        case .checking:
            ProgressView()
                .controlSize(.small)

        case .downloading:
            Text(localized("下载中…"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)

        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(localized("正在安装并重启…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }

        case .updateAvailable:
            EmptyView()
        }
    }

    private var statusIconName: String {
        switch checker.currentStatus {
        case .idle: return "arrow.triangle.2.circlepath"
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle.fill"
        case .updateAvailable: return "sparkles"
        case .downloading: return "arrow.down.circle.fill"
        case .installing: return "gearshape.2.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var statusIconColor: Color {
        switch checker.currentStatus {
        case .idle: return Theme.text
        case .checking: return ThemeHue.blue.ink
        case .upToDate: return ThemeHue.green.ink
        case .updateAvailable: return ThemeHue.blue.ink
        case .downloading: return ThemeHue.blue.ink
        case .installing: return ThemeHue.orange.ink
        case .failed: return ThemeHue.orange.ink
        }
    }

    private var statusIconBg: Color {
        switch checker.currentStatus {
        case .idle: return Theme.inset
        case .checking: return ThemeHue.blue.soft
        case .upToDate: return ThemeHue.green.soft
        case .updateAvailable: return ThemeHue.blue.soft
        case .downloading: return ThemeHue.blue.soft
        case .installing: return ThemeHue.orange.soft
        case .failed: return ThemeHue.orange.soft
        }
    }

    private var statusDetailText: String {
        switch checker.currentStatus {
        case .idle: return localized("点击右侧按钮检查 GitHub Releases 最新版本")
        case .checking: return localized("正在连接 GitHub 检查新版本…")
        case .upToDate: return localized("已是最新版本")
        case .updateAvailable(let version, _, _, _): return localized("发现新版本 \(version)")
        case .downloading: return localized("正在下载发布包…")
        case .installing: return localized("解压完成，正在校验签名并原子替换重启…")
        case .failed(let msg): return localized("检查失败：\(msg)")
        }
    }

    private var statusDetailColor: Color {
        switch checker.currentStatus {
        case .upToDate: return ThemeHue.green.ink
        case .updateAvailable: return ThemeHue.blue.ink
        case .failed: return ThemeHue.orange.ink
        default: return Theme.muted
        }
    }
}
