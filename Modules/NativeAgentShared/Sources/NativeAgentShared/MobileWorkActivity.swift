import Foundation
// Blueprint: | `MobileWorkActivity.swift` | `Experience` and `ObligationPhase` value contracts shared by owners and phone renderers; `MobileWorkActivity` and its revisioned experience snapshot |

/// One happening in her life (docs/EXPERIENCE.md), written once by the owner of
/// the happening and only ever appended to: evidence attaches, claims accrue,
/// obligations settle. Everything else is a view of experiences by id.
///
/// Destinations are plain names: `her` (her own turn), `person` (User),
/// `conversation:<session>`, and a door's own `<surface>:<destination>`.
public struct Experience: Codable, Sendable, Equatable {
    /// The act currently asking, including calls nested inside an act.
    @TaskLocal public static var currentAct: String?
    public enum Kind: String, Codable, Sendable {
        case heard, answer, act, decision, run, message
    }

    /// A raw record this experience stands on: its store, named the way that
    /// store names itself, and the record's id there. Never a copy.
    public struct Ref: Codable, Sendable, Hashable {
        public var source: String
        public var id: String
        public init(source: String, id: String) {
            self.source = source
            self.id = id
        }
    }

    /// Effects as the producing domain counted them.
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

    /// The one expression of it: the words, and the artifacts she chose.
    public struct Face: Codable, Sendable, Equatable {
        public var words: String
        public var artifacts: [Ref]
        public init(words: String, artifacts: [Ref]) {
            self.words = words
            self.artifacts = artifacts
        }
    }

    /// Owed to one destination until that destination durably accepts it,
    /// or its owner lets it go. Settling one obligation never closes another.
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

    /// An assertion, scoped to the evidence that bears it.
    public struct Claim: Codable, Sendable, Hashable {
        public var claim: String
        public var evidence: [Ref]
        public init(claim: String, evidence: [Ref]) {
            self.claim = claim
            self.evidence = evidence
        }
    }

    /// Stable, minted where the happening starts.
    public var id: String
    public var kind: Kind
    /// When its owner wrote it; the store stamps it.
    public var at = ""
    public var updatedAt: String?
    public var progress: String?
    /// The experiences that brought it about.
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

    /// It still owes something; the open experiences are the picture she is in.
    public var isOpen: Bool { owes.values.contains { !$0.phase.isSettled } }

    /// A run's answer, named by the run so every door that delivers it can
    /// settle it without a lookup, and its birth is the same whoever writes it.
    public static func answer(run: String) -> String { "answer:" + run }

    /// The face is bounded only at delivery; its identity and evidence stay exact.
    public var mobile: Self {
        var copy = self
        if let face {
            copy.face = .init(words: MobileDeskProjectionBounds.clipped(face.words, to: 2_000), artifacts: face.artifacts)
        }
        return copy
    }
}

/// One obligation's lifecycle: a copy of the artifact machine proven on builder
/// completions (`CodexCompletionLifecycle`, which keeps its own), so every
/// destination settles the same way. `owed` is new: an obligation its owner
/// declared before any attempt. `let_go` copies the seed's let-go settlement:
/// only the owner gives an obligation up, with a reason, and nothing moves it after.
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

    /// A repeated phase is a no-op, except a second dispatch start. Acceptance
    /// with no transport between (the destination wrote it itself) settles
    /// straight from `owed`; a reservation starts from `owed` or a failed preflight.
    public func step(to next: ObligationPhase) -> Step {
        if next == self, next != .dispatchStarted { return .already }
        let from: Set<ObligationPhase> = switch next {
        case .owed: []
        case .reserved: [.owed, .preDispatchFailed]
        case .dispatchStarted: [.reserved]
        case .accepted: [.owed, .dispatchStarted]
        case .rejected, .outcomeUnknown: [.dispatchStarted]
        case .preDispatchFailed: [.reserved, .preDispatchFailed]
        // Only the owner's let-go reaches it, never a step a transport takes.
        case .letGo: []
        }
        return from.contains(self) ? .allowed : .refused
    }
}

public struct MobileWorkActivity: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, preparing, working, tool, replying, retrying, waiting, blocked
        case completed, stopped, failed, interrupted, unknown

        public var isTerminal: Bool {
            [.completed, .stopped, .failed, .interrupted].contains(self)
        }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var state: State
        public var status: String
        public var updatedAt: Date

        public init(title: String, state: State, status: String, updatedAt: Date) {
            self.title = title; self.state = state; self.status = status; self.updatedAt = updatedAt
        }
    }

    public var id: String
    public var sessionID: String?
    public var startedAt: Date
    public var content: ContentState

    public init(id: String, sessionID: String?, startedAt: Date, content: ContentState) {
        self.id = id; self.sessionID = sessionID; self.startedAt = startedAt; self.content = content
    }

    public var staleDate: Date { content.updatedAt.addingTimeInterval(5 * 60) }
}

public struct MobileWorkActivitySnapshot: Codable, Sendable {
    public var experienceRevision: Int? = 1
    public var experiences: [Experience]? = nil
    public var unavailable: String? = nil
    public var activities: [MobileWorkActivity]
    public var pairingFingerprint: String
    public var pushConfigured: Bool
    public var pushConfigurationError: String?

    public init(activities: [MobileWorkActivity], pairingFingerprint: String, pushConfigured: Bool, pushConfigurationError: String? = nil) {
        self.pairingFingerprint = pairingFingerprint
        self.activities = activities; self.pushConfigured = pushConfigured; self.pushConfigurationError = pushConfigurationError
    }
}
