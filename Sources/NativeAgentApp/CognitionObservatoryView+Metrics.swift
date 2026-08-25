// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

/// One capacity reading for the Observatory's Tensions & Pruning panel. The
/// counts come from the same runtime snapshot as the panel, while caps come
/// from that snapshot's effective cognition configuration.
enum CognitionTensionsPresentation {
    enum Capacity: Equatable {
        case belowCap
        case atCap
        case overCap
    }

    struct Counter: Equatable, Identifiable {
        let label: String
        let count: Int
        let cap: Int
        let capacity: Capacity

        var id: String { label }
        var value: String { "\(count) / \(cap)" }
        var lead: String? {
            switch capacity {
            case .belowCap: return nil
            case .atCap: return "\(label) is at its configured cap; pruning may be active."
            case .overCap: return "\(label) exceeds its configured cap; the snapshot needs attention."
            }
        }
    }

    struct Model: Equatable {
        let inhibitedWorkspaceCount: Int
        let counters: [Counter]

        var leads: [String] { counters.compactMap(\.lead) }
    }

    static func model(
        configuration: CognitiveConfiguration,
        nodeCount: Int,
        workspaceCount: Int,
        thoughtSeedCount: Int,
        inhibitedWorkspaceCount: Int
    ) -> Model {
        Model(
            inhibitedWorkspaceCount: inhibitedWorkspaceCount,
            counters: [
                counter(label: "Nodes", count: nodeCount, cap: configuration.maximumActiveNodes),
                counter(label: "Workspace", count: workspaceCount, cap: configuration.maximumWorkspaceItems),
                counter(label: "Thought seeds", count: thoughtSeedCount, cap: configuration.maximumThoughtSeeds),
            ]
        )
    }

    static func model(detail: CognitiveObservatoryDetail) -> Model {
        model(
            configuration: detail.configuration,
            nodeCount: detail.substrate.nodes.count,
            workspaceCount: detail.workspace.items.count,
            thoughtSeedCount: detail.thoughtSeeds.count,
            inhibitedWorkspaceCount: detail.workspace.inhibitedNodeIds.count
        )
    }

    private static func counter(label: String, count: Int, cap: Int) -> Counter {
        Counter(
            label: label,
            count: count,
            cap: cap,
            capacity: count < cap ? .belowCap : (count == cap ? .atCap : .overCap)
        )
    }
}

extension CognitionObservatoryView {

    func metrics(_ detail: CognitiveObservatoryDetail) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.md) {
            MetricTile(title: "Nodes", value: "\(detail.summary.nodeCount)", systemImage: "circle.hexagonpath")
            MetricTile(title: "Workspace", value: "\(detail.summary.workspaceCount)", systemImage: "rectangle.3.group")
            MetricTile(title: "Seeds", value: "\(detail.summary.thoughtSeedCount)", systemImage: "sparkles")
            MetricTile(title: "Reflections", value: "\(detail.summary.reflectionCount)", systemImage: "brain.head.profile")
            MetricTile(
                title: "Persistence",
                value: detail.substrate.persistenceHealth.status.rawValue.capitalized,
                systemImage: "externaldrive"
            )
        }
    }

    func tensionsAndPruning(_ detail: CognitiveObservatoryDetail) -> some View {
        let presentation = CognitionTensionsPresentation.model(detail: detail)
        return VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            labeledRow("Inhibited workspace", "\(presentation.inhibitedWorkspaceCount)")
            ForEach(presentation.counters) { counter in
                labeledRow(counter.label, counter.value)
                if let lead = counter.lead {
                    Label(lead, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(counter.capacity == .overCap ? .red : .orange)
                }
            }
        }
    }
}
