import Foundation

// Blueprint: | `WorkshopWireVocabulary.swift` | The `workshop` surface spelling and trimmed event-kind matching |

// One spelling per wire name; callers use these vocabularies rather than open-coded spellings.

// MARK: - Surface vocabulary

/// The `workshop` surface: a Work-route model call with no conversation (the morning brief's), private and unattended.
public enum WorkshopSurfaceVocabulary {
    public static let canonical = "workshop"

    public static func isWorkshopSurface(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == canonical
    }
}

// MARK: - Execution event vocabulary

/// Event kinds compare trimmed; there is one spelling per kind.
public enum ExecutionEventVocabulary {
    /// Compare trimmed kinds; two absent values match.
    public static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
