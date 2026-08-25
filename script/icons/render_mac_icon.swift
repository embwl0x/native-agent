import AppKit
import CoreGraphics

// macOS frame for the shared Living Core: Big Sur+ squircle, transparent
// margin, and baked soft shadow.
@main
enum RenderMacIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: render_icon.sh mac <output.png>\n", stderr)
            exit(2)
        }

        let image = NSImage(size: NSSize(width: livingCoreSize, height: livingCoreSize))
        image.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        let inset: CGFloat = 34
        let squircle = CGRect(x: inset, y: inset, width: livingCoreSize - 2 * inset, height: livingCoreSize - 2 * inset)
        let radius = squircle.width * 0.2237

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: squircle, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color(0x083D42).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: squircle, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        drawLivingCore(ctx)
        let rim = CGGradient(colorsSpace: livingCoreColorSpace,
            colors: [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: livingCoreSize - inset), end: CGPoint(x: 512, y: 680), options: [])
        ctx.restoreGState()

        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try representation.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("wrote mac living-core icon")
    }
}
