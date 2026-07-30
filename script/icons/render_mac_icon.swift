import AppKit
import CoreGraphics

// NativeAgent app icon — "Living Core" (teal, Agent's color).
// macOS form: the Living Core composition inside a Big Sur+ squircle with a
// transparent margin and a soft drop shadow (baked in; macOS does not mask it).
//
// Shares the exact core composition with render_ios_icon.swift — only the frame
// (squircle + margin + shadow vs. full-bleed) differs between the two platforms.

func color(_ hex: UInt, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF)/255, green: CGFloat((hex >> 8) & 0xFF)/255,
            blue: CGFloat(hex & 0xFF)/255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let S: CGFloat = 1024

func drawLivingCore(_ ctx: CGContext) {
    // Deep teal field
    ctx.setFillColor(color(0x04262A).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
    let field = CGGradient(colorsSpace: space,
        colors: [color(0x11757B).cgColor, color(0x04262A, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(field, startCenter: CGPoint(x: 512, y: 540), startRadius: 40,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 620, options: [])
    // Outer teal aura
    let aura = CGGradient(colorsSpace: space,
        colors: [color(0x2DE0CB, 0.42).cgColor, color(0x2DE0CB, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(aura, startCenter: CGPoint(x: 512, y: 540), startRadius: 120,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 470, options: [])
    // A single sweeping orbit (continuity / a thought), behind the core
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0x5EEAD4, 0.50).cgColor); ctx.setLineWidth(11)
    ctx.addArc(center: CGPoint(x: 512, y: 528), radius: 322, startAngle: .pi * 1.16, endAngle: .pi * 1.92, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(color(0x9CFCEC, 0.30).cgColor); ctx.setLineWidth(6)
    ctx.addArc(center: CGPoint(x: 512, y: 528), radius: 360, startAngle: .pi * 0.12, endAngle: .pi * 0.60, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
    // Luminous core orb (white-hot -> teal -> deep), highlight upper-left
    let orbC = CGPoint(x: 512, y: 528); let orbR: CGFloat = 250
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: orbC.x - orbR, y: orbC.y - orbR, width: orbR*2, height: orbR*2))
    ctx.clip()
    let core = CGGradient(colorsSpace: space,
        colors: [color(0xF2FFFD).cgColor, color(0x54E6D6).cgColor, color(0x0B4C51).cgColor] as CFArray,
        locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(core, startCenter: CGPoint(x: orbC.x - 70, y: orbC.y + 64), startRadius: 46,
                           endCenter: orbC, endRadius: orbR,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    // Rim light on top of orb
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(7)
    ctx.addArc(center: orbC, radius: orbR - 5, startAngle: .pi * 0.30, endAngle: .pi * 0.86, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS squircle: transparent margin, Big Sur+ corner radius.
let inset: CGFloat = 34
let squircle = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let radius = squircle.width * 0.2237

// Drop shadow under the squircle plate
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(CGPath(roundedRect: squircle, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.setFillColor(color(0x083D42).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Clip to the squircle and draw the Living Core
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: squircle, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
drawLivingCore(ctx)
// Top-edge inner highlight (glass rim)
let rim = CGGradient(colorsSpace: space,
    colors: [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: S - inset), end: CGPoint(x: 512, y: 680), options: [])
ctx.restoreGState()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote mac living-core icon")
