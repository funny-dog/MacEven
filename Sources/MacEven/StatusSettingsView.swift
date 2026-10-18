import SwiftUI
import MacEvenCore
import AppKit
import ServiceManagement

struct PrivacyIndicators: View {
    @EnvironmentObject var tools: SystemTools
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(localized("摄像头：\(text(tools.cameraInUse))"), systemImage: "video")
                Label(localized("麦克风：\(text(tools.microphoneInUse))"), systemImage: "mic")
            }.font(.caption)
            Text(localized("使用状态来自 AVFoundation；无设备或接口不可用时显示未知，应用归属未提供。"))
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }
    private func text(_ value: Bool?) -> String { value.map { $0 ? localized("其他应用使用中") : localized("未检测到使用") } ?? localized("未知") }
}
