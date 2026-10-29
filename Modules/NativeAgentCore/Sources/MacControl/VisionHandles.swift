import Foundation
import NativeAgentCore
// Blueprint: | `VisionHandles.swift` | `VisionHandles` |

// Pixel tokens identify readouts and detect affordance collisions using the
// shared stable hash. Fingerprints contain role, redacted-safe label and
// quantized frame-relative centre; changing size alone preserves the token.

public enum VisionHandles {
    /// Buckets per axis. 16 × 16 over the frame — a redraw has to move a
    /// control by ~6% of the window before its handle changes.
    public static let positionBuckets = 16

    public static func quantize(_ value: Double, over extent: Double) -> Int {
        guard extent > 0 else { return 0 }
        let fraction = min(0.999, max(0, value / extent))
        return Int(fraction * Double(positionBuckets))
    }

    /// Letters kept from a label before it enters a fingerprint.
    public static let labelKeyLetters = 6
    /// Digits kept from a label before it enters a fingerprint.
    public static let labelKeyDigits = 6

    /// Prefix letters absorb OCR tail noise; separate digits distinguish rows.
    /// Pixels cannot distinguish a title from a value, so changing digits changes the token.
    public static func labelKey(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        let lowered = label.lowercased()
        let letters = lowered.filter { $0.isLetter }.prefix(labelKeyLetters)
        let digits = lowered.filter { $0.isNumber }.prefix(labelKeyDigits)
        return "\(letters)#\(digits)"
    }

    /// The pre-hash string; secrets never enter the label component.
    public static func fingerprint(
        roleGuess: String,
        label: String?,
        rect: VisionRect,
        imageSize: VisionSize
    ) -> String {
        let qx = quantize(rect.centerX, over: imageSize.width)
        let qy = quantize(rect.centerY, over: imageSize.height)
        return "vision>\(roleGuess)/\(labelKey(label))/\(qx):\(qy)"
    }

    public static func token(fingerprint: String) -> String {
        MacLookHandle.base36(fnv1a64(fingerprint), length: MacLookHandle.tokenLength)
    }

}
