import SwiftUI
import MacEvenCore

// 分页控件：数据层每页固定 100 项，这里只负责翻页与说明；简洁模式只显示页码。
struct Pager: View {
    let page: Int
    let canPrevious: Bool
    let canNext: Bool
    var note = localized("每页最多 100 项")
    let previous: () -> Void
    let next: () -> Void
    @Environment(\.advancedMode) private var advanced

    // 只有一页时不显示。
    var body: some View {
        if page > 1 || canNext { controls }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(localized("上一页"), action: previous).disabled(!canPrevious)
            Text(advanced ? localized("第 \(page) 页 · \(note)") : localized("第 \(page) 页")).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Button(localized("下一页"), action: next).disabled(!canNext)
        }.controlSize(.small)
    }
}
