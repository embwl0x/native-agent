import Foundation

/// Shared, pure lexical guards for the cheap turn router and preload predictor.
/// These signals allocate context/tool schemas only; they never grant authority.
public enum UserMessageIntentSignals {
    private static let punctuation = CharacterSet(charactersIn: ".,!?;:)('“”\"`")

    /// A slash between two ordinary words is usually prose (`inner/body`,
    /// `and/or`), not a local path. Preserve the strong path shapes used by
    /// real turns: absolute/tilde/dot-relative, 3+ components, or any
    /// component carrying filename syntax such as `.`, `_`, `-`, or digits.
    public static func isLikelyLocalPathToken<S: StringProtocol>(_ raw: S) -> Bool {
        let token = String(raw).trimmingCharacters(in: punctuation)
        guard token.count >= 3,
              token.contains("/"),
              !token.contains("://") else {
            return false
        }
        if token.hasPrefix("/") || token.hasPrefix("~/") ||
            token.hasPrefix("./") || token.hasPrefix("../") {
            return true
        }
        let components = token.split(separator: "/", omittingEmptySubsequences: false)
        if components.count >= 3 { return true }
        guard components.count == 2 else { return false }
        return !components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0)
            }
        }
    }

    public static func containsLikelyLocalPath(in text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .contains(where: isLikelyLocalPathToken)
    }

    /// A user forbidding tool use is a negative constraint, not tool-creation
    /// intent. Keep the vocabulary narrow and deterministic; explicit creation
    /// below can still win when both clauses appear in one message.
    public static func explicitlyProhibitsToolUse(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return [
            "don't call a tool", "do not call a tool",
            "don't call tools", "do not call tools",
            "don't use a tool", "do not use a tool",
            "don't use tools", "do not use tools",
            "without calling a tool", "without calling tools",
            "without using a tool", "without using tools",
            "no tool call", "no tool calls",
        ].contains(where: lower.contains)
    }

    public static func explicitlyRequestsToolCreation(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [
            "create a tool", "build a tool", "make a tool",
            "write a tool", "develop a tool", "turn it into a tool",
            "turn this into a tool", "turn that into a tool",
        ].contains(where: lower.contains)
    }
}
