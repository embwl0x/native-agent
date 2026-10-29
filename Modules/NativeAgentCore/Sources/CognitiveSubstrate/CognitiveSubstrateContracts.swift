import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `CognitiveSubstrateContracts.swift` | `CognitiveSubstrateDependencies` struct; injected frozen growth projection, explicit unavailable when unbound |

public struct CognitiveSubstrateDependencies: Sendable {
    public var growthProjection: @Sendable (JSONValue) async -> PartFaceSnapshot
    public var now: @Sendable () -> Date
    public var makeUUID: @Sendable () -> UUID
    public var decisions: @Sendable () async -> [String: Experience]
    /// How the agent addresses the user, resolved from the configured persona
    /// (profile.json `userName`, set at onboarding). Never hardcode a name in
    /// the capsule/reflection cues — a public install's user is not "User".
    /// Empty/whitespace → the helpers fall back to grammar-safe "you"/"your".
    public var userName: @Sendable () -> String
    /// Rebuildable hot-read publication. The substrate remains the only owner
    /// of this state; the sink receives a bounded immutable projection after a
    /// mutation so turn preparation never has to enter this actor.
    public var attentionProjectionSink: @Sendable (CognitiveAttentionSignals?) -> Void
    /// Live felt-layer dynamics; a persona recompile takes effect without rebuilding the actor.
    public var dynamics: @Sendable () -> PersonalityDynamicsConfiguration
    /// Last night's dream residue phrases (her diary's own words,
    /// embedded on device) scored against this message; [] when there is no
    /// living residue. Phrases in `spent` already surfaced and are skipped
    /// (all spent → no lookup at all). Local only, warm embedder only, never a
    /// provider call, never memory.
    public var dreamThemes: @Sendable (_ message: String, _ spent: Set<String>) async -> CognitiveCueRead<[CognitiveDreamTheme]>
    /// The local embedder, for the background reflection step
    /// only (paraphrase recurrence). Nil when it cannot embed; the lexical
    /// match still runs.
    public var embedTexts: @Sendable (_ texts: [String]) async -> [[Float]]?
    /// Whether a peer (`peer:<id>`, `claude`, …) is one the owner
    /// elevated in Trust. Unbound, no peer is.
    public var peerTrusted: @Sendable (_ peer: String) -> Bool
    /// Whether a surface is in the local-private disclosure tier (the memory
    /// disclosure law, `MemoryRecordDisclosurePolicy`). Her words from one
    /// conversation reach another only on such a surface. Unbound, none is.
    public var surfaceIsPrivate: @Sendable (_ surface: String) -> Bool
    /// What actually happened between the user's last turn and this
    /// one — a few short items with real content, [] when nothing did. Local
    /// reads only; the surface is the disclosure boundary for moments.
    public var sinceGap: @Sendable (_ from: Date, _ to: Date, _ surface: String) async -> CognitiveCueRead<[String]>

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        userName: @escaping @Sendable () -> String = { "" },
        attentionProjectionSink: @escaping @Sendable (CognitiveAttentionSignals?) -> Void = { _ in },
        dynamics: @escaping @Sendable () -> PersonalityDynamicsConfiguration = { .default },
        dreamThemes: @escaping @Sendable (String, Set<String>) async -> CognitiveCueRead<[CognitiveDreamTheme]>
            = { _, _ in CognitiveCueRead([]) },
        embedTexts: @escaping @Sendable ([String]) async -> [[Float]]? = { _ in nil },
        peerTrusted: @escaping @Sendable (String) -> Bool = { _ in false },
        surfaceIsPrivate: @escaping @Sendable (String) -> Bool = { _ in false },
        sinceGap: @escaping @Sendable (Date, Date, String) async -> CognitiveCueRead<[String]>
            = { _, _, _ in CognitiveCueRead([]) },
        decisions: @escaping @Sendable () async -> [String: Experience] = { [:] },
        growthProjection: @escaping @Sendable (JSONValue) async -> PartFaceSnapshot = { _ in
            .init(part: "growth-week", version: nil, sourceEpoch: 0, status: .unavailable, face: nil,
                error: .init(code: "unavailable", message: "The growth projection is not bound."), owed: false)
        }
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.decisions = decisions
        self.userName = userName
        self.attentionProjectionSink = attentionProjectionSink
        self.dynamics = dynamics
        self.dreamThemes = dreamThemes
        self.embedTexts = embedTexts
        self.peerTrusted = peerTrusted
        self.surfaceIsPrivate = surfaceIsPrivate
        self.sinceGap = sinceGap
        self.growthProjection = growthProjection
    }

    public static let live = CognitiveSubstrateDependencies()
}

/// What a continuity source read, and each source it could not read with its
/// cause: unreadable is never folded into "nothing came to mind".
public struct CognitiveCueRead<Value: Sendable>: Sendable {
    public var value: Value
    public var unreadable: [String]

    public init(_ value: Value, unreadable: [String] = []) {
        self.value = value
        self.unreadable = unreadable
    }
}

/// Receipt history is observational evidence, not an empty-by-default metric.
/// The Observatory must be able to distinguish a quiet loop from a disabled or
/// unreadable receipt lane instead of turning every failed read into `[]`.
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
