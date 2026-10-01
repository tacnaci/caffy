// 生成 Resources/AppIcon.icns
//   swift scripts/make-icon.swift
// 图形：深蓝夜空 + 月牙 + 冒热气的咖啡杯（深夜仍清醒）。
// 所有坐标基于 1024×1024 画布，原点左上；底板遵循 macOS 图标网格（824×824 圆角方块，四周留 100）。
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func fillLinear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let tilePath = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)

func drawBackground(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x14143A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(tilePath)
    ctx.clip()
    fillLinear(ctx, [rgb(0x34368A), rgb(0x14143A)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
}

func drawSky(_ ctx: CGContext) {
    ctx.setFillColor(rgb(0xFFF3C4, 0.9))
    for (x, y, r) in [(250.0, 250.0, 9.0), (330, 190, 6), (210, 380, 5), (820, 420, 6), (300, 330, 4)] {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // 月牙：大圆减去偏移的小圆
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.addEllipse(in: CGRect(x: 680, y: 160, width: 124, height: 124))
    ctx.clip(using: .evenOdd)
    ctx.setFillColor(rgb(0xFFE29A))
    ctx.fillEllipse(in: CGRect(x: 642, y: 182, width: 140, height: 140))
    ctx.restoreGState()
}

func drawCup(_ ctx: CGContext) {
    let light = rgb(0xFFF7EC), dark = rgb(0xE6D3BD)

    // 碟子与投影
    ctx.setFillColor(rgb(0x000000, 0.25))
    ctx.fillEllipse(in: CGRect(x: 262, y: 742, width: 500, height: 90))
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 272, y: 726, width: 480, height: 84))
    ctx.clip()
    fillLinear(ctx, [light, dark], from: CGPoint(x: 512, y: 726), to: CGPoint(x: 512, y: 810))
    ctx.restoreGState()

    // 把手（先画，被杯身盖住左半）
    ctx.setStrokeColor(dark)
    ctx.setLineWidth(34)
    ctx.strokeEllipse(in: CGRect(x: 650, y: 520, width: 130, height: 140))

    // 杯身
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 320, y: 480))
    body.addLine(to: CGPoint(x: 704, y: 480))
    body.addCurve(to: CGPoint(x: 590, y: 752), control1: CGPoint(x: 704, y: 650), control2: CGPoint(x: 670, y: 752))
    body.addLine(to: CGPoint(x: 434, y: 752))
    body.addCurve(to: CGPoint(x: 320, y: 480), control1: CGPoint(x: 354, y: 752), control2: CGPoint(x: 320, y: 650))
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    fillLinear(ctx, [light, dark], from: CGPoint(x: 320, y: 480), to: CGPoint(x: 704, y: 752))
    ctx.restoreGState()

    // 杯口与咖啡
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: 320, y: 452, width: 384, height: 56))
    ctx.setFillColor(rgb(0x6B3B22))
    ctx.fillEllipse(in: CGRect(x: 338, y: 458, width: 348, height: 44))
}

func drawSteam(_ ctx: CGContext) {
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.85))
    ctx.setLineWidth(24)
    ctx.setLineCap(.round)
    let bottom: CGFloat = 440
    for (x, top) in [(440.0, 300.0), (512, 250), (584, 300)] {
        let h = bottom - top
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: bottom))
        path.addCurve(to: CGPoint(x: x, y: bottom - h / 2),
                      control1: CGPoint(x: x - 42, y: bottom - h * 0.18), control2: CGPoint(x: x + 42, y: bottom - h * 0.32))
        path.addCurve(to: CGPoint(x: x, y: top),
                      control1: CGPoint(x: x - 42, y: bottom - h * 0.68), control2: CGPoint(x: x + 42, y: bottom - h * 0.82))
        ctx.addPath(path)
        ctx.strokePath()
    }
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / canvas
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawBackground(ctx)
    drawSky(ctx)
    drawCup(ctx)
    drawSteam(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("已生成 \(output.path)")
