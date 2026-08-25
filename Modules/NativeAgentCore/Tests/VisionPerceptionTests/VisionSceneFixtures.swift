import Foundation
import CoreGraphics
import CoreText
@testable import VisionPerception

// MARK: - Synthetic GENERIC UI scenes, rendered to REAL pixels
//
// These are not fixtures of what OCR "would" say — they are CGImages, and the
// tests run the real pipeline over them. A fixture of the text layer's output
// would encode my assumptions about the pixels and then test them against
// themselves; rendering the scene and reading it back is the difference
// between a passing test and evidence.
//
// GENERIC by construction: filled borderless buttons, bordered fields, a
// text-only list, a greyed control, a captioned secret. Nothing here names an
// app, and no rule in the module keys on this scene.

enum Scene {
    struct Target {
        let name: String
        let rect: VisionRect
        let expectedRole: String
    }

    struct Rendered {
        let image: CGImage
        let targets: [Target]
        let size: VisionSize
    }

    static let background = CGColor(red: 0.918, green: 0.918, blue: 0.918, alpha: 1)

    static func context(width: Int, height: Int) -> CGContext {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Top-left origin for every coordinate in this file, so the scene's
        // numbers and the module's rects are in the same space.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    static func fill(_ context: CGContext, _ rect: VisionRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h))
    }

    static func text(
        _ context: CGContext,
        _ string: String,
        at point: CGPoint,
        size: CGFloat = 15,
        color: CGColor = CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
        bold: Bool = false
    ) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes)
        )
        context.saveGState()
        // Undo the flip for glyph drawing only, so text is not mirrored.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + size * 0.8)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Centred caption inside a rect — the button shape.
    static func centredText(
        _ context: CGContext,
        _ string: String,
        in rect: VisionRect,
        size: CGFloat = 15,
        color: CGColor
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        text(
            context,
            string,
            at: CGPoint(x: rect.x + (rect.w - width) / 2, y: rect.y + (rect.h - size) / 2 - 1),
            size: size,
            color: color
        )
    }

    static let blue = CGColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)
    static let red = CGColor(red: 0.80, green: 0.20, blue: 0.18, alpha: 1)
    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let greyFill = CGColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
    static let greyText = CGColor(red: 0.67, green: 0.67, blue: 0.67, alpha: 1)
    static let darkText = CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)

    /// THE MAIN SCENE. Buttons (filled, borderless), fields (white wells), a
    /// TEXT-ONLY list (no fill contrast at all — the y-band clusterer's job),
    /// a greyed control, a title, and a captioned three-digit secret.
    ///
    /// - Parameter redraw: a HARMLESS redraw — a caret blink and a changed
    ///   decoration far from every target. Nothing moves. Handles must not
    ///   change across it.
    static func mainScene(redraw: Bool = false) -> Rendered {
        let width = 900
        let height = 560
        let context = self.context(width: width, height: height)

        text(context, "Account Settings", at: CGPoint(x: 40, y: 24), size: 24, bold: true)

        // A HARMLESS redraw also nudges the controls by a single pixel —
        // real windows do not re-lay-out to the same subpixel, and a handle
        // scheme that only survives a pixel-identical frame has not survived
        // anything. Quantized position absorbs it; raw pixels would not.
        let nudge = redraw ? 1.0 : 0.0
        let save = VisionRect(x: 40 + nudge, y: 80, w: 130, h: 42)
        let delete = VisionRect(x: 190 + nudge, y: 80, w: 190, h: 42)
        let archive = VisionRect(x: 400 + nudge, y: 80, w: 140, h: 42)
        fill(context, save, blue)
        centredText(context, "Save", in: save, color: white)
        fill(context, delete, red)
        centredText(context, "Delete Account", in: delete, color: white)
        // Greyed: low-contrast caption on a low-contrast fill.
        fill(context, archive, greyFill)
        centredText(context, "Archive", in: archive, color: greyText)

        let email = VisionRect(x: 40 + nudge, y: 150, w: 320, h: 38)
        let name = VisionRect(x: 40 + nudge, y: 200, w: 320, h: 38)
        fill(context, email, white)
        text(context, "user@example.com", at: CGPoint(x: email.x + 10, y: email.y + 10))
        fill(context, name, white)

        // A three-digit code under its caption. In PIXELS this is just "123";
        // only the caption beside it makes it a secret, which is exactly the
        // geometry the pixel channel has to prove it still applies.
        text(context, "CVV", at: CGPoint(x: 600, y: 158), size: 14)
        text(context, "451", at: CGPoint(x: 660, y: 158), size: 14)

        // The list: NO fill. White-on-background rows were the colour layer's
        // known miss (spike v1) and are the reason y-band clustering exists.
        var rows: [VisionRect] = []
        for index in 0..<5 {
            let y = 280.0 + Double(index) * 44
            text(context, "Report \(index + 1)", at: CGPoint(x: 60, y: y))
            text(context, "\(12 + index * 3) pts", at: CGPoint(x: 700, y: y))
            rows.append(VisionRect(x: 60, y: y, w: 700, h: 18))
        }

        if redraw {
            // A caret in the empty field and a one-shade decoration change in
            // a corner that holds no target. Harmless by construction.
            fill(context, VisionRect(x: name.x + 8, y: name.y + 8, w: 2, h: 22), darkText)
            fill(context, VisionRect(x: 840, y: 20, w: 30, h: 12),
                 CGColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1))
        } else {
            fill(context, VisionRect(x: 840, y: 20, w: 30, h: 12),
                 CGColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1))
        }

        var targets: [Target] = [
            Target(name: "Save", rect: save, expectedRole: VisionRoleGuess.button),
            Target(name: "Delete Account", rect: delete, expectedRole: VisionRoleGuess.button),
            Target(name: "Archive", rect: archive, expectedRole: VisionRoleGuess.button),
            Target(name: "email field", rect: email, expectedRole: VisionRoleGuess.textField),
            Target(name: "name field", rect: name, expectedRole: VisionRoleGuess.textField),
        ]
        for (index, rect) in rows.enumerated() {
            targets.append(Target(name: "row \(index + 1)", rect: rect, expectedRole: VisionRoleGuess.row))
        }

        return Rendered(
            image: context.makeImage()!,
            targets: targets,
            size: VisionSize(width: Double(width), height: Double(height))
        )
    }

    /// A scene where ABSTAINING IS THE CORRECT OUTPUT.
    ///
    /// A list of text-only rows, one of which carries an INLINE ACTION BUTTON
    /// sitting across the middle of the row. The row and the button are two
    /// different elements, and each one's action point falls inside the other:
    /// a click at the row's centre is a click on the button. There is no
    /// honest way to say which one a caller meant, so both must come back
    /// marked ambiguous — and forcing a pick would be exactly the hopeful
    /// click the contract exists to prevent.
    ///
    /// The other two rows and the unrelated button are unambiguous, so the
    /// abstain rate is a RATE and not "everything abstained".
    static func inlineActionScene() -> Rendered {
        let width = 720
        let height = 420
        let context = self.context(width: width, height: height)

        var rows: [VisionRect] = []
        for index in 0..<3 {
            let y = 100.0 + Double(index) * 60
            text(context, "Alpha \(index + 1)", at: CGPoint(x: 300, y: y))
            text(context, "ready", at: CGPoint(x: 560, y: y))
            rows.append(VisionRect(x: 300, y: y, w: 300, h: 18))
        }
        // Straddling the middle row, centred on it.
        let inline = VisionRect(x: 395, y: 142, w: 120, h: 36)
        fill(context, inline, blue)
        centredText(context, "Open", in: inline, size: 13, color: white)

        let unrelated = VisionRect(x: 80, y: 330, w: 130, h: 44)
        fill(context, unrelated, red)
        centredText(context, "Quit", in: unrelated, color: white)

        return Rendered(
            image: context.makeImage()!,
            targets: [
                Target(name: "inline Open", rect: inline, expectedRole: VisionRoleGuess.button),
                Target(name: "middle row", rect: rows[1], expectedRole: VisionRoleGuess.row),
                Target(name: "Quit", rect: unrelated, expectedRole: VisionRoleGuess.button),
            ],
            size: VisionSize(width: Double(width), height: Double(height))
        )
    }

    /// A scene whose only text is a standalone secret shape — a one-time code
    /// and an API-key-looking token, with no caption anywhere near them.
    static func secretsScene() -> Rendered {
        let width = 640
        let height = 300
        let context = self.context(width: width, height: height)
        text(context, "482913", at: CGPoint(x: 60, y: 60), size: 20)
        text(context, "sk-live-3kZq81PvA0dLwYtR7m", at: CGPoint(x: 60, y: 140), size: 16)
        return Rendered(
            image: context.makeImage()!,
            targets: [],
            size: VisionSize(width: Double(width), height: Double(height))
        )
    }
}

// MARK: - Helpers

extension Scene.Rendered {
    /// Does any emitted row cover this target well enough to count as a hit?
    /// IoU ≥ 0.4 against a synthetic rect is a real recall bar: a candidate
    /// that grew to the wrong extent does not sneak through.
    func hit(_ target: Scene.Target, in rows: [VisionAffordanceRow]) -> VisionAffordanceRow? {
        rows.filter { $0.rect.iou(target.rect) >= 0.4 }
            .max { $0.rect.iou(target.rect) < $1.rect.iou(target.rect) }
    }
}
