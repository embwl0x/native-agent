import AppKit
import CoreGraphics
import ImageIO

// The macOS frame needs a transparent margin and baked shadow around its squircle.
@main
enum RenderMacIcon {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: render_icon.sh mac <output.png>\n", stderr)
            exit(2)
        }

        guard let ctx = CGContext(data: nil, width: Int(livingCoreSize), height: Int(livingCoreSize), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: livingCoreColorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("could not create mac icon bitmap context")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: livingCoreSize, height: livingCoreSize))
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

        guard let image = ctx.makeImage() else { fatalError("could not create mac icon image") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
            fatalError("could not create mac icon png destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("mac icon png write failed") }
        print("wrote mac living-core icon")
    }
}
