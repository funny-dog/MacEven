import SwiftUI
import AppKit

// 页面骨架：26pt 页标题 + 副标题，页内二级切换放在右侧；底色由外壳的 ground-* 提供，这里保持透明。
struct PageScaffold<Accessory: View, Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title; self.subtitle = subtitle; self.accessory = accessory; self.content = content; self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).help(subtitle) }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) { accessory() }.fixedSize()
            }
            .padding(.horizontal, Theme.pagePadding).padding(.top, 22).padding(.bottom, 16)
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer()
        }
    }
}

extension PageScaffold where Footer == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, subtitle: subtitle, accessory: accessory, content: content) { EmptyView() }
    }
}
