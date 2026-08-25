import CognitiveSubstrate
import Testing
@testable import NativeAgentApp

@Suite("Cognition Observatory tensions behavior")
struct CognitionObservatoryTensionsBehaviorTests {
    private func configuration() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            thoughtSeedsEnabled: true,
            maximumActiveNodes: 4,
            maximumWorkspaceItems: 3,
            maximumThoughtSeeds: 2
        )
    }

    // app.mind / ui.cognitionObservatory.panel.tensions
    @Test("live snapshot counts below their configured caps have no saturation lead")
    func underCapCountsRemainMeasurementsRatherThanWarnings() {
        let model = CognitionTensionsPresentation.model(
            configuration: configuration(),
            nodeCount: 3,
            workspaceCount: 2,
            thoughtSeedCount: 1,
            inhibitedWorkspaceCount: 0
        )
        #expect(model.inhibitedWorkspaceCount == 0)
        #expect(model.counters.map(\.value) == ["3 / 4", "2 / 3", "1 / 2"])
        #expect(model.counters.allSatisfy { $0.capacity == .belowCap })
        #expect(model.leads.isEmpty)
    }

    // app.mind / ui.cognitionObservatory.panel.tensions
    @Test("a count pinned at a cap raises a saturation lead, while an overflow remains adverse")
    func capBoundaryAndOverflowRemainVisible() {
        let model = CognitionTensionsPresentation.model(
            configuration: configuration(),
            nodeCount: 4,
            workspaceCount: 4,
            thoughtSeedCount: 2,
            inhibitedWorkspaceCount: 1
        )
        #expect(model.counters.map(\.capacity) == [.atCap, .overCap, .atCap])
        #expect(model.leads.contains("Nodes is at its configured cap; pruning may be active."))
        #expect(model.leads.contains("Thought seeds is at its configured cap; pruning may be active."))
        #expect(model.leads.contains("Workspace exceeds its configured cap; the snapshot needs attention."))
    }
}
