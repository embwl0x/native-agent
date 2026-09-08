import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Production renderer (CoreGraphics + CoreText)

#if canImport(CoreGraphics) && canImport(CoreText) && os(macOS)

/// Set-of-marks renderer.
///
/// LEGIBILITY IN BOTH THEMES, deterministically: every stroke is drawn twice —
/// a thick WHITE halo underneath and a thin BLACK line on top — so the marker
/// survives a white background and a black one without sampling the pixels
/// underneath (sampling would make the output depend on the screen's content,
/// which is exactly the non-determinism a set-of-marks image must not have).
/// The number badge is the same sandwich: white plate, black border, black
/// digits.
public struct CoreGraphicsMacScreenImageRenderer: MacScreenImageRenderer {
    public init() {}

    public func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        downscale: Double
    ) -> Data? {
        guard let source = shot.cgImage else { return nil }
        let factor = max(0.05, min(downscale, 1.0))
        let width = max(1, Int((Double(shot.pixelWidth) * factor).rounded()))
        let height = max(1, Int((Double(shot.pixelHeight) * factor).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Marker scale: tie the badge to the IMAGE's own size so a 1x window
        // capture and a 2x retina capture look the same to the eye.
        let unit = max(1.0, Double(min(width, height)) / 400.0)
        let lineWidth = max(1.0, 1.5 * unit)
        let fontSize = max(9.0, 9.0 * unit)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        for placement in placements {
            let x = placement.x * factor
            let w = max(1.0, placement.w * factor)
            let h = max(1.0, placement.h * factor)
            // Placements are top-left origin (image space); CGContext is
            // bottom-left. Flip once, here, at the boundary.
            let y = Double(height) - (placement.y * factor) - h
            let rect = CGRect(x: x, y: y, width: w, height: h)

            context.setLineWidth(lineWidth * 2.2)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
            context.stroke(rect)
            context.setLineWidth(lineWidth)
            context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.95))
            context.stroke(rect)

            drawBadge(
                context: context,
                number: placement.mark,
                font: font,
                fontSize: fontSize,
                unit: unit,
                anchor: CGPoint(x: rect.minX, y: rect.maxY)
            )
        }

        guard let annotated = context.makeImage() else { return nil }
        return Self.encodePNG(annotated)
    }

    private func drawBadge(
        context: CGContext,
        number: Int,
        font: CTFont,
        fontSize: Double,
        unit: Double,
        anchor: CGPoint
    ) {
        let text = String(number)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        let textBounds = CTLineGetImageBounds(line, context)
        let padding = 2.0 * unit
        let plateWidth = max(fontSize, textBounds.width) + padding * 2
        let plateHeight = fontSize + padding * 2
        // Badge sits just ABOVE the element's top-left corner, tucked back
        // inside the image when the element is flush with an edge.
        var plate = CGRect(
            x: anchor.x,
            y: anchor.y,
            width: plateWidth,
            height: plateHeight
        )
        let canvasWidth = Double(context.width)
        let canvasHeight = Double(context.height)
        if plate.maxX > canvasWidth { plate.origin.x = canvasWidth - plate.width }
        if plate.maxY > canvasHeight { plate.origin.y = canvasHeight - plate.height }
        plate.origin.x = max(0, plate.origin.x)
        plate.origin.y = max(0, plate.origin.y)

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
        context.fill(plate)
        context.setLineWidth(max(1.0, unit))
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.stroke(plate)

        context.textPosition = CGPoint(
            x: plate.minX + (plate.width - textBounds.width) / 2 - textBounds.minX,
            y: plate.minY + padding
        )
        CTLineDraw(line, context)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        #if canImport(AppKit)
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}

#endif

/// Platform fallback: no renderer, reported as an encode failure rather than a
/// blank image.
public struct UnavailableMacScreenImageRenderer: MacScreenImageRenderer {
    public init() {}
    public func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        downscale: Double
    ) -> Data? { nil }
}

public func defaultMacScreenImageRenderer() -> any MacScreenImageRenderer {
    #if canImport(CoreGraphics) && canImport(CoreText) && os(macOS)
    return CoreGraphicsMacScreenImageRenderer()
    #else
    return UnavailableMacScreenImageRenderer()
    #endif
}
