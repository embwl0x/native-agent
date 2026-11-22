import Foundation
import Context
import NativeAgentShared
// Blueprint: | `NativeContextProjectionText.swift` | `NativeContextProjectionText`: projection text cleanup, date validation and trigger tokens |

enum NativeContextProjectionText {
    static func requiredDate(_ raw: String?, owner: String) throws -> Date {
        guard let raw, let date = NativeTimestampFormat.parseISO8601FractionalFirst(raw) else {
            throw ContextFlowStoreError.malformedStoredValue("\(owner): required source date is unavailable or invalid")
        }
        return date
    }

    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func containsDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }
    }

    static func triggers(_ text: String, minimumLength: Int = 2, excluding: Set<String> = []) -> [String] {
        triggerTokens([text], minimumLength: minimumLength,
            maximumCount: 12, excluding: excluding,
            tokens: { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) },
            bound: { $0 }).map { TextClipping.prefix($0, to: 64) }
    }

    /// Each projection supplies its trigger-token and bound rules.
    private static func triggerTokens(
        _ texts: [String], minimumLength: Int, maximumCount: Int,
        excluding stopwords: Set<String>, tokens: (String) -> [String],
        bound: (String) -> String
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for text in texts {
            for token in tokens(text) where !stopwords.contains(token) {
                let value = bound(token)
                guard value.count >= minimumLength, seen.insert(value).inserted else { continue }
                result.append(value)
                if result.count == maximumCount { return result }
            }
        }
        return result
    }
}
