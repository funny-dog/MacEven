import AppKit
import Combine
import Foundation
import ServiceManagement

@main
struct StatusToolsChecks {
    @MainActor
    static func main() async throws {
        print("--> 开始运行 StatusToolsChecks...")

        // 1. 临时 UserDefaults 注入测试 Settings 持久化
        // 域名会登记到 MACEVEN_TEST_DEFAULTS_LOG，进程退出后由 check-status.sh 删除残留 plist。
        let (tempDefaults, suiteName) = makeTestDefaults(prefix: "MacEven.Test.Settings")
        defer {
            tempDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = StatusSettings(defaults: tempDefaults)
        precondition(settings.primaryMetric == .cpu, "默认 primaryMetric 应为 cpu")
        precondition(settings.secondaryMetric == .ram, "默认 secondaryMetric 应为 ram")
        precondition(settings.showNetworkSpeed == false, "默认 showNetworkSpeed 应为 false")
        precondition(settings.layoutStyle == .stacked, "默认 layoutStyle 应为 stacked（新安装默认堆叠显示 CPU 与内存）")
        precondition(settings.menuBarOnly == false, "默认 menuBarOnly 应为 false")
        precondition(settings.globalHotkeyEnabled == false, "默认 globalHotkeyEnabled 应为 false")
        precondition(settings.pinnedExecutablePaths.isEmpty, "默认 pinnedExecutablePaths 应为空")
        precondition(settings.advancedMode == false, "默认界面应为简洁模式")

        // 修改并持久化
        settings.primaryMetric = .gpu
        settings.secondaryMetric = .thermal
        settings.showNetworkSpeed = true
        settings.layoutStyle = .horizontal
        settings.menuBarOnly = true
        settings.globalHotkeyEnabled = true
        settings.advancedMode = true

        // 重新实例化读取持久化
        let reloadedSettings = StatusSettings(defaults: tempDefaults)
        precondition(reloadedSettings.primaryMetric == .gpu, "持久化 primaryMetric 验证失败")
        precondition(reloadedSettings.secondaryMetric == .thermal, "持久化 secondaryMetric 验证失败")
        precondition(reloadedSettings.showNetworkSpeed == true, "持久化 showNetworkSpeed 验证失败")
        precondition(reloadedSettings.layoutStyle == .horizontal, "持久化 layoutStyle 验证失败（显式选择必须胜过新安装默认）")
        precondition(reloadedSettings.menuBarOnly == true, "持久化 menuBarOnly 验证失败")
        precondition(reloadedSettings.globalHotkeyEnabled == true, "持久化 globalHotkeyEnabled 验证失败")
        // 测试 none 指标持久化与重载
        settings.primaryMetric = .none
        settings.secondaryMetric = .none
        let reloadedNoneSettings = StatusSettings(defaults: tempDefaults)
        precondition(reloadedNoneSettings.primaryMetric == .none, "持久化 primaryMetric .none 验证失败")
        precondition(reloadedNoneSettings.secondaryMetric == .none, "持久化 secondaryMetric .none 验证失败")

        reloadedSettings.resetToDefaults()
        precondition(reloadedSettings.primaryMetric == .cpu, "resetToDefaults 应恢复 primaryMetric 为 cpu")
        precondition(reloadedSettings.secondaryMetric == .ram, "resetToDefaults 应恢复 secondaryMetric 为 ram")
        precondition(reloadedSettings.advancedMode == false, "resetToDefaults 应恢复简洁模式")
        precondition(reloadedSettings.layoutStyle == .stacked, "resetToDefaults 应恢复堆叠显示")
        precondition(StatusSettings(defaults: tempDefaults).advancedMode == false, "恢复简洁模式应写回持久化")
        print("PASS: 临时 UserDefaults settings 持久化")

        // 2. 验证 pin/path 不是 PID 且置顶持久化
        precondition(!StatusSettings.isValidExecutablePath("12345"), "纯数字 PID 必须被拒绝")
        precondition(!StatusSettings.isValidExecutablePath("9876"), "纯数字 PID 必须被拒绝")
        precondition(!StatusSettings.isValidExecutablePath(""), "空路径必须被拒绝")
        precondition(!StatusSettings.isValidExecutablePath("relative/path"), "相对路径必须被拒绝")

        let validPath = "/Applications/Safari.app/Contents/MacOS/Safari"
        precondition(StatusSettings.isValidExecutablePath(validPath), "合法绝对路径应被接受")

        let pinPidResult = settings.pin(path: "12345")
        precondition(!pinPidResult, "pin 纯数字 PID 必须返回 false")
        precondition(!settings.isPinned(path: "12345"), "纯数字 PID 不能进入 pinned 集合")

        let pinPathResult = settings.pin(path: validPath)
        precondition(pinPathResult, "pin 合法路径应返回 true")
        precondition(settings.isPinned(path: validPath), "合法路径应处于 pinned 状态")

        let reloadedWithPath = StatusSettings(defaults: tempDefaults)
        precondition(reloadedWithPath.isPinned(path: validPath), "置顶路径持久化验证失败")
        print("PASS: pin/path 验证与拒绝纯数字 PID")

        // 3. 验证默认不开启系统控制 / 默认不修改登录项
        precondition(settings.loginItemError == nil, "初始不应有登录项错误")

        let tools = SystemTools()
        precondition(tools.awakeUntil == nil, "默认常亮不应开启")
        precondition(tools.error == nil, "默认不应有系统工具错误")
        print("PASS: 默认不开启系统控制与默认状态安全")

        // 4. 常亮 duration validation（不操作真实设备）
        precondition(SystemTools.allowedMinutes == [15, 30, 60], "仅支持 15/30/60 分钟")

        // 验证非法时长
        tools.keepAwake(minutes: 5)
        precondition(tools.error != nil, "非法时长 5 分钟必须被拦截")
        precondition(tools.awakeUntil == nil, "非法时长不能开启常亮")

        tools.keepAwake(minutes: 45)
        precondition(tools.error != nil, "非法时长 45 分钟必须被拦截")
        precondition(tools.awakeUntil == nil, "非法时长不能开启常亮")

        tools.stopAwake()
        await tools.eject(url: URL(fileURLWithPath: "/"))
        precondition(tools.error != nil && !tools.volumeBusy, "根卷应在系统弹出调用前被拒绝")
        await tools.eject(url: URL(fileURLWithPath: "/tmp/MacEven-unmounted-test"))
        precondition(tools.error != nil && !tools.volumeBusy, "未枚举的挂载点应被拒绝")
        print("PASS: 常亮 duration validation 验证")

        print("--> StatusToolsChecks 全部通过！")
    }
}
