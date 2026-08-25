import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / cognition.observatoryDetail
@Suite("Cognition Observatory detail runtime boundary")
struct CognitionObservatoryDetailEvalTests {
    @Test("the live runtime reports complete evidence only when durable receipts are readable")
    func completeReceiptEvidenceIsObservable() async throws {
        let root = try temporaryRoot("complete")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )

        let outcome = await runtime.runMicrocycle(reason: "observatory detail evaluation")
        guard case .completed = outcome else {
            throw CognitionObservatoryDetailEvalError.microcycleDidNotComplete(outcome)
        }

        let read = await CognitionObservatoryActions.refreshRead(runtime: runtime)

        #expect(read.evidenceStatus == .complete)
        guard case .available(let receipts) = read.detail.receiptRead else {
            throw CognitionObservatoryDetailEvalError.receiptEvidenceWasNotAvailable
        }
        #expect(receipts.contains { $0.kind == "microcycle" })
        #expect(read.detail.configuration.enabled)
        #expect(read.detail.summary.generatedAt.timeIntervalSince1970 > 0,
                "the detail must be a real runtime projection, not a standalone receipt fixture")
    }

    @Test("disabled and non-durable configurations retain the snapshot but report missing receipt evidence")
    func unavailableReceiptEvidenceCannotMasqueradeAsQuiet() async throws {
        let disabledRoot = try temporaryRoot("disabled")
        defer { try? FileManager.default.removeItem(at: disabledRoot) }
        let disabled = NativeCognitionRuntime(
            dataRoot: disabledRoot,
            configurationOverride: .disabled,
            installedPhysiologySoakEnabled: false
        )
        let disabledRead = await CognitionObservatoryActions.refreshRead(runtime: disabled)

        #expect(disabledRead.evidenceStatus == .receiptEvidenceUnavailable(.cognitionDisabled))
        #expect(disabledRead.detail.configuration.enabled == false)
        #expect(disabledRead.detail.receiptRead == .unavailable(.cognitionDisabled))

        let nonDurableRoot = try temporaryRoot("persistence-off")
        defer { try? FileManager.default.removeItem(at: nonDurableRoot) }
        var nonDurableConfiguration = CognitiveConfiguration.allPhasesEnabled
        nonDurableConfiguration.persistenceEnabled = false
        let nonDurable = NativeCognitionRuntime(
            dataRoot: nonDurableRoot,
            configurationOverride: nonDurableConfiguration,
            installedPhysiologySoakEnabled: false
        )
        let nonDurableRead = await CognitionObservatoryActions.refreshRead(runtime: nonDurable)

        #expect(nonDurableRead.evidenceStatus == .receiptEvidenceUnavailable(.persistenceDisabled))
        #expect(nonDurableRead.detail.configuration.enabled)
        #expect(nonDurableRead.detail.receiptRead == .unavailable(.persistenceDisabled))
        #expect(CognitionObservatoryPresentation.receiptEvidenceUnavailableText(.persistenceDisabled)
            .contains("unavailable"))
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-observatory-detail-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum CognitionObservatoryDetailEvalError: Error {
    case microcycleDidNotComplete(CognitiveBackgroundRunOutcome)
    case receiptEvidenceWasNotAvailable
}
