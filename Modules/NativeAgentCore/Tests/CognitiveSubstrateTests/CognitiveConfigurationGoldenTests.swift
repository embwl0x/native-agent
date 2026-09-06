import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `substrate.configure.runtimeKnobs` (fence core.substrate.field),
// core half. The knob SET is the surface: eleven Bool gates and nine
// numeric/string knobs. Only ONE of them was pinned anywhere, and
// `configure(_:)` can replace the whole configuration mid-flight under a live
// field with no receipt — a shrunk `maximumActiveNodes` evicts nodes on the
// very next settle, silently.
//
// This pins the two halves that live inside this module:
//   1. a GOLDEN record of every default, so a default change fails a diff
//      instead of shipping (every caller that omits a knob inherits these);
//   2. the CLAMPS, which are how an out-of-range knob gets silently swallowed;
//   3. the observable consequence of a mid-flight `configure(_:)`, including
//      the fact that it leaves no receipt behind.
//
// The PRODUCTION values come from NativeCognitionRuntime.loadConfiguration()
// and are out of this fence — see the BUILD report's production-seam list.
@Suite("CognitiveConfigurationGolden")
struct CognitiveConfigurationGoldenTests {

    @Test("every default knob value is pinned")
    func defaultsAreGolden() {
        let c = CognitiveConfiguration()
        // Gates: every capability is OFF by default except the standing-view
        // relevance canary. A gate that silently flips to on ships a behaviour
        // change to every caller that never named it.
        #expect(c.enabled == false)
        #expect(c.persistenceEnabled == false)
        #expect(c.workspaceEnabled == false)
        #expect(c.capsuleInjectionEnabled == false)
        #expect(c.standingViewCapsuleRelevanceEnabled == true)
        #expect(c.affectEnabled == false)
        #expect(c.thoughtSeedsEnabled == false)
        #expect(c.replayEnabled == false)
        #expect(c.backgroundMicrocyclesEnabled == false)
        #expect(c.reflectiveCallsEnabled == false)
        #expect(c.observatoryEnabled == false)
        // Bounds.
        #expect(c.maximumActiveNodes == 256)
        #expect(c.defaultDecayHalfLife == 60 * 60)
        #expect(c.maximumMetadataKeys == 12)
        #expect(c.maximumMetadataStringCharacters == 500)
        #expect(c.maximumSummaryCharacters == 500)
        #expect(c.maximumCapsuleCharacters == 1800)
        #expect(c.maximumWorkspaceItems == 12)
        #expect(c.maximumThoughtSeeds == 128)
        #expect(c.dailyReflectionCallBudget == 0)
        #expect(c.reflectionLoadThreshold == 0.35)
        // Reflection routing.
        #expect(c.reflectionSurface == "cognition_reflection")
        #expect(c.reflectionProvider == "anthropic_oauth_direct")
        #expect(c.reflectionReasoningEffort == "high")
        #expect(c.reflectionModel.isEmpty == false)
    }

    @Test("the shipped presets keep their shape")
    func presetsKeepTheirShape() {
        #expect(CognitiveConfiguration.disabled.enabled == false)
        #expect(CognitiveConfiguration.phaseOneEnabled.enabled == true)
        // phaseOne is cognition ON with every downstream phase still off.
        #expect(CognitiveConfiguration.phaseOneEnabled.persistenceEnabled == false)
        #expect(CognitiveConfiguration.phaseOneEnabled.workspaceEnabled == false)

        let all = CognitiveConfiguration.allPhasesEnabled
        for gate in [
            all.enabled, all.persistenceEnabled, all.workspaceEnabled, all.capsuleInjectionEnabled,
            all.affectEnabled, all.thoughtSeedsEnabled, all.replayEnabled,
            all.backgroundMicrocyclesEnabled, all.reflectiveCallsEnabled, all.observatoryEnabled,
        ] {
            #expect(gate == true)
        }
        // A reflection budget of 0 would make "all phases enabled" quietly
        // unable to reflect at all.
        #expect(all.dailyReflectionCallBudget > 0)
    }

    @Test("out-of-range knobs are clamped, never accepted raw")
    func knobsAreClamped() {
        let c = CognitiveConfiguration(
            maximumActiveNodes: 0,
            defaultDecayHalfLife: -5,
            maximumMetadataKeys: -1,
            maximumMetadataStringCharacters: -1,
            maximumSummaryCharacters: -1,
            maximumCapsuleCharacters: -1,
            maximumWorkspaceItems: 0,
            maximumThoughtSeeds: -1,
            dailyReflectionCallBudget: -1,
            reflectionLoadThreshold: 4,
            reflectionSurface: "   ",
            reflectionModel: "",
            reflectionProvider: "  ",
            reflectionReasoningEffort: ""
        )
        // A zero node cap would be a mind that can hold nothing; a zero
        // workspace cap, a mind that can attend to nothing.
        #expect(c.maximumActiveNodes == 1)
        #expect(c.maximumWorkspaceItems == 1)
        #expect(c.defaultDecayHalfLife == 1)
        #expect(c.maximumMetadataKeys == 0)
        #expect(c.maximumMetadataStringCharacters == 0)
        #expect(c.maximumSummaryCharacters == 0)
        #expect(c.maximumCapsuleCharacters == 0)
        #expect(c.maximumThoughtSeeds == 0)
        #expect(c.dailyReflectionCallBudget == 0)
        // A threshold above 1 is unreachable load — it would silence spontaneous
        // reflection forever instead of gating it.
        #expect(c.reflectionLoadThreshold == 1)
        // A blank routing string falls back rather than producing an unroutable
        // reflection request.
        #expect(c.reflectionSurface == "cognition_reflection")
        #expect(c.reflectionProvider == "anthropic_oauth_direct")
        #expect(c.reflectionReasoningEffort == "high")
        #expect(c.reflectionModel.isEmpty == false)
    }

    @Test("a mid-flight configure() shrinks the live field immediately, and silently")
    func configureShrinksTheLiveFieldWithoutAReceipt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-cogconfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let mind = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, persistenceEnabled: true, workspaceEnabled: true,
                maximumActiveNodes: 64),
            dependencies: CognitiveSubstrateDependencies(now: { at }),
            store: store
        )
        for index in 0..<6 {
            await mind.ingest(CognitiveEvent(
                id: "turn-\(index)",
                kind: .userMessageReceived,
                subject: CognitiveSubjectReference(type: "topic", id: "topic-\(index)"),
                sourceClass: .userStated,
                occurredAt: at,
                summary: "turn \(index)",
                importance: 0.5 + Double(index) / 20
            ))
        }
        #expect(await mind.snapshot().nodes.count == 6)

        var shrunk = await mind.configurationSnapshot()
        shrunk.maximumActiveNodes = 2
        await mind.configure(shrunk)

        // The cap takes effect on the very next read — no restart, no migration,
        // no confirmation. This is the behaviour a UI knob actually produces.
        let after = await mind.snapshot()
        #expect(after.nodes.count <= 2)
        #expect(after.maximumActiveNodes == 2)

        // CHARACTERIZATION: the swap writes no receipt of any kind, so a field
        // that shrank from 64 to 2 leaves no trace to diagnose later. Pinned so
        // that adding one is a deliberate, visible change.
        let receipts = try await store.loadReceiptRecords(limit: 200)
        #expect(receipts.contains { $0.kind.contains("configur") } == false)
    }
}
