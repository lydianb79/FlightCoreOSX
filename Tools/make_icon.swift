// Draws the FlightCore app icon. Usage: swift Tools/make_icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)! }

// macOS icon shape: 824pt rounded square on a 1024 canvas, with a soft drop shadow
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: col(0, 0, 0, 0.35))
ctx.addPath(shape); ctx.setFillColor(col(0.2, 0.5, 0.9)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// sky
let horizon: CGFloat = 400
ctx.drawLinearGradient(gradient([col(0.07, 0.30, 0.78), col(0.25, 0.56, 0.93), col(0.70, 0.87, 0.98)], [0, 0.55, 1]),
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation])
// sun glow
ctx.drawRadialGradient(gradient([col(1, 0.98, 0.85, 0.95), col(1, 0.95, 0.7, 0.35), col(1, 0.95, 0.7, 0)], [0, 0.25, 1]),
                       startCenter: CGPoint(x: 265, y: 770), startRadius: 0, endCenter: CGPoint(x: 265, y: 770), endRadius: 260, options: [])
ctx.setFillColor(col(1, 0.99, 0.92)); ctx.fillEllipse(in: CGRect(x: 225, y: 730, width: 80, height: 80))
// clouds
func cloud(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat, _ a: CGFloat) {
    ctx.saveGState(); ctx.setAlpha(a); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(col(1, 1, 1))
    for (dx, dy, r) in [(0.0, 0.0, 44.0), (52, 14, 56), (112, 4, 46), (160, -4, 34), (-44, -6, 30)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.fillEllipse(in: CGRect(x: x + (dx - r) * k, y: y + (dy - r * 0.62) * k, width: 2 * r * k, height: 1.24 * r * k))
    }
    ctx.endTransparencyLayer(); ctx.restoreGState()
}
cloud(640, 560, 1.0, 0.85); cloud(190, 520, 0.7, 0.7); cloud(560, 800, 0.6, 0.55)

// distant hills
func hills(_ base: CGFloat, _ amp: CGFloat, _ freq: CGFloat, _ phase: CGFloat, _ c: CGColor) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 100, y: 100))
    var x: CGFloat = 100
    while x <= 924 { p.addLine(to: CGPoint(x: x, y: base + amp * sin(x * freq + phase) + amp * 0.4 * sin(x * freq * 2.3 + phase * 1.7))); x += 4 }
    p.addLine(to: CGPoint(x: 924, y: 100)); p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath()
}
hills(horizon + 38, 26, 0.008, 0.6, col(0.45, 0.66, 0.62))
hills(horizon + 8, 18, 0.011, 2.4, col(0.33, 0.60, 0.40))
// field
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: horizon))
ctx.drawLinearGradient(gradient([col(0.42, 0.72, 0.28), col(0.20, 0.50, 0.16)], [0, 1]),
                       start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 100), options: [.drawsAfterEndLocation])
ctx.restoreGState()
// mowing stripes in perspective
ctx.setFillColor(col(1, 1, 1, 0.05))
for i in 0..<7 {
    let t0 = CGFloat(i) / 7, t1 = (CGFloat(i) + 0.5) / 7
    let y0 = horizon - 300 * pow(t0, 1.8), y1 = horizon - 300 * pow(t1, 1.8)
    ctx.fill(CGRect(x: 100, y: y1, width: 824, height: y0 - y1))
}
// runway converging on the horizon
let vp = CGPoint(x: 600, y: horizon - 4)
let rw = CGMutablePath()
rw.move(to: CGPoint(x: 250, y: 100)); rw.addLine(to: CGPoint(x: 640, y: 100))
rw.addLine(to: CGPoint(x: vp.x + 9, y: vp.y)); rw.addLine(to: CGPoint(x: vp.x - 9, y: vp.y)); rw.closeSubpath()
ctx.addPath(rw); ctx.setFillColor(col(0.23, 0.24, 0.27)); ctx.fillPath()
ctx.setFillColor(col(0.95, 0.95, 0.93))
for i in 0..<7 {
    let a = 1 - pow(0.62, CGFloat(i)), b = 1 - pow(0.62, CGFloat(i) + 0.55)        // 0 at bottom edge, 1 at vanishing point
    func pt(_ t: CGFloat, _ off: CGFloat) -> CGPoint { CGPoint(x: 445 + off * (1 - t) + (vp.x - 445) * t, y: 100 + (vp.y - 100) * t) }
    let d = CGMutablePath()
    d.move(to: pt(a, -9)); d.addLine(to: pt(a, 9)); d.addLine(to: pt(b, 9)); d.addLine(to: pt(b, -9)); d.closeSubpath()
    ctx.addPath(d); ctx.fillPath()
}

// the model: a high-wing trainer in a climbing turn, seen from above
ctx.saveGState()
ctx.translateBy(x: 505, y: 590)
ctx.rotate(by: -0.62)
ctx.scaleBy(x: 1.0, y: 0.86)
ctx.setShadow(offset: CGSize(width: 18, height: -26), blur: 30, color: col(0, 0.1, 0.3, 0.38))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
let red = col(0.88, 0.13, 0.11), darkRed = col(0.66, 0.08, 0.08), white = col(0.98, 0.98, 0.97)
// stabiliser
ctx.addPath(CGPath(roundedRect: CGRect(x: -112, y: -236, width: 224, height: 62), cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.setFillColor(red); ctx.fillPath()
// fuselage
let f = CGMutablePath()
f.move(to: CGPoint(x: 0, y: 262))
f.addCurve(to: CGPoint(x: 40, y: 130), control1: CGPoint(x: 24, y: 262), control2: CGPoint(x: 40, y: 200))
f.addLine(to: CGPoint(x: 15, y: -212))
f.addQuadCurve(to: CGPoint(x: -15, y: -212), control: CGPoint(x: 0, y: -236))
f.addLine(to: CGPoint(x: -40, y: 110))
f.addCurve(to: CGPoint(x: 0, y: 262), control1: CGPoint(x: -40, y: 200), control2: CGPoint(x: -24, y: 262))
ctx.addPath(f); ctx.setFillColor(white); ctx.fillPath()
// fin
ctx.addPath(CGPath(roundedRect: CGRect(x: -6, y: -240, width: 12, height: 96), cornerWidth: 6, cornerHeight: 6, transform: nil))
ctx.setFillColor(darkRed); ctx.fillPath()
// wing with white tip stripes
let wing = CGPath(roundedRect: CGRect(x: -292, y: 18, width: 584, height: 104), cornerWidth: 36, cornerHeight: 36, transform: nil)
ctx.addPath(wing); ctx.setFillColor(red); ctx.fillPath()
ctx.saveGState(); ctx.addPath(wing); ctx.clip()
ctx.setFillColor(white)
for x in [-236.0, 200.0] as [CGFloat] { ctx.fill(CGRect(x: x, y: 0, width: 36, height: 140)) }
ctx.setFillColor(col(0, 0, 0, 0.13)); ctx.fill(CGRect(x: -300, y: 18, width: 600, height: 24))      // ailerons / trailing edge
ctx.setFillColor(col(1, 1, 1, 0.16)); ctx.fill(CGRect(x: -300, y: 100, width: 600, height: 22))     // leading-edge highlight
ctx.restoreGState()
// canopy
ctx.setFillColor(col(0.10, 0.20, 0.42)); ctx.fillEllipse(in: CGRect(x: -23, y: 132, width: 46, height: 66))
ctx.setFillColor(col(0.55, 0.75, 1, 0.55)); ctx.fillEllipse(in: CGRect(x: -14, y: 162, width: 16, height: 26))
// spinner and propeller disc
ctx.setFillColor(col(1, 1, 1, 0.42)); ctx.fillEllipse(in: CGRect(x: -104, y: 252, width: 208, height: 20))
ctx.setFillColor(red); ctx.fillEllipse(in: CGRect(x: -17, y: 244, width: 34, height: 34))
ctx.endTransparencyLayer()
ctx.restoreGState()

// glassy top highlight and inner edge
ctx.drawLinearGradient(gradient([col(1, 1, 1, 0.16), col(1, 1, 1, 0)], [0, 1]),
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 700), options: [])
ctx.restoreGState()
ctx.addPath(shape); ctx.setStrokeColor(col(1, 1, 1, 0.22)); ctx.setLineWidth(3); ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
