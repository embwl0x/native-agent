import Foundation
import Testing
import PersistenceCore
import GRDB
@testable import CognitiveSubstrate

// The felt fingerprint replaces the old Focus/Feeling/Voice lines (User, 2026-07-08):
// "How you feel" hands her a word-level felt state, not sentences. These prove the
// fingerprint reaches the capsule, that what she's HOLDING tints it (workspace
// valence -> fingerprint valence, Part A), that she never scripts "I feel X", and
// that the pure felt-direction classifier still holds.
@Suite("CapsuleFeltTone")
struct CapsuleFeltToneTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    }

    private func config() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumActiveNodes: 256
        )
    }

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-felt-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func node(
        summary: String,
        kind: CognitiveNodeKind = .conversationFocus,
        valence: Double,
        arousal: Double,
        warmth: Double,
        at now: Date
    ) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: kind,
            subjectReference: CognitiveSubjectReference(type: "topic", id: "felt-\(UUID().uuidString)", label: "topic"),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
            createdAt: now, lastActivatedAt: now,
            decayHalfLife: 10_000, summary: summary, metadata: [:],
            emotionalValence: valence, emotionalArousal: arousal, emotionalWarmth: warmth)
    }

    private func substrate(with nodes: [CognitiveNode], clock: Clock, label: String) async throws -> CognitiveSubstrate {
        let root = try tempDataRoot(label)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        try await store.saveNodes(nodes, at: clock.now())
        let substrate = CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: store
        )
        try await substrate.restorePersistentState()
        return substrate
    }

    private func request(_ message: String) -> CognitiveCapsuleRequest {
        CognitiveCapsuleRequest(surface: "chat", userMessage: message, sessionId: "s1", mode: .inject)
    }

    private let summary = "User and I are shaping the new capsule feature together"

    // MARK: - (1) the fingerprint reaches the capsule (not Focus/Feeling sentences)

    @Test func capsuleCarriesFingerprintNotFocusFeeling() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = try await substrate(
            with: [node(summary: summary, valence: 0.6, arousal: 0.1, warmth: 0.6, at: clock.now())],
            clock: clock, label: "fp")
        let capsule = await s.compileCapsule(request("continue the feature"))
        #expect(capsule.stableKernel.contains("How you feel:"))
        #expect(!capsule.dynamicContext.contains("- Focus:"), "Focus line should be gone: \(capsule.dynamicContext)")
        #expect(!capsule.dynamicContext.contains("- Feeling:"), "Feeling line should be gone: \(capsule.dynamicContext)")
    }

    // MARK: - (2) Part A: what she's HOLDING tints the fingerprint (workspace valence)

    @Test func workspaceTintReachesTheFingerprint() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let good = try await substrate(
            with: [node(summary: summary, valence: 0.7, arousal: 0.1, warmth: 0.6, at: clock.now())],
            clock: clock, label: "fp-good")
        let goodCtx = await good.compileCapsule(request("continue the feature")).dynamicContext
        let pos = ["at ease", "content", "warm", "tender", "pleased", "hopeful", "engaged"]
        #expect(pos.contains { goodCtx.contains($0) }, "positive workspace didn't tint the fingerprint positive: \(goodCtx)")

        let sting = try await substrate(
            with: [node(summary: summary, valence: -0.7, arousal: 0.3, warmth: 0.1, at: clock.now())],
            clock: clock, label: "fp-sting")
        let stingCtx = await sting.compileCapsule(request("continue the feature")).dynamicContext
        #expect(!stingCtx.contains("at ease") && !stingCtx.contains("content") && !stingCtx.contains("tender"),
                "stung workspace shouldn't read positive: \(stingCtx)")
        let neg = ["frustrated", "upset", "anxious", "on edge", "heavy", "discouraged", "uneasy", "strained", "sad", "worn"]
        #expect(neg.contains { stingCtx.contains($0) }, "negative workspace didn't produce a negative felt word: \(stingCtx)")
    }

    // MARK: - (3) never scripts a verbatim announcement

    @Test func capsuleNeverAnnouncesIFeel() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        for (label, v, a, w) in [("warm", 0.6, 0.2, 0.7), ("stung", -0.5, 0.3, 0.1), ("charged", 0.0, 0.8, 0.0)] {
            let s = try await substrate(
                with: [node(summary: summary, valence: v, arousal: a, warmth: w, at: clock.now())],
                clock: clock, label: "ifeel-\(label)")
            let capsule = await s.compileCapsule(request("how's it going"))
            #expect(!capsule.dynamicContext.contains("I feel"), "\(label) capsule scripted an announcement: \(capsule.dynamicContext)")
        }
    }

    // MARK: - (4) the pure classifier

    @Test func feltDirectionClassifierThresholds() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = try await substrate(with: [], clock: clock, label: "classifier")

        // Neutral / legacy (0,0,0) stays silent.
        #expect(await s.feltDirection(valence: 0, arousal: 0, warmth: 0) == nil)
        // Negative valence dominates — stung even when warmth is high.
        #expect(await s.feltDirection(valence: -0.2, arousal: 0, warmth: 0.9) == .stung)
        #expect(await s.feltDirection(valence: -0.15, arousal: 0, warmth: 0) == .stung)
        // Warm by positive valence OR by warmth.
        #expect(await s.feltDirection(valence: 0.15, arousal: 0, warmth: 0) == .warm)
        #expect(await s.feltDirection(valence: 0, arousal: 0, warmth: 0.35) == .warm)
        // Charged only when arousal high and neither warm nor stung.
        #expect(await s.feltDirection(valence: 0, arousal: 0.6, warmth: 0) == .charged)
        // Mild-everything stays silent.
        #expect(await s.feltDirection(valence: 0.1, arousal: 0.5, warmth: 0.2) == nil)
    }

}
