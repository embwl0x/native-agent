import Foundation
import NativeAgentCore
import PersistenceCore

public struct CognitiveSubstrateDependencies: Sendable {
    public var now: @Sendable () -> Date
    public var makeUUID: @Sendable () -> UUID
    /// How the agent addresses the user, resolved from the configured persona
    /// (profile.json `userName`, set at onboarding). Never hardcode a name in
    /// the capsule/reflection cues — a public install's user is not "User".
    /// Empty/whitespace → the helpers fall back to grammar-safe "you"/"your".
    public var userName: @Sendable () -> String
    /// Rebuildable hot-read publication. The substrate remains the only owner
    /// of this state; the sink receives a bounded immutable projection after a
    /// mutation so turn preparation never has to enter this actor.
    public var attentionProjectionSink: @Sendable (CognitiveAttentionSignals?, Date) -> Void
    /// W4/P1 — the felt layer's dynamics constants as CONFIGURATION rather than
    /// compile-time literals, resolved the same way `now()`/`userName()` are.
    /// A closure rather than a stored value so a persona recompile can change the
    /// physics without rebuilding the substrate actor. Defaults to
    /// `.default`, which is byte-for-byte the pre-P1 literals.
    public var dynamics: @Sendable () -> PersonalityDynamicsConfiguration
    /// UNBIDDEN RECALL (2026-09-02). A LOCAL, provider-free lookup of felt
    /// moments by the words of the felt line — not by the user's message. The
    /// substrate never learns what a memory store is: it hands over a felt line
    /// and gets back moments, or nothing.
    ///
    /// THE SURFACE IS NOT OPTIONAL CONTEXT — it is the disclosure boundary. A
    /// memory restricted to one surface must never arrive unbidden on another,
    /// and this line is the least expected place for a leak precisely because
    /// nobody asked for it. The substrate passes the capsule request's own
    /// surface; the wiring must hand it to the store's disclosure policy rather
    /// than recalling unfiltered.
    ///
    /// Default is silence, and silence is the honest degraded state: a cold or
    /// unavailable memory store simply means she is not reminded of anything
    /// this turn. It must never cost a provider call.
    public var recallMoments: @Sendable (
        _ feltLine: String, _ k: Int, _ surface: String
    ) async -> [CognitiveRecalledMoment]
    /// Phase 5 B1. Last night's dream residue phrases (her diary's own words,
    /// embedded on device) scored against this message; [] when there is no
    /// living residue. Phrases in `spent` already surfaced and are skipped
    /// (all spent → no lookup at all). Local only, warm embedder only, never a
    /// provider call, never memory.
    public var dreamThemes: @Sendable (_ message: String, _ spent: Set<String>) async -> [CognitiveDreamTheme]
    /// Phase 5 D1: the local embedder, for the background reflection step
    /// only (paraphrase recurrence). Nil when it cannot embed; the lexical
    /// match still runs.
    public var embedTexts: @Sendable (_ texts: [String]) async -> [[Float]]?
    /// Phase 5 D1: whether a peer (`peer:<id>`, `claude`, …) is one the owner
    /// elevated in Trust. Unbound, no peer is.
    public var peerTrusted: @Sendable (_ peer: String) -> Bool
    /// Phase 5 B2. What actually happened between User's last turn and this
    /// one — a few short items with real content, [] when nothing did. Local
    /// reads only; the surface is the disclosure boundary for moments.
    public var sinceGap: @Sendable (_ from: Date, _ to: Date, _ surface: String) async -> [String]
    /// Phase 5 E3: a human cause for the body's feelings — an interest she
    /// came back to (curiosity), an opinion revised on evidence (coherence).
    public var feltCause: @Sendable (_ curiosity: Double, _ coherence: Double) async -> Void

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        userName: @escaping @Sendable () -> String = { "" },
        attentionProjectionSink: @escaping @Sendable (CognitiveAttentionSignals?, Date) -> Void = { _, _ in },
        dynamics: @escaping @Sendable () -> PersonalityDynamicsConfiguration = { .default },
        recallMoments: @escaping @Sendable (String, Int, String) async -> [CognitiveRecalledMoment]
            = { _, _, _ in [] },
        dreamThemes: @escaping @Sendable (String, Set<String>) async -> [CognitiveDreamTheme] = { _, _ in [] },
        embedTexts: @escaping @Sendable ([String]) async -> [[Float]]? = { _ in nil },
        peerTrusted: @escaping @Sendable (String) -> Bool = { _ in false },
        sinceGap: @escaping @Sendable (Date, Date, String) async -> [String] = { _, _, _ in [] },
        feltCause: @escaping @Sendable (Double, Double) async -> Void = { _, _ in }
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.userName = userName
        self.attentionProjectionSink = attentionProjectionSink
        self.dynamics = dynamics
        self.recallMoments = recallMoments
        self.dreamThemes = dreamThemes
        self.embedTexts = embedTexts
        self.peerTrusted = peerTrusted
        self.sinceGap = sinceGap
        self.feltCause = feltCause
    }

    public static let live = CognitiveSubstrateDependencies()
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

    public var receipts: [CognitiveReceiptRecord] {
        guard case .available(let receipts) = self else { return [] }
        return receipts
    }
}
