import Foundation
import NativeAgentCore
// Blueprint: | `VisionHandles.swift` | `VisionHandles` |

// Use shared stable hashing over safe labels, role and quantized centre; size changes alone must preserve tokens.

public enum VisionHandles {
    /// A 16-by-16 grid tolerates redraw movement under roughly six percent before changing a handle.
    public static let positionBuckets = 16

    public static func quantize(_ value: Double, over extent: Double) -> Int {
        guard extent > 0 else { return 0 }
        let fraction = min(0.999, max(0, value / extent))
        return Int(fraction * Double(positionBuckets))
    }

    public static let labelKeyLetters = 6
    public static let labelKeyDigits = 6

    /// Prefix letters absorb OCR tail noise while separate digits distinguish rows; pixels cannot separate title from changing value.
    public static func labelKey(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        let lowered = label.lowercased()
        let letters = lowered.filter { $0.isLetter }.prefix(labelKeyLetters)
        let digits = lowered.filter { $0.isNumber }.prefix(labelKeyDigits)
        return "\(letters)#\(digits)"
    }

    /// Secret text must never enter the fingerprint.
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
