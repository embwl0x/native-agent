import Foundation
// Blueprint: | `TextNormalization.swift` | Trimmed lowercase, collapsed whitespace and lowercase word keys shared across surfaces |

public enum TextNormalization {
    public static func trimmedLowercased(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func trimmedLowercasedOrEmpty(_ text: String?) -> String {
        trimmedLowercased(text ?? "")
    }

    public static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func lowercasedWithCollapsedWhitespace(_ text: String) -> String {
        collapseWhitespace(text.lowercased())
    }

    public static func lowercaseWords(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
