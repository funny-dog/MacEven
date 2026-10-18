import SwiftUI
import MacEvenCore

// 全盘按用途汇总：一条按用途着色的堆叠条 + 单行用途小卡（兼作图例与按钮）；点用途后下方列表显示该用途占用最多的位置。
// 小屏（可用高度约 712pt）上要给列表留空间，所以卡片保持紧凑，口径说明放在悬停提示里。
struct PurposeSummaryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.advancedMode) private var advanced

    // 颜色只辅助区分，小卡上都有文字；按占用排序依次取色，未识别为浅灰。
    private static let palette: [ThemeHue] = [.blue, .violet, .teal, .orange, .pink, .green]
    private static let unlabeledColor = ThemeHue.gray.base.opacity(0.35)

    var body: some View {
        if let summary = model.purposeSummary {
            if summary.total == 0 {
                Text(localized("扫描范围内没有占用空间的文件。")).foregroundStyle(Theme.muted).cardStyle()
            } else {
                card(summary)
            }
        } else if model.loading {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(localized("正在汇总用途…")).foregroundStyle(Theme.muted) }.cardStyle()
        }
    }

    private func hue(_ index: Int) -> ThemeHue { Self.palette[index % Self.palette.count] }

    private func percent(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0%" }
        let ratio = Double(value) / Double(total) * 100
        return ratio > 0 && ratio < 1 ? "<1%" : "\(Int(ratio.rounded()))%"
    }

    private func card(_ summary: PurposeSummary) -> some View {
        let groups = Array(summary.groups.enumerated())
        var segments = groups.map { SegmentedBar.Segment(fraction: Double($1.bytes) / Double(summary.total), color: hue($0).base, label: $1.category.title) }
        if summary.unlabeled > 0 { segments.append(.init(fraction: Double(summary.unlabeled) / Double(summary.total), color: Self.unlabeledColor, label: localized("未识别"))) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localized("已识别用途")).font(.callout).foregroundStyle(Theme.muted)
                Text(bytes(summary.labeled)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                Text(localized("占 \(bytes(summary.total)) 的 \(percent(summary.labeled, of: summary.total))")).font(.callout).foregroundStyle(Theme.muted)
                if advanced {
                    Image(systemName: "info.circle").foregroundStyle(Theme.muted)
                        .help(localized("每个文件只计入离它最近的用途；文件夹中被更具体用途识别的部分（例如应用数据里的缓存）计入更具体的用途。“可重建”只说明删除后会重新生成，不等于建议删除，也不等于可释放的空间。"))
                        .accessibilityLabel(localized("统计口径说明"))
                }
                Spacer(minLength: 8)
                // 安全等级与列表里的用途标签同色：绿 = 可重建，橙 = 谨慎，灰 = 勿动。
                ForEach([PurposeSafety.regenerable, .caution, .keep], id: \.self) { safety in
                    if let value = summary.safetyBytes[safety], value > 0 {
                        PillLabel(text: "\(safety.title) \(bytes(value))", tint: safety.tint).help(safety.explanation)
                    }
                }
            }
            SegmentedBar(segments: segments, height: 10)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 6) {
                ForEach(groups, id: \.element.id) { index, group in chip(group, color: hue(index), total: summary.total) }
                if summary.unlabeled > 0 { unlabeledChip(summary) }
            }
        }
        .cardStyle(padding: 14)
        .disabled(model.scanning || model.operating)
    }

    private func chip(_ group: PurposeSummary.Group, color: ThemeHue, total: Int64) -> some View {
        let selected = group.category == model.purposeCategory
        return Button {
            if model.purposeCategory == group.category && model.expandPurposeFiles {
                model.expandPurposeFiles = false
            } else {
                model.showPurpose(group.category)
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color.base).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(group.category.title).font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? color.ink : Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Text(bytes(group.bytes)).font(.callout).monospacedDigit().foregroundStyle(selected ? color.ink : Theme.muted).lineLimit(1)
                if selected {
                    Image(systemName: model.expandPurposeFiles ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(selected ? color.ink : Theme.muted)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(selected ? color.soft : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(selected ? color.base.opacity(0.6) : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localized("\(group.category.title)：\(bytes(group.bytes))，占 \(percent(group.bytes, of: total))") + (advanced ? localized("，\(group.count.formatted()) 个位置") : "") + localized("。点击查看占用最多的位置。"))
        .accessibilityLabel(localized("\(group.category.title)，\(bytes(group.bytes))，占 \(percent(group.bytes, of: total))"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // 未识别的部分没有可列出的“位置”，只显示合计。
    private func unlabeledChip(_ summary: PurposeSummary) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Self.unlabeledColor).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(localized("未识别")).font(.callout).foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            Text(bytes(summary.unlabeled)).font(.callout).monospacedDigit().foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .help(localized("没有匹配任何用途规则的文件（占 \(percent(summary.unlabeled, of: summary.total))），例如你自己建的项目文件夹；可在“目录占用”中查看。"))
        .accessibilityElement(children: .combine)
    }
}
