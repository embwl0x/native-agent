import Foundation
import PersistenceCore
// Blueprint: | `MacVisionTextRedaction.swift` | `VisionTextRedaction`, `VisionRedactedText`; fixed OCR caption/proximity rules with caller-owned text limits; one positional caption/overlap redaction boundary for both OCR readers |

// MARK: - Shared positional OCR redaction
//
// A vision percept rides the ordinary tool sinks — turn trace, persisted tool
// row, iOS/Telegram sync. A screen that shows a one-time code shows it in
// PIXELS, and OCR turns those pixels into a string in a JSON payload. So the
// pixel channel gets the SAME redactor the AX channel uses, not a second one:
// `MacScreenViewTextRedaction` is reused, never re-implemented. Two copies
// drift, and the copy that drifts is the one nobody re-reviews (the reason
// ActivityWatch depends on MacControl for exactly this, Package.swift).
//
// OCR boxes use the shared AX caption predicate in their own pixel units.
// This file owns overlap between recognized fragments, not enclosing AX groups.

public struct VisionRedactedText: Sendable, Equatable {
    /// The recognized string, kept in memory for geometry and matching. It is
    /// NEVER what rides out — `json` is.
    public let raw: String
    /// What the percept emits: the clear string, or the redactor's
    /// `{redacted, sha256, reason}` digest object.
    public let json: JSONValue
    public var secret: Bool {
        if case .string = json { return false }
        return true
    }

    public init(raw: String, json: JSONValue) {
        self.raw = raw
        self.json = json
    }

    /// The clear text when redaction let it through, nil when it withheld it.
    /// Every prose/summary channel in this module reads THIS, never `raw` —
    /// the same rule the AX lane's `displayLabel` enforces.
    public var display: String? { secret ? nil : raw }
}

public enum VisionTextRedaction {
    /// OCR captions name a secret in at most 32 characters; proximity uses image pixels.
    private static let maxCaptionChars = 32
    private static let proximityFraction = 0.25
    private static let proximityFloorPixels = 120.0

    /// Is `caption` immediately left of the value on the same line, or directly
    /// above with horizontal overlap? Coordinates and proximity must share units.
    public static func isCaption(
        _ caption: VisionRect,
        forValueAt value: VisionRect,
        proximity: Double
    ) -> Bool {
        guard caption != value else { return false }
        return MacScreenViewTextRedaction.labelDistance(
            MacAXFrame(x: caption.x, y: caption.y, w: caption.w, h: caption.h),
            forValueAt: MacAXFrame(x: value.x, y: value.y, w: value.w, h: value.h),
            proximity: proximity
        ) != nil
    }

    /// Every OCR string, redacted under the shared rules, BEFORE anything
    /// downstream can copy it into a label, a readout, a handle fingerprint or
    /// a glance line. Positional with the input array.
    public static func redact(
        boxes: [VisionTextBox],
        imageSize: VisionSize,
        valueChars: Int = 120
    ) -> [VisionRedactedText] {
        let proximity = max(
            proximityFloorPixels,
            max(imageSize.width, imageSize.height) * proximityFraction
        )
        let captions = boxes.filter { $0.text.count <= maxCaptionChars }

        var redacted = boxes.map { box in
            var json = MacScreenViewTextRedaction.redactedLegendString(
                box.text,
                valueChars: valueChars
            )
            // A generic caption must not mask a CVV or recovery-phrase label.
            for caption in captions where isCaption(
                caption.rect, forValueAt: box.rect, proximity: proximity
            ) {
                guard case .string = json else { break }
                json = MacScreenViewTextRedaction.redactedLegendString(
                    box.text, valueChars: valueChars, under: caption.text
                )
            }
            return VisionRedactedText(raw: box.text, json: json)
        }
        // Whole-frame and tile OCR can observe the same secret as different
        // strings. Withhold every overlapping fragment before any text escapes.
        var pending = redacted.indices.filter { redacted[$0].secret }
        while let secretIndex = pending.popLast() {
            for index in boxes.indices where !redacted[index].secret
                && boxes[index].rect.intersection(boxes[secretIndex].rect).area > 0 {
                redacted[index] = VisionRedactedText(
                    raw: boxes[index].text,
                    json: MacScreenViewTextRedaction.redactedText(boxes[index].text, reason: "overlapping_secret")
                )
                pending.append(index)
            }
        }
        return redacted
    }
}
