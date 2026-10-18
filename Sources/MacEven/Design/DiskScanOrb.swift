import SwiftUI
import MacEvenCore

private typealias OrbState<Value> = SwiftUI.State<Value>

/// 居中的圆形磁盘扫描按钮组件：待机引导开始扫描，扫描时展示进度环与取消入口。
struct DiskScanOrb: View {
    let scanning: Bool
    let estimate: ProgressEstimate
    let disabled: Bool
    let start: () -> Void
    let cancel: () -> Void

    @OrbState private var rotation: Double = 0
    @OrbState private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let orbGradient = AngularGradient(
        colors: [
            ThemeHue.blue.base,
            ThemeHue.violet.base,
            ThemeHue.teal.base,
            ThemeHue.blue.base
        ],
        center: .center
    )

    var body: some View {
        ZStack {
            // 外层轨道与光环（约 202x202 处于 220x220 外框中）
            orbitRing

            // 内部可点击圆形按钮（约 174x174）
            Button(action: {
                if scanning {
                    cancel()
                } else {
                    start()
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Theme.surfaceRaised)
                        .overlay(
                            Circle()
                                .strokeBorder(isHovered && !disabled ? Theme.controlBorder : Theme.border, lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 3)

                    if isFocused {
                        Circle()
                            .strokeBorder(Theme.focusRing, lineWidth: 2.5)
                    }

                    buttonContent
                }
                .frame(width: 174, height: 174)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1.0)
            .focused($isFocused)
            .onHover { hovering in
                isHovered = hovering
            }
            .accessibilityLabel(scanning ? localized("取消扫描") : localized("扫描内部磁盘"))
            .accessibilityValue(scanning ? (estimate.percentText ?? localized("正在扫描，总数未知")) : "")
            .accessibilityHint(scanning ? localized("点击取消当前磁盘扫描") : localized("点击开始扫描内部磁盘"))
        }
        .frame(width: 220, height: 220)
        .onAppear {
            updateAnimation()
        }
        .onChange(of: scanning) { _, _ in
            updateAnimation()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateAnimation()
        }
    }

    @ViewBuilder
    private var orbitRing: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: 6)
                .frame(width: 202, height: 202)

            if scanning {
                Circle()
                    .stroke(orbGradient, lineWidth: 2)
                    .blur(radius: 4)
                    .opacity(0.4)
                    .frame(width: 202, height: 202)
                    .rotationEffect(.degrees(rotation))

                if let fraction = estimate.fraction {
                    Circle()
                        .trim(from: 0, to: max(0.01, min(fraction, 1.0)))
                        .stroke(orbGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 202, height: 202)
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
                } else {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(orbGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 202, height: 202)
                        .rotationEffect(.degrees(rotation))
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var buttonContent: some View {
        if scanning {
            VStack(spacing: 6) {
                if let percentText = estimate.percentText {
                    Text(percentText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                } else {
                    Text(localized("扫描中"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                }

                Text(localized("取消扫描"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovered && !disabled ? Theme.destructive : Theme.muted)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(orbGradient)

                Text(localized("扫描内部磁盘"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
    }

    private func updateAnimation() {
        if scanning && !reduceMotion {
            if rotation == 0 {
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                rotation = 0
            }
        }
    }
}
