#!/usr/bin/env swift
//
//  make-appicon.swift
//  kimi-companion
//
//  生成 app 图标（`Resources/AppIcon.icns`）。设计是纯几何的：macOS 标准圆角方形
//  （squircle）+ 三条白色配额条 —— 对应菜单里每个 Provider 的余额 / 配额行。
//
//  不借用任何 Provider 的品牌 logo 当自己的图标（同 `LogoCatalog` 的原则：
//  宁可只显示文字，也不拿别家 vendor 的 mark 误导用户），因此这里是原创图形。
//
//  用法：
//      swift Tools/make-appicon.swift [输出路径.icns]
//  默认输出 `Resources/AppIcon.icns`（相对仓库根目录）。中间产物写在临时目录，
//  最终由 `iconutil` 打包成 .icns。
//

import AppKit
import Foundation

// MARK: - 设计空间

/// 所有几何量都在 1024×1024 的设计空间里描述，渲染时按目标像素尺寸整体缩放。
private let designSide: CGFloat = 1024

/// macOS app 图标网格：squircle 主体 824×824 居中（四周留 100 的阴影余量）。
private let bodySide: CGFloat = 824
private let bodyOrigin: CGFloat = (designSide - bodySide) / 2

/// squircle 指数：Apple 的连续圆角可近似为超椭圆 |x|ⁿ + |y|ⁿ = 1（n ≈ 5）。
private let squircleExponent: CGFloat = 5

/// 三条配额条（自上而下）。比例是「已用 / 已填充」的示意长度。
private let barFillRatios: [CGFloat] = [0.92, 0.70, 0.48]

private let barHeight: CGFloat = 92
private let barGap: CGFloat = 66
private let barTrackInset: CGFloat = 146          // 左右各留的内边距
private let barTrackWidth = bodySide - barTrackInset * 2

// 小尺寸（16 / 32pt）下轨道太细会被糊掉：去掉轨道、只画实心条，并加粗加宽间距。
private let smallBarHeight: CGFloat = 108
private let smallBarGap: CGFloat = 78

// MARK: - 调色

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private let bodyTop = color(0x7C5CFF)
private let bodyBottom = color(0x31179B)
private let barFill = color(0xFFFFFF)
private let barTrack = color(0xFFFFFF, alpha: 0.22)

// MARK: - 路径

/// 超椭圆（squircle）路径，用来近似 Apple 图标的连续圆角。
private func squirclePath(in rect: CGRect, exponent: CGFloat, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let power = 2 / exponent

    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), power)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), power)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 胶囊（两端半圆）路径。
private func capsule(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
}

// MARK: - 绘制

private func drawIcon(into ctx: CGContext, pixelSize: Int) {
    let scale = CGFloat(pixelSize) / designSide
    ctx.scaleBy(x: scale, y: scale)

    let body = CGRect(x: bodyOrigin, y: bodyOrigin, width: bodySide, height: bodySide)
    let bodyPath = squirclePath(in: body, exponent: squircleExponent)

    // 1) 主体 + 下方投影（macOS 图标惯例：投影落在主体下缘）。
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40,
                  color: color(0x000000, alpha: 0.30))
    ctx.addPath(bodyPath)
    ctx.setFillColor(bodyBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // 2) 主体渐变（上亮下暗），裁在主体内。
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [bodyTop, bodyBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY),
                           options: [])

    // 3) 顶部高光，让平面色块有一点玻璃质感。
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [color(0xFFFFFF, alpha: 0.20), color(0xFFFFFF, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY + 40),
                           options: [])
    ctx.restoreGState()

    // 4) 三条配额条。
    let simplified = pixelSize <= 32
    let height = simplified ? smallBarHeight : barHeight
    let gap = simplified ? smallBarGap : barGap
    let groupHeight = height * CGFloat(barFillRatios.count) + gap * CGFloat(barFillRatios.count - 1)
    var y = body.midY + groupHeight / 2 - height

    for ratio in barFillRatios {
        let track = CGRect(x: body.minX + barTrackInset, y: y, width: barTrackWidth, height: height)

        if !simplified {
            ctx.addPath(capsule(track))
            ctx.setFillColor(barTrack)
            ctx.fillPath()
        }

        let fillWidth = max(height, track.width * ratio)
        let fill = CGRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
        ctx.addPath(capsule(fill))
        ctx.setFillColor(barFill)
        ctx.fillPath()

        y -= height + gap
    }
}

/// 渲染指定像素边长的 PNG。
private func renderPNG(pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(into: ctx.cgContext, pixelSize: pixelSize)
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

// MARK: - 打包 .icns

/// .icns 需要的完整尺寸集合（含同一像素尺寸的多个槽位，iconutil 按文件名区分）。
private let iconsetEntries: [(pixelSize: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

private func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "make-appicon", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) 失败"])
    }
}

// MARK: - 入口

let repoRoot = FileManager.default.currentDirectoryPath
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "\(repoRoot)/Resources/AppIcon.icns"

let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("kimi-companion-iconset-\(UUID().uuidString)")
let iconsetDir = workDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

for entry in iconsetEntries {
    let data = renderPNG(pixelSize: entry.pixelSize)
    try data.write(to: iconsetDir.appendingPathComponent(entry.name))
}

try run("/usr/bin/iconutil", ["-c", "icns", iconsetDir.path, "-o", outputPath])
print("==> \(outputPath)")
