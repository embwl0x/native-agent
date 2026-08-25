import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, rows `cognition.organism.continuityReset`
// (NativeCognitionRuntime+Organism.swift:220 / :234) and
// `cognition.backgroundGate` (NativeCognitionRuntime.swift:1618).
//
// continuityReset — silent failure: WRONG VALUE. "A reset that does not also
// clear the persisted file resurrects the old body at next launch." The UI
// shows a fresh body; the next launch restores the one the user just cleared,
// and nothing errors. Only a RELAUNCH read can catch it, so this test builds a
// second runtime over the same root.
//
// backgroundGate — silent failure: SILENT ZERO. It is the single chokepoint
// every background cognition run passes; a gate that always answers "skipped"
// stops the whole subconscious while each caller just logs "skipped".
@Suite("Native cognition runtime continuity and background gate", .serialized)
struct NativeCognitionRuntimeContinuityAndGateTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-continuity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func configuration() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            replayEnabled: true,
            backgroundMicrocyclesEnabled: true,
            observatoryEnabled: true,
            maximumCapsuleCharacters: 4_000,
            maximumThoughtSeeds: 64
        )
    }

    private func liveTurn(_ runtime: NativeCognitionRuntime, index: Int) async {
        await runtime.observeTurnMessage(
            surface: "chat",
            role: "user",
            text: "Turn \(index): how is the wave going?",
            sessionId: "continuity-session",
            messageId: "u-\(index)"
        )
        await runtime.observeAssistantTurnCompleted(
            surface: "chat",
            text: "Turn \(index): steady and on track.",
            sessionId: "continuity-session",
            messageId: "a-\(index)"
        )
    }

    @Test("a continuity reset clears the persisted body so a relaunch cannot resurrect it")
    func continuityResetSurvivesRelaunch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")

        let first = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration(),
            organismConfigurationOverride: .enabled
        )
        await first.bootstrap()
        for index in 0..<3 { await liveTurn(first, index: index) }
        _ = await first.settleOrganismContinuity()

        let lived = await first.organismSnapshot().signalCount
        #expect(lived > 0, "the test needs a body with something in it before it can prove a reset")
        #expect(
            FileManager.default.fileExists(atPath: stateURL.path),
            "settled continuity must be durable — otherwise there is nothing to reset"
        )

        let afterReset = await first.resetOrganismContinuity()
        #expect(afterReset.signalCount == 0)
        #expect(
            FileManager.default.fileExists(atPath: stateURL.path),
            "reset must REWRITE the persisted body, not merely delete it — a missing file is indistinguishable from a fresh install"
        )

        // THE tooth: a second runtime over the same root is the relaunch, and
        // the yardstick is a runtime on a never-used root. If reset had only
        // cleared in-memory state, the relaunch reads back the old body and
        // every symptom is invisible until the user notices she is unchanged.
        // (Bootstrap itself contributes its own launch signals, so the honest
        // comparison is relaunched-after-reset == blank install, not == 0.)
        let blankRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: blankRoot) }
        let blank = NativeCognitionRuntime(
            dataRoot: blankRoot,
            configurationOverride: configuration(),
            organismConfigurationOverride: .enabled
        )
        await blank.bootstrap()
        let blankBaseline = await blank.organismSnapshot().signalCount

        let relaunched = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration(),
            organismConfigurationOverride: .enabled
        )
        await relaunched.bootstrap()
        let restored = await relaunched.organismSnapshot().signalCount
        #expect(
            restored == blankBaseline,
            "a relaunch after reset carried \(restored) signals against a blank install's \(blankBaseline) — the cleared body came back"
        )
        #expect(restored < lived)
    }

    @Test("the background cognition chokepoint allows work on a healthy machine")
    func backgroundGateAllowsOnANominalHost() async throws {
        let process = ProcessInfo.processInfo
        // Honest precondition: this host's own power/thermal state is an input
        // to the gate. On a throttled machine `skipped` is the CORRECT answer,
        // so the assertion would be measuring the host, not the code.
        try #require(!process.isLowPowerModeEnabled)
        try #require(process.thermalState == .nominal || process.thermalState == .fair)

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration()
        )
        await runtime.bootstrap()

        // Both an expensive reason and a cheap one: a gate stuck on "skipped"
        // silently stops the entire subconscious and every caller just logs it.
        #expect(await runtime.backgroundCognitionGate(reason: "reflection_event:test") == .allowed)
        #expect(await runtime.backgroundCognitionGate(reason: "microcycle") == .allowed)
    }
}
