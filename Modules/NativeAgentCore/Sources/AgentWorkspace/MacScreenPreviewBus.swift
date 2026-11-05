import Foundation
import CoreGraphics
import MacControl
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacScreenPreviewBus.swift` | `MacScreenPreviewUpdate`, captions and source-masked resizing; the turn carries its screen-preview sink |

/// Preview is transient presentation, never evidence or provider input; per-verb receipts remain authoritative. Nil fields mean unchanged.
public struct MacScreenPreviewUpdate: @unchecked Sendable {
    /// Masked at capture, then downscaled by ``MacScreenPreviewFrame``. `nil` keeps whatever frame the card is showing.
    public let image: CGImage?
    /// One line of plain words. `nil` keeps the caption already shown.
    public let caption: String?
    public let at: Date

    public init(image: CGImage?, caption: String?, at: Date) {
        self.image = image
        self.caption = caption
        self.at = at
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

/// Resize only source-masked observations.
public enum MacScreenPreviewFrame {
    /// Keep previews above the expanded card's drawn size but below retina-desktop resolution.
    public static let maxWidth = 960

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
