import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `CognitiveLivedMoment.swift` | `CognitiveLivedMoment` journal; `LivedMomentDoor` records before folding |

// Record before living; each part folds a moment once in journal order (docs/SUBCONSCIOUS.md, "Lived moments").

/// Each part owns its lived stamp, so no per-part outcome is stored here. A meant row with a fold seq resumes an unfinished fold at opening.
public enum CognitiveMomentState: String, Codable, Sendable, Equatable {
    /// Recorded, not yet judged (or its judgment failed: judged again).
    case owed
    /// Judged; the interpretation is on the row and its living is owed.
    case meant
    /// Its attempt reached its end (fold and facts). The payloads are dropped.
    case lived
    /// Refused, with its reason (another life, the agent's own work, nothing to live).
    case refused
}

/// The care a thought of the agent's attends, carried through the reply into its journal record.
public struct CognitiveCareWake: Codable, Sendable, Equatable {
    public var careID: UUID
    public var watch: String
    public var at: Date

    public init(careID: UUID, watch: String, at: Date) {
        self.careID = careID
        self.watch = watch
        self.at = at
    }

    var key: String { watch + "|" + careID.uuidString }
}

/// Capture the settled exchange so interpretation can resume after relaunch.
public struct CognitiveMomentTurn: Codable, Sendable, Equatable {
    public var sessionId: String
    public var surface: String
    public var user: String
    /// The words the person actually asked (`AfterTurnOrigin.userMessage`).
    public var asked: String
    public var assistant: String
    public var turnId: String?
    public var runId: String?
    public var messageId: String?
    public var occurredAt: Date?
    /// Reply boundary captured before deferred memory work.
    public var repliedAt: Date?
    public var took: String?
    public var standingAgentName: String?
    /// The recorded envelope and answered source decisions accompany the complete carried sources.
    public var envelope: JSONValue?
    public var elevatedSources: [String]?
    /// Retain the same principal and carried steer as queue.add; missing provenance stays absent.
    public var originPrincipal: String?
    public var carriedSources: [String]?
    /// Only the agent's thoughts about a care enter the journal from the agent's own work.
    public var careWakes: [CognitiveCareWake]?

    public var isCareWake: Bool {
        sessionId == Happening.stream && careWakes?.isEmpty == false
            && !assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(sessionId: String, surface: String, user: String, asked: String, assistant: String,
                turnId: String? = nil, runId: String? = nil, messageId: String? = nil,
                occurredAt: Date? = nil, repliedAt: Date? = nil, took: String? = nil, standingAgentName: String? = nil,
                envelope: JSONValue? = nil,
                elevatedSources: [String]? = nil, originPrincipal: String? = nil,
                carriedSources: [String]? = nil, careWakes: [CognitiveCareWake]? = nil) {
        self.sessionId = sessionId
        self.surface = surface
        self.user = user
        self.asked = asked
        self.assistant = assistant
        self.turnId = turnId
        self.runId = runId
        self.messageId = messageId
        self.occurredAt = occurredAt
        self.repliedAt = repliedAt
        self.took = took
        self.standingAgentName = standingAgentName
        self.envelope = envelope
        self.elevatedSources = elevatedSources
        self.originPrincipal = originPrincipal
        self.carriedSources = carriedSources
        self.careWakes = careWakes
    }

    public var origin: AfterTurnOrigin? {
        guard let messageId else { return nil }
        var origin = AfterTurnOrigin(sessionId: sessionId, runId: runId, messageId: messageId,
                                     occurredAt: occurredAt, userMessage: asked)
        origin.took = took
        origin.careWakes = careWakes
        return origin
    }
}

/// The substrate's deferred-turn entry, recorded: the turn's event and its frozen caring request (with the exact clipped exchange around it), the completion
/// slot it answers and the node its ingest touched.
public struct CognitiveDeferredTurnRecord: Codable, Sendable, Equatable {
    public var event: CognitiveEvent
    /// An observed terminal edge bounds admission; nil leaves that evidence unavailable.
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

public struct CognitiveMomentInput: Codable, Sendable, Equatable {
    public var turn: CognitiveMomentTurn?
    public var deferred: CognitiveDeferredTurnRecord?
    /// Deliberately disabled cognition has no mind share. Missing ordinary context is unavailable evidence, never that permission.
    public var factsOnly: Bool?
    /// Set only after every mind/body save completes for this row's fold seq. Absent until every mind/body share has been durably folded.
    public var folded: UInt64?

    public init(turn: CognitiveMomentTurn? = nil, deferred: CognitiveDeferredTurnRecord? = nil,
                factsOnly: Bool? = nil, folded: UInt64? = nil) {
        self.turn = turn
        self.deferred = deferred
        self.factsOnly = factsOnly
        self.folded = folded
    }
}

public struct CognitiveLivedMoment: Codable, Sendable {
    public var id: String
    /// The `DataRootLife` it belongs to. A row from another life is refused.
    public var life: String
    public var kind: String
    public var livedAt: Date
    public var acceptedAt: Date
    public var state: CognitiveMomentState
    public var foldSeq: UInt64?
    public var mindEpoch: UInt64
    public var bodyEpoch: UInt64
    public var input: CognitiveMomentInput?
    /// The interpretation owner's checkpoint in parts_json, read from the same journal row.
    public var recovery: JSONValue?
    /// The interpretation, as the interpretation owner encoded it (`AfterTurnInterpretation` lives in MemoryV2, above this module).
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

    /// A turn's identity is its origin: the session and the incoming message. One chat message minted twice is one moment.
    public static func turnID(sessionId: String, messageId: String) -> String {
        ["turn", sessionId, messageId].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// Preparation distinguishes a broken input from its embedding owner and a local journal operation.
public enum LivedMomentPreparationFailure: Error, LocalizedError, Sendable {
    case record(String), embedding(String), local(String)

    public var errorDescription: String? {
        switch self {
        case .record(let words), .embedding(let words), .local(let words): return words
        }
    }
}

/// Only recorded turns may fold through the interpretation owner's installed door.
public struct LivedMomentDoor: Sendable {
    /// The data root whose journal this door keeps (never a global default).
    public var saveRecovery: @Sendable (String, JSONValue) async throws -> Void
    public var routeAnswer: @Sendable (String) async throws -> String?
    public var recordAnswer: @Sendable (String, String) async throws -> Void
    public var dataRoot: URL
    /// Record the settled turn as owed. Returns its identity, or nil when the journal cannot record it (the turn cannot fold).
    public var recordOwed: @Sendable (CognitiveMomentTurn) async -> String?
    /// The interpretation context for a recorded moment (rebuilt from the record after a relaunch); its caring request is saved with the input.
    public var prepare: @Sendable (_ moment: String, _ origin: AfterTurnOrigin, _ reply: String) async throws -> AfterTurnContext
    /// The interpretation came back: written onto the row (`meant`) before any part applies it. True only when the write is durable.
    public var meant: @Sendable (_ moment: String, _ meaning: JSONValue) async -> Bool
    /// The moment's attempt reached its end (its fold landed and its facts are settled): `lived`, payloads dropped.
    public var lived: @Sendable (_ moment: String) async -> Void
    public var refuse: @Sendable (_ moment: String, _ reason: String) async -> Void
    /// Moments of this life still owed or meant, oldest first. Rows from another life are refused on the way; age never discards owed work. nil means the
    /// journal is unavailable, never a proven empty queue.
    public var unlived: @Sendable () async -> [CognitiveLivedMoment]?
    /// Import held turns as owed moments in one transaction; true when they landed. One moment's row as it now stands (nil when absent or unreadable).
    public var moment: @Sendable (_ moment: String) async -> CognitiveLivedMoment?

    public init(
        dataRoot: URL,
        saveRecovery: @escaping @Sendable (String, JSONValue) async throws -> Void,
        routeAnswer: @escaping @Sendable (String) async throws -> String?,
        recordAnswer: @escaping @Sendable (String, String) async throws -> Void,
        recordOwed: @escaping @Sendable (CognitiveMomentTurn) async -> String?,
        prepare: @escaping @Sendable (String, AfterTurnOrigin, String) async throws -> AfterTurnContext,
        meant: @escaping @Sendable (String, JSONValue) async -> Bool,
        lived: @escaping @Sendable (String) async -> Void,
        refuse: @escaping @Sendable (String, String) async -> Void,
        unlived: @escaping @Sendable () async -> [CognitiveLivedMoment]?,
        moment: @escaping @Sendable (String) async -> CognitiveLivedMoment?
    ) {
        self.saveRecovery = saveRecovery
        self.routeAnswer = routeAnswer
        self.recordAnswer = recordAnswer
        self.dataRoot = dataRoot
        self.recordOwed = recordOwed
        self.prepare = prepare
        self.meant = meant
        self.lived = lived
        self.refuse = refuse
        self.unlived = unlived
        self.moment = moment
    }
}
