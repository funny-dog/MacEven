import SwiftUI
import AppKit
import MacEvenCore

/// 「查看构成」的加载与呈现状态：点击入口后异步取数，完成后以弹层展示；一次只显示一份构成。
@MainActor final class CleanupCompositionPresenter: ObservableObject {
    @Published var showing = false
    @Published private(set) var composition: CleanupComposition?
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    private var task: Task<Void, Never>?

    func load(_ provider: @escaping @MainActor () async -> CleanupComposition?) {
        guard !loading else { return }
        loading = true; loadError = nil; composition = nil; showing = true
        task = Task { [weak self] in
            let result = await provider()
            guard let self, !Task.isCancelled else { return }
            self.composition = result
            self.loadError = result == nil ? localized("暂时无法读取构成；请重新扫描后再试。") : nil
            self.loading = false
        }
    }

    func reset() {
        task?.cancel(); task = nil
        showing = false; composition = nil; loading = false; loadError = nil
    }
}

/// 弹层宿主：统计进行中显示进度，完成后显示构成清单。
struct CleanupCompositionSheetHost: View {
    @ObservedObject var presenter: CleanupCompositionPresenter
    @Environment(\.pageGround) private var ground

    var body: some View {
        Group {
            if presenter.loading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text(localized("正在统计构成，大目录可能需要一些时间…")).font(.callout).foregroundStyle(Theme.muted)
                    Button(localized("取消")) { presenter.reset() }
                        .buttonStyle(.evenSecondary).controlSize(.small)
                }
                .padding(28).frame(width: 420)
            } else if let composition = presenter.composition {
                CleanupCompositionSheet(composition: composition, close: { presenter.reset() })
            } else if let error = presenter.loadError {
                VStack(alignment: .leading, spacing: 12) {
                    InlineNotice(error, tone: .warning)
                    HStack {
                        Spacer()
                        Button(localized("好")) { presenter.reset() }.keyboardShortcut(.defaultAction).buttonStyle(.evenPrimary)
                    }
                }
                .padding(18).frame(width: 420)
            }
        }
    }
}

/// 清理组「查看构成」：聚合大小的直接子项构成（按占用排序）。只读，不在此清理任何内容。
struct CleanupCompositionSheet: View {
    let composition: CleanupComposition
    let close: () -> Void
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle").font(.title2).foregroundStyle(Theme.info)
                    .frame(width: 40, height: 40).background(Theme.info.opacity(0.14), in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("查看构成")).font(.title3.bold())
                    Text(summary).foregroundStyle(Theme.muted).monospacedDigit()
                }
                Spacer(minLength: 8)
                Button(localized("在 Finder 查看")) { NSWorkspace.shared.activateFileViewerSelecting([composition.root]) }
                    .buttonStyle(.evenSecondary).controlSize(.small)
            }
            Text(displayPath).font(.system(size: 11)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if let issue = composition.issue {
                InlineNotice(issue, tone: .warning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(composition.entries) { row($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 260)
            .cardStyle(padding: 10)
            Text(footnote).font(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(localized("完成"), action: close).keyboardShortcut(.defaultAction).buttonStyle(.evenPrimary)
            }
            .background {
                Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
        }
        .padding(18).frame(width: 560)
    }

    private var summary: String {
        let shown = composition.entries.reduce(0) { $0 + $1.allocatedSize }
        return localized("\(composition.totalChildren) 个子项 · 前 \(composition.entries.count) 项占用 \(bytes(shown))")
    }

    private var displayPath: String {
        composition.root.path.hasPrefix(home) ? "~" + composition.root.path.dropFirst(home.count) : composition.root.path
    }

    private var footnote: String {
        var text = composition.measuredLive
            ? localized("以上为打开弹层时的实时统计；目录子项的大小为完整遍历估算，不跟随符号链接。")
            : localized("以上来自本次扫描的索引快照；刚修改过内容时请重新扫描后查看。")
        if composition.totalChildren > composition.entries.count {
            text += localized(" 仅列出占用最大的前 \(composition.entries.count) 项。")
        }
        return text
    }

    private func row(_ entry: CleanupCompositionEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .font(.callout).foregroundStyle(entry.isDirectory ? Theme.info : Theme.muted)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .help(entry.name)
                if let date = entry.modifiedAt {
                    Text(localized("最后修改 ") + date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: localizationLocale)))
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
            Spacer(minLength: 8)
            Text(bytes(entry.allocatedSize)).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

/// 行内「查看构成」入口：小号链接样式按钮，点击后由共享 presenter 弹出构成。
struct CompositionButton: View {
    let label: String
    let provider: @MainActor () async -> CleanupComposition?
    @ObservedObject var presenter: CleanupCompositionPresenter

    var body: some View {
        Button(label) { presenter.load(provider) }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .disabled(presenter.loading)
            .help(localized("查看这一项里的直接子项构成"))
            .sheet(isPresented: $presenter.showing, onDismiss: { presenter.reset() }) {
                CleanupCompositionSheetHost(presenter: presenter)
            }
    }
}
