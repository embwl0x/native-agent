import AppKit
import CoreGraphics

// Shared Living Core composition. Platform renderers own only their frame and
// output format; any pixel change to the core now has exactly one source.
func color(_ hex: UInt, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let livingCoreColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let livingCoreSize: CGFloat = 1024

func drawLivingCore(_ ctx: CGContext) {
    ctx.setFillColor(color(0x04262A).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: livingCoreSize, height: livingCoreSize))
    let field = CGGradient(colorsSpace: livingCoreColorSpace,
        colors: [color(0x11757B).cgColor, color(0x04262A, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(field, startCenter: CGPoint(x: 512, y: 540), startRadius: 40,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 620, options: [])
    let aura = CGGradient(colorsSpace: livingCoreColorSpace,
        colors: [color(0x2DE0CB, 0.42).cgColor, color(0x2DE0CB, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(aura, startCenter: CGPoint(x: 512, y: 540), startRadius: 120,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 470, options: [])

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0x5EEAD4, 0.50).cgColor); ctx.setLineWidth(11)
    ctx.addArc(center: CGPoint(x: 512, y: 528), radius: 322, startAngle: .pi * 1.16, endAngle: .pi * 1.92, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(color(0x9CFCEC, 0.30).cgColor); ctx.setLineWidth(6)
    ctx.addArc(center: CGPoint(x: 512, y: 528), radius: 360, startAngle: .pi * 0.12, endAngle: .pi * 0.60, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    let orbCenter = CGPoint(x: 512, y: 528); let orbRadius: CGFloat = 250
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2))
    ctx.clip()
    let core = CGGradient(colorsSpace: livingCoreColorSpace,
        colors: [color(0xF2FFFD).cgColor, color(0x54E6D6).cgColor, color(0x0B4C51).cgColor] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(core, startCenter: CGPoint(x: orbCenter.x - 70, y: orbCenter.y + 64), startRadius: 46,
                           endCenter: orbCenter, endRadius: orbRadius,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(7)
    ctx.addArc(center: orbCenter, radius: orbRadius - 5, startAngle: .pi * 0.30, endAngle: .pi * 0.86, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}
