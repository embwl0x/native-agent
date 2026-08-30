import Foundation
import Testing
import CognitiveSubstrate
@testable import NativeAgentApp

@Suite("Cognition surface disposition")
struct CognitionSurfaceSplitDispositionTests {
    @Test func observatoryAcceptsOnlyObservationalPanelIDs() {
        let panelIDs = Set(CognitionObservatoryPanelID.allCases.map(\.rawValue))

        #expect(panelIDs == [
            "controls", "contextFlow", "workshop", "organism", "loop",
            "harness", "workspace", "associations", "tensions", "affect",
            "seeds", "interruptions", "timeline", "capsule", "reflections",
        ])
        #expect(panelIDs.isDisjoint(with: ["standingViews", "schemaProposals", "identityProposals"]))
    }

    @Test func approvalControlsHaveOneActivityOwnerAndSchemaLineageIsReadOnly() {
        #expect(CognitionSurfaceDispositionPresentation.approvalsDestination == .activityCognitionProposals)
        #expect(CognitionSurfaceDispositionPresentation.activityApprovalSection.rawValue == "cognitionProposals")
        #expect(CognitionSurfaceDispositionPresentation.standingViewActions(isPending: true) == [.approve, .reject])
        #expect(CognitionSurfaceDispositionPresentation.standingViewActions(isPending: false).isEmpty)
    }

    @Test func activityKeepsUnavailableCognitionHonestAndRefusesMissingApproval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-surface-disposition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration(enabled: false),
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await runtime.bootstrap()

        let read = await CognitionProposalsFeed.read(runtime: runtime)
        guard case .unavailable(let reason) = read else {
            Issue.record("disabled cognition must remain unavailable to Activity")
            return
        }
        #expect(ActivityQueuePresentation.cognition(
            count: read.pending.count,
            state: .unavailable(reason)
        ) == .unavailable)

        let missingReview = await CognitionProposalActions.resolveWithOutcome(
            runtime: runtime,
            id: UUID(),
            approved: true
        )
        #expect(missingReview.status == .unavailable("That standing view is no longer awaiting review."))
    }

    @Test func diagnosticsAndDeskDebugHaveExplicitDestinations() {
        let diagnosticModes = DiagnosticsView.DiagnosticsMode.allCases.map(\.rawValue)
        #expect(diagnosticModes.contains("Cognition"))
        #expect(diagnosticModes.contains("Inspector"))
        #expect(CognitionSurfaceDispositionPresentation.deskDebugDestination == .diagnosticsCognition)
    }
}
