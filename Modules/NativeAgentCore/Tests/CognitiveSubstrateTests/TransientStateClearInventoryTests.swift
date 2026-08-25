import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `substrate.clearTransientState` (fence core.substrate.field).
//
// One irreversible click in the Cognition Observatory wipes Agent's entire
// cognition, and the only test that touched it asserted a single disposition
// day-claim. Nothing said WHAT the wipe must clear versus preserve — so a
// family added later and forgotten in `clearTransientState()` would survive the
// wipe as a ghost describing nodes that no longer exist, and nobody would see
// it. LIVE: zero `user.clear_transient_state` receipts in this install, i.e.
// the destructive path has never been exercised on real data.
//
// This is a fixed INVENTORY: seed every publicly observable family, wipe, and
// require all of them empty/neutral in one assertion block.
@Suite("TransientStateClearInventory")
struct TransientStateClearInventoryTests {

    private static let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-clearstate-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func substrate(store: CognitiveSQLiteStore?) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: store != nil,
                workspaceEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                replayEnabled: true,
                reflectiveCallsEnabled: true,
                dailyReflectionCallBudget: 8
            ),
            dependencies: CognitiveSubstrateDependencies(now: { Self.at }),
            store: store
        )
    }

    /// Fill every family the wipe claims to reset, through real entry points.
    private func seedEveryFamily(_ mind: CognitiveSubstrate) async throws {
        await mind.ingest(CognitiveEvent(
            id: "user-turn",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat.user_turn", id: "turn-1"),
            sourceClass: .userStated,
            occurredAt: Self.at,
            summary: "We need this right now, immediately — keep moving.",
            importance: 1,
            metadata: ["sessionId": .string("session-a")]
        ))
        // A verification node so the `verificationNodeMayExist` latch is raised.
        await mind.ingest(CognitiveEvent(
            id: "verify-turn",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat.user_turn", id: "turn-verify"),
            sourceClass: .userStated,
            occurredAt: Self.at,
            summary: "snapshot verify ping",
            importance: 0.4,
            turnKind: .verification,
            metadata: ["sessionId": .string("session-a")]
        ))
        _ = await mind.addThoughtSeed(
            kind: .followUp, text: "Follow up on the auction-house scan.", priority: 0.9)
        _ = await mind.integrateReplay(CognitiveReplayIntegrationInput(
            reason: "seed",
            dreamEntries: [CognitiveDreamReplayReference(
                id: "dream-1", date: "2026-08-22", filename: "2026-08-22.md",
                content: "A dream worth remembering as an episode.")]))
        _ = await mind.recordUnreservedReflectionResultForTesting(
            request: CognitiveReflectionRequest(reason: "reflect", prompt: "p", requestedAt: Self.at),
            resultSummary: "A quiet pass.\nview: I trust work I have verified myself",
            provider: "test")
        await mind.setAblation("workspace", enabled: false)
    }

    @Test("the wipe empties EVERY publicly observable family")
    func clearEmptiesEveryFamily() async throws {
        let mind = substrate(store: nil)
        try await seedEveryFamily(mind)

        // Precondition: the seed really populated what we are about to assert on,
        // otherwise every "is empty" below would pass vacuously.
        #expect(await mind.snapshot().nodes.isEmpty == false)
        #expect(await mind.thoughtSeedSnapshot().isEmpty == false)
        #expect(await mind.episodeSnapshot().isEmpty == false)
        #expect(await mind.developmentalTimelineSnapshot().isEmpty == false)
        #expect(await mind.reflectionReceiptSnapshot().isEmpty == false)
        #expect(await mind.standingViewSnapshot().isEmpty == false)
        #expect(await mind.observatorySnapshot().ablations.isEmpty == false)
        #expect(await mind.affectSnapshot().taskPressure > 0)

        await mind.clearTransientState()

        #expect(await mind.snapshot().nodes.isEmpty)
        #expect(await mind.workspaceSnapshot().items.isEmpty)
        #expect(await mind.associationSnapshot().isEmpty)
        #expect(await mind.thoughtSeedSnapshot().isEmpty)
        #expect(await mind.thoughtSuggestionSnapshot().isEmpty)
        #expect(await mind.episodeSnapshot().isEmpty)
        #expect(await mind.schemaProposalSnapshot().isEmpty)
        #expect(await mind.developmentalTimelineSnapshot().isEmpty)
        #expect(await mind.reflectionReceiptSnapshot().isEmpty)
        #expect(await mind.standingViewSnapshot().isEmpty)
        #expect(await mind.researchExperimentSnapshot().isEmpty)

        // The faculty read is DERIVED (always eight rows), so its evidence is
        // what must go to zero — every data-backed faculty reports nothing left.
        let faculties = Dictionary(
            uniqueKeysWithValues: await mind.facultyMeasurementSnapshot().map { ($0.faculty, $0.score) })
        for faculty in ["event-continuity", "workspace-focus", "thought-seeds", "replay-lineage", "reflection-yield"] {
            #expect(faculties[faculty] == 0, "\(faculty) still reports evidence after the wipe")
        }

        let observatory = await mind.observatorySnapshot()
        #expect(observatory.nodeCount == 0)
        #expect(observatory.workspaceCount == 0)
        #expect(observatory.thoughtSeedCount == 0)
        #expect(observatory.episodeCount == 0)
        #expect(observatory.reflectionCount == 0)
        #expect(observatory.ablations.isEmpty)

        // Affect returns to the neutral origin, not to "whatever it happened to
        // decay to" — a wipe that leaves her pressured is a wipe that lied.
        let affect = await mind.affectSnapshot()
        #expect(affect.arousal == 0)
        #expect(affect.uncertainty == 0)
        #expect(affect.taskPressure == 0)
        #expect(affect.socialWarmth == 0)
    }

    @Test("a wiped mind accepts new life immediately")
    func clearedSubstrateIsUsableAgain() async throws {
        let mind = substrate(store: nil)
        try await seedEveryFamily(mind)
        await mind.clearTransientState()

        await mind.ingest(CognitiveEvent(
            id: "after-wipe",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat.user_turn", id: "turn-after"),
            sourceClass: .userStated,
            occurredAt: Self.at,
            summary: "Still here.",
            importance: 0.7,
            metadata: ["sessionId": .string("session-b")]
        ))
        // The dedup ledger must not have survived the wipe as a ghost that
        // silently swallows the first post-wipe events.
        #expect(await mind.snapshot().nodes.count == 1)
        #expect(await mind.workspaceSnapshot().items.count == 1)
    }

    // CHARACTERIZATION, not endorsement. The runtime's clear sequence calls
    // CognitiveSQLiteStore.clear() (nodes + artifacts + receipts) and then
    // substrate.clearTransientState(). `cognitive_motor_consequence_admission`
    // is NOT in that DELETE list, so after a wipe every previously-admitted
    // motor consequence remains permanently non-re-admissible into a now-empty
    // field. This test states the CURRENT contract explicitly so the asymmetry
    // is visible and any deliberate change to it fails here rather than being
    // discovered on a user's machine. See the BUILD report's production-seam
    // list — resolving it is a production decision, not a test change.
    @Test("store.clear() empties nodes/artifacts/receipts and RETAINS motor admissions")
    func storeClearInventoryIncludingTheRetainedAdmissionTable() async throws {
        let root = try tempDataRoot("storeclear")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let mind = substrate(store: store)
        try await seedEveryFamily(mind)
        try await mind.persistSnapshot()

        let motor = MotorActionReadModel(
            domain: "workshop", actionIdentity: "wipe-me",
            phase: .succeeded, domainState: "succeeded", verification: .satisfied,
            expectedNextEvidence: nil, updatedAt: "2026-08-23T10:00:00Z")
        #expect(try await store.admitMotorConsequence(motor, at: Self.at) == true)

        #expect(try await store.loadNodes().isEmpty == false)
        #expect(try await store.loadArtifacts(limit: 100).isEmpty == false)

        try await store.clear()

        #expect(try await store.loadNodes().isEmpty)
        #expect(try await store.loadArtifacts(limit: 100).isEmpty)
        #expect(try await store.loadReceipts(limit: 100).isEmpty)
        // The asymmetry, pinned: the admission key outlives the field it guards.
        #expect(try await store.admitMotorConsequence(motor, at: Self.at.addingTimeInterval(1)) == false)
    }
}
