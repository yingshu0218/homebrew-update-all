// IconGen.swift — 程序化生成 BrewUA App 图标(1024x1024 主图)。
// 风格:深色渐变背景(#161b22→#0d1117)呼应 brew-ua CLI 暗色主题;
// 主体金色啤酒杯(brew 语义)+ 蓝紫色弧形升级箭头(#58a6ff,更新语义)。
// 用法:swiftc IconGen.swift && ./IconGen <输出目录>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 画布

let size = 1024
let px = size * 4  // 4x 超采样,输出再缩小到 1024 抗锯齿
let ctx = CGContext(
    data: nil, width: px, height: px,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// 坐标归一化到 0..1(原点左下)
func X(_ v: CGFloat) -> CGFloat { v * CGFloat(px) }
func Y(_ v: CGFloat) -> CGFloat { (1 - v) * CGFloat(px) }

// MARK: - 背景(圆角方块,底色渐变)

let bgRect = CGRect(x: 0, y: 0, width: px, height: px)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: X(0.22), cornerHeight: X(0.22), transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let bgGradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.30, green: 0.31, blue: 0.36, alpha: 1), // 顶部浅灰蓝
        CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1), // 底部深色 #161b22
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: Y(1.0)), end: CGPoint(x: 0, y: Y(0)),
    options: []
)

// 底部微光:深蓝紫氛围
let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.19, green: 0.32, blue: 0.55, alpha: 0.55),
        CGColor(red: 0.19, green: 0.32, blue: 0.55, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: X(0.5), y: Y(0.18)), startRadius: 0,
    endCenter: CGPoint(x: X(0.5), y: Y(0.18)), endRadius: X(0.75),
    options: []
)

// MARK: - 上拱升级弧(蓝 #58a6ff)
// 用三次贝塞尔画"∩"形弧,两端点在杯身两侧,控制点高拱在杯上方——角度换算易绕晕,直接路径最可控

func drawUpwardArc() {
    // 端点与上拱控制点(坐标归一化)
    let leftEnd = CGPoint(x: X(0.27), y: Y(0.46))
    let rightEnd = CGPoint(x: X(0.73), y: Y(0.46))
    // 控制点取在两端中点上方 0.30 处,拱顶接近 y=0.87(图标上方)
    let c1 = CGPoint(x: X(0.38), y: Y(0.86))
    let c2 = CGPoint(x: X(0.62), y: Y(0.86))

    let path = CGMutablePath()
    path.move(to: leftEnd)
    path.addCurve(to: rightEnd, control1: c1, control2: c2)
    ctx.setStrokeColor(CGColor(red: 0.345, green: 0.651, blue: 1.0, alpha: 1)) // #58a6ff
    ctx.setLineWidth(X(0.07))
    ctx.setLineCap(.round)
    ctx.addPath(path)
    ctx.strokePath()

    // 箭头:画在右端点,指向右上方(50°)
    let tip = rightEnd
    let dir: CGFloat = 50 * .pi / 180
    let headLen = X(0.12)
    let h1 = CGPoint(x: tip.x + headLen * cos(dir - 0.5), y: tip.y + headLen * sin(dir - 0.5))
    let h2 = CGPoint(x: tip.x + headLen * cos(dir + 0.5), y: tip.y + headLen * sin(dir + 0.5))
    ctx.setFillColor(CGColor(red: 0.345, green: 0.651, blue: 1.0, alpha: 1))
    ctx.move(to: tip)
    ctx.addLine(to: h1)
    ctx.addLine(to: h2)
    path.closeSubpath()
    ctx.fillPath()
}

drawUpwardArc()

// MARK: - 啤酒杯

// 杯身(梯形玻璃杯)
let glass = CGMutablePath()
glass.move(to: CGPoint(x: X(0.34), y: Y(0.24)))
glass.addLine(to: CGPoint(x: X(0.30), y: Y(0.62)))  // 左上
glass.addLine(to: CGPoint(x: X(0.70), y: Y(0.62)))  // 右上
glass.addLine(to: CGPoint(x: X(0.66), y: Y(0.24)))  // 右下
    glass.closeSubpath()

// 杯身玻璃:半透明浅色描边 + 液体
ctx.setStrokeColor(CGColor(red: 0.85, green: 0.88, blue: 0.92, alpha: 0.9))
ctx.setLineWidth(X(0.035))
ctx.setLineJoin(.round)
ctx.addPath(glass)
ctx.strokePath()

// 金色液体
let liquidPath = CGMutablePath()
liquidPath.move(to: CGPoint(x: X(0.325), y: Y(0.30)))
liquidPath.addLine(to: CGPoint(x: X(0.305), y: Y(0.56)))
liquidPath.addLine(to: CGPoint(x: X(0.695), y: Y(0.56)))
liquidPath.addLine(to: CGPoint(x: X(0.675), y: Y(0.30)))
    liquidPath.closeSubpath()
let liquidGrad = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 1), // 亮金 #f2bf40
        CGColor(red: 0.85, green: 0.55, blue: 0.10, alpha: 1), // 深金
    ] as CFArray,
    locations: [0, 1]
)!
ctx.saveGState()
ctx.addPath(liquidPath)
ctx.clip()
ctx.drawLinearGradient(
    liquidGrad,
    start: CGPoint(x: 0, y: Y(0.56)), end: CGPoint(x: 0, y: Y(0.30)),
    options: []
)
ctx.restoreGState()

// 泡沫(白色圆角带)
let foam = CGMutablePath()
foam.move(to: CGPoint(x: X(0.322), y: Y(0.315)))
foam.addLine(to: CGPoint(x: X(0.310), y: Y(0.36)))
foam.addQuadCurve(to: CGPoint(x: X(0.40), y: Y(0.375)), control: CGPoint(x: X(0.35), y: Y(0.395)))
foam.addQuadCurve(to: CGPoint(x: X(0.55), y: Y(0.375)), control: CGPoint(x: X(0.48), y: Y(0.40)))
foam.addQuadCurve(to: CGPoint(x: X(0.68), y: Y(0.355)), control: CGPoint(x: X(0.62), y: Y(0.392)))
foam.addQuadCurve(to: CGPoint(x: X(0.688), y: Y(0.315)), control: CGPoint(x: X(0.69), y: Y(0.36)))
    foam.closeSubpath()
ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
ctx.addPath(foam)
ctx.fillPath()

// 杯柄(右侧)
let handle = CGMutablePath()
handle.addArc(center: CGPoint(x: X(0.745), y: Y(0.43)), radius: X(0.075), startAngle: -0.9, endAngle: 0.9, clockwise: false)
ctx.setStrokeColor(CGColor(red: 0.85, green: 0.88, blue: 0.92, alpha: 0.9))
ctx.setLineWidth(X(0.03))
ctx.setLineCap(.round)
ctx.addPath(handle)
ctx.strokePath()

// 高光(左上方细白线)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
ctx.setLineWidth(X(0.018))
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: X(0.40), y: Y(0.34)))
ctx.addLine(to: CGPoint(x: X(0.385), y: Y(0.55)))
ctx.strokePath()

// MARK: - 导出

let image = ctx.makeImage()!
// 缩小到 1024(4x 超采样抗锯齿)
let finalW = size
let finalCtx = CGContext(
    data: nil, width: finalW, height: finalW,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
finalCtx.interpolationQuality = .high
finalCtx.draw(image, in: CGRect(x: 0, y: 0, width: finalW, height: finalW))

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/brewua-icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon-1024.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, finalCtx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(url.path)")