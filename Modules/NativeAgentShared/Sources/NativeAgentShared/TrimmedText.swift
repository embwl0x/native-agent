import Foundation
// Blueprint: | `TrimmedText.swift` | `trimmedNonEmpty` on `String` and `String?`: whitespace and newlines trimmed, nil when nothing is left |

extension String {
    /// The text without surrounding whitespace and newlines, or nil when nothing is left.
    public var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    /// Absent text reads like blank text: nil.
    public var trimmedNonEmpty: String? {
        flatMap { $0.trimmedNonEmpty }
    }
}
