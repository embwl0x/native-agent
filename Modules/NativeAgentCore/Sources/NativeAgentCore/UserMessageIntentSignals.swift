import Foundation

// Blueprint: | `UserMessageIntentSignals.swift` | `UserMessageIntentSignals`: pure lexical context/tool allocation signals and control-handoff recognition; never effect authority |

/// Pure lexical work and control-handoff recognition; never effect authority.
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

}
