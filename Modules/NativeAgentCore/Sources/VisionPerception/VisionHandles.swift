import Foundation
import MacControl

// MARK: - HANDLES on the pixel channel
//
// Same scheme as the AX lane, same primitives (`MacLookHandle.fnv1a64` /
// `base36` / `rendered` / `ambiguityNote` are imported, not re-implemented —
// including the deliberate choice of FNV-1a over `Hasher`, which is per-process
// seeded and would hand out different handles next launch for the same screen).
//
// What differs is the FINGERPRINT INPUT, because pixels publish no ancestor
// chain and no title:
//
//     vision > roleGuess / label / qx:qy
//
//   • roleGuess — what we think it is.
//   • label     — its OCR text, REDACTED-SAFE: a secret never enters a
//     fingerprint, because a handle rides out in every envelope and a digest
//     of a secret is still keyed by the secret.
//   • qx:qy     — its centre as a REGION-RELATIVE QUANTIZED position, never
//     raw pixels. Raw pixels would mint a new handle for a one-pixel redraw;
//     quantizing to a coarse grid makes a harmless redraw a no-op. Coarse
//     quantization is not free: a control sitting exactly on a bucket seam can
//     still flip, which is precisely why an unlabeled row's handle is
//     announced as position-derived rather than presented as stable.
//
// Size deliberately does NOT enter the fingerprint: a button that grows by a
// few pixels when its label changes length is the same button.

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

    /// The NOISE-TOLERANT form of an OCR label.
    ///
    /// Measured, not theoretical: two captures of the identical synthetic
    /// scene read the same greyed button as "Archive" and "Archivel". OCR is a
    /// sensor, and a sensor is noisy at the character level — so a handle keyed
    /// on the exact recognized string inherits that noise and renames a control
    /// nobody touched, which is the one thing a handle exists to prevent.
    ///
    /// The key is the first few LETTERS plus the label's DIGITS, kept apart:
    ///   • letters absorb a mangled tail ("archiv" from both readings);
    ///   • digits are what distinguishes otherwise identical list rows
    ///     ("Report 1 12 pts" vs "Report 2 15 pts" → 112 vs 215), so dropping
    ///     them would collapse a whole list onto one token and force every row
    ///     onto a position-derived ordinal — the exact fragility finding B in
    ///     the AX lane was about.
    ///
    /// KNOWN LIMIT, stated rather than hidden: the AX lane can exclude a
    /// control's VALUE from its identity because AX tells it which string is a
    /// title and which is a value. Pixels do not. So a control whose displayed
    /// number changes (a counter, a popup showing its selection) WILL re-mint
    /// here where the AX lane would not, and the caller sees that as a drifted
    /// handle rather than as a silent mis-address.
    public static func labelKey(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        let lowered = label.lowercased()
        let letters = lowered.filter { $0.isLetter }.prefix(labelKeyLetters)
        let digits = lowered.filter { $0.isNumber }.prefix(labelKeyDigits)
        return "\(letters)#\(digits)"
    }

    /// The pre-hash string. Public so a test can pin exactly what does and
    /// does not enter it (the AX lane's `MacLookHandle.fingerprint` is public
    /// for the same reason).
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
        MacLookHandle.base36(MacLookHandle.fnv1a64(fingerprint), length: MacLookHandle.tokenLength)
    }

    /// Mint handles for rows in document order, appending the AX lane's
    /// ORDINAL suffix for repeats and its ambiguity note — an unlabeled
    /// candidate in a list of identical unlabeled candidates is
    /// position-derived, and a silently positional handle is worse than a
    /// drifted one.
    public static func mint(
        fingerprints: [String]
    ) -> [(handle: String, ambiguity: String?)] {
        let tokens = fingerprints.map { token(fingerprint: $0) }
        var totals: [String: Int] = [:]
        for token in tokens { totals[token, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return tokens.map { token in
            let ordinal = (seen[token] ?? 0) + 1
            seen[token] = ordinal
            let total = totals[token] ?? 1
            let rendered = MacLookHandle.rendered(token: token, ordinal: ordinal)
            let ambiguity = total > 1
                ? MacLookHandle.ambiguityNote(ordinal: ordinal, total: total)
                : nil
            return (rendered, ambiguity)
        }
    }
}
