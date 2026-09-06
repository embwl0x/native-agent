import Foundation

/// User, 2026-09-03: the UI must never hard-code a gender for the agent. Where a
/// name fits, the sentence says the agent's NAME; where it doesn't, it says
/// "the agent". There is no pronoun setting and nothing to pick — the name IS
/// the voice. A name is always third-person singular, so the verb helpers are
/// fixed and every templated sentence still agrees.
struct AgentVoice: Equatable {
    let name: String

    init(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "The agent" : trimmed
    }

    static func current(name: String) -> AgentVoice { AgentVoice(name: name) }

    // MARK: words
    //
    // Every slot is the name. The helpers stay so the call sites keep reading
    // as sentences rather than as string concatenation.

    /// "Agent"
    var subject: String { name }
    /// "Agent" — a name needs no sentence-start capitalization.
    var Subject: String { name }
    /// "Agent"
    var object: String { name }
    /// "Agent's"
    var possessive: String { name + "'s" }
    var Possessive: String { possessive }
    /// Reads in "an hour on \(reflexive)" — a name has no reflexive form, so
    /// the possessive stands in.
    var reflexive: String { name + "'s own" }

    /// A name is third-person singular. Always.
    var isVerb: String { "is" }
    var hasVerb: String { "has" }
    var doesVerb: String { "does" }

    /// Third-person present for a base verb: feel → feels, carry → carries,
    /// go → goes, watch → watches.
    func verb(_ base: String) -> String {
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
    static var live: AgentVoice {
        get { liveLock.lock(); defer { liveLock.unlock() }; return _live }
        set { liveLock.lock(); _live = newValue; liveLock.unlock() }
    }
}
