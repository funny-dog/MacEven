import SwiftUI
import AppKit
import MacEvenCore

private typealias PermissionsViewState<Value> = SwiftUI.State<Value>

/// 系统权限设置区块：展示完全磁盘访问与辅助功能权限检测与引导
public struct PermissionsSection: View {
    @PermissionsViewState private var hasFDA = FullDiskAccessChecker.check()
    @PermissionsViewState private var hasAccessibility = AccessibilityChecker.check()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            HStack {
                Spacer()
                Button(localized("重新查看权限引导…")) {
                    NotificationCenter.default.post(name: .openOnboarding, object: nil)
                }
                .buttonStyle(.evenSecondary)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        hasFDA = FullDiskAccessChecker.check()
        hasAccessibility = AccessibilityChecker.check()
    }
}
