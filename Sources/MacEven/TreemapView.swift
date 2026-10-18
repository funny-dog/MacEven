import SwiftUI
import MacEvenCore

// 按路径稳定配色，顶层与未识别用途的目录也能区分；颜色不代表清理资格。
enum DiskMapPalette {
    static let colors: [Color] = [
        Color(light: 0xd6caf8, dark: 0x51406d),
        Color(light: 0xf5dfc6, dark: 0x614a31),
        Color(light: 0xcde4f8, dark: 0x354e6a),
        Color(light: 0xccebea, dark: 0x2d5c5a),
        Color(light: 0xf7d4e0, dark: 0x663f51),
        Color(light: 0xd2ebd6, dark: 0x36583e)
    ]

    static func index(for path: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(colors.count))
    }

    static func color(for path: String) -> Color { colors[index(for: path)] }
}

struct TreemapView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @Environment(\.advancedMode) private var advanced

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("空间地图")).font(.headline)
                    if !compact { Text(localized("颜色区分目录，面积表示占用")).font(.caption).foregroundStyle(Theme.muted) }
                }
                Spacer()
                Label(localized("占用估算"), systemImage: "square.grid.2x2").font(.caption).foregroundStyle(Theme.muted)
            }
            crumbRow
            if let notice = model.treemapDirectoryNotice {
                Label(notice, systemImage: "lock.trianglebadge.exclamationmark").font(.caption).foregroundStyle(Theme.warning)
            }
            if let snapshot = model.treemapSnapshot, snapshot.invalidSizeCount > 0 {
                Label(localized("索引包含异常大小或总量溢出，暂不绘制面积；请重新扫描。"), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.warning)
                Spacer(minLength: 0)
            } else {
                GeometryReader { geometry in
                    if let snapshot = model.treemapSnapshot, !snapshot.weights.isEmpty {
                        let rects = TreemapLayout.rectangles(weights: snapshot.weights, width: geometry.size.width, height: geometry.size.height)
                        ZStack(alignment: .topLeading) {
                            ForEach(rects, id: \.id) { tile in
                                tileView(tile, snapshot: snapshot)
                                    .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                                    .offset(x: tile.rect.minX, y: tile.rect.minY)
                            }
                        }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    } else {
                        Text(model.treemapEmptyNotice).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minHeight: 100, maxHeight: .infinity)
                    .disabled(model.busy)
            }
            legend
            if let snapshot = model.treemapSnapshot, snapshot.invalidSizeCount == 0 {
                Text(advanced ? localized("按磁盘占用估算绘制最大 \(snapshot.entries.count) 项；其他 \(snapshot.otherCount) 项合计 \(bytes(snapshot.otherAllocatedSize))（逻辑大小 \(bytes(snapshot.otherLogicalSize))），点开回到目录视图分页查看。\(snapshot.zeroAllocatedCount) 项占用估算为零，不绘制面积。单击或空格选择，双击目录或在其上按回车打开。")
                    : localized("面积为已分配块估算，不等于可释放空间。单击选择，双击目录打开。"))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    .help(localized("面积为已分配块估算，不等于可释放空间。单击或空格选择；双击目录或按回车打开。小项合并为“其他”，点开后可分页查看。零占用项目不绘制面积。"))
            }
        }
        .accessibilityIdentifier("disk-space-map")
    }

    private var legend: some View {
        let entries = model.entries.filter { $0.allocatedSize > 0 && $0.logicalSize >= 0 }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(entries) { entry in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(DiskMapPalette.color(for: entry.url.path))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.border))
                            .frame(width: 9, height: 9).accessibilityHidden(true)
                        Text(entry.name).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).help(entry.url.path)
                    }
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    // 面包屑与当前目录合计。
    private var crumbRow: some View {
        HStack(spacing: 8) {
            Button {
                if let parent = model.breadcrumbs.dropLast().last { model.load(directory: parent.id) }
            } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.evenLink).disabled(model.breadcrumbs.count < 2 || model.busy)
                .help(localized("返回上级")).accessibilityLabel(localized("返回上级"))
            HStack(spacing: 4) {
                ForEach(Array(model.breadcrumbs.suffix(3).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Text("›").foregroundStyle(Theme.faint) }
                    let name = item.id == 1 ? localized("整个磁盘") : item.name
                    if item.id == model.breadcrumbs.last?.id { Text(name).fontWeight(.semibold).lineLimit(1) }
                    else { Button(name) { model.load(directory: item.id) }.buttonStyle(.evenLink).lineLimit(1).disabled(model.busy) }
                }
            }.font(.callout).truncationMode(.middle)
            Spacer(minLength: 8)
            if let snapshot = model.treemapSnapshot {
                Text(snapshot.invalidSizeCount == 0 ? localized("占用估算 \(bytes(snapshot.totalAllocatedSize))") : localized("合计不可用"))
                    .font(.caption).foregroundStyle(snapshot.invalidSizeCount == 0 ? Theme.muted : Theme.warning).monospacedDigit()
                    .help(snapshot.invalidSizeCount == 0 ? localized("逻辑大小 \(bytes(snapshot.totalLogicalSize))") : localized("大小异常，请重新扫描"))
            }
        }
    }

    @ViewBuilder private func tileView(_ tile: TreemapRect, snapshot: TreemapSnapshot) -> some View {
        if let entry = snapshot.entries.first(where: { $0.id == tile.id }) {
            let selected = model.selection.contains(entry.id)
            let locked = model.blocked[entry.id] != nil
            Button { model.selectTreemapEntry(entry.id) } label: {
                tileLabel(name: entry.name, size: entry.allocatedSize, tile: tile, fill: DiskMapPalette.color(for: entry.url.path),
                    selected: selected, locked: locked, dashed: false)
            }.buttonStyle(.plain)
                .accessibilityIdentifier("disk-map-tile-\(entry.id)")
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if entry.isDirectory && !model.busy { model.load(directory: entry.id) }
                })
                .onKeyPress(.return) {
                    if entry.isDirectory && !model.busy { model.load(directory: entry.id); return .handled }
                    return .ignored
                }
                .help(localized("\(entry.url.path)\n占用估算 \(bytes(entry.allocatedSize)) · 逻辑大小 \(bytes(entry.logicalSize))") + (model.blocked[entry.id].map { localized("\n受保护，只读：\($0.lockReason)") } ?? ""))
                .accessibilityLabel(localized("\(entry.name)，\(entry.isDirectory ? localized("目录") : localized("文件"))，占用估算 \(bytes(entry.allocatedSize))，逻辑大小 \(bytes(entry.logicalSize))\(locked ? localized("，受保护只读") : "")"))
                .accessibilityValue(selected ? localized("已选择") : localized("未选择"))
                .accessibilityHint(entry.isDirectory ? localized("双击或回车打开目录") : localized("选择此文件，在下方查看操作"))
        } else {
            Button { model.setBrowseMode(.directory) } label: {
                tileLabel(name: localized("其他 \(snapshot.otherCount) 项"), size: snapshot.otherAllocatedSize, tile: tile, fill: Theme.inset,
                    selected: false, locked: false, dashed: true)
            }.buttonStyle(.plain).disabled(model.busy)
                .help(localized("其他子项完整合计；点开回到目录视图分页查看，不能整体选择或移到废纸篓。"))
                .accessibilityLabel(localized("其他 \(snapshot.otherCount) 项，占用估算 \(bytes(snapshot.otherAllocatedSize))，逻辑大小 \(bytes(snapshot.otherLogicalSize))"))
                .accessibilityHint(localized("打开目录视图分页查看"))
        }
    }

    private func tileLabel(name: String, size: Int64, tile: TreemapRect, fill: Color, selected: Bool, locked: Bool, dashed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: selected ? 5 : 8, style: .continuous)
        return ZStack(alignment: .topLeading) {
            // focus-ring：2px 实线，离图块 2px；画在图块框内，避免被相邻图块遮挡。
            if selected { shape.strokeBorder(Theme.focusRing, lineWidth: 2) }
            ZStack(alignment: .topLeading) {
                inner.fill(fill)
                if tile.rect.width >= 56 && tile.rect.height >= 34 {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if locked { Image(systemName: "lock.fill").font(.system(size: 9)).accessibilityHidden(true) }
                            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        if tile.rect.height >= 52 {
                            Spacer(minLength: 0)
                            Text(bytes(size))
                                .font(.system(size: tile.rect.width >= 180 && tile.rect.height >= 120 ? 28 : tile.rect.width >= 110 && tile.rect.height >= 80 ? 19 : 12, weight: .semibold))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }.foregroundStyle(Theme.text).padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .overlay(inner.strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
            .padding(selected ? 4 : 0)
        }
        .contentShape(Rectangle()).clipped()
    }
}
