import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S = 1024.0
let C = CGPoint(x: S/2, y: S/2)

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip to a top-left origin so coordinates match SVG-style thinking.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(colorSpace: cs, components: [r/255, g/255, b/255, 1])!
}

let bgGrad = CGGradient(colorsSpace: cs,
    colors: [rgb(35,43,57), rgb(14,19,27)] as CFArray, locations: [0, 1])!
let gearGrad = CGGradient(colorsSpace: cs,
    colors: [rgb(203,213,225), rgb(139,151,168)] as CFArray, locations: [0, 1])!
let green = rgb(52,211,153)

func paintBG() {
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 92),
                           end: CGPoint(x: 0, y: 932), options: [])
}

// 1) Background squircle
ctx.saveGState()
let bgRect = CGRect(x: 92, y: 92, width: 840, height: 840)
ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 188, cornerHeight: 188, transform: nil))
ctx.clip()
paintBG()
ctx.restoreGState()

// 2) Gear (10 teeth + ring), gradient-filled
func rot(_ p: CGPoint, _ deg: Double) -> CGPoint {
    let a = deg * .pi / 180
    let dx = p.x - C.x, dy = p.y - C.y
    return CGPoint(x: C.x + dx*cos(a) - dy*sin(a),
                   y: C.y + dx*sin(a) + dy*cos(a))
}
let gearPath = CGMutablePath()
let n = 10, rBase = 250.0, rTip = 312.0, wBase = 40.0, wTip = 26.0
for i in 0..<n {
    let ang = Double(i) * 360.0 / Double(n)
    let pts = [
        CGPoint(x: C.x - wBase, y: C.y - rBase),
        CGPoint(x: C.x - wTip,  y: C.y - rTip),
        CGPoint(x: C.x + wTip,  y: C.y - rTip),
        CGPoint(x: C.x + wBase, y: C.y - rBase),
    ].map { rot($0, ang) }
    gearPath.move(to: pts[0])
    pts.dropFirst().forEach { gearPath.addLine(to: $0) }
    gearPath.closeSubpath()
}
gearPath.addEllipse(in: CGRect(x: C.x-252, y: C.y-252, width: 504, height: 504))
ctx.saveGState()
ctx.addPath(gearPath)
ctx.clip()
ctx.drawLinearGradient(gearGrad, start: CGPoint(x: 0, y: 250),
                       end: CGPoint(x: 0, y: 774), options: [])
ctx.restoreGState()

// 3) Hub hole — shows the background again
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: C.x-176, y: C.y-176, width: 352, height: 352))
ctx.clip()
paintBG()
ctx.restoreGState()

// 4) >_ prompt
ctx.setStrokeColor(green)
ctx.setLineWidth(34)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 470, y: 452))
ctx.addLine(to: CGPoint(x: 548, y: 512))
ctx.addLine(to: CGPoint(x: 470, y: 572))
ctx.strokePath()
ctx.setFillColor(green)
ctx.addPath(CGPath(roundedRect: CGRect(x: 486, y: 576, width: 120, height: 30),
                   cornerWidth: 15, cornerHeight: 15, transform: nil))
ctx.fillPath()

// Write PNG
let img = ctx.makeImage()!
let out = CommandLine.arguments[1]
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote", out)
