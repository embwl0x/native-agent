import Foundation

/// Shared, pure lexical guards for the cheap turn router and preload predictor.
/// These signals allocate context/tool schemas only; they never grant authority.
public enum UserMessageIntentSignals {
    /// Explicit requests, including answer-only work, rather than topic words
    /// such as "code" in an ordinary conversation about someone's day.
    public static func explicitlyRequestsWork(_ text: String) -> Bool {
        let prefix = #"(?i)^\s*(?:(?:hey|hi|hello|thanks|ok|okay)[,!]?\s+)?(?:please\s+)?(?:(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)|(?:i\s+(?:want|need|would\s+like)\s+(?:(?:you\s+)?to\s+)?))?"#
        // Conversational imperatives are still conversation. These explicit
        // social asks must not acquire a delivery obligation just from a verb.
        guard text.range(of: prefix + #"(?:tell\s+me\s+(?:about\s+your\s+day|(?:a\s+)?joke)|give\s+me\s+(?:a\s+)?hug|say\s+(?:hi|hello)|help\s+me\s+relax)\b"#,
                         options: .regularExpression) == nil else { return false }
        return text.range(of: prefix + #"(?:do|go|add|remove|improve|commit|push|merge|try|test|deploy|restart|ship|release|build|make|create|write|draft|edit|fix|implement|research|find|search|look\s+up|check|review|read|summarize|explain|compare|calculate|convert|translate|design|draw|generate|analyze|inspect|audit|report|update|install|download|open|close|move|delete|rename|organize|save|export|print|book|cancel|continue|finish|delegate|ask|set|get|start|stop|remember|forget|tell|give|show|list|recommend|teach|describe|send|schedule|remind|run|help|take\s+(?:a\s+)?screenshot)\b"#,
                   options: .regularExpression) != nil
    }

    public static func isWorkQuestion(_ text: String) -> Bool {
        text.range(of: #"(?i)^\s*(?:what|where|when|how|why|which|who)\b"#,
                   options: .regularExpression) != nil
    }

    private static let punctuation = CharacterSet(charactersIn: ".,!?;:)('“”\"`")

    /// Whole commands only: quoted examples and longer prose are ordinary turns.
    public static let controlHandoffCommands = [
        "let me take over", "stop, i got it", "stop i got it",
    ]

    public static func isControlHandoff(_ text: String) -> Bool {
        let command = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return controlHandoffCommands.contains(command)
    }

    /// "Take over": he hands her the work where he left it.
    public static func isTakeOver(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .range(of: #"^(?:please )?(?:(?:can|could|will|would) you )?(?:please )?take over(?:$|[\s,:.!?])"#,
                   options: .regularExpression) != nil
    }

    public static func controlHandoffReply(lastActivity: String?) -> String {
        let activity = lastActivity?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activity, !activity.isEmpty {
            return "I released control. Last recorded step: \(String(activity.prefix(180))). Any in-flight change is unconfirmed."
        }
        return "I released control. I don't have a recorded stopping point for this turn. Any in-flight change is unconfirmed."
    }

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
