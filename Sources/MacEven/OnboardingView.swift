import SwiftUI
import AppKit
import MacEvenCore

private typealias OnboardingViewState<Value> = SwiftUI.State<Value>

/// 首次启动引导视图：包含欢迎页、完全磁盘访问权限引导、辅助功能权限引导以及完成页。
public struct OnboardingView: View {
    public let onClose: () -> Void
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @OnboardingViewState private var currentStep: Int = 0

    private let totalSteps = 4

    public init(initialStep: Int = 0, onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
        _currentStep = OnboardingViewState(initialValue: initialStep)
    }

    public var body: some View {
        ZStack {
            PageGround.status.color
                .ignoresSafeArea()
            PageGround.status.gradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部分段进度条
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { index in
                        Capsule()
                            .fill(index <= currentStep ? Theme.accent : Theme.track.opacity(0.35))
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .animation(.easeInOut(duration: 0.25), value: currentStep)

                // 内容区域：按步骤显示
                ZStack {
                    switch currentStep {
                    case 0:
                        WelcomeStep()
                    case 1:
                        FDAStep()
                    case 2:
                        AccessibilityStep()
                    default:
                        CompletionStep()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .id(currentStep)

                // 底部导航
                HStack {
                    Text(verbatim: "\(currentStep + 1) / \(totalSteps)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.muted)

                    Spacer()

                    HStack(spacing: 10) {
                        if currentStep > 0 {
                            Button(localized("上一步")) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    currentStep -= 1
                                }
                            }
                            .buttonStyle(.evenSecondary)
                        }

                        if currentStep < totalSteps - 1 {
                            Button(localized("下一步")) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    currentStep += 1
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.evenPrimary)
                        } else {
                            Button(localized("开始使用")) {
                                hasCompletedOnboarding = true
                                onClose()
                            }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.evenPrimary)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
            }
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - Step 0: 欢迎页

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)

            Text(localized("欢迎使用 MacEven"))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 14)

            Text(localized("轻量、专业、透明的 macOS 系统监控与磁盘分析工具"))
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            HStack(spacing: 12) {
                FeatureHighlightCard(
                    icon: "sparkles",
                    title: localized("智能清理"),
                    description: localized("安全清理缓存、日志与临时文件"),
                    hue: .orange
                )
                FeatureHighlightCard(
                    icon: "internaldrive",
                    title: localized("完全磁盘分析"),
                    description: localized("大文件透视、重复文件与应用残留"),
                    hue: .blue
                )
                FeatureHighlightCard(
                    icon: "chart.xyaxis.line",
                    title: localized("低开销实时监控"),
                    description: localized("原生采集 CPU、内存、网络与硬件健康"),
                    hue: .green
                )
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)

            Spacer(minLength: 0)
        }
    }
}

private struct FeatureHighlightCard: View {
    let icon: String
    let title: String
    let description: String
    var hue: ThemeHue = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hue.ink)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hue.soft)
                )

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 10)

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.top, 3)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

// MARK: - Step 外壳容器

private struct PermissionStepContainer<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.inset)
                    )

                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 12)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 44)
                    .padding(.top, 6)

                content
                    .frame(maxWidth: 460)
                    .padding(.top, 16)
            }
            .padding(.top, 20)
            .padding(.horizontal, 36)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Step 1: 完全磁盘访问权限（FDAStep）

private struct FDAStep: View {
    @OnboardingViewState private var hasFDA = FullDiskAccessChecker.check()

    var body: some View {
        PermissionStepContainer(
            icon: "internaldrive",
            title: localized("授予完全磁盘访问（推荐）"),
            subtitle: localized("用于扫描 ~/Library、Containers 等系统保护目录中的缓存与残留文件。可以先跳过，之后在设置中授权。")
        ) {
            PermissionBlock(
                title: localized("完全磁盘访问"),
                granted: hasFDA,
                grantedDetail: localized("已授权"),
                deniedDetail: localized("未授权 — 在 ~/Library、Containers 等受保护目录将无法扫描分析与清理"),
                explanation: localized("MacEven 需要「完全磁盘访问」权限，才能扫描系统保护目录、分析清理缓存与废纸篓残留文件、检测重复文件以及彻底卸载应用程序残留。"),
                openTitle: localized("打开系统设置授权…"),
                tip: localized("提示：版本更新后若授权失效，请在系统设置中点「-」删除旧项，再点「+」重新添加。"),
                steps: [
                    localized("1. 点击上方按钮，系统将自动跳转到「完全磁盘访问」列表"),
                    localized("2. 点击列表底部「+」，添加 MacEven.app（通常在 /Applications/MacEven.app）"),
                    localized("3. 打开 MacEven 旁边的开关"),
                    localized("4. 回到此处点击「重新检测」或直接切回应用自动检测"),
                ],
                onOpen: {
                    NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL)
                },
                onRecheck: refresh
            )
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        hasFDA = FullDiskAccessChecker.check()
    }
}

// MARK: - Step 2: 辅助功能权限（AccessibilityStep）

private struct AccessibilityStep: View {
    @OnboardingViewState private var hasAccessibility = AccessibilityChecker.check()

    var body: some View {
        PermissionStepContainer(
            icon: "accessibility",
            title: localized("授予辅助功能（可选）"),
            subtitle: localized("用于获取前台活跃应用状态与增强进程管理。可以先跳过，之后在设置中授权。")
        ) {
            PermissionBlock(
                title: localized("辅助功能"),
                granted: hasAccessibility,
                grantedDetail: localized("已授权"),
                deniedDetail: localized("未授权 — 无法获取完整前台应用状态与执行进阶进程管理"),
                explanation: localized("MacEven 可使用「辅助功能」权限获取前台应用运行状态、辅助进行进程退出与控制操作。该权限为可选增强权限。"),
                openTitle: localized("打开辅助功能设置…"),
                tip: localized("提示：版本更新后若授权失效，请在系统设置中点「-」删除旧项，再点「+」重新添加。"),
                steps: [
                    localized("1. 点击上方按钮，系统将自动跳转到「辅助功能」列表"),
                    localized("2. 找到 MacEven 并打开开关；如果列表里没有，点击「+」添加 MacEven.app"),
                    localized("3. 版本更新后若未生效：先选中 MacEven 点「-」删除旧项，再点「+」重新添加"),
                    localized("4. 回到此处点击「重新检测」或直接切回应用自动检测"),
                ],
                onOpen: {
                    NSWorkspace.shared.open(AccessibilityChecker.settingsURL)
                },
                onRecheck: refresh
            )
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        hasAccessibility = AccessibilityChecker.check()
    }
}

// MARK: - Step 3: 完成页（CompletionStep）

private struct CompletionStep: View {
    @OnboardingViewState private var showCheckmark = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(ThemeHue.green.soft)
                    .frame(width: 88, height: 88)

                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(ThemeHue.green.ink)
                    .scaleEffect(showCheckmark ? 1.0 : 0.5)
                    .opacity(showCheckmark ? 1.0 : 0.0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)
            }

            Text(localized("一切就绪！"))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 18)

            Text(localized("MacEven 已准备好为你服务。"))
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .padding(.top, 6)

            Text(localized("提示：可随时在菜单栏或主窗口使用。"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .padding(.top, 10)

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "menubar.arrow.up.rectangle")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                    Text(localized("状态栏菜单：实时监控 CPU、内存、网络与快捷操作"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().background(Theme.border)

                HStack(spacing: 12) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                    Text(localized("主窗口：深度磁盘扫描、大文件透视与应用卸载"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: 420)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .padding(.top, 22)

            Spacer(minLength: 0)
        }
        .onAppear {
            showCheckmark = true
        }
    }
}
