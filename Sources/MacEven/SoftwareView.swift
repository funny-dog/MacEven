import SwiftUI
import AppKit
import ServiceManagement
import MacEvenCore

extension SoftwareTab {
    // 显示标题与顺序只在视图层定义，rawValue 保持不变。
    static let displayOrder: [SoftwareTab] = [.uninstall, .updates, .startup]
    var title: String {
        switch self { case .uninstall: localized("卸载"); case .leftovers: localized("残留"); case .updates: localized("更新"); case .startup: localized("启动项") }
    }
}

struct SoftwareTabPicker: View {
    @ObservedObject var software: SoftwareModel
    @ObservedObject var removal: ApplicationRemovalModel
    private var tabs: [SoftwareTab] { SoftwareTab.displayOrder }
    var body: some View {
        Picker(localized("应用"), selection: $software.tab) {
            ForEach(tabs, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(software.busy || removal.busy)
    }
}

struct SoftwareView: View {
    @ObservedObject var software: SoftwareModel
    @ObservedObject var removal: ApplicationRemovalModel
    @ObservedObject var disk: AppModel
    @ObservedObject var cache: CacheModel
    @ObservedObject var duplicate: DuplicateModel
    @Environment(\.advancedMode) private var advanced
    private var otherBusy: Bool { disk.busy || disk.loading || cache.busy || removal.busy || duplicate.busy }
    private var filteredStartupCount: Int {
        software.startupItems.filter {
            $0.kind == .loginItem && (
                software.search.isEmpty
                || $0.displayName.localizedCaseInsensitiveContains(software.search)
                || $0.url.path.localizedCaseInsensitiveContains(software.search)
                || ($0.appName?.localizedCaseInsensitiveContains(software.search) ?? false)
            )
        }.count
    }
    var body: some View {
        Group {
            if software.tab == .uninstall {
                ApplicationRemovalView(removal: removal, software: software, disk: disk, cache: cache).disabled(software.busy || duplicate.busy)
            } else { managementBody }
        }
        .onAppear {
            if software.tab == .startup && software.startupItems.isEmpty && !software.busy { software.refreshStartup() }
        }
        .onChange(of: software.tab) { _, newTab in
            software.offset = 0; software.search = ""; software.dismissConfirmation()
            if newTab == .startup && software.startupItems.isEmpty && !software.busy { software.refreshStartup() }
        }
        .sheet(item: Binding(get: { software.confirmation }, set: { if $0 == nil { software.dismissConfirmation() } })) { frozen in
            VStack(alignment: .leading, spacing: 16) {
                Text(confirmationTitle(frozen)).font(.title3.bold())
                if let entry = frozen.entry {
                    Text("\(entry.name) · \(entry.version) → \(entry.latestVersion ?? localized("未知"))").monospacedDigit()
                    Text(entry.url?.path ?? entry.id).font(.callout).textSelection(.enabled).cardStyle(padding: 10)
                    Text(localized("通过 Homebrew 安装，可能下载并更新所需依赖。不会替你退出正在运行的应用。安装开始后请等待完成；关闭窗口不取消安装，退出会等待当前操作结束。失败后请重新检查实际版本。"))
                } else if !frozen.entries.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(frozen.entries) { item in
                                HStack {
                                    Text(item.name).font(.headline)
                                    Spacer()
                                    Text("\(item.version) → \(item.latestVersion ?? localized("未知"))")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(Theme.muted)
                                }
                                Text(item.url?.path ?? item.id)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                if item.id != frozen.entries.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .cardStyle(padding: 10)
                    Text(localized("通过 Homebrew 串行升级以上 \(frozen.entries.count) 个软件，可能下载并更新所需依赖。不会替你退出正在运行的应用。更新开始后请等待完成；关闭窗口不取消更新，退出会等待当前操作结束。单项失败将记录并继续下一项。"))
                }
                if let item = frozen.startup {
                    HStack(spacing: 12) {
                        AppIcon(path: item.appURL?.path ?? item.program?.path ?? item.url.path, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName).font(.headline)
                            Text(item.appURL?.path ?? localized("登录时打开")).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Text(item.url.path).font(.callout).textSelection(.enabled).cardStyle(padding: 10)
                    Text(localized("从 macOS 登录项中移除此应用；不会删除应用程序本身，随后可在「添加启动项」或系统设置中重新添加。"))
                }
                HStack {
                    Spacer()
                    Button(localized("取消"), action: software.dismissConfirmation).keyboardShortcut(.defaultAction)
                    Button(confirmButtonTitle(frozen), action: software.execute)
                }.background { Button("", action: software.dismissConfirmation).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
            }.padding(24).frame(width: 600)
        }
    }

    private var statusText: String {
        if software.tab == .startup && software.status == localized("点击检查更新；不会自动升级软件") {
            return localized("支持管理开机登录自启应用")
        }
        return software.status
    }

    private var managementBody: some View {
        PageScaffold(localized("应用"), subtitle: software.tab == .updates ? localized("检查可用更新；不会自动升级软件") : localized("管理开机登录时自动启动的应用程序")) {
            SoftwareTabPicker(software: software, removal: removal)
            if software.checking { Button(localized("取消检查"), action: software.cancel) }
            else if software.tab == .startup {
                Button(localized("添加启动项")) { software.promptAddStartupItem() }
                    .buttonStyle(.evenPrimary).disabled(software.busy || otherBusy)
                Button(localized("刷新")) { software.refreshStartup() }
                    .disabled(software.busy || otherBusy)
            } else {
                if !software.upgradableEntries.isEmpty {
                    Button(localized("一键更新 (\(software.upgradableEntries.count))")) { software.prepareUpgradeAll() }
                        .buttonStyle(.evenPrimary).disabled(software.busy || otherBusy)
                }
                if !software.appStoreUpdatableEntries.isEmpty {
                    Button(localized("在 App Store 中更新 (\(software.appStoreUpdatableEntries.count))")) {
                        NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
                    }
                    .help(localized("打开 App Store 的软件更新页，由商店的「全部更新」一次安装以上商店应用"))
                    .disabled(software.busy || otherBusy)
                }
                if software.upgradableEntries.isEmpty {
                    Button(localized("检查更新")) { software.refresh() }
                        .buttonStyle(.evenPrimary).disabled(software.busy || otherBusy)
                } else {
                    Button(localized("检查更新")) { software.refresh() }
                        .disabled(software.busy || otherBusy)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if advanced && software.tab == .updates {
                    InlineNotice(localized("Homebrew 支持确认后升级；Sparkle 与商店应用交给对应更新器安装。"),
                        message: localized("版本未知或检查失败，不代表已是最新。"), tone: .neutral)
                }
                HStack { if software.busy && !software.checkingUpdates { ProgressView().controlSize(.small) }; Text(statusText).textSelection(.enabled) }
                if software.checkingUpdates {
                    ScanProgressBar(estimate: software.progressEstimate,
                        caption: software.checkedCount.map { localized("\($0)/\(software.entries.count) 个应用") } ?? localized("正在读取应用列表…"))
                }
                if otherBusy { InlineNotice(localized("其他文件任务正在工作，请结束后再执行软件操作。"), tone: .neutral) }
                TextField(software.tab == .startup ? localized("搜索应用名称") : localized("搜索名称或路径"), text: $software.search).textFieldStyle(.roundedBorder).disabled(software.busy)
                if software.tab == .updates { updateTable } else { startupTable }
                Pager(page: software.offset / 100 + 1, canPrevious: software.offset > 0 && !software.busy,
                    canNext: !software.busy && (software.tab == .updates ? software.filteredEntries.count : filteredStartupCount) > software.offset + 100,
                    previous: { software.offset = max(0, software.offset - 100) }, next: { software.offset += 100 })
                if !software.errors.isEmpty {
                    DisclosureGroup(localized("检查问题（\(software.errors.count) 条）")) {
                        ScrollView { VStack(alignment: .leading) { ForEach(Array(software.errors.enumerated()), id: \.offset) { _, text in Text(text).font(.callout).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                    }
                }
            }.padding(.horizontal, Theme.pagePadding).padding(.vertical, 16)
        } footer: {
            if software.tab == .updates, let entry = software.selectedEntry {
                ActionBar("\(entry.name) · \(entry.version) → \(entry.latestVersion ?? localized("未知"))", note: entry.url?.path ?? entry.id) {
                    if let url = entry.url { Button(localized("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                    if entry.canUpgrade { Button(localized("升级…")) { software.prepareUpgrade(entry) }.buttonStyle(.evenPrimary).disabled(software.busy || otherBusy) }
                    else if entry.source == .appStore { Button(localized("在 App Store 更新")) { NSWorkspace.shared.open(entry.actionURL ?? URL(string: "macappstore://showUpdatesPage")!) }.disabled(software.busy) }
                    else if let url = entry.url { Button(localized("打开应用更新")) { NSWorkspace.shared.open(url) }.disabled(software.busy) }
                }
            } else if software.tab == .startup, let item = software.selectedStartup {
                ActionBar(item.displayName, note: item.appURL?.path ?? item.url.path) {
                    if let appURL = item.appURL ?? (FileManager.default.fileExists(atPath: item.url.path) ? item.url : nil) {
                        Button(localized("在 Finder 中显示应用")) { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
                    }
                    Button(localized("移除启动项…")) { software.prepareStartup(item, enabled: false) }
                        .buttonStyle(.evenPrimary).disabled(software.busy || otherBusy)
                }
            }
        }
    }

    private var updateTable: some View {
        Table(software.visibleEntries, selection: $software.selection) {
            TableColumn(localized("软件")) { entry in
                HStack(spacing: 8) { AppIcon(path: entry.url?.path, size: 22); Text(entry.name).lineLimit(1) }
            }.width(min: 150, ideal: 200)
            TableColumn(localized("来源")) { Text(localizedText($0.source.rawValue)) }.width(120)
            TableColumn(localized("已安装")) { Text($0.version).monospacedDigit() }.width(85)
            TableColumn(localized("可用版本")) { Text($0.latestVersion ?? localized("未知")).monospacedDigit() }.width(85)
            TableColumn(localized("状态")) { entry in
                if entry.hasUpdate && entry.blockedReason == nil { StatusChip(text: entry.note, tone: .good).help(entry.note) }
                else { Text(entry.blockedReason ?? entry.note).lineLimit(2).foregroundStyle(Theme.muted).help(entry.blockedReason ?? entry.note) }
            }
        }.tableCard().disabled(software.busy)
    }
    private var startupTable: some View {
        Table(software.visibleStartupItems, selection: $software.startupSelection) {
            TableColumn(localized("应用")) { item in
                HStack(spacing: 10) {
                    AppIcon(path: item.appURL?.path ?? item.program?.path ?? item.url.path, size: 28)
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .help(localized("\(item.displayName)\n路径：\(item.appURL?.path ?? item.url.path)"))
            }.width(min: 200, ideal: 260)
            TableColumn(localized("路径")) { item in
                Text(item.appURL?.path ?? item.url.path)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }.width(min: 220, ideal: 340)
            TableColumn(localized("状态")) { item in
                if item.running == true {
                    StatusChip(text: localized("运行中"), tone: .good)
                } else {
                    StatusChip(text: localized("已启用"), tone: .neutral)
                }
            }.width(85)
            TableColumn(localized("操作")) { item in
                Button(localized("移除")) { software.prepareStartup(item, enabled: false) }
                    .controlSize(.small)
            }.width(75)
        }.tableCard().disabled(software.busy)
    }
    private func state(_ value: Bool?) -> String { value.map { $0 ? localized("是") : localized("否") } ?? localized("未知") }
    private func confirmationTitle(_ frozen: SoftwareConfirmation) -> String {
        if frozen.startup != nil { return localized("确认移除登录项？") }
        if frozen.entry != nil { return localized("确认升级软件？") }
        return localized("确认一键更新 \(frozen.entries.count) 个软件？")
    }
    private func confirmButtonTitle(_ frozen: SoftwareConfirmation) -> String {
        if frozen.startup != nil { return localized("确认移除") }
        if frozen.entry != nil { return localized("确认执行") }
        return localized("确认更新")
    }
}
