import Foundation
import MacControl
import PersistenceCore

// Blueprint: | `ActivityTitleRedaction.swift` | `ActivityTitleRedaction.redact`: the source boundary that removes secrets before titles enter spans or disk |

/// Redact at the source so no downstream sink can reach a raw title.
/// Share MacScreenViewTextRedaction with mac_view so secret heuristics cannot drift.
public enum ActivityTitleRedaction {
    /// Match mac_view’s 200-character metadata cap; longer text risks storing document content.
    public static let maxTitleChars = 200

    /// Keep a secret-shaped window’s existence but no string or recoverable digest fingerprint.
    public static let redactedPlaceholder = "[redacted]"

    /// Return nil for empty titles, a redaction marker for secrets, and capped text otherwise.
    public static func redact(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Only a plain-string redactor result is safe to store; secret objects fail closed.
        switch MacScreenViewTextRedaction.redactedLegendString(trimmed, valueChars: maxTitleChars) {
        case .string(let clean):
            return String(clean.prefix(maxTitleChars))
        default:
            return redactedPlaceholder
        }
    }
}
