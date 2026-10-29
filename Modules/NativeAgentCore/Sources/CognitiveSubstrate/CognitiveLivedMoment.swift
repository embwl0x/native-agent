import Foundation
import PersistenceCore

// Blueprint: | `CognitiveLivedMoment.swift` | `CognitiveLivedMoment`: a settled turn's journal record (identity, life, forgetting epochs, state owed → meant → lived or refused, fold seq, recorded input and caring request, meaning) and `LivedMomentDoor`, the interpretation owner's closures |

// HER LIFE HAS ONE DOOR (docs/SUBCONSCIOUS.md, "Lived moments").
//
// She changes only by living a moment, and every moment that means something
// comes in by one door. A moment is recorded before it changes her, each part
// of her lives it once in the order the door folds it. This file is its shape; the
// journal is `lived_moments` in cognition.sqlite (`CognitiveSQLiteStore+
// LivedMoments.swift`) and the door is `NativeCognitionRuntime+Door.swift`.

/// Where a moment stands: owed → meant → lived, or refused. Each piece of
/// her knows the last moment it lived (its `lived` stamp; facts by operation
/// identity), so the row needs no per-piece outcome: a meant row whose fold
/// seq is set is a fold that began and did not finish, refolded at the
/// opening. A row an older binary wrote as `folding` reads as meant.
public enum CognitiveMomentState: String, Codable, Sendable, Equatable {
    /// Recorded, not yet judged (or its judgment failed: judged again).
    case owed
    /// Judged; the interpretation is on the row and its living is owed.
    case meant
    /// Its attempt reached its end (fold and facts). The payloads are dropped.
    case lived
    /// Refused, with its reason (another life, her own work, nothing to live).
    case refused
}

/// The exchange as it settled: everything the interpretation owner needs to
/// judge it again after a relaunch, captured where it is selected today.
public struct CognitiveMomentTurn: Codable, Sendable, Equatable {
    public var sessionId: String
    public var surface: String
    /// The incoming words as the promotion carried them.
    public var user: String
    /// The words the person actually asked (`AfterTurnOrigin.userMessage`).
    public var asked: String
    public var assistant: String
    public var turnId: String?
    public var runId: String?
    public var messageId: String?
    public var occurredAt: Date?
    public var took: String?
    public var standingAgentName: String?
    /// Provenance, kept exactly as the held queue keeps it: the turn's envelope,
    /// its source checkpoint and its elevated sources.
    public var envelope: JSONValue?
    public var sourceCheckpoint: [String]?
    public var elevatedSources: [String]?

    public init(sessionId: String, surface: String, user: String, asked: String, assistant: String,
                turnId: String? = nil, runId: String? = nil, messageId: String? = nil,
                occurredAt: Date? = nil, took: String? = nil, standingAgentName: String? = nil,
                envelope: JSONValue? = nil, sourceCheckpoint: [String]? = nil,
                elevatedSources: [String]? = nil) {
        self.sessionId = sessionId
        self.surface = surface
        self.user = user
        self.asked = asked
        self.assistant = assistant
        self.turnId = turnId
        self.runId = runId
        self.messageId = messageId
        self.occurredAt = occurredAt
        self.took = took
        self.standingAgentName = standingAgentName
        self.envelope = envelope
        self.sourceCheckpoint = sourceCheckpoint
        self.elevatedSources = elevatedSources
    }

    /// The origin the interpretation reads, rebuilt from the record.
    public var origin: AfterTurnOrigin? {
        guard let messageId else { return nil }
        var origin = AfterTurnOrigin(sessionId: sessionId, runId: runId, messageId: messageId,
                                     occurredAt: occurredAt, userMessage: asked)
        origin.took = took
        return origin
    }
}

/// The substrate's deferred-turn entry, recorded: the turn's event and its
/// frozen caring request (with the exact clipped exchange around it), the
/// completion slot it answers and the node its ingest touched.
public struct CognitiveDeferredTurnRecord: Codable, Sendable, Equatable {
    public var event: CognitiveEvent
    /// The explicit terminal edge, when observed before durable recording.
    /// nil retains the admission without a bound, including legacy records.
    public var endedAt: Date?
    public var caring: CaringAppraisalRequest?
    public var completionNodeKey: String?
    public var completionRecordedAt: Date?
    public var completionSessionId: String?
    public var outcomeKey: String?
    /// The forgetting epochs stamped at ingest (`AfterTurnContext`).
    public var mindEpoch: UInt64
    public var bodyEpoch: UInt64

    public init(event: CognitiveEvent, caring: CaringAppraisalRequest?,
                completionNodeKey: String? = nil, completionRecordedAt: Date? = nil,
                completionSessionId: String? = nil, outcomeKey: String? = nil,
                mindEpoch: UInt64 = 0, bodyEpoch: UInt64 = 0) {
        self.event = event
        self.caring = caring
        self.completionNodeKey = completionNodeKey
        self.completionRecordedAt = completionRecordedAt
        self.completionSessionId = completionSessionId
        self.outcomeKey = outcomeKey
        self.mindEpoch = mindEpoch
        self.bodyEpoch = bodyEpoch
    }
}

/// What the moment was.
public struct CognitiveMomentInput: Codable, Sendable, Equatable {
    public var turn: CognitiveMomentTurn?
    public var deferred: CognitiveDeferredTurnRecord?
    /// A retired held-turn import or deliberately disabled cognition has no mind share.
    /// Missing ordinary context is unavailable evidence, never that permission.
    public var factsOnly: Bool?
    /// Set only after every mind/body save completes for this row's fold seq.
    /// Absent on older inputs: replay their saved meaning before settlement.
    public var folded: UInt64?

    public init(turn: CognitiveMomentTurn? = nil, deferred: CognitiveDeferredTurnRecord? = nil,
                factsOnly: Bool? = nil, folded: UInt64? = nil) {
        self.turn = turn
        self.deferred = deferred
        self.factsOnly = factsOnly
        self.folded = folded
    }
}

/// One lived moment, as the journal keeps it.
public struct CognitiveLivedMoment: Codable, Sendable {
    public var id: String
    /// The `DataRootLife` it belongs to. A row from another life is refused.
    public var life: String
    /// `turn`; old forgetting rows remain readable but no longer execute.
    public var kind: String
    public var livedAt: Date
    public var acceptedAt: Date
    public var state: CognitiveMomentState
    public var foldSeq: UInt64?
    /// The forgetting epochs it was admitted under.
    public var mindEpoch: UInt64
    public var bodyEpoch: UInt64
    public var input: CognitiveMomentInput?
    /// The interpretation, as the interpretation owner encoded it
    /// (`AfterTurnInterpretation` lives in MemoryV2, above this module).
    public var meaning: JSONValue?

    public init(id: String, life: String, kind: String, livedAt: Date, acceptedAt: Date,
                state: CognitiveMomentState = .owed, foldSeq: UInt64? = nil,
                mindEpoch: UInt64, bodyEpoch: UInt64, input: CognitiveMomentInput? = nil,
                meaning: JSONValue? = nil) {
        self.id = id
        self.life = life
        self.kind = kind
        self.livedAt = livedAt
        self.acceptedAt = acceptedAt
        self.state = state
        self.foldSeq = foldSeq
        self.mindEpoch = mindEpoch
        self.bodyEpoch = bodyEpoch
        self.input = input
        self.meaning = meaning
    }

    /// A turn's identity is its origin: the session and the incoming message.
    /// One chat message minted twice is one moment.
    public static func turnID(sessionId: String, messageId: String) -> String {
        ["turn", sessionId, messageId].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// The door, as the interpretation owner (`AdaptiveMemoryPromoter`) reaches it.
/// Installed by the cognition runtime. Only recorded turns can fold into her.
public struct LivedMomentDoor: Sendable {
    /// The data root whose journal this door keeps (never a global default).
    public var dataRoot: URL
    /// Record the settled turn as owed. Returns its identity, or nil when the
    /// journal cannot record it (the turn cannot fold).
    public var recordOwed: @Sendable (CognitiveMomentTurn) async -> String?
    /// The interpretation context for a recorded moment (rebuilt from the
    /// record after a relaunch); its caring request is saved with the input.
    public var prepare: @Sendable (_ moment: String, _ origin: AfterTurnOrigin, _ reply: String) async -> AfterTurnContext?
    /// The interpretation came back: written onto the row (`meant`) before any
    /// part applies it. True only when the write is durable.
    public var meant: @Sendable (_ moment: String, _ meaning: JSONValue) async -> Bool
    /// The moment's attempt reached its end (its fold landed and its facts
    /// are settled): `lived`, payloads dropped.
    public var lived: @Sendable (_ moment: String) async -> Void
    /// The moment is refused, with its reason.
    public var refuse: @Sendable (_ moment: String, _ reason: String) async -> Void
    /// Moments of this life still owed or meant, oldest first. Rows
    /// from another life are refused on the way; age never discards owed work.
    /// nil means the journal is unavailable, never a proven empty queue.
    public var unlived: @Sendable () async -> [CognitiveLivedMoment]?
    /// Import held turns as owed moments in one transaction; true when they landed.
    public var importHeld: @Sendable ([CognitiveMomentTurn]) async -> Bool
    /// One moment's row as it now stands (nil when absent or unreadable).
    public var moment: @Sendable (_ moment: String) async -> CognitiveLivedMoment?

    public init(
        dataRoot: URL,
        recordOwed: @escaping @Sendable (CognitiveMomentTurn) async -> String?,
        prepare: @escaping @Sendable (String, AfterTurnOrigin, String) async -> AfterTurnContext?,
        meant: @escaping @Sendable (String, JSONValue) async -> Bool,
        lived: @escaping @Sendable (String) async -> Void,
        refuse: @escaping @Sendable (String, String) async -> Void,
        unlived: @escaping @Sendable () async -> [CognitiveLivedMoment]?,
        importHeld: @escaping @Sendable ([CognitiveMomentTurn]) async -> Bool,
        moment: @escaping @Sendable (String) async -> CognitiveLivedMoment?
    ) {
        self.dataRoot = dataRoot
        self.recordOwed = recordOwed
        self.prepare = prepare
        self.meant = meant
        self.lived = lived
        self.refuse = refuse
        self.unlived = unlived
        self.importHeld = importHeld
        self.moment = moment
    }
}
