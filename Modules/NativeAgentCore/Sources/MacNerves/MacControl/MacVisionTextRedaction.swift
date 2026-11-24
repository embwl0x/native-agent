import Foundation
import PersistenceCore
// Blueprint: | `MacVisionTextRedaction.swift` | `VisionTextRedaction`, `VisionRedactedText`: Shared OCR caption/proximity and overlap redaction |

// MARK: - Shared positional OCR redaction
// OCR text reaches trace, persistence and sync, so share AX’s redactor rather than a drifting copy. Use pixel units for caption geometry; this owner handles
// fragment overlap rather than AX ancestry.

public struct VisionRedactedText: Sendable, Equatable {
    /// Keep raw strings only for in-memory geometry and matching; outbound text must use redacted JSON.
    public let raw: String
    /// Emit approved clear text or the shared redaction object, never unchecked raw text.
    public let json: JSONValue
    public var secret: Bool {
        if case .string = json { return false }
        return true
    }

    public init(raw: String, json: JSONValue) {
        self.raw = raw
        self.json = json
    }

    /// Every prose and summary channel uses approved display text, never raw OCR.
    public var display: String? { secret ? nil : raw }
}

public enum VisionTextRedaction {
    /// Bound secret captions to 32 characters and measure proximity in image pixels.
    private static let maxCaptionChars = 32
    private static let proximityFraction = 0.25
    private static let proximityFloorPixels = 120.0

    /// Caption adjacency and value bounds must share coordinate units.
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

    /// Redact every OCR string before labels, readouts, fingerprints or glances can copy it; preserve input ordering.
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
        // Whole-frame and tile reads may split one secret differently; withhold overlapping fragments before text escapes.
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
