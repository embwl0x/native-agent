import Foundation
import Context
// Blueprint: | `NativeContextProjectionText.swift` | `NativeContextProjectionText` enum; `clean`, `bounded`; projection triggers delegate to ContextMarkdownCompiler |

/// Shared text rules for rebuildable context projections.
enum NativeContextProjectionText {
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func bounded(_ value: String, to maximum: Int) -> String {
        value.count <= maximum ? value : String(value.prefix(maximum))
    }

    static func containsDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }
    }

    static func triggers(_ text: String, minimumLength: Int = 2, excluding: Set<String> = []) -> [String] {
        ContextMarkdownCompiler.triggerTokens([text], minimumLength: minimumLength,
            maximumCount: 12, excluding: excluding,
            tokens: { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) },
            bound: { $0 }).map { bounded($0, to: 64) }
    }
}
