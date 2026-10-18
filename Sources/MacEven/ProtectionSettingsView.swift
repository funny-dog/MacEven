import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacEvenCore

private typealias ProtectionViewState<Value> = SwiftUI.State<Value>

// 设置页“保护列表”卡片内容：只增加限制，不放开任何既有保护。
struct ProtectionListSection: View {
    @EnvironmentObject var protection: ProtectionModel
    @ProtectionViewState private var identifier = ""
    @ProtectionViewState private var confirmReset = false

    var body: some View {
        Text(localized("列表中的路径（连同其中内容）和应用标识（连同以“标识.”开头的条目）不会被任何清理功能移到废纸篓；执行前会再次核对最新列表。"))
            .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        if let error = protection.loadError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).textSelection(.enabled)
            Button(localized("重置保护列表…"), role: .destructive) { confirmReset = true }
        }
        if protection.entries.isEmpty {
            if protection.loadError == nil { Text(localized("尚未添加保护项。")).foregroundStyle(Theme.muted) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(protection.entries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.kind == .path ? "folder" : "app").foregroundStyle(Theme.muted).frame(width: 18)
                            Text(entry.value).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(entry.value)
                            Spacer(minLength: 8)
                            Text(entry.kind == .path ? localized("路径") : localized("应用标识")).font(.caption).foregroundStyle(Theme.muted)
                            Button(localized("移除")) { protection.remove(entry) }.buttonStyle(.borderless)
                        }
                    }
                }
            }.frame(maxHeight: 220)
        }
        Divider()
        HStack {
            Button(localized("添加文件夹或文件…")) { if let urls = choose(applications: false) { protection.addPaths(urls) } }
            Button(localized("添加应用…")) { if let urls = choose(applications: true) { protection.addApplications(urls) } }
        }.disabled(protection.loadError != nil)
        HStack {
            TextField(localized("应用标识，例如 com.example.app"), text: $identifier).textFieldStyle(.roundedBorder).onSubmit(addIdentifier)
            Button(localized("添加标识"), action: addIdentifier).disabled(identifier.trimmingCharacters(in: .whitespaces).isEmpty)
        }.disabled(protection.loadError != nil)
        if let message = protection.message { Text(message).font(.caption).foregroundStyle(Theme.warning).textSelection(.enabled) }
        Text(localized("共 \(protection.entries.count) / \(ProtectionStore.maxEntries) 条")).font(.caption).foregroundStyle(Theme.muted)
            .alert(localized("重置保护列表？"), isPresented: $confirmReset) {
                Button(localized("取消"), role: .cancel) {}
                Button(localized("备份并重置"), role: .destructive) { protection.reset() }
            } message: { Text(localized("无法读取的原文件会改名备份到同一目录，之后从空列表开始。")) }
    }

    private func addIdentifier() {
        if protection.addIdentifier(identifier) { identifier = "" }
    }

    private func choose(applications: Bool) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = !applications
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = localized("加入保护")
        if applications {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

// 设置页“操作记录”卡片内容：最近 100 条移到废纸篓尝试。
struct OperationRecordsSection: View {
    @EnvironmentObject var journal: OperationJournal

    var body: some View {
        Text(localized("记录每次移到废纸篓的尝试，包括失败与保留的项目，保存在 ~/Library/Logs/MacEven/operations.log。"))
            .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        if let failure = journal.failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).textSelection(.enabled) }
        if journal.skippedLines > 0 { Text(localized("有 \(journal.skippedLines) 行记录无法解析，已跳过。")).font(.caption).foregroundStyle(Theme.muted) }
        if journal.recent.isEmpty {
            Text(localized("暂无操作记录。")).foregroundStyle(Theme.muted)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(journal.recent) { record in row(record) }
                }
            }.frame(maxHeight: 300)
        }
        Divider()
        HStack {
            Button(localized("刷新")) { journal.reload() }
            Button(localized("在 Finder 中显示日志文件")) {
                let url = FileManager.default.fileExists(atPath: journal.log.fileURL.path) ? journal.log.fileURL : journal.log.directory
                if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func row(_ record: OperationRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(record)).foregroundStyle(record.moved ? (record.error == nil ? Theme.primary : Theme.warning) : Theme.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.path.isEmpty ? localized("（未指定路径）") : record.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(record.path)
                Text(detail(record)).font(.caption).foregroundStyle(Theme.muted).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let destination = record.destination, FileManager.default.fileExists(atPath: destination) {
                Button(localized("在废纸篓中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: destination)]) }.buttonStyle(.borderless)
            }
        }
    }

    private func icon(_ record: OperationRecord) -> String {
        record.moved ? (record.error == nil ? "checkmark.circle" : "exclamationmark.triangle") : "xmark.circle"
    }

    private func detail(_ record: OperationRecord) -> String {
        var parts = [record.time.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: localizationLocale)), OperationJournal.sourceName(record.source)]
        if let size = record.allocatedSize { parts.append(bytes(size)) }
        parts.append(record.moved ? localized("已移到废纸篓") : localized("未移动"))
        if let error = record.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}
