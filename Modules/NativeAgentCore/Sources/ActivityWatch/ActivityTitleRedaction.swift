import Foundation
import MacControl
import PersistenceCore

/// THE ONLY DOOR a window title may walk through on its way to disk.
///
/// Redaction happens at the SOURCE (per [[perception-organ-secret-redaction]]):
/// the raw `kAXTitle` string is converted here, and `ActivitySpan.titleRedacted`
/// can only be populated from this function's output. That ordering is what
/// makes the guarantee structural — a future sink added downstream physically
/// has no un-redacted string to reach for, because none exists past this point.
///
/// This is a THIN ADAPTER over `MacScreenViewTextRedaction`, not a second
/// redactor. The heuristics — OTP shape, card numbers, seed phrases, known
/// secret prefixes, high-entropy tokens — live in MacControl and are shared with
/// `mac_view`; duplicating them here would let the two drift, and the copy that
/// drifts is always the one nobody re-reviews.
public enum ActivityTitleRedaction {
    /// Titles are metadata, not content. 200 chars is `mac_view`'s own hard cap;
    /// a "title" longer than that is a document body wearing a hat.
    public static let maxTitleChars = 200

    /// What a title becomes when the redactor says the whole string is a secret.
    /// We keep the FACT that a window was there and drop the string entirely —
    /// storing the redactor's `sha256` digest would be storing a recoverable
    /// fingerprint of a secret, which is exactly what this feature must not do.
    public static let redactedPlaceholder = "[redacted]"

    /// Convert a raw AX title into a storable one.
    ///
    /// - Returns: `nil` when there is nothing worth storing (empty/whitespace),
    ///   `"[redacted]"` when the string is secret-shaped, otherwise the
    ///   truncated title.
    public static func redact(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // `redactedLegendString` returns `.string(...)` when the text is clean
        // and a `{redacted, sha256, reason}` OBJECT when it is not. Anything
        // that is not a plain string is, by construction, a secret — so the
        // default branch here fails CLOSED.
        switch MacScreenViewTextRedaction.redactedLegendString(trimmed, valueChars: maxTitleChars) {
        case .string(let clean):
            return String(clean.prefix(maxTitleChars))
        default:
            return redactedPlaceholder
        }
    }
}
