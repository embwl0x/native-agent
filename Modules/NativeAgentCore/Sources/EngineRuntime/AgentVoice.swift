import Foundation
// Blueprint: | `AgentVoice.swift` | Agent name grammar and lock-protected live voice shared across presentation surfaces |

/// Use the agent's name and third-person singular agreement without a gender.
/// Settings-family sentences speak as the agent ("I", "my"); names are labels.
public struct AgentVoice: Equatable {
    public let name: String

    public init(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "The agent" : trimmed
    }

    public static func current(name: String) -> AgentVoice { AgentVoice(name: name) }

    // MARK: words
    //
    // Every slot is the name. The helpers stay so the call sites keep reading
    // as sentences rather than as string concatenation.

    /// "Agent"
    public var subject: String { name }
    /// "Agent" — a name needs no sentence-start capitalization.
    public var Subject: String { name }
    /// "Agent"
    public var object: String { name }
    /// "Agent's"
    public var possessive: String { name + "'s" }
    public var Possessive: String { possessive }
    /// Third-person present for a base verb: feel → feels, carry → carries,
    /// go → goes, watch → watches.
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
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var _live = AgentVoice(name: "The agent")

    /// The voice the app is currently speaking in, for copy built outside a
    /// view (status phrases, approval cards, tool rows). Set whenever the
    /// persona name changes.
    public static var live: AgentVoice {
        get { liveLock.lock(); defer { liveLock.unlock() }; return _live }
        set { liveLock.lock(); _live = newValue; liveLock.unlock() }
    }
}
