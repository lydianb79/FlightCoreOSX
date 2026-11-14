// Draws the FlightCore app icon in the style of the splash artwork. Usage: swift Tools/make_icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
let red = col(0.76, 0.13, 0.10), ring1 = col(0.70, 0.10, 0.08), ring2 = col(0.66, 0.09, 0.07)
let shadow = col(0.50, 0.07, 0.05), cream = col(0.965, 0.93, 0.875), ink = col(0.11, 0.075, 0.07), propCol = col(0.42, 0.08, 0.06)

// macOS icon shape: 824pt rounded square on a 1024 canvas, with a soft drop shadow
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: col(0, 0, 0, 0.35))
ctx.addPath(shape); ctx.setFillColor(red); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// concentric discs behind the aircraft
let c = CGPoint(x: 560, y: 480)
for (r, colr) in [(CGFloat(470), ring1), (330, ring2)] {
    ctx.setFillColor(colr); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

/// The aircraft from above, nose toward +y. `fill` nil draws the full-colour version.
func plane(_ fill: CGColor?) {
    func rr(_ r: CGRect, _ rad: CGFloat, _ color: CGColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)); ctx.setFillColor(fill ?? color); ctx.fillPath()
    }
    // propeller (behind the spinner)
    if fill == nil {
        ctx.setStrokeColor(propCol); ctx.setLineWidth(11); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: -150, y: 318)); ctx.addLine(to: CGPoint(x: 150, y: 318)); ctx.strokePath()
    }
    // tailplane, wing
    let stab = CGRect(x: -150, y: -330, width: 300, height: 96), wing = CGRect(x: -330, y: 10, width: 660, height: 176)
    rr(stab, 48, cream); rr(wing, 84, cream)
    // fuselage: wide at the wing, tapering to the tail, rounded nose
    let f = CGMutablePath()
    f.move(to: CGPoint(x: -46, y: -300))
    f.addLine(to: CGPoint(x: -62, y: 150))
    f.addCurve(to: CGPoint(x: 0, y: 330), control1: CGPoint(x: -62, y: 250), control2: CGPoint(x: -40, y: 330))
    f.addCurve(to: CGPoint(x: 62, y: 150), control1: CGPoint(x: 40, y: 330), control2: CGPoint(x: 62, y: 250))
    f.addLine(to: CGPoint(x: 46, y: -300)); f.closeSubpath()
    ctx.addPath(f); ctx.setFillColor(fill ?? cream); ctx.fillPath()
    guard fill == nil else { return }
    // red tip stripes
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: wing, cornerWidth: 84, cornerHeight: 84, transform: nil)); ctx.clip()
    ctx.setFillColor(red)
    for x in [CGFloat(-262), 228] { ctx.fill(CGRect(x: x, y: 0, width: 34, height: 200)) }
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: stab, cornerWidth: 48, cornerHeight: 48, transform: nil)); ctx.clip()
    for x in [CGFloat(-118), 100] { ctx.fill(CGRect(x: x, y: -340, width: 18, height: 120)) }
    ctx.restoreGState()
    // canopy and spinner
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: -34, y: 196, width: 68, height: 98))
    ctx.fillEllipse(in: CGRect(x: -34, y: 286, width: 68, height: 68))
}

let angle: CGFloat = 0.56          // nose toward the upper left, as on the splash screen
for pass in 0..<2 {
    ctx.saveGState()
    ctx.translateBy(x: 520 + (pass == 0 ? 34 : 0), y: 500 - (pass == 0 ? 44 : 0))
    ctx.rotate(by: angle)
    ctx.scaleBy(x: 0.98, y: 0.98)
    plane(pass == 0 ? shadow : nil)
    ctx.restoreGState()
}
ctx.restoreGState()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
