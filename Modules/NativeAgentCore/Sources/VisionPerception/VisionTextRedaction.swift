import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl

// MARK: - REDACTION on the pixel channel
//
// A vision percept rides the ordinary tool sinks — turn trace, persisted tool
// row, iOS/Telegram sync. A screen that shows a one-time code shows it in
// PIXELS, and OCR turns those pixels into a string in a JSON payload. So the
// pixel channel gets the SAME redactor the AX channel uses, not a second one:
// `MacScreenViewTextRedaction` is imported, never re-implemented. Two copies
// drift, and the copy that drifts is the one nobody re-reviews (the reason
// ActivityWatch depends on MacControl for exactly this, Package.swift).
//
// What this file DOES own is the GEOMETRY, because the pixel channel has no AX
// tree: there are no enclosing groups and no control captions, only boxes. So
// the beside/above caption test that `MacScreenViewTextRedaction.applied` runs
// over AX frames is run here over OCR BOXES — the caption of a value is the
// short text immediately left of it on the same line, or directly above it.
// That is the design detail the v0 pipeline said it had to prove.

public struct VisionRedactedText: Sendable, Equatable {
    /// The recognized string, kept in memory for geometry and matching. It is
    /// NEVER what rides out — `json` is.
    public let raw: String
    /// What the percept emits: the clear string, or the redactor's
    /// `{redacted, sha256, reason}` digest object.
    public let json: JSONValue
    public let secret: Bool
    public let reason: String?

    public init(raw: String, json: JSONValue, secret: Bool, reason: String?) {
        self.raw = raw
        self.json = json
        self.secret = secret
        self.reason = reason
    }

    /// The clear text when redaction let it through, nil when it withheld it.
    /// Every prose/summary channel in this module reads THIS, never `raw` —
    /// the same rule the AX lane's `displayLabel` enforces.
    public var display: String? { secret ? nil : raw }
}

public struct VisionRedactionConfig: Sendable, Equatable {
    /// A caption has to be SHORT — the redactor's own bar for "this line names
    /// a secret" rather than "this line is prose about one".
    public let maxCaptionChars: Int
    /// How far a caption may sit from its value, in IMAGE PIXELS. The AX
    /// channel uses 240 points; pixels are points × backing scale, so this is
    /// expressed relative to the frame and floored, rather than assuming 1×.
    public let proximityFraction: Double
    public let proximityFloorPixels: Double
    public let valueChars: Int

    public init(
        maxCaptionChars: Int = 32,
        proximityFraction: Double = 0.25,
        proximityFloorPixels: Double = 120,
        valueChars: Int = 120
    ) {
        self.maxCaptionChars = maxCaptionChars
        self.proximityFraction = proximityFraction
        self.proximityFloorPixels = proximityFloorPixels
        self.valueChars = valueChars
    }

    public static let `default` = VisionRedactionConfig()
}

public enum VisionTextRedaction {
    /// Is `caption` positioned as the LABEL of the value at `value`?
    /// Mirrors the AX channel's geometry: immediately left on the same line,
    /// or directly above with horizontal overlap.
    public static func isCaption(
        _ caption: VisionRect,
        forValueAt value: VisionRect,
        proximity: Double
    ) -> Bool {
        guard caption.w > 0, caption.h > 0, value.w > 0, value.h > 0 else { return false }
        guard caption != value else { return false }
        let sameRow = caption.y < value.maxY && caption.maxY > value.y
        let toTheLeft = caption.maxX <= value.x + 1
        if sameRow, toTheLeft {
            let distance = value.x - caption.maxX
            return distance >= 0 && distance <= proximity
        }
        let above = caption.maxY <= value.y + 1
        let horizontallyOverlapping = caption.x < value.maxX && caption.maxX > value.x
        if above, horizontallyOverlapping {
            let distance = value.y - caption.maxY
            return distance >= 0 && distance <= proximity
        }
        return false
    }

    /// Every OCR string, redacted under the shared rules, BEFORE anything
    /// downstream can copy it into a label, a readout, a handle fingerprint or
    /// a glance line. Positional with the input array.
    public static func redact(
        boxes: [VisionTextBox],
        imageSize: VisionSize,
        config: VisionRedactionConfig = .default
    ) -> [VisionRedactedText] {
        let proximity = max(
            config.proximityFloorPixels,
            max(imageSize.width, imageSize.height) * config.proximityFraction
        )
        // Candidate captions: SHORT lines only, the same bar the AX channel
        // applies before a line is allowed to darken its neighbour.
        let captions = boxes.filter { $0.text.count <= config.maxCaptionChars }

        return boxes.map { box in
            let caption = captions.first { candidate in
                isCaption(candidate.rect, forValueAt: box.rect, proximity: proximity)
                    && (MacScreenViewTextRedaction.looksLikeSecretLabel(candidate.text)
                        || MacScreenViewTextRedaction.isCardVerificationLabel(candidate.text)
                        || MacScreenViewTextRedaction.isSeedPhraseLabel(candidate.text))
            }
            // The DECISION is the shared redactor's, in both branches: the
            // standalone shape test, plus (when we found one) the caption that
            // makes an otherwise-innocuous value a secret. Passing `under:` is
            // exactly how `mac_view`'s legend hands its control's own caption
            // to the same code.
            let json = MacScreenViewTextRedaction.redactedLegendString(
                box.text,
                valueChars: config.valueChars,
                under: caption?.text
            )
            if case .string = json {
                return VisionRedactedText(raw: box.text, json: json, secret: false, reason: nil)
            }
            var reason: String?
            if case .object(let object) = json, case .string(let value)? = object["reason"] {
                reason = value
            }
            return VisionRedactedText(raw: box.text, json: json, secret: true, reason: reason)
        }
    }
}
