import SwiftUI
import MacEvenCore
import AppKit

// 卡片等高：在 HStack 上设置 cardFillsHeight 并 fixedSize 纵向，行内卡片撑满同一高度。
private struct CardFillsHeightKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var cardFillsHeight: Bool {
        get { self[CardFillsHeightKey.self] }
        set { self[CardFillsHeightKey.self] = newValue }
    }
}

// 卡片：半透明 surface + hairline 描边，圆角 16。unavailable 为“未取得 / 不适用”态：虚线框、无填充。
struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    var hue: ThemeHue?
    var unavailable = false
    @Environment(\.cardFillsHeight) private var fills
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
        content.padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(unavailable ? Color.clear : Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: unavailable ? [5, 4] : [])))
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16, hue: ThemeHue? = nil, unavailable: Bool = false) -> some View {
        modifier(CardStyle(padding: padding, hue: hue, unavailable: unavailable))
    }
}

// 卡片标题行：14px 线性图标（取 data 色，无数据时降为 faint）+ 标题，右上至多一个芯片。
struct CardHeader: View {
    let title: String
    var symbol: String?
    var tint: Color?
    var chip: String?
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint ?? Theme.faint).accessibilityHidden(true) }
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let chip { ChipLabel(text: chip) }
        }.frame(minHeight: 20)
    }
}

// 小标签（机型、温度、内存压力等）：chip-bg 底、ink-muted 字、圆角 6。
struct ChipLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// 指标卡：标题（图标 + 右上芯片）、34pt 大数字 + 降档单位、附加内容、一行脚注。数字一律用 text。
struct MetricCard<Content: View>: View {
    let title: String
    var detail: String?
    let value: String
    var unit: String?
    var caption: String?
    var hue: ThemeHue?
    var symbol: String?
    var tint: Color?
    var unavailable = false
    @ViewBuilder var content: () -> Content

    init(_ title: String, detail: String? = nil, value: String, unit: String? = nil, caption: String? = nil, hue: ThemeHue? = nil,
        symbol: String? = nil, tint: Color? = nil, unavailable: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.detail = detail; self.value = value; self.unit = unit; self.caption = caption; self.hue = hue
        self.symbol = symbol; self.tint = tint; self.unavailable = unavailable; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: title, symbol: symbol, tint: unavailable ? nil : (tint ?? hue?.base), chip: detail)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 34, weight: .bold)).foregroundStyle(unavailable ? Theme.muted : Theme.text)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                if let unit { Text(unit).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.muted) }
            }
            content()
            if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(3) }
        }.cardStyle(hue: hue, unavailable: unavailable)
    }
}

extension MetricCard where Content == EmptyView {
    init(_ title: String, detail: String? = nil, value: String, unit: String? = nil, caption: String? = nil, hue: ThemeHue? = nil,
        symbol: String? = nil, tint: Color? = nil, unavailable: Bool = false) {
        self.init(title, detail: detail, value: value, unit: unit, caption: caption, hue: hue, symbol: symbol, tint: tint, unavailable: unavailable) { EmptyView() }
    }
}

// 进度条：默认用页面色；track 可换成白色（彩色卡上）。
struct MeterBar: View {
    let fraction: Double?
    var tint: Color?
    var height: CGFloat = 8
    var track: Color = Theme.track
    @Environment(\.pageHue) private var hue
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if let fraction, fraction.isFinite {
                    Capsule().fill(tint ?? hue.base).frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}

// 环形图：单值占比，中心可放文字。fraction 为 nil 时只画轨道。
struct RingGauge<Label: View>: View {
    let fraction: Double?
    var tint: Color
    var track: Color = Theme.track
    var lineWidth: CGFloat = 9
    @ViewBuilder var label: () -> Label
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            if let fraction, fraction.isFinite {
                Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            label()
        }
        .padding(lineWidth / 2)
    }
}

// 历史摘要不参与清理；重启后需要重新扫描才会出现可操作明细。
struct LastAnalysisNotice: View {
    let report: AnalysisReport
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(report.details.enumerated()), id: \.offset) { _, detail in
                    Text(detail).font(.caption).textSelection(.enabled)
                }
                Text(localized("历史结果供参考，文件可能已变化；执行清理前会重新核验。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }.padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("上次分析 · ") + report.completedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: localizationLocale)))
                    .font(.caption).foregroundStyle(Theme.muted)
                Text(report.summary).font(.callout).foregroundStyle(Theme.text)
            }
        }.cardStyle(padding: 10)
    }
}
