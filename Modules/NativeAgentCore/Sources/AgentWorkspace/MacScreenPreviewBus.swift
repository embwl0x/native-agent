import Foundation
import CoreGraphics
import MacControl
import NativeAgentCore
import PersistenceCore

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
    /// Already downscaled and secret-masked by ``MacScreenPreviewFrame``.
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
/// surface has bound `publish` the four-verb path decodes nothing, masks
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
    /// Tense matches the frame, which is the whole point. `act` looks at the
    /// screen up to six times to resolve its target before it sends any input
    /// (MacFourVerbs+Act.swift:321, :342, :364), so every frame the card can
    /// show mid-verb is a PRE-action frame: it shows a Save button that has not
    /// been clicked. The words therefore promise nothing — "About to click
    /// Save" — and only ``settled(tool:input:ok:)`` speaks in the past tense,
    /// after the verb returns with its own verified result over the
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
            // `wait` sends no input at all — it only looks, repeatedly
            // (MacFourVerbs+Wait.swift:69, :119). Nothing is claimed by these
            // words that the frame does not show, so they stand for the whole
            // verb and there is no settled form.
            let until = safeTarget(text(input["until"]))
            return until.isEmpty ? "Waiting" : "Waiting for \(until)"
        default:
            return nil
        }
    }

    /// The caption for the frame captured AFTER the verb finished, said in the
    /// past tense only because two things now back it: the post-action look
    /// (MacFourVerbs+Act.swift:542, MacFourVerbs+Navigation.swift:81) is the
    /// frame on the card, and `ok` is the verb's own verified effect result.
    ///
    /// `nil` where there is nothing new to say: `screen` and `wait` never acted.
    public static func settled(tool: String, input: [String: JSONValue], ok: Bool) -> String? {
        switch tool {
        case "act":
            let verb = text(input["verb"])?.lowercased() ?? ""
            let target = safeTarget(text(input["target"]))
            let what = target.isEmpty ? "the screen" : target
            return ok ? "\(pastTense(verb)) \(what)" : "Could not \(plainVerb(verb)) \(what)"
        case "go":
            let name = safeTarget(text(input["name"]) ?? text(input["target"]))
            guard !name.isEmpty else { return nil }
            return ok ? "Opened \(name)" : "Could not open \(name)"
        default:
            return nil
        }
    }

    static func pastTense(_ verb: String) -> String {
        switch verb {
        case "click": return "Clicked"
        case "open": return "Opened"
        case "type": return "Typed into"
        case "select": return "Selected"
        case "toggle": return "Switched"
        case "scroll": return "Scrolled"
        case "dismiss": return "Dismissed"
        case "hover": return "Hovered over"
        case "move": return "Moved to"
        case "drag": return "Dragged"
        case "hold": return "Held"
        case "key": return "Pressed"
        default: return "Finished on"
        }
    }

    static func plainVerb(_ verb: String) -> String {
        switch verb {
        case "click": return "click"
        case "open": return "open"
        case "type": return "type into"
        case "select": return "select"
        case "toggle": return "switch"
        case "scroll": return "scroll"
        case "dismiss": return "dismiss"
        case "hover": return "hover over"
        case "move": return "move to"
        case "drag": return "drag"
        case "hold": return "hold"
        case "key": return "press"
        default: return "act on"
        }
    }

    /// The caption for a capture, named by the app actually resolved.
    public static func looking(at appName: String?) -> String {
        let name = safeTarget(appName)
        return name.isEmpty ? "Looking at the screen" : "Looking at \(name)"
    }

    static func act(verb: String, target: String) -> String {
        let what = target.isEmpty ? "the screen" : target
        return "About to \(plainVerb(verb)) \(what)"
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

/// Turns the frame a verb already captured into the frame the card can show:
/// small, and with every secure field painted out.
///
/// The perception path's redaction is text-only — it withholds a password
/// field's VALUE and LABEL from the legend while the pixels of that field ride
/// along inside the capture. A picture on screen is a second channel, so the
/// same verdict (``MacScreenViewBuilder.isSecretField``) is applied to the
/// pixels here: every secure field's rect is filled opaque before the image
/// leaves this function. The downscale is the other half — a 72pt thumbnail
/// and its sheet never need a retina desktop, and the cap bounds what one
/// turn holds in memory.
public enum MacScreenPreviewFrame {
    /// Widest preview kept. Comfortably above the expand sheet's drawn size,
    /// far below a captured retina desktop.
    public static let maxWidth = 960

    /// `marks` are the view's own control rows — role, subrole, label, value —
    /// in the same global screen points `origin`/`logicalSize` describe, which
    /// is what makes the mapping to pixels exact rather than approximate.
    public static func previewImage(
        from image: CGImage,
        marks: [JSONValue],
        origin: (x: Double, y: Double),
        logicalSize: (w: Double, h: Double)
    ) -> CGImage? {
        guard image.width > 0, image.height > 0,
              logicalSize.w > 0, logicalSize.h > 0 else { return nil }

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

        let secrets = secretRects(
            marks: marks,
            imagePixelSize: (w: image.width, h: image.height),
            origin: origin,
            logicalSize: logicalSize
        )
        if !secrets.isEmpty {
            // Opaque, not blurred: a blur of a short code is still the code.
            context.setFillColor(gray: 0.08, alpha: 1)
            for rect in secrets {
                // Image space is top-left origin; the context is bottom-left.
                let x = rect.minX * scale
                let w = rect.width * scale
                let h = rect.height * scale
                let y = Double(targetH) - (rect.minY * scale) - h
                context.fill(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        return context.makeImage()
    }

    /// Secure-field rects in the capture's PIXEL space, top-left origin.
    /// Public so the masking verdict can be exercised directly by the review
    /// fixture rather than re-implemented there — a security claim checked
    /// against a copy of the logic is not checked at all.
    public static func secretRects(
        marks: [JSONValue],
        imagePixelSize: (w: Int, h: Int),
        origin: (x: Double, y: Double),
        logicalSize: (w: Double, h: Double)
    ) -> [CGRect] {
        let scaleX = Double(imagePixelSize.w) / logicalSize.w
        let scaleY = Double(imagePixelSize.h) / logicalSize.h
        return marks.compactMap { value -> CGRect? in
            guard case .object(let mark) = value,
                  case .string(let role)? = mark["role"],
                  let frame = frame(mark["frame"]),
                  isSecret(mark: mark, role: role) else { return nil }
            let x = (frame.x - origin.x) * scaleX
            let y = (frame.y - origin.y) * scaleY
            let w = frame.w * scaleX
            let h = frame.h * scaleY
            let rect = CGRect(x: x, y: y, width: w, height: h)
                .intersection(CGRect(x: 0, y: 0, width: imagePixelSize.w, height: imagePixelSize.h))
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
            return rect
        }
    }

    static func isSecret(mark: [String: JSONValue], role: String) -> Bool {
        // The legend's own verdict, carried on the row it classified
        // (MacScreenView.swift:304, MacPerceptionCompiler.swift:279). It is the
        // canonical answer and it is checked FIRST: a field the compiler
        // classified as secret but whose value came back empty or truncated
        // would not trip the label test below, and would otherwise stay
        // readable in the picture after being withheld from the words.
        if mark["secret_field"] == .bool(true) { return true }
        let subrole: String? = {
            guard case .string(let value)? = mark["subrole"] else { return nil }
            return value
        }()
        // A label or value the text redactor already WITHHELD arrives as an
        // object rather than a string. That verdict is reused rather than
        // re-derived: whatever made the words unprintable makes the pixels
        // unshowable.
        if case .object? = mark["label"] { return true }
        if case .object? = mark["value"] { return true }
        let label: String? = {
            guard case .string(let value)? = mark["label"] else { return nil }
            return value
        }()
        if MacScreenViewBuilder.isSecretField(role: role, subrole: subrole, label: label) { return true }
        // Last signal, and the one that does not depend on how a toolkit names
        // things: a field whose displayed value is obscured glyphs IS a
        // password box, whatever its role, subrole or label say. AppKit and
        // WebKit both publish a secure field's value to accessibility as
        // bullets, so an unlabelled web `<input type=password>` with no secure
        // subrole — the one shape the checks above can miss — is caught here.
        if case .string(let value)? = mark["value"], isObscured(value) { return true }
        return false
    }

    /// True when every character is a mask glyph and there is at least one.
    static func isObscured(_ value: String) -> Bool {
        let masks: Set<Character> = ["\u{2022}", "\u{25CF}", "\u{00B7}", "\u{2024}", "*"]
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { masks.contains($0) }
    }

    private static func frame(_ value: JSONValue?) -> MacAXFrame? {
        guard case .object(let object)? = value else { return nil }
        func number(_ value: JSONValue?) -> Double? {
            switch value {
            case .int(let value)?: return Double(value)
            case .double(let value)? where value.isFinite: return value
            default: return nil
            }
        }
        guard let x = number(object["x"]), let y = number(object["y"]),
              let w = number(object["w"]), let h = number(object["h"]),
              w > 0, h > 0 else { return nil }
        return MacAXFrame(x: x, y: y, w: w, h: h)
    }
}
