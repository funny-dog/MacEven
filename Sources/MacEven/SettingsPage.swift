import SwiftUI
import MacEvenCore
import ServiceManagement

private typealias SettingsViewState<Value> = SwiftUI.State<Value>

// 设置页：界面模式、菜单栏显示、启动与窗口、通知、快捷工具；高级模式另有隐私指示、监控历史、保护列表、操作记录。
// 设置项仍绑定 StatusSettings、SystemTools、StatusNotifications，行为与 0.11.0 相同。
struct SettingsPage: View {
    @ObservedObject var monitor: MonitorModel
    @EnvironmentObject var settings: StatusSettings
    @EnvironmentObject var tools: SystemTools
    @EnvironmentObject var notifications: StatusNotifications
    @SettingsViewState private var confirmClear = false
    var body: some View {
        PageScaffold(localized("设置"), subtitle: settings.advancedMode ? localized("界面模式、菜单栏、系统权限、软件更新、快捷工具与清理保护") : localized("界面模式、菜单栏、系统权限与软件更新")) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(localized("界面模式")) {
                        row(localized("界面"), detail: localized("简洁模式隐藏专业指标、说明文字与进阶功能；高级模式为 beta，安全提示和确认窗口始终显示")) {
                            Picker(localized("界面"), selection: $settings.advancedMode) {
                                Text(localized("简洁")).tag(false)
                                Text(localized("高级 (beta)")).tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                        }
                    }
                    section(localized("菜单栏显示")) {
                        row(localized("第一项")) { metricPicker(localized("第一项"), selection: $settings.primaryMetric) }
                        Divider()
                        row(localized("第二项")) { metricPicker(localized("第二项"), selection: $settings.secondaryMetric) }
                        Divider()
                        row(localized("布局")) {
                            Picker(localized("布局"), selection: $settings.layoutStyle) {
                                ForEach(StatusLayoutStyle.allCases) { Text($0.displayName).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                        }
                        Divider()
                        row(localized("独立显示上传 / 下载网速")) { Toggle(localized("独立显示上传 / 下载网速"), isOn: $settings.showNetworkSpeed).labelsHidden().toggleStyle(.switch) }
                    }
                    section(localized("启动与窗口")) {
                        row(localized("仅菜单栏模式"), detail: localized("不显示 Dock 图标，启动时不打开主窗口")) {
                            Toggle(localized("仅菜单栏模式"), isOn: $settings.menuBarOnly).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        row(localized("登录时启动"), detail: localized("实际状态：\(loginStatusText)")) {
                            HStack {
                                if settings.loginItemStatus == .requiresApproval {
                                    Button(localized("打开登录项设置")) { SMAppService.openSystemSettingsLoginItems() }
                                }
                                Button(localized("刷新")) { settings.refreshLoginItemStatus() }.help(localized("刷新登录项实际状态"))
                                Toggle(localized("登录时启动"), isOn: Binding(get: { settings.loginItemStatus == .enabled || settings.loginItemStatus == .requiresApproval }, set: { try? settings.setLaunchAtLogin(enabled: $0) }))
                                    .labelsHidden().toggleStyle(.switch)
                            }
                        }
                        if let error = settings.loginItemError { Text(error).font(.caption).foregroundStyle(Theme.warning) }
                        Divider()
                        row(localized("全局快捷键"), detail: localized("Control + Option + Command + M 打开菜单栏面板")) {
                            Toggle(localized("全局快捷键"), isOn: $settings.globalHotkeyEnabled).labelsHidden().toggleStyle(.switch)
                        }
                        if let error = settings.hotkeyError { Text(error).font(.caption).foregroundStyle(Theme.warning) }
                    }
                    section(localized("通知")) {
                        row(localized("设备使用与低电量通知"), detail: localized("默认关闭；开启时才请求系统通知权限")) {
                            Toggle(localized("设备使用与低电量通知"), isOn: Binding(get: { notifications.enabled }, set: { notifications.setEnabled($0) })).labelsHidden().toggleStyle(.switch)
                        }
                        if let message = notifications.message { Text(message).font(.caption).foregroundStyle(Theme.warning) }
                    }
                    section(localized("快捷工具")) {
                        row(localized("屏幕常亮"), detail: tools.awakeUntil.map { localized("至 \($0.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: localizationLocale)))；睡眠和退出时取消") } ?? localized("睡眠和退出时取消")) {
                            HStack {
                                if tools.awakeUntil != nil { Button(localized("取消常亮"), action: tools.stopAwake) }
                                Menu(localized("开启")) {
                                    ForEach([15, 30, 60], id: \.self) { minutes in Button(localized("\(minutes) 分钟")) { tools.keepAwake(minutes: minutes) } }
                                }.fixedSize()
                            }
                        }
                        Divider()
                        row(localized("弹出外部卷"), detail: tools.volumes.isEmpty ? localized("没有可弹出的卷") : localized("\(tools.volumes.count) 个可弹出的卷")) {
                            HStack {
                                Button(localized("刷新列表"), action: tools.refreshVolumes)
                                Menu(localized("弹出")) {
                                    ForEach(tools.volumes, id: \.self) { url in
                                        Button(url.lastPathComponent) { Task { await tools.eject(url: url) } }.disabled(tools.volumeBusy)
                                    }
                                    if tools.volumes.isEmpty { Text(localized("没有可弹出卷")) }
                                }.fixedSize().disabled(tools.volumeBusy)
                            }
                        }
                        if let error = tools.error { Text(error).font(.caption).foregroundStyle(Theme.warning).textSelection(.enabled) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localized("系统权限")).font(.headline)
                        PermissionsSection()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localized("软件更新")).font(.headline)
                        UpdateSection()
                    }
                    if settings.advancedMode {
                        section(localized("隐私指示")) { PrivacyIndicators() }
                        section(localized("监控历史")) {
                            Text(localized("仅覆盖 MacEven 运行期间，保留最近 7 天，每分钟保存均值与峰值。不保存进程详情。")).font(.callout).foregroundStyle(Theme.muted)
                            if let error = monitor.historyError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
                            Button(localized("清除监控历史…"), role: .destructive) { confirmClear = true }
                        }
                        section(localized("保护列表")) { ProtectionListSection() }
                        section(localized("操作记录")) { OperationRecordsSection() }
                    }
                }.padding(Theme.pagePadding).frame(maxWidth: 720, alignment: .leading)
            }
        }
        .alert(localized("清除七天监控历史？"), isPresented: $confirmClear) {
            Button(localized("取消"), role: .cancel) {}
            Button(localized("清除历史"), role: .destructive) { monitor.clearHistory() }
        } message: { Text(localized("此操作会删除已保存的监控历史。实时采集会继续，之后的数据重新保存。")) }
    }

    private var loginStatusText: String {
        switch settings.loginItemStatus {
        case .enabled: localized("已开启")
        case .requiresApproval: localized("等待系统批准")
        case .notRegistered: localized("未开启")
        case .notFound: localized("未找到登录项")
        @unknown default: localized("未知")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }.cardStyle()
        }
    }

    private func row<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control()
        }.frame(minHeight: 28)
    }

    // 确认没有内置电池时不提供“电池电量”，已选中的保留以免选择失效。
    private func metricPicker(_ title: String, selection: Binding<StatusMetric>) -> some View {
        let noBattery = monitor.hardware.map { !$0.battery.isInstalled } ?? false
        let metrics = StatusMetric.allCases.filter { !(noBattery && $0 == .battery && selection.wrappedValue != .battery) }
        return Picker(title, selection: selection) { ForEach(metrics) { Text($0.displayName).tag($0) } }.labelsHidden().fixedSize()
    }
}
