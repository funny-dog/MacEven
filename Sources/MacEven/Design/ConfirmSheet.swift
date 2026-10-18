import SwiftUI
import MacEvenCore

struct ConfirmPath: Identifiable {
    let path: String
    var size: String?
    var id: String { path }
}

// 移到废纸篓确认框版式：数量与占用、前 8 条完整路径（其余可展开）、说明、“取消”为默认按钮。
struct TrashConfirmationLayout<Extra: View>: View {
    let title: String
    let summary: String
    let paths: [ConfirmPath]
    let notes: [String]
    var confirmTitle = localized("移到废纸篓")
    var confirmDisabled = false
    let cancel: () -> Void
    let confirm: () -> Void
    @ViewBuilder var extra: () -> Extra
    @Environment(\.pageGround) private var ground

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash").font(.title2).foregroundStyle(Theme.dangerText)
                    .frame(width: 40, height: 40).background(Theme.dangerText.opacity(0.14), in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold())
                    Text(summary).foregroundStyle(Theme.muted).monospacedDigit()
                }
            }
            extra()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(paths.prefix(8))) { row($0) }
                    if paths.count > 8 {
                        DisclosureGroup(localized("显示其余 \(paths.count - 8) 项")) {
                            ForEach(Array(paths.dropFirst(8))) { row($0) }
                        }.padding(.vertical, 6)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 220)
            .cardStyle(padding: 10)
            Text(paths.count > 8 ? localized("完整路径，默认列出前 8 项，其余可展开查看。") : localized("完整路径。")).font(.caption).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                // 『移到废纸篓』是 data-danger 描边的次级按钮；『取消』是药丸主按钮且为默认按钮，Esc 同样取消。
                Button(confirmTitle, role: .destructive, action: confirm).destructiveConfirmStyle().disabled(confirmDisabled)
                Button(localized("取消"), action: cancel).keyboardShortcut(.defaultAction).buttonStyle(.evenPrimary)
            }.background {
                Button("", action: cancel).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
        }
        .padding(24).frame(width: 620)
        .foregroundStyle(Theme.text)
        .background { ZStack { ground.color; PageGround.sidebarShade } }
    }

    private func row(_ item: ConfirmPath) -> some View {
        HStack(alignment: .top) {
            Text(item.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if let size = item.size { Text(size).font(.callout).monospacedDigit().foregroundStyle(Theme.muted) }
        }.padding(.vertical, 4)
    }
}

extension TrashConfirmationLayout where Extra == EmptyView {
    init(title: String, summary: String, paths: [ConfirmPath], notes: [String], confirmTitle: String = localized("移到废纸篓"), confirmDisabled: Bool = false, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.init(title: title, summary: summary, paths: paths, notes: notes, confirmTitle: confirmTitle, confirmDisabled: confirmDisabled, cancel: cancel, confirm: confirm) { EmptyView() }
    }
}
