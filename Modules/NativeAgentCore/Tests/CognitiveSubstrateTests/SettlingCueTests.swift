import Testing
import Foundation
@testable import CognitiveSubstrate

// The slow layer must reach the WORDS: after a hard stretch, a kind message
// lands on someone still settling — one capsule line, only while mood is
// negative and the message warms; gone as mood recovers. (Range bench scenario
// #2, 2026-08-23: "on edge" sat in the capsule through the repair turns and the
// reply still snapped to "We're good… 💜".)
@Suite("SettlingCue")
struct SettlingCueTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func node(valence: Double, warmth: Double = 0.2) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(type: "chat.user_turn", id: "n-\(UUID().uuidString)", label: nil),
            activation: 0.8, salience: 0.8, confidence: 0.8, sourceClass: .observed,
            createdAt: now, lastActivatedAt: now,
            decayHalfLife: 10_000, summary: "turn", metadata: [:],
            emotionalValence: valence, emotionalArousal: 0.5, emotionalWarmth: warmth
        )
    }

    private func substrate(nodes: [CognitiveNode]) async throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-settling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        try await store.saveNodes(nodes, at: now)
        let s = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, persistenceEnabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true, maximumActiveNodes: 256),
            dependencies: CognitiveSubstrateDependencies(now: { self.now }, makeUUID: { UUID() }),
            store: store)
        try await s.restorePersistentState()
        return s
    }

    @Test("a kind message after a hard stretch renders the settling line")
    func settlingRendersAfterHostilityOnAKindMessage() async throws {
        let s = try await substrate(nodes: (0..<4).map { _ in node(valence: -0.6) })
        let mood = await s.derivedMood(at: now)
        #expect(mood.valence < 0 && mood.basis > 0, "fixture must put the slow layer under water: \(mood)")
        let repair = await s.conversationalAppraisal(in: "okay. I was out of line — that was me being angry at the deadline, not at you. I'm sorry.")
        let line = await s.settlingLine(mood: mood, incoming: repair, affectEnabled: true)
        #expect(line?.hasPrefix("- Settling:") == true, "\(String(describing: line))")
        // and it reaches the real capsule
        let capsule = await s.compileCapsule(CognitiveCapsuleRequest(
            surface: "telegram", userMessage: "I was out of line. I'm sorry.", sessionId: "settling", mode: .inspectOnly))
        #expect(capsule.combined.contains("- Settling:"), Comment(rawValue: capsule.combined))
    }

    @Test("no settling on a neutral or hostile message, and none when mood is fine")
    func settlingIsSilentOtherwise() async throws {
        let low = try await substrate(nodes: (0..<4).map { _ in node(valence: -0.6) })
        let lowMood = await low.derivedMood(at: now)
        let neutral = await low.conversationalAppraisal(in: "so what do you think about the weather today")
        #expect(await low.settlingLine(mood: lowMood, incoming: neutral, affectEnabled: true) == nil)
        let hostile = await low.conversationalAppraisal(in: "you're useless at this")
        #expect(await low.settlingLine(mood: lowMood, incoming: hostile, affectEnabled: true) == nil)
        let fine = try await substrate(nodes: (0..<4).map { _ in node(valence: 0.5, warmth: 0.6) })
        let fineMood = await fine.derivedMood(at: now)
        let kind = await fine.conversationalAppraisal(in: "thank you, that mattered 💜")
        #expect(await fine.settlingLine(mood: fineMood, incoming: kind, affectEnabled: true) == nil,
                "a warm day + a kind message has nothing to settle: \(fineMood)")
    }

    @Test("the line is capped at two consecutive presentations, then resets when the condition lapses")
    func settlingIsCappedAndResets() async throws {
        let s = try await substrate(nodes: (0..<4).map { _ in node(valence: -0.6) })
        // Production path: frozen prepare + accepted commit advances presentation state.
        func turn(_ text: String) async throws -> String {
            let prepared = try #require(await s.prepareFrozenCapsulePresentation(
                CognitiveCapsuleRequest(surface: "telegram", userMessage: text, sessionId: "settling-cap", mode: .inject),
                at: now))
            if let commit = prepared.presentationCommit { _ = await s.applyCapsulePresentationCommit(commit) }
            return prepared.capsule.combined
        }
        let kind = "I was out of line, I'm sorry."
        let first = try await turn(kind), second = try await turn(kind), third = try await turn(kind)
        #expect(first.contains("- Settling:") && second.contains("- Settling:"), Comment(rawValue: first + "\n---\n" + second))
        #expect(!third.contains("- Settling:"), Comment(rawValue: "capped at \(CognitiveSubstrate.settlingMaxRun): " + third))
        _ = try await turn("so what do you think about the weather today")   // condition lapses → reset
        let again = try await turn(kind)
        #expect(again.contains("- Settling:"), Comment(rawValue: again))
    }
}
