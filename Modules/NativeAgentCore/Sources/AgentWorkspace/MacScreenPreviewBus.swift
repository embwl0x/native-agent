import Foundation
import CoreGraphics
import MacControl
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacScreenPreviewBus.swift` | Shared masked screen previews, capture geometry and bounded read text; source replacement clears stale content. |

/// Preview is transient presentation, never evidence or provider input; per-verb receipts remain authoritative.
public struct MacScreenPreviewUpdate: @unchecked Sendable {
    /// Masked before downscaling. `nil` keeps current content unless a read or explicit source replacement arrives.
    public let image: CGImage?
    /// The read's returned text and structure, bounded before publication; mutually exclusive with an image.
    public let readText: String?
    /// One line of plain words. `nil` keeps the caption already shown.
    public let caption: String?
    public let at: Date
    /// A new source must not keep another page's picture or read text.
    public let replacesImage: Bool

    public init(image: CGImage?, caption: String?, at: Date, replacesImage: Bool = false, readText: String? = nil) {
        self.image = image
        self.readText = image == nil ? readText.flatMap(MacScreenPreviewReadText.screenful) : nil
        self.caption = caption
        self.at = at
        self.replacesImage = replacesImage
    }
}

/// One readable screenful, preserving the read's line breaks, headings and numbered rows.
public enum MacScreenPreviewReadText {
    // A conventional 80-column, 24-row text viewport bounds transient retention.
    // WorkPane also caps drawn lines because its narrower width can wrap a source row.
    public static let maxLines = 24
    private static let maxCharacters = 80 * maxLines

    public static func screenful(_ text: String) -> String? {
        let bounded = String(text.prefix(maxCharacters)).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).joined(separator: "\n")
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bounded
    }
}

/// Use subject-free verb phrases because the card title already names the agent.
public enum MacScreenPreviewCaption {
    /// Bound captions before mid-word truncation.
    static let maxTargetChars = 48

    /// A password field's label may be the password; use the shared secret check before displaying it.
    static let withheldTarget = "a hidden field"

    /// In-flight frames precede input; only verified settled results may use past tense. Captures name the app actually resolved.
    public static func intent(tool: String, input: [String: JSONValue]) -> String? {
        switch tool {
        case "screen":
            return nil
        case "act":
            let verb = text(input["verb"])?.lowercased() ?? ""
            let target = safeTarget(text(input["target"]))
            return act(verb: verb, target: target)
        case "go":
            let name = safeTarget(text(input["name"]) ?? text(input["target"]))
            return name.isEmpty ? "About to open something" : "About to open \(name)"
        case "wait":
            // `wait` only looks, so its caption has no settled form.
            let until = safeTarget(text(input["until"]))
            return until.isEmpty ? "Waiting" : "Waiting for \(until)"
        default:
            return nil
        }
    }

    /// Past-tense captions require the post-action frame and verified result; screen and wait do not act.
    public static func settled(tool: String, input: [String: JSONValue], ok: Bool) -> String? {
        switch tool {
        case "act":
            let verb = text(input["verb"])?.lowercased() ?? ""
            let target = safeTarget(text(input["target"]))
            let what = target.isEmpty ? "the screen" : target
            let forms = wordForms(verb)
            return ok ? "\(forms.past) \(what)" : "Could not \(forms.plain) \(what)"
        case "go":
            let name = safeTarget(text(input["name"]) ?? text(input["target"]))
            guard !name.isEmpty else { return nil }
            return ok ? "Opened \(name)" : "Could not open \(name)"
        default:
            return nil
        }
    }

    static func wordForms(_ verb: String) -> (past: String, plain: String) {
        switch verb {
        case "click": return ("Clicked", "click")
        case "open": return ("Opened", "open")
        case "type": return ("Typed into", "type into")
        case "select": return ("Selected", "select")
        case "toggle": return ("Switched", "switch")
        case "scroll": return ("Scrolled", "scroll")
        case "dismiss": return ("Dismissed", "dismiss")
        case "hover": return ("Hovered over", "hover over")
        case "move": return ("Moved to", "move to")
        case "drag": return ("Dragged", "drag")
        case "hold": return ("Held", "hold")
        case "key": return ("Pressed", "press")
        default: return ("Finished on", "act on")
        }
    }

    /// Use the resolved app for capture captions instead of a possibly absent argument.
    public static func looking(at appName: String?) -> String {
        let name = safeTarget(appName)
        return name.isEmpty ? "Looking at the screen" : "Looking at \(name)"
    }

    /// Site and title are labels, never typed values or URL queries.
    public static func browser(activity: String, title: String?, url: String?) -> String {
        let site = safeTarget(url.flatMap { URL(string: $0)?.host })
        let title = safeTarget(title)
        return activity + " " + (site.isEmpty ? "in Chrome" : site) + (title.isEmpty ? "" : " — " + title)
    }

    public static func unavailable(_ reason: String) -> String {
        "preview unavailable: " + safeTarget(reason)
    }

    static func act(verb: String, target: String) -> String {
        let what = target.isEmpty ? "the screen" : target
        return "About to \(wordForms(verb).plain) \(what)"
    }

    /// Only labels enter captions; typed text must never be exposed as a caption input.
    static func safeTarget(_ raw: String?) -> String {
        guard let raw else { return "" }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        // Apply the same secret verdict as legend and prose so code-like labels cannot leak above the composer.
        if MacScreenViewTextRedaction.standaloneSecretReason(collapsed) != nil {
            return withheldTarget
        }
        guard collapsed.count > maxTargetChars else { return collapsed }
        return String(collapsed.prefix(maxTargetChars - 1)) + "\u{2026}"
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }
}

/// Paint local copies at source resolution; resize only source-masked observations.
public enum MacScreenPreviewFrame {
    /// Keep previews above the expanded card's drawn size but below retina-desktop resolution.
    public static let maxWidth = 960

    /// Paint the returned capture's geometry onto a local source-resolution copy before resizing.
    /// Geometry uses the capture's top-left origin, in units of its declared viewport width/height.
    public static func previewImage(from image: CGImage, painting geometry: JSONValue) -> CGImage? {
        guard let fields = geometry.objectValue,
              let width = fields["width"]?.numberValue(coercingStrings: false, finiteOnly: true), width > 0,
              let height = fields["height"]?.numberValue(coercingStrings: false, finiteOnly: true), height > 0,
              let rects = fields["rects"]?.arrayValue,
              image.width > 0, image.height > 0,
              // Bound source pixels without multiplication overflow.
              image.width <= 32_000_000 / image.height,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }

        let pixelWidth = Double(image.width), pixelHeight = Double(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(gray: 24.0 / 255.0, alpha: 1)
        for value in rects {
            guard let rect = value.objectValue,
                  let x = rect["x"]?.numberValue(coercingStrings: false, finiteOnly: true), x >= 0, x <= width,
                  let y = rect["y"]?.numberValue(coercingStrings: false, finiteOnly: true), y >= 0, y <= height,
                  let w = rect["width"]?.numberValue(coercingStrings: false, finiteOnly: true), w > 0, w <= width - x,
                  let h = rect["height"]?.numberValue(coercingStrings: false, finiteOnly: true), h > 0, h <= height - y else { return nil }
            // Outward rounding and the existing two source-pixel margin cover antialiased field edges.
            // Normalize before multiplying so finite viewport coordinates cannot overflow pixel arithmetic.
            let left = max(0, (x / width * pixelWidth).rounded(.down) - 2)
            let top = max(0, (y / height * pixelHeight).rounded(.down) - 2)
            let right = min(pixelWidth, ((x + w) / width * pixelWidth).rounded(.up) + 2)
            let bottom = min(pixelHeight, ((y + h) / height * pixelHeight).rounded(.up) + 2)
            // CoreGraphics has a bottom-left origin; Chrome's capture has a top-left origin.
            context.fill(CGRect(x: left, y: pixelHeight - bottom, width: right - left, height: bottom - top))
        }
        guard let masked = context.makeImage() else { return nil }
        return previewImage(from: masked)
    }

    public static func previewImage(from image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }

        let scale = min(1, Double(maxWidth) / Double(image.width))
        let targetW = max(1, Int((Double(image.width) * scale).rounded()))
        let targetH = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        return context.makeImage()
    }
}
