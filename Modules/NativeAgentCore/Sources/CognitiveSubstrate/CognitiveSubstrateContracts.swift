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

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        userName: @escaping @Sendable () -> String = { "" },
        attentionProjectionSink: @escaping @Sendable (CognitiveAttentionSignals?, Date) -> Void = { _, _ in },
        dynamics: @escaping @Sendable () -> PersonalityDynamicsConfiguration = { .default },
        recallMoments: @escaping @Sendable (String, Int, String) async -> [CognitiveRecalledMoment]
            = { _, _, _ in [] }
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.userName = userName
        self.attentionProjectionSink = attentionProjectionSink
        self.dynamics = dynamics
        self.recallMoments = recallMoments
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
