import Foundation

// Blueprint: | `REMReplacement.swift` | Source-bound displaced REM content and shared review wording; missing history is not recorded |

/// Historical words, not permission to remove or restore their source. The producer binds both fields to the source it read when making the proposal.
public struct REMReplacement: Codable, Sendable, Equatable {
    public let source: String
    public let text: String

    public init(source: String, text: String) {
        self.source = source
        self.text = text
    }

    public static func describe(_ replacement: Self?) -> String {
        guard let replacement,
              !replacement.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !replacement.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Replaced content: not recorded"
        }
        return "Replaced content (\(replacement.source)):\n\(replacement.text)"
    }
}
