import AppKit
import CoreGraphics
import ImageIO

// iOS frame for the shared Living Core: opaque, full-bleed 1024.
@main
enum RenderIOSIcon {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: render_icon.sh ios <output.png>\n", stderr)
            exit(2)
        }
        let ctx = CGContext(data: nil, width: Int(livingCoreSize), height: Int(livingCoreSize), bitsPerComponent: 8,
                            bytesPerRow: 0, space: livingCoreColorSpace,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        drawLivingCore(ctx)
        let image = ctx.makeImage()!
        let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
        let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("png write failed") }
        print("wrote ios living-core icon (opaque, no alpha)")
    }
}
