import Foundation
import Testing
import CognitiveSubstrate
@testable import NativeAgentApp

// Eval coverage — fence `app.mind`, ledger row
// `ui.cognitionObservatory.panel.associations`. The model below is the exact
// presentation boundary mounted by associationGraph(_:nodes:), not a parallel
// count or source scrape.

private func associationNode(id: UUID, summary: String) -> CognitiveNode {
    CognitiveNode(
        id: id,
        kind: .conversationFocus,
        subjectReference: CognitiveSubjectReference(type: "topic", id: id.uuidString),
        activation: 0.7,
        salience: 0.7,
        confidence: 0.8,
        sourceClass: .observed,
        createdAt: .distantPast,
        lastActivatedAt: .distantPast,
        decayHalfLife: 60,
        summary: summary,
        metadata: [:])
}

@Test("an association graph with no resolvable endpoints is visibly a resolution failure")
func associationPanelDoesNotRenderTotalResolutionFailureAsForgottenPairs() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let fourth = UUID()
    let unresolved = [
        CognitiveAssociationEdge(fromNodeId: first, toNodeId: second, weight: 0.8),
        CognitiveAssociationEdge(fromNodeId: third, toNodeId: fourth, weight: 0.6),
    ]

    #expect(
        CognitiveAssociationGraphPresentation.state(edges: unresolved, nodes: [])
            == .endpointResolutionFailure(edgeCount: 2))

    let partiallyResolved = CognitiveAssociationGraphPresentation.state(
        edges: [CognitiveAssociationEdge(fromNodeId: first, toNodeId: second, weight: 0.8)],
        nodes: [associationNode(id: first, summary: "A real live association endpoint")])
    guard case .rows(let rows) = partiallyResolved else {
        Issue.record("one live endpoint should retain an ordinary association row")
        return
    }
    #expect(rows.count == 1)
    #expect(rows[0].fromLabel == "A real live association endpoint")
    #expect(rows[0].toLabel == "(forgotten)")
}
