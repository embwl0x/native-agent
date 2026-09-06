import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.cognitionObservatory.panel.loopActivity
@Suite("Cognition Observatory loop activity")
struct CognitionObservatoryLoopActivityEvalTests {
    @Test("a lifecycle-only receipt read stays available while reporting no loop activity")
    func lifecycleBaselineDoesNotImplyLoopActivity() async throws {
        let root = try temporaryRoot("quiet")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )

        let detail = await CognitionObservatoryActions.refresh(runtime: runtime)

        guard case .available(let receipts) = detail.receiptRead else {
            Issue.record("A bootstrapped, enabled receipt store must remain observable")
            return
        }
        // Bootstrap itself records lifecycle restoration. It proves the store
        // is available, but it is not evidence that a background loop ran.
        #expect(receipts.contains { $0.kind == "lifecycle.restore" })
        // 2026-09-06: 7df7a4cd wired the pressure-dream trigger into the
        // residual-repair pass bootstrap already runs, and it books ONE receipt
        // the first time the decision changes — here "belowThreshold", a
        // decision NOT to dream (NativeCognitionRuntime+PressureDream.swift:84).
        // That is still not evidence a background loop ran, it is just no longer
        // lifecycle-prefixed, so it is admitted BY NAME: any other non-lifecycle
        // receipt on a quiet bootstrap would mean a loop actually ran.
        let loopEvidence = receipts.filter {
            !$0.kind.hasPrefix("lifecycle.") && $0.kind != "dream.pressure_not_due"
        }
        #expect(loopEvidence.isEmpty)
        #expect(CognitionLoopActivityPresentation.receiptCount(for: detail.receiptRead) == receipts.count)
        #expect(CognitionLoopActivityPresentation.collapsedHint(for: detail.receiptRead)?
            .hasPrefix("\(receipts[0].kind) · ") == true)

        // Quiet remains a presentation of a genuinely empty successful read,
        // not a claim that runtime bootstrap leaves no lifecycle evidence.
        let emptyRead = CognitiveReceiptRead.available([])
        #expect(CognitionLoopActivityPresentation.state(for: emptyRead) == .empty)
        #expect(CognitionLoopActivityPresentation.receiptCount(for: emptyRead) == 0)
        #expect(CognitionLoopActivityPresentation.collapsedHint(for: emptyRead) == "quiet")
    }

    @Test("a real microcycle receipt is observable through the mounted runtime read model")
    func microcycleReceiptProjectsToLoopActivity() async throws {
        let root = try temporaryRoot("active")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            now: { Date(timeIntervalSince1970: 1_785_974_400) },
            monotonicNowNanoseconds: { 42 },
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )

        let outcome = await runtime.runMicrocycle(reason: "loop activity evaluation")
        guard case .completed = outcome else {
            throw LoopActivityEvalError.microcycleDidNotComplete(outcome)
        }
        let detail = await CognitionObservatoryActions.refresh(runtime: runtime)
        let visible = CognitionLoopActivityPresentation.state(for: detail.receiptRead)

        guard case .receipts(let receipts) = visible else {
            throw LoopActivityEvalError.receiptWasNotObservable(visible)
        }
        #expect(receipts.contains { $0.kind == "microcycle" })
        #expect(CognitionLoopActivityPresentation.receiptCount(for: detail.receiptRead) == receipts.count)
        // Lifecycle restoration and the loop can share a deterministic clock
        // in this fixture. The collapsed row truthfully names the latest
        // receipt in storage; the activity assertion above identifies the
        // microcycle without assuming its UUID wins a timestamp tie.
        #expect(CognitionLoopActivityPresentation.collapsedHint(for: detail.receiptRead)?
            .hasPrefix("\(receipts[0].kind) · ") == true)
    }

    @Test("disabled receipt evidence is visibly unavailable, not a quiet zero")
    func disabledCognitionDoesNotRenderAsNoReceipts() async throws {
        let root = try temporaryRoot("disabled")
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = CognitiveConfiguration.allPhasesEnabled
        configuration.enabled = false
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration,
            installedPhysiologySoakEnabled: false
        )

        let detail = await CognitionObservatoryActions.refresh(runtime: runtime)
        let visible = CognitionLoopActivityPresentation.state(for: detail.receiptRead)

        #expect(detail.receiptRead == .unavailable(.cognitionDisabled))
        #expect(CognitionLoopActivityPresentation.receiptCount(for: detail.receiptRead) == nil)
        #expect(visible == .unavailable("Loop activity is unavailable while cognition is off."))
        #expect(CognitionLoopActivityPresentation.collapsedHint(for: detail.receiptRead)?.contains("unavailable") == true)
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-loop-activity-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum LoopActivityEvalError: Error {
    case microcycleDidNotComplete(CognitiveBackgroundRunOutcome)
    case receiptWasNotObservable(CognitionLoopActivityPresentation.State)
}
