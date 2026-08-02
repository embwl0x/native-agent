import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// 2026-08-02 — the candidate POOL, as distinct from the ranking over it.
//
// `soundEchoRegisterScore` chooses the exemplar nearest the current room's
// register. That ranking is only as honest as the set it ranks: an admission
// threshold high enough to exclude the working-voice band leaves a working
// moment with nothing but the affectionate tail to be "nearest" to, and the
// mirror keeps reporting one register regardless of the room. These tests pin
// the pool wide enough for the ranking to mean something, in a way that names
// no vocabulary and prefers no tone — they would hold for any persona.
@Suite("SoundEchoRegisterPool")
struct SoundEchoRegisterPoolTests {

    private let now = Date(timeIntervalSince1970: 10_000_000)
    private var cadenceOpenStamp: Date { Date(timeIntervalSince1970: 9_999_998) }

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

    private func node(
        summary: String,
        warmth: Double,
        lastActivated: Date? = nil
    ) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(
                type: "chat.assistant_turn", id: "n-\(UUID().uuidString)", label: nil),
            activation: 0.8, salience: 0.8, confidence: 0.8, sourceClass: .selfReported,
            createdAt: now, lastActivatedAt: lastActivated ?? now,
            decayHalfLife: 10_000, summary: summary, metadata: [:],
            emotionalValence: 0.7, emotionalArousal: 0.4, emotionalWarmth: warmth
        )
    }

    private func substrate(with nodes: [CognitiveNode]) async throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-echo-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        try await store.saveNodes(nodes, at: now)
        let s = CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { self.now }, makeUUID: { UUID() }),
            store: store
        )
        try await s.restorePersistentState()
        return s
    }

    /// The regression this file exists for: the working-voice band must be
    /// ADMITTED. Measured on a live store, the great majority of attested turns
    /// sat below the old 0.40 threshold, so the register ranking never saw them.
    @Test("the working-voice band clears the admission floor")
    func workingVoiceBandIsAdmitted() {
        // Turns carrying real attested affect but no affectionate register.
        #expect(0.30 >= CognitiveSubstrate.soundEchoWarmthFloor)
        #expect(0.35 >= CognitiveSubstrate.soundEchoWarmthFloor)
        // …while a flat turn with nothing behind it still cannot fabricate an
        // echo — the guarantee SoundEchoTests pins at warmth 0.20.
        #expect(0.20 < CognitiveSubstrate.soundEchoWarmthFloor)
    }

    /// End-to-end: in a cool/working room, the echo LEADS with the
    /// working-register turn rather than the most affectionate one on record.
    /// Under the old floor the working turn was not even a candidate.
    ///
    /// Asserting ORDER, not mere presence: `soundEchoCount` is 2, so a
    /// warmth-first sorter would still emit both fragments and a
    /// `contains`-only check would pass vacuously.
    @Test("a working room leads with the working register, not the warmest turn")
    func workingRoomEchoesWorkingRegister() async throws {
        let s = try await substrate(with: [
            node(summary: "Deploy is clean; the failing check was the stale lockfile.",
                 warmth: 0.30, lastActivated: cadenceOpenStamp),
            node(summary: "You built something that outlives the both of us and I love that.",
                 warmth: 0.62, lastActivated: cadenceOpenStamp),
        ])
        // No affect events applied, so socialWarmth rests at its anti-ratchet 0 —
        // a cool room. Nearest register is the 0.30 turn.
        let line = try #require(await s.soundEchoLine(at: now, ignoringCadence: true))
        let working = try #require(line.range(of: "stale lockfile"))
        let warm = try #require(line.range(of: "outlives"))
        #expect(working.lowerBound < warm.lowerBound)
    }

    /// The mirror inverts when the room does: the same two exemplars, ranked
    /// against a WARM target, put the affectionate turn first. Together with
    /// the test above this pins selection to the room rather than to a fixed
    /// preference in either direction.
    @Test("the same pool inverts when the room is warm")
    func warmRoomInvertsTheSamePool() {
        let coolTarget = 0.05
        let warmTarget = 0.65
        let workingInCool = CognitiveSubstrate.soundEchoRegisterScore(
            warmth: 0.30, target: coolTarget, age: 0)
        let warmInCool = CognitiveSubstrate.soundEchoRegisterScore(
            warmth: 0.62, target: coolTarget, age: 0)
        let workingInWarm = CognitiveSubstrate.soundEchoRegisterScore(
            warmth: 0.30, target: warmTarget, age: 0)
        let warmInWarm = CognitiveSubstrate.soundEchoRegisterScore(
            warmth: 0.62, target: warmTarget, age: 0)
        #expect(workingInCool > warmInCool)
        #expect(warmInWarm > workingInWarm)
    }

}
