// EVAL COVERAGE — fence `app.mind`, wave A (2026-08-23).
//
// The Cognition Observatory is the fence's densest cluster of "dead control"
// and "silent zero" surfaces: every button in CognitionObservatoryView is
// `private`, discards its result, and reports back only by the panel below it
// redrawing. None of that is reachable from a test, so what these evals pin is
// the SEAM the buttons sit on — `NativeCognitionRuntime`, which IS internal and
// IS root-injectable. If a control silently stops doing anything, it stops here
// first.
//
// Hermetic: every runtime gets its own temp dataRoot. Nothing reads or writes
// the live `data/` root. The one exception is `UserDefaults.standard` (the
// toggles' real storage) — that suite is `.serialized` and restores every key
// it touches, and the app test target runs `--no-parallel` (script/test.sh:232).
import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// MARK: - helpers

private func mindTempRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindObservatory-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A runtime with cognition genuinely ON, persistence on (so the SQLite store
/// really opens under the temp root), organism off, and microcycles hand-flushed.
private func mindRuntime(dataRoot: URL) -> NativeCognitionRuntime {
    NativeCognitionRuntime(
        dataRoot: dataRoot,
        configurationOverride: CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            replayEnabled: true,
            backgroundMicrocyclesEnabled: true,
            observatoryEnabled: true
        ),
        organismConfigurationOverride: .disabled,
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
}

private func mindEvent(_ id: String, _ summary: String) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "conversation", id: id),
        sourceClass: .userStated,
        occurredAt: Date(),
        summary: summary,
        importance: 0.8,
        turnKind: .live
    )
}

// MARK: - Ablation round trip (ui.cognitionObservatory.button.ablateWorkspace /
//         .button.restoreWorkspace / .panel.workspace)

@Suite("Mind observatory — ablation + workspace", .serialized)
struct MindObservatoryAblationTests {

    /// The Restore button's `disabled()` predicate is literally
    /// `detail?.summary.ablations["workspace"] == false`
    /// (CognitionObservatoryView.swift:127). If the runtime ever stops emitting
    /// that exact key, Restore is permanently greyed out and the ablation can
    /// never be lifted from the UI. This pins the key, the value, and the fact
    /// that Restore's predicate flips back.
    @Test func workspaceAblationRoundTripsThroughTheExactKeyRestoreReads() async throws {
        let root = try mindTempRoot("ablation")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()

        // Before: no key at all — Ablate is enabled, Restore is disabled.
        let before = await runtime.observatoryDetail()
        #expect(before.summary.ablations["workspace"] == nil)
        #expect((before.summary.ablations["workspace"] == false) == false,
                "Restore must start disabled when nothing is ablated")

        await runtime.setAblation("workspace", enabled: false)
        let ablated = await runtime.observatoryDetail()
        #expect(ablated.summary.ablations["workspace"] == false,
                "Ablate must publish workspace=false under the key Restore reads")

        await runtime.setAblation("workspace", enabled: true)
        let restored = await runtime.observatoryDetail()
        #expect(restored.summary.ablations["workspace"] == true)
        #expect((restored.summary.ablations["workspace"] == false) == false,
                "Restore must disable itself again once the ablation is lifted")
    }

    /// The workspace ablation is a real runtime control, not only a recorded
    /// preference: after it is applied the observatory must stop exposing the
    /// transient workspace items that the control says it removes.
    @Test func workspaceAblationRemovesWorkspaceItems() async throws {
        let root = try mindTempRoot("ablation-inert")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()
        for i in 0..<4 {
            await runtime.observe(mindEvent("ablation-inert-\(i)", "workspace seed \(i)"))
        }
        let populated = await runtime.observatoryDetail()
        try #require(populated.workspace.items.count > 0,
                     "fixture must actually put items in the workspace")

        await runtime.setAblation("workspace", enabled: false)
        let after = await runtime.observatoryDetail()
        #expect(after.summary.ablations["workspace"] == false)
        #expect(after.workspace.items.isEmpty,
                "workspace=false must remove the transient items from the runtime read model")
    }
}

// MARK: - Clear transient state (ui.cognitionObservatory.button.clear /
//         .notice.persistenceDegraded)

@Suite("Mind observatory — clear transient state", .serialized)
struct MindObservatoryClearTests {

    @Test func clearReportsClearedAndActuallyEmptiesTheField() async throws {
        let root = try mindTempRoot("clear-ok")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()
        for i in 0..<3 { await runtime.observe(mindEvent("clear-\(i)", "before the wipe \(i)")) }
        let before = await runtime.observatoryDetail()
        try #require(before.summary.nodeCount > 0, "fixture must seed a non-empty field")

        let outcome = await runtime.clearTransientState()
        #expect(outcome == .cleared)

        let after = await runtime.observatoryDetail()
        #expect(after.summary.nodeCount == 0,
                "Clear must actually empty the field, not just toast success")
        #expect(after.summary.ablations.isEmpty,
                "Clear must also drop ablations — otherwise an ablation survives the wipe")
    }

    /// The ONE honest failure surface in the panel. `clearTransientState` returns
    /// `.persistenceFailed` only when the cognitive SQLite store could not be
    /// opened; the view maps that to the `.persistenceFailed` toast and the
    /// degraded notice (CognitionObservatoryView.swift:79, :158-165). Negative
    /// control: make the store un-openable by parking a regular FILE where the
    /// `cognition/` directory has to be, and prove Clear refuses instead of
    /// reporting success.
    @Test func clearFailsLoudWhenTheCognitiveStoreCannotOpen() async throws {
        let root = try mindTempRoot("clear-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        // A file (not a directory) at <root>/cognition blocks the store's
        // directory creation, so `try? CognitiveSQLiteStore(dataRoot:)` is nil.
        try Data("not a directory".utf8)
            .write(to: root.appendingPathComponent("cognition", isDirectory: false))

        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()
        let outcome = await runtime.clearTransientState()
        switch outcome {
        case .persistenceFailed:
            break  // the honest surface fired
        case .cleared:
            Issue.record("Clear reported success with no cognitive store; the degraded notice would never render")
        }
    }
}

// MARK: - Pin top concern (ui.cognitionObservatory.button.pinConcern /
//         .panel.thoughtSuggestions / .panel.thoughtSeeds)

@Suite("Mind observatory — pin concern", .serialized)
struct MindObservatoryPinConcernTests {

    /// nil maps to "Nothing pressing to pin right now" — which is exactly what a
    /// broken concern selector also produces. This pins both halves: nil on a
    /// genuinely empty mind, AND a real pin (returned text + a new seed) the
    /// moment there is something to pin. A dead selector fails the second half.
    @Test func pinConcernIsNilOnAnEmptyMindAndAddsASeedWhenThereIsAConcern() async throws {
        let root = try mindTempRoot("pin")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()

        #expect(await runtime.pinTopConcern() == nil,
                "an empty mind must report nothing to pin")

        let substrate = await runtime.substrateForIntegration()
        _ = await substrate.addThoughtSeed(
            kind: .followUp,
            text: "the release gate is still unproven",
            priority: 0.9
        )
        let seedsBefore = await runtime.observatoryDetail().thoughtSeeds.count

        let pinned = try #require(await runtime.pinTopConcern(),
                                  "a mind with an open seed must have something to pin")
        #expect(pinned.contains("release gate"))

        let after = await runtime.observatoryDetail()
        #expect(after.thoughtSeeds.count == seedsBefore + 1,
                "pinning must add a seed, not just return a string")
        #expect(after.thoughtSeeds.contains { $0.text.hasPrefix("Pinned concern: ") },
                "the pinned seed must carry the 'Pinned concern:' prefix the panel shows")
    }
}

// MARK: - Research harness + export (ui.cognitionObservatory.button.runEvals /
//         .button.export / .panel.researchHarness)

@Suite("Mind observatory — research harness", .serialized)
struct MindObservatoryResearchHarnessTests {

    /// "Run evals" has NO result surface — the only feedback is the Research
    /// Harness panel filling in. A harness that produces nothing renders exactly
    /// like one that was never run, so pin that one run produces a result for
    /// EVERY experiment kind plus a computed (not default-constructed) welfare
    /// bound.
    @Test func researchHarnessFillsEveryExperimentKindAndComputesWelfareBounds() async throws {
        let root = try mindTempRoot("harness")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()
        for i in 0..<3 { await runtime.observe(mindEvent("harness-\(i)", "harness input \(i)")) }

        let before = await runtime.observatoryDetail()
        #expect(before.experiments.isEmpty, "no experiments before the button is pressed")
        let pressedAt = Date()

        await runtime.runResearchHarness()
        let after = await runtime.observatoryDetail()

        let kinds = Set(after.experiments.map(\.kind))
        #expect(kinds == Set(CognitiveExperimentKind.allCases),
                "every experiment kind must produce a row: got \(kinds.map(\.rawValue).sorted())")
        #expect(!after.facultyMeasurements.isEmpty,
                "faculty measurements must be non-empty after a harness run")
        // The collapsed hint says "bounded" whenever withinBounds is true, and a
        // default-constructed bound is ALSO withinBounds. Pin that the bound was
        // actually computed: generatedAt moves off the epoch and the affect
        // reading reflects the seeded field.
        #expect(after.welfareBounds.generatedAt >= pressedAt,
                "a welfare bound stamped before the run was never recomputed")
        #expect(after.welfareBounds.maxAffectValue > 0,
                "a computed welfare bound over a seeded field must not read 0.00")
    }

    /// Export's result is discarded by the view (`_ =`), so a failed export leaves
    /// the PREVIOUS path on screen and reads as proof of a fresh export. The
    /// runtime at least has to tell the truth: a real path that exists on success,
    /// and nil — with `lastResearchExportPath` untouched — on failure.
    @Test func exportWritesARealFileAndReturnsNilWhenItCannot() async throws {
        let root = try mindTempRoot("export")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()
        await runtime.runResearchHarness()

        let path = try #require(await runtime.exportResearchTrace(),
                                "a healthy export must return the path it wrote")
        #expect(FileManager.default.fileExists(atPath: path),
                "the exported trace must exist on disk, not just be reported")
        #expect(await runtime.observatoryDetail().lastResearchExportPath == path)

        // Negative control: block the exports directory with a regular file so
        // the write cannot land.
        let blockedRoot = try mindTempRoot("export-blocked")
        defer { try? FileManager.default.removeItem(at: blockedRoot) }
        let cognitionDir = blockedRoot.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: cognitionDir, withIntermediateDirectories: true)
        try Data("not a directory".utf8)
            .write(to: cognitionDir.appendingPathComponent("exports", isDirectory: false))
        let blocked = mindRuntime(dataRoot: blockedRoot)
        await blocked.bootstrap()
        #expect(await blocked.exportResearchTrace() == nil,
                "a failed export must report nil so the caller can refuse to show a path")
        #expect(await blocked.observatoryDetail().lastResearchExportPath == nil,
                "a failed export must not stamp a path the UI would render as fresh")
    }
}

// MARK: - Microcycle button (ui.cognitionObservatory.button.microcycle)

@Suite("Mind observatory — manual microcycle", .serialized)
struct MindObservatoryMicrocycleTests {

    /// The manual-run button has no result surface at all, so a microcycle that
    /// REFUSES looks identical to one that ran. Pin the three-way outcome: a live
    /// mind completes, a disabled substrate reports `.skipped` (never `.completed`).
    @Test func manualMicrocycleDistinguishesCompletedFromSkipped() async throws {
        let root = try mindTempRoot("microcycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()
        for i in 0..<3 { await runtime.observe(mindEvent("micro-\(i)", "dirty the field \(i)")) }

        let ran = await runtime.runMicrocycle(reason: "observatory manual run")
        #expect(ran == .completed("cognitive field settled through checked persistence"),
                "a dirty live mind must report completed, got \(ran)")

        let offRoot = try mindTempRoot("microcycle-off")
        defer { try? FileManager.default.removeItem(at: offRoot) }
        let off = NativeCognitionRuntime(
            dataRoot: offRoot,
            configurationOverride: CognitiveConfiguration(enabled: false),
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await off.bootstrap()
        let refused = await off.runMicrocycle(reason: "observatory manual run")
        if case .completed = refused {
            Issue.record("a disabled substrate reported a completed microcycle: \(refused)")
        }
    }
}

// MARK: - Change stream (loop.cognitionObservatory.changeStream /
//         loop.livingStatus.cognitionChangeStream)

@Suite("Mind observatory — change stream", .serialized)
struct MindObservatoryChangeStreamTests {

    /// The observatory AND LivingStatusPanel each call `changes()` and refresh per
    /// event. Neither has a timer fallback, so a stream that starves a second
    /// subscriber freezes one panel at its last read behind a plausible
    /// "updated <time>" header. Pin that two concurrent subscribers BOTH receive.
    @Test func twoConcurrentSubscribersBothReceiveTheSameChange() async throws {
        let root = try mindTempRoot("stream")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = mindRuntime(dataRoot: root)
        await runtime.bootstrap()

        let observatory = await runtime.changes()
        let livingStatus = await runtime.changes()
        let first = Task { () -> NativeCognitionRuntimeChange? in
            for await change in observatory { return change }
            return nil
        }
        let second = Task { () -> NativeCognitionRuntimeChange? in
            for await change in livingStatus { return change }
            return nil
        }

        await runtime.observe(mindEvent("stream-1", "both panels should wake"))

        let a = try #require(await first.value, "the observatory subscriber got nothing")
        let b = try #require(await second.value, "the LivingStatusPanel subscriber got nothing")
        #expect(a.reason == "event:userMessageReceived")
        #expect(a == b, "the two subscribers disagreed: \(a) vs \(b)")
    }
}

// MARK: - Toggles ↔ UserDefaults ↔ configuration
//         (ui.cognitionObservatory.toggle.capsuleInjection / .backgroundMicrocycles /
//          .reflection / .copy.masterSwitchClaim)

@Suite("Mind observatory — subconscious switches", .serialized)
struct MindObservatorySwitchTests {

    /// Every toggle in the panel writes a UserDefaults key that
    /// `NativeCognitionRuntime.loadConfiguration()` reads back by a matching
    /// string literal in the same file. That is a two-vocabulary seam: a rename on
    /// either side turns the switch into a decoration and nothing fails. These
    /// keys are the ones the panel and the Settings master both drive.
    private static let keys = [
        "cognitiveSubstrateEnabled",
        "cognitiveSubstrateCapsuleEnabled",
        "cognitiveSubstrateBackgroundEnabled",
        "cognitiveSubstrateReflectionEnabled",
        "cognitiveSubstrateDailyReflectionBudget",
        NativeCognitionRuntime.organismKernelEnabledKey,
    ]

    private func withSavedDefaults(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    /// The caption at CognitionObservatoryView.swift:56 makes a behavioural CLAIM:
    /// "Settings ▸ Subconscious is the master switch — flipping it there resets all
    /// of these together." If the master stops writing any one of the six keys the
    /// caption keeps promising it does. This pins the claim to the code.
    @Test func theMasterSwitchReallyMovesEveryToggleTogether() async throws {
        // env can force cognition on independently of the defaults; skip rather
        // than assert a false negative in that configuration.
        let env = ProcessInfo.processInfo.environment
        try #require(env["NATIVE_AGENT_COGNITION_ENABLED"] != "1",
                     "NATIVE_AGENT_COGNITION_ENABLED overrides the master switch")
        try #require(env["NATIVE_AGENT_COGNITION_REFLECTION_ENABLED"] != "1")

        try await withSavedDefaults {
            let root = try mindTempRoot("master")
            defer { try? FileManager.default.removeItem(at: root) }
            // No configurationOverride: this runtime must read the real defaults.
            let runtime = NativeCognitionRuntime(
                dataRoot: root,
                organismConfigurationOverride: .disabled,
                microcycleSchedulingMode: .manuallyFlushed,
                installedPhysiologySoakEnabled: false
            )

            _ = await runtime.setSubconsciousMasterEnabled(true, reflectionBudget: 4)
            let on = NativeCognitionRuntime.loadConfiguration()
            #expect(on.enabled)
            #expect(on.capsuleInjectionEnabled)
            #expect(on.backgroundMicrocyclesEnabled)
            #expect(on.reflectiveCallsEnabled)
            #expect(on.dailyReflectionCallBudget == 4)
            #expect(UserDefaults.standard.bool(forKey: NativeCognitionRuntime.organismKernelEnabledKey))

            _ = await runtime.setSubconsciousMasterEnabled(false, reflectionBudget: 4)
            let off = NativeCognitionRuntime.loadConfiguration()
            #expect(!off.enabled)
            #expect(!off.capsuleInjectionEnabled)
            #expect(!off.backgroundMicrocyclesEnabled)
            #expect(!off.reflectiveCallsEnabled)
            #expect(off.dailyReflectionCallBudget == 0)
            #expect(!UserDefaults.standard.bool(forKey: NativeCognitionRuntime.organismKernelEnabledKey))
        }
    }

    /// Each sub-toggle owns its own key AND is gated by the master: the panel
    /// renders capsule/background/reflection as independent switches, but
    /// `loadConfiguration()` ANDs all three with `enabled`. A regression that
    /// dropped the AND would let the capsule keep injecting with the subconscious
    /// switched off — the exact "wrong value" the capsule row names.
    @Test func eachSubToggleOwnsItsKeyAndStaysGatedByTheMaster() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["NATIVE_AGENT_COGNITION_ENABLED"] != "1")
        try #require(env["NATIVE_AGENT_COGNITION_REFLECTION_ENABLED"] != "1")

        try await withSavedDefaults {
            let root = try mindTempRoot("subtoggles")
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = NativeCognitionRuntime(
                dataRoot: root,
                organismConfigurationOverride: .disabled,
                microcycleSchedulingMode: .manuallyFlushed,
                installedPhysiologySoakEnabled: false
            )
            _ = await runtime.setSubconsciousMasterEnabled(true, reflectionBudget: 2)

            await runtime.setCapsuleEnabled(false)
            #expect(!NativeCognitionRuntime.loadConfiguration().capsuleInjectionEnabled)
            #expect(NativeCognitionRuntime.loadConfiguration().backgroundMicrocyclesEnabled,
                    "the capsule toggle must not move the background gate")
            await runtime.setCapsuleEnabled(true)

            await runtime.setBackgroundEnabled(false)
            #expect(!NativeCognitionRuntime.loadConfiguration().backgroundMicrocyclesEnabled)
            #expect(NativeCognitionRuntime.loadConfiguration().capsuleInjectionEnabled)
            await runtime.setBackgroundEnabled(true)

            await runtime.setReflectionEnabled(false)
            #expect(!NativeCognitionRuntime.loadConfiguration().reflectiveCallsEnabled)
            // The stored budget is deliberately RETAINED across a reflection-off
            // flip (loadConfiguration: `storedBudget ?? budgetDefault`), so the
            // user's number survives a toggle round trip. Pin that, because the
            // budget stepper is hidden while reflection is off and a silent reset
            // to the 2/0 default would only surface on the next re-enable.
            #expect(NativeCognitionRuntime.loadConfiguration().dailyReflectionCallBudget == 2,
                    "the user's reflection budget must survive a reflection-off flip")
            await runtime.setReflectionEnabled(true)
            #expect(NativeCognitionRuntime.loadConfiguration().dailyReflectionCallBudget == 2)

            // Master off wins over all three sub-keys, which are still ON.
            await runtime.setEnabled(false)
            let gated = NativeCognitionRuntime.loadConfiguration()
            #expect(!gated.capsuleInjectionEnabled,
                    "capsule injection survived the master being switched off")
            #expect(!gated.backgroundMicrocyclesEnabled)
            #expect(!gated.reflectiveCallsEnabled)
        }
    }
}

// MARK: - Collapsible panel ids (setting.cognitionObservatoryExpandedPanels)

@Suite("Mind observatory — panel id persistence")
struct MindObservatoryPanelIdTests {

    /// `expandedPanelsRaw` comma-JOINS the open panel ids into one @AppStorage
    /// string (CognitionObservatoryView.swift:387) and comma-SPLITS them back
    /// (:379). The doc comment states the rule — "Panel ids must not contain
    /// commas" — and nothing enforces it. An id with a comma splits into two
    /// ids that `insert`/`remove` can never match, so that panel can never be
    /// expanded again and the user's saved layout silently loses a row.
    @Test func everyCollapsiblePanelIdIsCommaFreeAndUnique() {
        let ids = CognitionObservatoryPanelID.allCases.map(\.rawValue)
        #expect(ids.count >= 8, "expected the observatory's collapsible panels, found \(ids)")
        for id in ids {
            #expect(!id.contains(","), "panel id \"\(id)\" contains a comma and can never be re-expanded")
            #expect(!id.isEmpty)
        }
        #expect(Set(ids).count == ids.count)
    }
}

// MARK: - Summary metric tiles (ui.cognitionObservatory.summary.metrics /
//         .badge.enabled)

@Suite("Mind observatory — summary metrics", .serialized)
struct MindObservatoryMetricTests {

    /// Every tile in CognitionObservatoryView+Metrics.swift:10 renders a bare
    /// integer with no absent/unreadable state, so 0 nodes reads as a calm empty
    /// mind. `observatorySnapshot()` has a hard early return that reports
    /// nodeCount/workspaceCount/thoughtSeedCount/episodeCount/reflectionCount as
    /// ZERO whenever `observatoryEnabled` is false — even over a full field. The
    /// only thing keeping that from being a lie in production is
    /// `loadConfiguration()` tying `observatoryEnabled` to `enabled`, so the
    /// header badge ("Enabled"/"Off") and the zeros can never disagree.
    /// Both halves are pinned here.
    @Test func metricTilesAreZeroOnlyWhenTheHeaderBadgeAlsoSaysOff() async throws {
        let root = try mindTempRoot("metrics-blind")
        defer { try? FileManager.default.removeItem(at: root) }
        // A substrate that is fully ON except for the observatory read.
        let blind = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                replayEnabled: true,
                backgroundMicrocyclesEnabled: true,
                observatoryEnabled: false
            ),
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await blind.bootstrap()
        for i in 0..<4 { await blind.observe(mindEvent("metrics-\(i)", "a real thought \(i)")) }
        let blindDetail = await blind.observatoryDetail()
        // The field really is populated…
        #expect(blindDetail.workspace.items.count > 0)
        // …and every tile still reads zero. That is the silent zero.
        #expect(blindDetail.summary.nodeCount == 0)
        #expect(blindDetail.summary.workspaceCount == 0)
        #expect(blindDetail.summary.thoughtSeedCount == 0)

        // Production can never reach that state: loadConfiguration ties the
        // observatory read to the master switch, so zeros imply the badge is Off.
        let env = ProcessInfo.processInfo.environment
        try #require(env["NATIVE_AGENT_COGNITION_ENABLED"] != "1")
        let shipped = NativeCognitionRuntime.loadConfiguration()
        #expect(shipped.observatoryEnabled == shipped.enabled,
                "observatoryEnabled must track enabled, or the tiles can read 0 while the badge says Enabled")

        // And with the observatory on, the tiles report the real counts.
        let honestRoot = try mindTempRoot("metrics-honest")
        defer { try? FileManager.default.removeItem(at: honestRoot) }
        let honest = mindRuntime(dataRoot: honestRoot)
        await honest.bootstrap()
        for i in 0..<4 { await honest.observe(mindEvent("metrics-ok-\(i)", "a real thought \(i)")) }
        let detail = await honest.observatoryDetail()
        #expect(detail.summary.nodeCount > 0, "a populated field must not render as 0 nodes")
        #expect(detail.summary.workspaceCount == detail.workspace.items.count,
                "the Workspace tile and the Workspace panel must agree")
    }
}
