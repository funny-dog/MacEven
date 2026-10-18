import SwiftUI

// 轻量折线与面积图。只接收调用方已限长的数组；nil 表示缺口，不跨缺口连线。
struct Sparkline: View {
    let values: [Double?]
    var maximum: Double?
    var color: Color?
    var fill = true
    var dashed = false
    @Environment(\.pageHue) private var hue

    var body: some View {
        let color = color ?? hue.base
        return GeometryReader { geometry in
            let segments = segments(in: geometry.size)
            ZStack {
                if fill {
                    ForEach(segments.indices, id: \.self) { index in
                        area(segments[index], height: geometry.size.height)
                            .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    }
                }
                ForEach(segments.indices, id: \.self) { index in
                    let points = segments[index]
                    if points.count == 1 {
                        Circle().fill(color).frame(width: 3, height: 3).position(points[0])
                    } else {
                        line(points).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dashed ? [4, 3] : []))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func segments(in size: CGSize) -> [[CGPoint]] {
        let finite = values.compactMap { $0 }.filter(\.isFinite)
        let top = max(maximum ?? finite.max() ?? 1, 0.000_001)
        let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        var result: [[CGPoint]] = []; var current: [CGPoint] = []
        for (index, value) in values.enumerated() {
            guard let value, value.isFinite else {
                if !current.isEmpty { result.append(current); current = [] }
                continue
            }
            let ratio = CGFloat(min(max(value / top, 0), 1))
            current.append(CGPoint(x: CGFloat(index) * step, y: size.height - 2 - ratio * (size.height - 4)))
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func line(_ points: [CGPoint]) -> Path {
        Path { path in path.addLines(points) }
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last, points.count > 1 else { return }
            path.move(to: CGPoint(x: first.x, y: height))
            path.addLines(points)
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.closeSubpath()
        }
    }
}
