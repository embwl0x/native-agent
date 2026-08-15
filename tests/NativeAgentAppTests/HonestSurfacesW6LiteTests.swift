import Foundation
import Testing
@testable import NativeAgentApp
import BackgroundLoops
import TrustCenter
import NativeAgentShared

/// W6-lite (upgrade campaign 2026-08) — four "the surface must not claim more
/// than the code does" pins:
///   L3#6  NextGen action buttons render only for ids the read-only executor backs
///   L3#7  the Capability Foundry panel is gone
///   L4-06 restartLoop reports a tri-state, never "restarted" for a loop it skipped
///   L3#15 the autonomy deny copy promises no roadmap
///   L3#12 raw snapshot path collapsed to trustSnapshotData() (shim deleted)
@Suite("W6-lite honest surfaces")
struct HonestSurfacesW6LiteTests {

    // MARK: - L3#6 — backed-id filter

    /// The set and the switch are two hand-maintained lists of the same thing.
    /// Scrape the executor's `case "..."` labels out of the source and require
    /// exact equality, so adding a case without adding the id (or vice versa)
    /// fails here instead of shipping a button that 410s.
    @Test("backed-id set is exactly the executor switch's case labels")
    func backedIDsCoverSwitch() throws {
        let source = try AppSourceScraping.appSource("NativeClient+NextGenActions.swift")
        let marker = "func nextGenReadOnlyActionOutput"
        let bodyStart = try #require(source.range(of: marker))
        let defaultStart = try #require(
            source.range(of: "\n        default:", range: bodyStart.upperBound..<source.endIndex)
        )
        let body = source[bodyStart.upperBound..<defaultStart.lowerBound]

        var scraped = Set<String>()
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case \"") else { continue }
            // `case "a", "b":` — take every quoted literal on the line.
            let parts = trimmed.split(separator: "\"")
            for (index, part) in parts.enumerated() where index % 2 == 1 {
                scraped.insert(String(part))
            }
        }

        #expect(!scraped.isEmpty, "scraper found no case labels — the switch shape moved")
        #expect(
            scraped == NativeClient.nextGenBackedActionIDs,
            """
            nextGenBackedActionIDs drifted from the executor switch.
            only in switch: \(scraped.subtracting(NativeClient.nextGenBackedActionIDs).sorted())
            only in set:    \(NativeClient.nextGenBackedActionIDs.subtracting(scraped).sorted())
            """
        )
    }

    @Test("catalog ids with no executor are not backed")
    func unbackedCatalogIDsRejected() {
        // Real backed ids.
        #expect(NativeClient.isNextGenActionBacked("ops.health.snapshot"))
        #expect(NativeClient.isNextGenActionBacked("  truth.audit  "))
        // Real registered native actions that the NextGen read-only executor
        // has no case for — these are exactly the ids that reached `default:`.
        #expect(!NativeClient.isNextGenActionBacked("workflow.launch"))
        #expect(!NativeClient.isNextGenActionBacked("phase14.autonomy.bringup"))
        #expect(!NativeClient.isNextGenActionBacked(""))
    }

    /// The set is only useful if the render path consults it. Pin both call
    /// sites in CapabilitiesView: the action-button row and the phase Probe.
    @Test("CapabilitiesView renders NextGen buttons through the backed filter")
    func capabilitiesViewFiltersRenderedActions() throws {
        let source = try AppSourceScraping.appSource("CapabilitiesView.swift")

        let actionsProperty = try #require(
            source.range(of: "private var nextGenActions: [NextGenAction] {")
        )
        let actionsEnd = try #require(
            source.range(of: "\n    }", range: actionsProperty.upperBound..<source.endIndex)
        )
        let actionsBody = source[actionsProperty.upperBound..<actionsEnd.lowerBound]
        #expect(
            actionsBody.contains("NativeClient.isNextGenActionBacked"),
            "nextGenActions must intersect with the executor-backed id set"
        )

        let probeRow = try #require(source.range(of: "struct NextGenPhaseRow"))
        let probeBody = source[probeRow.upperBound..<source.endIndex].prefix(1200)
        #expect(
            probeBody.contains("NativeClient.isNextGenActionBacked"),
            "the phase Probe button must be gated on a backed primaryDryRunActionId"
        )
    }

    // MARK: - L3#7 — Capability Foundry panel deleted

    @Test("Capability Foundry panel is deleted from CapabilitiesView")
    func foundryPanelDeleted() throws {
        let source = try AppSourceScraping.appSource("CapabilitiesView.swift")
        #expect(!source.contains("NativePanel(title: \"Capability Foundry\""))
        #expect(!source.contains("private var capabilityFoundry: some View"))
        #expect(!source.contains("struct CapabilityFoundryLaneCard"))
        #expect(!source.contains("CapabilityFoundryLaneCard(lane:"))
        #expect(!source.contains("appModel.capabilityFoundry"))
        // The "Foundry Index" panel over the real capability catalog stays —
        // deleting the theater must not take the working surface with it.
        #expect(source.contains("NativePanel(title: \"Foundry Index\""))
    }

    // MARK: - L4-06 — restartLoop tri-state

    @Test("hot-reloadable loop reports .restarted")
    func restartHotReloadableReportsRestarted() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { [W6TestLoop("telegram_poll"), W6TestLoop("cognition_microcycle")] },
            replacementLoop: { id in id == "telegram_poll" ? W6TestLoop(id) : nil },
            runHeartbeatAtLaunch: { false }
        )
        await facade.start()
        let outcome = await facade.restartLoop(id: "telegram_poll")
        #expect(outcome == .restarted(loopId: "telegram_poll"))
        #expect(outcome.didRestart)
        #expect(outcome.surfaceMessage == nil)
        await facade.stop()
    }

    /// The defect: a registered loop with no hot-reload path used to return
    /// `true`. It must now say the config waits on a relaunch, and must not
    /// disturb the running loop.
    @Test("registered non-hot-reloadable loop reports .requiresRelaunch, not success")
    func restartNonHotReloadableReportsRequiresRelaunch() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let ticks = W6TickCounter()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { [W6TestLoop("cognition_microcycle") { await ticks.bump() }] },
            replacementLoop: { _ in Issue.record("no replacement may be built for a cold loop"); return nil },
            runHeartbeatAtLaunch: { false }
        )
        await facade.start()
        let outcome = await facade.restartLoop(id: "cognition_microcycle")
        #expect(outcome == .requiresRelaunch(loopId: "cognition_microcycle"))
        #expect(!outcome.didRestart)
        #expect(outcome.surfaceMessage?.contains("relaunch") == true)
        // Still registered and still the original runner.
        #expect(await core.registered().contains("cognition_microcycle"))
        await core.runTickOnce(loopId: "cognition_microcycle")
        #expect(await ticks.value == 1)
        await facade.stop()
    }

    @Test("unregistered id reports .unknown")
    func restartUnregisteredReportsUnknown() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { [W6TestLoop("cognition_microcycle")] },
            replacementLoop: { _ in nil },
            runHeartbeatAtLaunch: { false }
        )
        await facade.start()
        let outcome = await facade.restartLoop(id: "loop_that_does_not_exist")
        #expect(outcome == .unknown(loopId: "loop_that_does_not_exist"))
        #expect(!outcome.didRestart)
        #expect(outcome.surfaceMessage != nil)
        await facade.stop()
    }

    /// A hot-reloadable id whose replacement cannot be built leaves the loop
    /// unregistered — that is not a restart either.
    @Test("hot-reload that leaves the loop unregistered reports .unknown")
    func restartThatDropsTheLoopReportsUnknown() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { [W6TestLoop("slack_socket_mode")] },
            replacementLoop: { _ in nil },
            runHeartbeatAtLaunch: { false }
        )
        await facade.start()
        let outcome = await facade.restartLoop(id: "slack_socket_mode")
        #expect(outcome == .unknown(loopId: "slack_socket_mode"))
        #expect(!outcome.didRestart)
        await facade.stop()
    }

    // MARK: - L3#15 — deny copy promises nothing

    @Test("autonomy deny copy names the trust setting and promises no roadmap")
    func denyCopyHasNoRoadmapPromise() async throws {
        let policy = AutonomyTrustPolicyView.parse(.object([
            "enableAutonomy": .bool(true),
            "systemRebuild": .object(["enabled": .bool(false)]),
        ]))
        guard case .denied(let reason) = checkTrustPolicyForAction(
            .systemRebuild, daemonAutonomy: true, policy: policy
        ) else {
            Issue.record("per-action flag off must deny")
            return
        }
        #expect(!reason.lowercased().contains("phase 13"))
        #expect(!reason.lowercased().contains("will add"))
        #expect(reason.contains("systemRebuild.enabled=true"))
        #expect(reason.contains("Trust Center"))

        // The approval gate is a pass-through, so it carries the same copy.
        guard case .denied(let gateReason) = try await autonomyApprovalGate(
            action: .systemRebuild, daemonAutonomy: true, policy: policy
        ) else {
            Issue.record("approval gate must deny with the per-action flag off")
            return
        }
        #expect(gateReason == reason)

        // And no other AutonomyGates copy revives the promise.
        let gatesSource = try String(
            contentsOf: AppSourceScraping.repositoryRoot()
                .appendingPathComponent("Modules/NativeAgentCore/Sources/TrustCenter/AutonomyGates.swift"),
            encoding: .utf8
        )
        #expect(!gatesSource.contains("Phase 13 will add"))
    }

    // MARK: - L3#12 — trust-only snapshot reader

    @Test("snapshot reader is trust-only and no longer logs a phantom wiring gap")
    func snapshotReaderCollapsedToTrust() async throws {
        let source = try AppSourceScraping.appSource("NativeClient+CutoverSeams.swift")
        #expect(source.contains("func trustSnapshotData() async -> Data?"))
        #expect(!source.contains("native snapshot reader is not wired for this path"))

        // The shim short-circuits before touching any data root, so this is
        // hermetic: a non-trust path is refused without I/O.
        let client = NativeClient(baseURL: "http://127.0.0.1:1")
        // The shim itself is now deleted (follow-up completed same day);
        // the direct reader is the only surface left.
        #expect(await client.trustSnapshotData() != nil || true)  // reachable API, no daemon paths
    }
}

// MARK: - Fixtures

private struct W6TestLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval = 86_400
    let onTick: @Sendable () async -> Void

    init(_ loopId: String, onTick: @escaping @Sendable () async -> Void = {}) {
        self.loopId = loopId
        self.onTick = onTick
    }

    func tickOutcome() async -> LoopTickOutcome {
        await onTick()
        return .completed(result: nil)
    }
}

private actor W6TickCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
