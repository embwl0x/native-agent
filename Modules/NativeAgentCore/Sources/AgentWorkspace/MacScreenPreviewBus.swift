import Foundation
import CoreGraphics
import MacControl
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacScreenPreviewBus.swift` | `MacScreenPreviewBus` enum; preview resizes the source-masked observation |

/// What the agent is looking at, on its way to the chat's working card.
///
/// This is a LIVE VIEW, not evidence: the per-verb receipts remain the record
/// of what happened. Nothing here is persisted, and nothing here is sent to a
/// provider — the frame travels from the verb that already captured it to the
/// one card floating above the composer, inside this process.
///
/// Both fields are optional and mean "unchanged": a verb that moves the mouse
/// publishes a caption with no new frame and the card keeps showing the last
/// picture, while a capture with no caption keeps the words already there.
public struct MacScreenPreviewUpdate: @unchecked Sendable {
    /// Masked at capture, then downscaled by ``MacScreenPreviewFrame``.
    /// `nil` keeps whatever frame the card is showing.
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

/// The one channel from a Mac verb to the chat's live computer pane.
///
/// Dead-control-by-construction, exactly like ``ToolNoticeBus``: when no
/// surface has bound `publish` the preview decodes nothing, resizes
/// nothing, and hands nothing anywhere. A headless turn, a Telegram turn, and
/// every test therefore pay zero for this feature.
public enum MacScreenPreviewBus {
    /// Bound by the surface that owns a chat turn, for that turn's lifetime.
    @TaskLocal public static var publish: (@Sendable (MacScreenPreviewUpdate) async -> Void)?
}

/// Plain words for the verb in flight. Pure, so the copy is readable in one
/// place and testable without a screen.
///
/// House copy: the agent is never a pronoun. These are verb phrases with no
/// subject at all — the card's own title already names the agent.
public enum MacScreenPreviewCaption {
    /// Longest caption the card will show before truncating mid-word.
    static let maxTargetChars = 48

    /// What a bare target is called when it cannot be shown. A password field's
    /// label is frequently the password, so the same standalone-secret test the
    /// legend uses decides this.
    static let withheldTarget = "a hidden field"

    /// The caption for the frames captured WHILE a verb is in flight.
    ///
    /// In-flight frames precede input, so only ``settled(tool:input:ok:)``
    /// speaks in the past tense, backed by the verb's verified result and
    /// post-action frame.
    ///
    /// Returns `nil` for `screen`, whose best caption is the app the perception
    /// path resolved rather than the (often absent) `app` argument.
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

    /// The caption for the frame captured AFTER the verb finished, said in the
    /// past tense backed by the post-action frame and the verb's verified
    /// effect result in `ok`.
    ///
    /// `nil` where there is nothing new to say: `screen` and `wait` never acted.
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

    /// The caption for a capture, named by the app actually resolved.
    public static func looking(at appName: String?) -> String {
        let name = safeTarget(appName)
        return name.isEmpty ? "Looking at the screen" : "Looking at \(name)"
    }

    static func act(verb: String, target: String) -> String {
        let what = target.isEmpty ? "the screen" : target
        return "About to \(wordForms(verb).plain) \(what)"
    }

    /// One line, bounded, and never the secret itself. `act.text` — the typed
    /// string — is deliberately never a caption input; only labels are.
    static func safeTarget(_ raw: String?) -> String {
        guard let raw else { return "" }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        // The same verdict the legend and prose channels use. A label shaped
        // like a code or key is withheld here too, rather than being printed
        // above the composer in 11pt.
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

/// Sizes the source-masked observation for the card.
public enum MacScreenPreviewFrame {
    /// Widest preview kept. Comfortably above the expand sheet's drawn size,
    /// far below a captured retina desktop.
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
