import SwiftUI
import MacEvenCore

// 不确定进度的活动条；开启“减少动态效果”时显示静态轨道。
struct ActivityBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion { MeterBar(fraction: nil) }
        else { ProgressView().progressViewStyle(.linear).accessibilityLabel(localized("进行中，总数未知")) }
    }
}

// 扫描进度：能算出或估算总数时显示进度条与百分比（估算标“约”），否则显示活动条；下方一行说明。
// 简洁与高级模式都显示；更细的明细由各页面在高级模式下另行显示。
struct ScanProgressBar: View {
    let estimate: ProgressEstimate
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let fraction = estimate.fraction {
                    MeterBar(fraction: fraction, height: 8)
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else {
                    ActivityBar()
                }
                if let percent = estimate.percentText {
                    Text(percent).font(.callout.weight(.semibold)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                }
            }
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("扫描进度"))
        .accessibilityValue([estimate.percentText ?? localized("进行中，总数未知"), caption].filter { !$0.isEmpty }.joined(separator: localized("，")))
    }
}
