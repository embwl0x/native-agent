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

struct ReachCandidate: Sendable, Equatable {
    enum Kind: Int, Sendable, Comparable {
        case plan, care, dream
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        var name: String { ["plan", "care", "dream"][rawValue] }
    }
    var kind: Kind
    /// Share subject identity between cooldown and mind.reject.
    var subject: String
    var source: String
    var why: String
    var text: String
    /// Use the source event time so material predating the person's last turn cannot appear newly shared.
    var at: Date
}

enum Reach {
    /// A pass spends the daily offer because it still costs one wake turn.
    static let dailyCap = 1
    /// Separate offers across day boundaries so midnight cannot place two adjacent.
    static let minimumSpacing: TimeInterval = 8 * 3_600
    /// Apply weekly subject pacing regardless of outcome.
    static let subjectCooldown: TimeInterval = 7 * 86_400
    /// Recent verified person activity indicates the person is occupied.
    static let activeWindow: TimeInterval = 30 * 60
    static let freshness: TimeInterval = 72 * 3_600
    static let answerWindow = ReachAnswerSettlement.window
    static let scanInterval: TimeInterval = 10 * 60

    enum Verdict: String, Sendable, Equatable {
        case offer, quietHours, userActive, dailyCap, spacing, awaitingUser
        case subjectCooldown, alreadySeen, rejected, stale
    }

    struct Timing: Sendable {
        var now: Date
        var quietHours: Bool
        var liveTurn: Bool
        var lastUserTurn: Date?
        var calendar: Calendar = .current
    }

    /// Respect quiet hours and current person activity before offering.
    static func presence(_ t: Timing) -> Verdict {
        if t.quietHours { return .quietHours }
        if t.liveTurn || t.lastUserTurn.map({ t.now.timeIntervalSince($0) < activeWindow }) == true { return .userActive }
        return .offer
    }

    /// Recheck pacing at delivery time; uncertain unanswered speech holds outreach without escalation.
    static func pace(_ t: Timing, ledger: ReachLedger) -> Verdict {
        let sent = ledger.offers.filter(\.mayHaveReachedPerson).compactMap(\.sentAt)
        if sent.filter({ t.calendar.isDate($0, inSameDayAs: t.now) }).count >= dailyCap { return .dailyCap }
        guard let last = sent.max() else { return .offer }
        if t.now.timeIntervalSince(last) < minimumSpacing { return .spacing }
        if (t.lastUserTurn ?? .distantPast) < last { return .awaitingUser }
        return .offer
    }

    /// A pass spends daily offer admission because the wake turn already ran.
    static func timing(_ t: Timing, ledger: ReachLedger) -> Verdict {
        let moment = presence(t)
        guard moment == .offer else { return moment }
        let paced = pace(t, ledger: ledger)
        guard paced == .offer else { return paced }
        let offered = ledger.offers.filter { $0.outcome != "withheld" && t.calendar.isDate($0.offeredAt, inSameDayAs: t.now) }
        return offered.count >= dailyCap ? .dailyCap : .offer
    }

    /// Recheck every gate at delivery; the agent's own wake is not person activity.
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

    /// Withdraw when quiet hours or renewed person activity invalidate timing; the agent's own live wake does not. Nil while the moment holds.
    static func momentPassed(_ t: Timing) -> Verdict? {
        var now = t
        now.liveTurn = false
        let moment = presence(now)
        return moment == .offer ? nil : moment
    }

    /// Treat Desk words as person-authorized only if every steering peer is trusted as the person's own.
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

    /// Expose source and reason, never absence counters or duration away.
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

    /// Keep message content in chat; the notification carries only its pointer.
    static let knockLine = "Left you something in chat. No reply needed."

    static func digest(_ text: String) -> String {
        String(fnv1a64(text), radix: 16)
    }
}
