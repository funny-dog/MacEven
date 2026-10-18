import SwiftUI
import MacEvenCore
import AppKit

// 侧边栏 × Mole 设计系统（tokens.json）：深色为主、浅色同构；每页一种暖色底，卡片为半透明 surface。
extension Color {
    init(light: UInt32, dark: UInt32) { self.init(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1) }
    init(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255,
                alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

enum Theme {
    // 文字三档：在每个 ground-* 与 surface 上都 ≥4.5:1。
    static let text = Color(light: 0x211c14, dark: 0xf5f1ea)          // ink
    static let muted = Color(light: 0x5d564a, dark: 0xbdb5a6)         // ink-muted
    static let faint = Color(light: 0x6f6859, dark: 0xaaa391)         // ink-faint
    static let surface = Color(light: 0xffffff, lightAlpha: 0.72, dark: 0xffffff, darkAlpha: 0.06)
    static let surfaceRaised = Color(light: 0xffffff, lightAlpha: 1, dark: 0xffffff, darkAlpha: 0.14)
    static let inset = Color(light: 0x000000, lightAlpha: 0.06, dark: 0xffffff, darkAlpha: 0.10)    // chip-bg
    static let border = Color(light: 0x000000, lightAlpha: 0.10, dark: 0xffffff, darkAlpha: 0.10)   // hairline
    static let track = border
    static let controlBorder = Color(light: 0x7a7364, dark: 0x8f887a)
    static let canvas = PageGround.settings.color                         // 无页面上下文时的底色
    // 统一操作色：accent 用于链接、勾选与计数；白色药丸只给非破坏性主操作。
    static let primary = Color(light: 0xb4501f, dark: 0xf0a37f)       // accent
    static let accent = primary
    static let focusRing = Color(light: 0x1d4fd1, dark: 0xffd479)
    static let buttonFill = Color(light: 0x211c14, dark: 0xffffff)    // cta-bg
    static let buttonText = Color(light: 0xffffff, dark: 0x1c1810)    // cta-ink
    static let navActive = Color.white
    static let navActiveText = Color(light: 0x1c1810, dark: 0x1c1810)
    static let badge = Color(light: 0xc23566, dark: 0xd03f72)
    static let destructive = Color(light: 0xc4372b, dark: 0xd9453b)   // danger-fill：全 App 唯一的红色实心入口
    static let dangerText = Color(light: 0xc4372b, dark: 0xff8a80)    // data-danger
    static let warning = Color(light: 0xbf5a14, dark: 0xf09a62)       // data-heat
    static let info = ThemeHue.blue.base
    static let teal = ThemeHue.teal.base
    static let brand = Color(light: 0x5b47d6, dark: 0x7c6cf2)

    // data-*：只画曲线、柱、环、条，数字一律用 text。
    static let dataCPU = Color(light: 0x1f8f5f, dark: 0x6fd3a0)
    static let dataMemory = Color(light: 0xa8650a, dark: 0xe8b45a)
    static let dataDisk = Color(light: 0x3563c9, dark: 0x86a9f2)
    static let dataNetwork = Color(light: 0x137f8c, dark: 0x5fcad4)
    static let dataPower = Color(light: 0x3f8a1c, dark: 0xa7dc72)
    static let dataHeat = warning

    static let radiusCard: CGFloat = 16
    static let radiusControl: CGFloat = 10
    static let pagePadding: CGFloat = 28
    static let sidebarWidth: CGFloat = 232
    static let sidebarCollapsedWidth: CGFloat = 68
}

// 每页一种窗口底色（ground-*），侧边栏与内容区一起染色。
enum PageGround: Sendable {
    case status, scan, disk, clean, apps, settings
    var color: Color {
        switch self {
        case .status, .scan, .clean: Color(light: 0xf3eee1, dark: 0x2b2518)
        case .disk: Color(light: 0xf5ebe1, dark: 0x35241a)
        case .apps: Color(light: 0xf7e7e9, dark: 0x3a1f24)
        case .settings: Color(light: 0xeeeef0, dark: 0x272729)
        }
    }
    // 窗口顶部略亮（深色混 6% 白、浅色混 45% 白），向下 38% 处回到底色。
    var gradient: LinearGradient {
        LinearGradient(stops: [.init(color: Color(light: 0xffffff, lightAlpha: 0.45, dark: 0xffffff, darkAlpha: 0.06), location: 0),
            .init(color: .clear, location: 0.38)], startPoint: .top, endPoint: .bottom)
    }
    // 侧边栏：深色加深 28%，浅色加白 58%。
    static let sidebarShade = Color(light: 0xffffff, lightAlpha: 0.58, dark: 0x000000, darkAlpha: 0.28)
    // 底部操作栏：深色加深 16%，浅色加白 50%。
    static let barShade = Color(light: 0xffffff, lightAlpha: 0.50, dark: 0x000000, darkAlpha: 0.16)
}

/// 色相：base 用于图表与进度，soft 为卡片浅底，ink 为浅底上的标题 / 强调文字，deep 为浅底上的大数字，
/// action 为白字按钮底色（两种外观都保证白字对比度），top / bottom 为侧边栏图标渐变。
enum ThemeHue: CaseIterable, Sendable {
    case blue, violet, orange, green, pink, teal, gray

    private var values: (base: (UInt32, UInt32), soft: (UInt32, UInt32), ink: (UInt32, UInt32), deep: (UInt32, UInt32), action: (UInt32, UInt32), top: UInt32, bottom: UInt32) {
        switch self {
        case .blue: ((0x4b7bf5, 0x5b8cff), (0xedf2ff, 0x1b2540), (0x2f5fd6, 0x93b2ff), (0x17306e, 0xe0e8ff), (0x2f5fd6, 0x3d6fe8), 0x6f9dff, 0x3a6cf0)
        case .violet: ((0x8b67ee, 0x9b7bff), (0xf3efff, 0x271e40), (0x6b47d6, 0xbba5ff), (0x33206e, 0xece5ff), (0x6b47d6, 0x7652de), 0xa98bff, 0x7350e6)
        case .orange: ((0xf2913d, 0xff9f4d), (0xfff3e6, 0x3a2716), (0xa65a14, 0xffbd82), (0x5a3008, 0xffeadb), (0xa65a14, 0xb0621c), 0xffb46e, 0xef7f2a)
        case .green: ((0x3aa86b, 0x45c07c), (0xeaf7ef, 0x163020), (0x22754a, 0x82daa7), (0x12402a, 0xddf5e6), (0x22754a, 0x24804f), 0x62d396, 0x2c9b5c)
        case .pink: ((0xe95c87, 0xff6f98), (0xfdeef2, 0x3a1926), (0xb8345c, 0xffa2bd), (0x561528, 0xffe2ea), (0xb8345c, 0xbf3a63), 0xff8aac, 0xe04a78)
        case .teal: ((0x2aa3b5, 0x3cc0d2), (0xe8f6f8, 0x12303a), (0x146f7d, 0x82d8e4), (0x0d3d44, 0xdcf5f8), (0x146f7d, 0x16808f), 0x52cddd, 0x1b91a4)
        case .gray: ((0x8e8e99, 0x9a9aa5), (0xf0f0f4, 0x2c2c32), (0x5f5f6a, 0xbcbcc6), (0x2c2c33, 0xececf0), (0x5f5f6a, 0x5f5f6a), 0xa9a9b4, 0x77777f)
        }
    }
    var base: Color { Color(light: values.base.0, dark: values.base.1) }
    var soft: Color { Color(light: values.soft.0, dark: values.soft.1) }
    var ink: Color { Color(light: values.ink.0, dark: values.ink.1) }
    var deep: Color { Color(light: values.deep.0, dark: values.deep.1) }
    var action: Color { Color(light: values.action.0, dark: values.action.1) }
    var gradient: LinearGradient {
        LinearGradient(colors: [Color(light: values.top, dark: values.top), Color(light: values.bottom, dark: values.bottom)], startPoint: .top, endPoint: .bottom)
    }
}

// 当前页面的色相：链接与默认图表色跟随页面。由 ContentView 按页面注入。
private struct PageHueKey: EnvironmentKey { static let defaultValue = ThemeHue.blue }
extension EnvironmentValues {
    var pageHue: ThemeHue {
        get { self[PageHueKey.self] }
        set { self[PageHueKey.self] = newValue }
    }
}

// 当前页面的窗口底色：确认弹层等浮层沿用同一色系。
private struct PageGroundKey: EnvironmentKey { static let defaultValue = PageGround.settings }
extension EnvironmentValues {
    var pageGround: PageGround {
        get { self[PageGroundKey.self] }
        set { self[PageGroundKey.self] = newValue }
    }
}

// 分段堆叠条：目录占用构成。fractions 之和不必为 1，剩余显示为空轨道。
struct SegmentedBar: View {
    struct Segment: Identifiable { let id = UUID(); let fraction: Double; let color: Color; let label: String }
    let segments: [Segment]
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { g in
            // 先扣掉段间距再按比例分配，段数多时不会超出轨道。
            let available = max(0, g.size.width - 2 * CGFloat(max(segments.count - 1, 0)))
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: max(2, available * min(max(s.fraction, 0), 1)))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule().fill(Theme.track))
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\($0.label) \(Int($0.fraction * 100))%" }.joined(separator: localized("，")))
    }
}

// 保留徽章等“填色小标签”。
struct PillLabel: View {
    let text: String
    var tint: Color?
    @Environment(\.pageHue) private var hue
    var body: some View {
        let tint = tint ?? hue.ink
        return Text(text).font(.caption.weight(.medium)).foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// 主按钮：cta 白色药丸（深色）/ 墨色药丸（浅色），只给非破坏性主操作。
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(large ? .system(size: 14, weight: .bold) : .body.weight(.semibold)).foregroundStyle(Theme.buttonText)
            .padding(.horizontal, large ? 30 : 20).frame(minHeight: large ? 46 : 32)
            .background(Theme.buttonFill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .shadow(color: .black.opacity(large ? 0.30 : 0.18), radius: large ? 11 : 4, y: large ? 6 : 2)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

// 次按钮：透明药丸 + control-border 描边（ghost）。
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 16).frame(minHeight: 30)
            .background(Theme.surface.opacity(configuration.isPressed ? 1 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

// 『移到废纸篓』入口：danger-fill 红色实心药丸，白字。
struct DangerPillButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(large ? .system(size: 14, weight: .bold) : .body.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, large ? 30 : 20).frame(minHeight: large ? 46 : 32)
            .background(Theme.destructive.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

// 确认弹层里的『移到废纸篓』：data-danger 描边的次级按钮，不是红色实心。
struct DangerOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.medium)).foregroundStyle(Theme.dangerText)
            .padding(.horizontal, 16).frame(minHeight: 32)
            .background(Theme.dangerText.opacity(configuration.isPressed ? 0.12 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.dangerText, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var evenPrimary: PrimaryButtonStyle { .init() }
    static var evenHero: PrimaryButtonStyle { .init(large: true) }
}
extension ButtonStyle where Self == SecondaryButtonStyle { static var evenSecondary: SecondaryButtonStyle { .init() } }
extension ButtonStyle where Self == DangerPillButtonStyle { static var evenDanger: DangerPillButtonStyle { .init() } }
extension ButtonStyle where Self == DangerOutlineButtonStyle { static var evenDangerOutline: DangerOutlineButtonStyle { .init() } }

// 链接按钮：accent 文字，按下变淡；替代系统蓝的 .link 样式。
struct EvenLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Theme.accent).opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}
extension ButtonStyle where Self == EvenLinkButtonStyle { static var evenLink: EvenLinkButtonStyle { .init() } }

// 表格 / 列表放进半透明圆角卡：隐藏系统底，裁圆角并描边；关闭斑马纹，避免空白区域画出空行。
extension View {
    func tableCard() -> some View {
        alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}
