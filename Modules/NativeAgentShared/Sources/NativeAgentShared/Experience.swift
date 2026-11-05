import Foundation
// Blueprint: | `Experience.swift` | Canonical experience and obligation lifecycle value contracts shared by domain owners |

/// One happening in the agent's life (docs/EXPERIENCE.md), written once by the owner of the happening and only ever appended to: evidence attaches, claims
/// accrue, obligations settle. Everything else is a view of experiences by id. Destinations name `her`, `person`, `conversation:<session>`, or a
/// door's `<surface>:<destination>`.
public struct Experience: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case heard, answer, act, decision, run, message
    }

    /// A raw record this experience stands on: its store, named the way that store names itself, and the record's id there. Never a copy.
    public struct Ref: Codable, Sendable, Hashable {
        public var source: String
        public var id: String
        public init(source: String, id: String) {
            self.source = source
            self.id = id
        }
    }

    public enum Effects: String, Codable, Sendable {
        case none, occurred, unknown
    }

    /// The one outcome, owned by the domain that produced it.
    public struct Outcome: Codable, Sendable, Equatable {
        public var domain: String
        public var status: String
        public var effects: Effects?
        public var at: String?
        public init(domain: String, status: String, effects: Effects? = nil, at: String? = nil) {
            self.domain = domain
            self.status = status
            self.effects = effects
            self.at = at
        }
    }

    public struct Face: Codable, Sendable, Equatable {
        public var words: String
        public var artifacts: [Ref]
        /// The row every door draws it as (on a page, in a conversation, in an alert), and the part that speaks it.
        public var row: PartFace.Row?
        public var from: String?
        public init(words: String, artifacts: [Ref], row: PartFace.Row? = nil, from: String? = nil) {
            self.words = words
            self.artifacts = artifacts
            self.row = row
            self.from = from
        }
    }

    /// Owed to one destination until that destination durably accepts it, or its owner lets it go. Settling one obligation never closes another.
    public struct Obligation: Codable, Sendable, Equatable {
        public var to: String
        public var phase: ObligationPhase
        public var attempt: String?
        /// The record that last moved it: for `accepted`, the acceptance itself.
        public var evidence: Ref?
        /// Why its owner let it go.
        public var reason: ObligationPhase.LetGo?
        public init(to: String) {
            self.to = to
            self.phase = .owed
        }
    }

    public struct Claim: Codable, Sendable, Hashable {
        public var claim: String
        public var evidence: [Ref]
        public init(claim: String, evidence: [Ref]) {
            self.claim = claim
            self.evidence = evidence
        }
    }

    public var id: String
    public var kind: Kind
    public var at = ""
    public var updatedAt: String?
    public var progress: String?
    public var cause: [String]
    public var evidence: [Ref]
    public var outcome: Outcome?
    public var face: Face?
    public var addressedTo: [String]
    public var owes: [String: Obligation]
    public var claims: [Claim]

    public init(id: String, kind: Kind, cause: [String] = [], evidence: [Ref] = [], outcome: Outcome? = nil,
                face: Face? = nil, addressedTo: [String] = [], owes: [String: Obligation] = [:], claims: [Claim] = []) {
        self.id = id
        self.kind = kind
        self.cause = cause
        self.evidence = evidence
        self.outcome = outcome
        self.face = face
        self.addressedTo = addressedTo
        self.owes = owes
        self.claims = claims
    }

    /// It still owes something; the open experiences are the picture the agent is in.
    public var isOpen: Bool { owes.values.contains { !$0.phase.isSettled } }

    /// A run's answer, named by the run so every door that delivers it can settle it without a lookup, and its birth is the same whoever writes it.
    public static func answer(run: String) -> String { "answer:" + run }

}

/// Each destination settles independently. Only its owner may let an obligation go, with a reason; terminal settlements never move again.
public enum ObligationPhase: String, Codable, Sendable, Hashable {
    case owed
    case reserved
    case preDispatchFailed = "pre_dispatch_failed"
    case dispatchStarted = "dispatch_started"
    case accepted
    case rejected
    case outcomeUnknown = "outcome_unknown"
    case letGo = "let_go"

    public enum LetGo: String, Codable, Sendable { case cancelled, failed, expired, abandoned }

    /// Accepted by its destination, or let go by its owner.
    public var isSettled: Bool { self == .accepted || self == .letGo }

    public enum Step: Sendable, Equatable { case already, allowed, refused }

    /// A repeated phase is a no-op, except a second dispatch start. Acceptance with no transport between (the destination wrote it itself) settles
    /// straight from `owed`; a reservation starts from `owed` or a failed preflight.
    public func step(to next: ObligationPhase) -> Step {
        if next == self, next != .dispatchStarted { return .already }
        let from: Set<ObligationPhase> = switch next {
        case .owed: []
        // A refused door may be tried again under a new attempt; an unknown one never is (it may have arrived).
        case .reserved: [.owed, .preDispatchFailed, .rejected]
        case .dispatchStarted: [.reserved]
        // A destination's own receipt is the truth whenever it lands, after an unknown or a refused attempt too.
        case .accepted: [.owed, .dispatchStarted, .outcomeUnknown, .rejected]
        case .rejected, .outcomeUnknown: [.dispatchStarted]
        case .preDispatchFailed: [.reserved, .preDispatchFailed]
        // Only the owner's let-go reaches it, never a step a transport takes.
        case .letGo: []
        }
        return from.contains(self) ? .allowed : .refused
    }
}


/// An experience this build cannot read is left out of what carries it, never fatal to it.
extension Experience: LeftOutWhenUnreadable {}
