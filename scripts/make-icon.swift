#!/usr/bin/env swift
// 生成 MacEven 应用图标：暖白圆角方块 + 青绿色平行切角（Even E2）。
// 用法：swift scripts/make-icon.swift <输出 iconset 目录> [预览 PNG 路径]
// 之后用 iconutil -c icns 转成 Resources/AppIcon.icns（见 scripts/build-icon.sh）。
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// 以 1024×1024 为设计画布绘制，调用方负责缩放。
func drawIcon() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    color(0xF1EEE6).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186).fill()

    color(0x17695D).setFill()
    for y in [CGFloat(546), CGFloat(336)] {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 286, y: y))
        path.line(to: NSPoint(x: 654, y: y))
        path.line(to: NSPoint(x: 738, y: y + 142))
        path.line(to: NSPoint(x: 370, y: y + 142))
        path.close()
        path.fill()
    }
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("用法: make-icon.swift <iconset 目录> [预览 PNG]\n".utf8)); exit(2) }
let directory = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, pixels) in variants { try render(pixels: pixels).write(to: directory.appendingPathComponent(name + ".png")) }
if args.count >= 3 { try render(pixels: 1024).write(to: URL(fileURLWithPath: args[2])) }
print("已生成 \(variants.count) 个尺寸：\(directory.path)")
