import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `CognitiveSubstrateContracts.swift` | `CognitiveSubstrateDependencies`, `CognitiveEmbeddingBatch`: checked reads |

public struct CognitiveSubstrateDependencies: Sendable {
    public var growthProjection: @Sendable (JSONValue) async -> PartFaceSnapshot
    public var now: @Sendable () -> Date
    public var makeUUID: @Sendable () -> UUID
    public var decisions: @Sendable () async -> CognitiveCueRead<[String: Experience]>
    /// Proposal-owned history, read on demand rather than copied into schemas.
    public var remReplacements: @Sendable () async -> CognitiveCueRead<[String: String]>
    /// Resolve address from profile.json `userName`; unset uses grammatical you/your and unreadable profile throws. Never hardcode a person's name.
    public var userName: @Sendable () throws -> String
    /// Publish bounded immutable projections after mutation so turn preparation need not enter the substrate actor; ownership stays here.
    public var attentionProjectionSink: @Sendable (CognitiveAttentionSignals?) -> Void
    /// Checked live felt-layer dynamics. Failure withholds trait-dependent output.
    public var dynamics: @Sendable () throws -> PersonalityDynamicsConfiguration
    /// Use warm local dream vectors only; spent phrases perform no lookup and never become memory or provider traffic.
    public var dreamThemes: @Sendable (_ message: String, _ spent: Set<String>) async -> CognitiveCueRead<[CognitiveDreamTheme]>
    /// The warm local embedder. Nil means no resident model was requested; a resident inference or configuration failure throws its exact cause.
    public var embedTexts: @Sendable (_ texts: [String]) async throws -> CognitiveEmbeddingBatch?
    public var embeddingEpoch: @Sendable () async -> String?
    /// Only an owner Trust grant elevates a peer identity; an unbound checker grants none.
    public var peerTrusted: @Sendable (_ peer: String) -> Bool
    /// Validated AgentPeerStore identity projection, refreshed off the turn path.
    public var carePersonAliases: @Sendable () throws -> [String: String]
    /// Whether a surface is in the local-private disclosure tier (the memory disclosure law, `MemoryRecordDisclosurePolicy`). The agent's words from one
    /// conversation reach another only on such a surface. Unbound, none is.
    public var surfaceIsPrivate: @Sendable (_ surface: String) -> Bool
    /// Read actual gap events locally within the requested surface's disclosure boundary; no events returns empty.
    public var sinceGap: @Sendable (_ from: Date, _ to: Date, _ surface: String) async -> CognitiveCueRead<[String]>

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        userName: @escaping @Sendable () throws -> String = { "" },
        attentionProjectionSink: @escaping @Sendable (CognitiveAttentionSignals?) -> Void = { _ in },
        dynamics: @escaping @Sendable () throws -> PersonalityDynamicsConfiguration = { .default },
        dreamThemes: @escaping @Sendable (String, Set<String>) async -> CognitiveCueRead<[CognitiveDreamTheme]>
            = { _, _ in CognitiveCueRead([]) },
        embedTexts: @escaping @Sendable ([String]) async throws -> CognitiveEmbeddingBatch? = { _ in nil },
        embeddingEpoch: @escaping @Sendable () async -> String? = { nil },
        peerTrusted: @escaping @Sendable (String) -> Bool = { _ in false },
        carePersonAliases: @escaping @Sendable () throws -> [String: String] = { [:] },
        surfaceIsPrivate: @escaping @Sendable (String) -> Bool = { _ in false },
        sinceGap: @escaping @Sendable (Date, Date, String) async -> CognitiveCueRead<[String]>
            = { _, _, _ in CognitiveCueRead([]) },
        decisions: @escaping @Sendable () async -> CognitiveCueRead<[String: Experience]> = { CognitiveCueRead([:],
            unreadable: ["Approval decision reader is not bound"]) },
        remReplacements: @escaping @Sendable () async -> CognitiveCueRead<[String: String]>
            = { CognitiveCueRead([:], unreadable: ["REM proposal reader is not bound"]) },
        growthProjection: @escaping @Sendable (JSONValue) async -> PartFaceSnapshot = { _ in
            .init(part: "growth-week", version: nil, sourceEpoch: 0, status: .unavailable, face: nil,
                error: .init(code: "unavailable", message: "The growth projection is not bound."), owed: false)
        }
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.decisions = decisions
        self.remReplacements = remReplacements
        self.userName = userName
        self.attentionProjectionSink = attentionProjectionSink
        self.dynamics = dynamics
        self.dreamThemes = dreamThemes
        self.embedTexts = embedTexts
        self.embeddingEpoch = embeddingEpoch
        self.peerTrusted = peerTrusted
        self.carePersonAliases = carePersonAliases
        self.surfaceIsPrivate = surfaceIsPrivate
        self.sinceGap = sinceGap
        self.growthProjection = growthProjection
    }

    public static let live = CognitiveSubstrateDependencies()
}

/// The memory owner's vector-space identity travels with its inference result. Kept here to avoid a dependency from the substrate back into MemoryV2.
public struct CognitiveEmbeddingBatch: Sendable {
    public var epoch: String
    public var vectors: [[Float]]

    public init(epoch: String, vectors: [[Float]]) {
        self.epoch = epoch
        self.vectors = vectors
    }
}

/// What a continuity source read, and each source it could not read with its cause: unreadable is never folded into "nothing came to mind".
public struct CognitiveCueRead<Value: Sendable>: Sendable {
    public var value: Value
    public var unreadable: [String]

    public init(_ value: Value, unreadable: [String] = []) {
        self.value = value
        self.unreadable = unreadable
    }
}

/// Receipt reads must distinguish quiet, disabled and unreadable owners; failure cannot become an empty metric.
public enum CognitiveReceiptReadUnavailability: String, Sendable, Equatable {
    case cognitionDisabled = "cognition_disabled"
    case persistenceDisabled = "persistence_disabled"
    case storeUnavailable = "store_unavailable"
    case readFailed = "receipt_read_failed"
}

public enum CognitiveReceiptRead: Sendable, Equatable {
    case available([CognitiveReceiptRecord])
    case unavailable(CognitiveReceiptReadUnavailability)
}
