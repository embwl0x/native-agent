import Foundation
import ChatTurnRuntime
import Desk
import BackgroundLoops
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
import Experiences
import MemoryV2
import AgentWorkspace
import AgentConversations
import DreamREMCycle
import Transcripts
import TurnTrace
import NativeAgentShared
import Studio
import ApprovalInbox
import ChatToolRuntime
import ContextFlow
import AuthoredCapabilities
// Blueprint: | `Reach.swift` | `ReachCandidate` and pure `Reach` pacing, eligibility, provenance and delivery policy |

/// One thing worth sharing, and why.
struct ReachCandidate: Sendable, Equatable {
    enum Kind: Int, Sendable, Comparable {
        case plan, care, shipped, dream
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        var name: String { ["plan", "care", "shipped", "dream"][rawValue] }
    }
    var kind: Kind
    /// `desk:<handle>`, `care:<uuid>`, `view:<uuid>`, `ship:<builder>:<id>` or `dream:<id>`:
    /// what the cooldown keys on and what `mind.reject` takes.
    var subject: String
    var source: String
    var why: String
    var text: String
    /// When it happened. Something from before User's last turn, he has been
    /// around for.
    var at: Date
}

/// The policy, as pure functions over facts.
enum Reach {
    /// Offers (her wake turns) per local day. A pass spends it: the cost is
    /// bounded to one turn a day whatever she decides.
    static let dailyCap = 1
    /// Between two offers, so a day boundary cannot put two side by side.
    static let minimumSpacing: TimeInterval = 8 * 3_600
    /// One subject at most once a week, whatever came of it.
    static let subjectCooldown: TimeInterval = 7 * 86_400
    /// User's last turn at a verified door (or Claude's last worklog line)
    /// this recent means he is in the middle of something.
    static let activeWindow: TimeInterval = 30 * 60
    /// Older than this it is not news.
    static let freshness: TimeInterval = 72 * 3_600
    /// "He took a turn within a day after it."
    static let answerWindow = ReachAnswerSettlement.window
    /// How often the candidates are read from disk.
    static let scanInterval: TimeInterval = 10 * 60

    enum Verdict: String, Sendable, Equatable {
        case offer, quietHours, userActive, withClaude, dailyCap, spacing, awaitingUser
        case subjectCooldown, alreadySeen, rejected, stale
    }

    struct Timing: Sendable {
        var now: Date
        var quietHours: Bool
        var liveTurn: Bool
        var lastUserTurn: Date?
        var lastClaude: Date?
        var calendar: Calendar = .current
    }

    /// Is this a considerate moment: not his quiet hours, not while he is
    /// talking to her or working with Claude.
    static func presence(_ t: Timing) -> Verdict {
        if t.quietHours { return .quietHours }
        if t.liveTurn || t.lastUserTurn.map({ t.now.timeIntervalSince($0) < activeWindow }) == true { return .userActive }
        if let claude = t.lastClaude, t.now.timeIntervalSince(claude) < activeWindow { return .withClaude }
        return .offer
    }

    /// The pace of what actually reached him, on DELIVERY time (a wake from
    /// yesterday that delivers today is today's): one a day, eight hours
    /// apart, and after a message he has not come back to, nothing more until
    /// he takes a turn — no escalation.
    static func pace(_ t: Timing, ledger: ReachLedger) -> Verdict {
        let sent = ledger.offers.filter(\.mayHaveReachedHim).compactMap(\.sentAt)
        if sent.filter({ t.calendar.isDate($0, inSameDayAs: t.now) }).count >= dailyCap { return .dailyCap }
        guard let last = sent.max() else { return .offer }
        if t.now.timeIntervalSince(last) < minimumSpacing { return .spacing }
        if (t.lastUserTurn ?? .distantPast) < last { return .awaitingUser }
        return .offer
    }

    /// Offer time: presence, pace, and the cost bound — one wake of hers a
    /// day for this, so a pass spends the day's.
    static func timing(_ t: Timing, ledger: ReachLedger) -> Verdict {
        let moment = presence(t)
        guard moment == .offer else { return moment }
        let paced = pace(t, ledger: ledger)
        guard paced == .offer else { return paced }
        let offered = ledger.offers.filter { $0.outcome != "withheld" && t.calendar.isDate($0.offeredAt, inSameDayAs: t.now) }
        return offered.count >= dailyCap ? .dailyCap : .offer
    }

    /// Right before delivery, every gate again, on delivery time (her own
    /// wake turn is the live one, so it does not count as his).
    static func deliverable(_ offer: ReachLedger.Offer, timing t: Timing, ledger: ReachLedger,
                            rejectedSources: [String]) -> Verdict {
        var now = t
        now.liveTurn = false
        let moment = presence(now)
        guard moment == .offer else { return moment }
        let paced = pace(now, ledger: ledger)
        guard paced == .offer else { return paced }
        if rejectedSources.contains(where: { offer.subject == $0 || offer.subject.hasPrefix($0 + ":") }) { return .rejected }
        if let user = t.lastUserTurn, let at = offer.at, at <= user { return .alreadySeen }
        return .offer
    }

    /// The moment for an offer already made has passed: quiet hours began,
    /// or he took a turn. (Not "a turn is live": her own wake is one.)
    static func momentPassed(_ t: Timing) -> Bool {
        var now = t
        now.liveTurn = false
        now.lastClaude = nil
        return presence(now) != .offer
    }

    /// A Desk item's text came from User only when no peer steered it in: every
    /// peer on its steps, elevated or not, must be one User trusts as his own.
    static func deskProvenanceTrusted(_ item: DeskItem, trusts: (String) -> Bool) -> Bool {
        item.refs.allSatisfy { ref in
            guard case .step(let step) = ref.kind else { return true }
            return (step.peers + step.elevated).allSatisfy(trusts)
        }
    }

    static func decide(_ c: ReachCandidate, timing t: Timing, ledger: ReachLedger, rejectedSources: [String]) -> Verdict {
        let gate = timing(t, ledger: ledger)
        guard gate == .offer else { return gate }
        if case .plan = c.kind, c.at > t.now { return .stale }
        if rejectedSources.contains(where: { c.subject == $0 || c.subject.hasPrefix($0 + ":") }) { return .rejected }
        if ledger.offers.contains(where: {
            $0.subject == c.subject && $0.outcome != "withheld" && t.now.timeIntervalSince($0.offeredAt) < subjectCooldown
        }) { return .subjectCooldown }
        if let user = t.lastUserTurn, c.at <= user { return .alreadySeen }
        if t.now.timeIntervalSince(c.at) > freshness { return .stale }
        return .offer
    }

    /// What her wake reads: the thing, its source and why — no counters, no
    /// absence, nothing about how long he has been gone.
    static func wakeLine(_ c: ReachCandidate, person: String) -> String {
        "Something you could share with \(person), if you want to. From \(c.source): \(c.text). "
            + "Why it might be worth it: \(c.why). Nothing is owed and no reply will be chased. "
            + "If you want to tell \(person), write the message itself as your whole reply; it goes to "
            + "\(person)'s chat as you wrote it. If not, reply only: pass"
    }

    static func isDecline(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let first = trimmed.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return first == "pass" && trimmed.count <= 80
    }

    /// The knock carries nothing of the message: that is in his chat.
    static let knockLine = "Left you something in chat. No reply needed."

    static func digest(_ text: String) -> String {
        String(fnv1a64(text), radix: 16)
    }
}
