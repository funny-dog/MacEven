import SwiftUI
import AppKit

// 应用图标缓存：按路径 / 标识只向系统取一次，表格翻页与重绘不重复读取。
@MainActor enum AppIconCache {
    private static var byPath: [String: NSImage] = [:]
    private static var byIdentifier: [String: NSImage?] = [:]

    static func icon(path: String) -> NSImage {
        if let image = byPath[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        byPath[path] = image
        return image
    }

    // 找不到对应应用时返回 nil（例如已卸载），结果同样缓存。
    static func icon(bundleIdentifier: String) -> NSImage? {
        if let cached = byIdentifier[bundleIdentifier] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map { icon(path: $0.path) }
        byIdentifier[bundleIdentifier] = image
        return image
    }
}

// 应用图标；没有图标时显示通用应用占位符，保持行内对齐。
struct AppIcon: View {
    let image: NSImage?
    var size: CGFloat = 20

    init(path: String?, size: CGFloat = 20) { image = path.map(AppIconCache.icon(path:)); self.size = size }
    init(bundleIdentifier: String, size: CGFloat = 20) { image = AppIconCache.icon(bundleIdentifier: bundleIdentifier); self.size = size }

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: "app.dashed").resizable().foregroundStyle(Theme.muted) }
        }
        .aspectRatio(contentMode: .fit).frame(width: size, height: size).accessibilityHidden(true)
    }
}

// MacEven 品牌标：直接用本应用的图标（Resources/AppIcon.icns），与 Dock、访达、关于面板保持同一图形。
// size 是可见圆角方块的边长；icns 按系统网格四周各留 100/1024 透明边，这里放大后用负边距抵消，布局只占 size。
struct BrandMark: View {
    var size: CGFloat = 30

    var body: some View {
        let full = size * 1024 / 824
        let inset = (full - size) / 2
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
            .frame(width: full, height: full).padding(-inset)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.14), radius: size * 0.05, y: size * 0.03)   // 暖白底在浅色侧栏上需要一点轮廓
            .accessibilityHidden(true)
    }
}
