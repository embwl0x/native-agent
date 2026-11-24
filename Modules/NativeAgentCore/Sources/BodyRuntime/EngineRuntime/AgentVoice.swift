import Synchronization
import Foundation
// Blueprint: | `AgentVoice.swift` | Agent name grammar and lock-protected live voice shared across presentation surfaces |

/// Use name-based agreement without gender; settings speak as the agent.
public struct AgentVoice: Equatable, Sendable {
    public let name: String

    public init(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "The agent" : trimmed
    }

    public static func current(name: String) -> AgentVoice { AgentVoice(name: name) }

    // MARK: words
    // Keep call sites readable as sentences.

    public var subject: String { name }
    /// Names retain their own capitalization at sentence starts.
    public var Subject: String { name }
    public var object: String { name }
    public var possessive: String { name + "'s" }
    public func verb(_ base: String) -> String {
        let lower = base.lowercased()
        if lower == "have" { return "has" }
        if lower == "be" { return "is" }
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) {
            return String(lower.dropLast()) + "ies"
        }
        for tail in ["s", "x", "z", "ch", "sh", "o"] where lower.hasSuffix(tail) {
            return lower + "es"
        }
        return lower + "s"
    }
}

extension AgentVoice {
    private static let current = Mutex(AgentVoice(name: "The agent"))

    /// Keep non-view copy in sync with persona name changes.
    public static var live: AgentVoice {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}
