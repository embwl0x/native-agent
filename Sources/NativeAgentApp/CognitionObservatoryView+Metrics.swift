// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    func metrics(_ detail: CognitiveObservatoryDetail) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.md) {
            MetricTile(title: "Nodes", value: "\(detail.summary.nodeCount)", systemImage: "circle.hexagonpath")
            MetricTile(title: "Workspace", value: "\(detail.summary.workspaceCount)", systemImage: "rectangle.3.group")
            MetricTile(title: "Seeds", value: "\(detail.summary.thoughtSeedCount)", systemImage: "sparkles")
            MetricTile(title: "Identity", value: "\(detail.summary.identityProposalCount)", systemImage: "person.text.rectangle")
            MetricTile(title: "Reflections", value: "\(detail.summary.reflectionCount)", systemImage: "brain.head.profile")
            MetricTile(
                title: "Persistence",
                value: detail.substrate.persistenceHealth.status.rawValue.capitalized,
                systemImage: "externaldrive"
            )
        }
    }

    func tensionsAndPruning(_ detail: CognitiveObservatoryDetail) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            labeledRow("Inhibited workspace", "\(detail.workspace.inhibitedNodeIds.count)")
            labeledRow("Node cap", "\(detail.configuration.maximumActiveNodes)")
            labeledRow("Workspace cap", "\(detail.configuration.maximumWorkspaceItems)")
            labeledRow("Seed cap", "\(detail.configuration.maximumThoughtSeeds)")
        }
    }
}
