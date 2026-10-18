import SwiftUI

// 底部操作栏：页面底色加深（浅色加白）+ 顶部 hairline；说明文字只在高级模式显示，确认窗口仍列出完整注意事项。
struct ActionBar<Buttons: View>: View {
    let summary: String
    var note: String?
    @ViewBuilder var buttons: () -> Buttons
    @Environment(\.advancedMode) private var advanced

    init(_ summary: String, note: String? = nil, @ViewBuilder buttons: @escaping () -> Buttons) {
        self.summary = summary; self.note = note; self.buttons = buttons
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 12) {
                Text(summary).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1).layoutPriority(1)
                Spacer(minLength: 12)
                if advanced, let note { Text(note).font(.caption).foregroundStyle(Theme.muted).lineLimit(2) }
                buttons()
            }
            .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
        }
        .background(PageGround.barShade)
    }
}

extension View {
    // 破坏性入口：danger-fill 红色实心药丸，全 App 唯一的红色实心入口。
    func destructiveEntryStyle() -> some View { buttonStyle(.evenDanger) }
    // 确认弹层中的执行按钮：data-danger 描边，『取消』才是默认按钮。
    func destructiveConfirmStyle() -> some View { buttonStyle(.evenDangerOutline) }
}
