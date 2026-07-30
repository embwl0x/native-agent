// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    @ViewBuilder
    func loopActivity(_ receipts: [CognitiveReceiptRecord]) -> some View {
        if receipts.isEmpty {
            Text("No cognition loop receipts.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(Array(receipts.prefix(10)), id: \.id) { receipt in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(receipt.kind)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(receipt.createdAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(payloadSummary(receipt.payload))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Divider()
                }
            }
        }
    }

    func researchHarness(_ detail: CognitiveObservatoryDetail) -> some View {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                HStack {
                    Text("Welfare bounds")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(detail.welfareBounds.withinBounds ? "bounded" : "attention")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("max affect \(String(format: "%.2f", detail.welfareBounds.maxAffectValue)), reflection pressure \(String(format: "%.2f", detail.welfareBounds.reflectionBudgetPressure))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let path = detail.lastResearchExportPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Divider()
                ForEach(Array(detail.facultyMeasurements.prefix(6)), id: \.id) { measurement in
                    HStack {
                        Text(measurement.faculty)
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.2f", measurement.score))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !detail.experiments.isEmpty {
                    Divider()
                    ForEach(Array(detail.experiments.prefix(4)), id: \.id) { experiment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(experiment.kind.rawValue): \(String(format: "%.2f", experiment.score))")
                                .font(.caption.weight(.semibold))
                            Text(experiment.reproducibilityKey)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
    }

    @ViewBuilder
    func workspace(_ workspace: CognitiveWorkspaceSnapshot) -> some View {
        if workspace.items.isEmpty {
            Text("No active workspace items.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(workspace.items, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.node.kind.rawValue)
                                .font(NativeAgentFont.label.bold())
                            Spacer()
                            Text(String(format: "%.2f", item.score))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.node.summary)
                            .font(.caption)
                            .textSelection(.enabled)
                        Text(item.reasons.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }

    func associationGraph(_ edges: [CognitiveAssociationEdge], nodes: [CognitiveNode]) -> some View {
        // An edge row without its endpoints ("sessionId · 0.94") is unreadable —
        // resolve both node ids to summary snippets so the row says WHAT is
        // associated, with the reasons as the why-line underneath.
        let labelsById = Dictionary(nodes.map { ($0.id, $0.summary) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            if edges.isEmpty {
                Text("No association edges.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(edges.prefix(8)), id: \.id) { edge in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(nodeSnippet(labelsById[edge.fromNodeId])) ↔ \(nodeSnippet(labelsById[edge.toNodeId]))")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(String(format: "%.2f", edge.weight))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("why: \(edge.reasons.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// One-line label for an association endpoint; a node evicted since the edge
    /// formed has no summary — say so instead of rendering an empty gap.
    private func nodeSnippet(_ summary: String?) -> String {
        guard let summary else { return "(forgotten)" }
        let oneLine = summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return "(forgotten)" }
        return oneLine.count > 44 ? String(oneLine.prefix(44)) + "…" : oneLine
    }

    private func payloadSummary(_ value: JSONValue) -> String {
        switch value {
        case .object(let object):
            // Preferred keys lead for scanability, but every key renders with its
            // value — a keys-only fallback made prune / consolidation receipts read
            // as broken ("deletedNodes, maxNodes" with the counts silently dropped).
            let preferredKeys = [
                "reason", "status", "workspaceCount", "inhibitedCount", "nodeCount",
                "reinforced", "calmed", "surface", "model", "provider", "resource",
                "docCount",
            ]
            var parts: [String] = []
            for key in preferredKeys {
                guard let value = object[key] else { continue }
                parts.append("\(key)=\(scalarSummary(value))")
            }
            for key in object.keys.sorted() where !preferredKeys.contains(key) {
                guard let value = object[key] else { continue }
                parts.append("\(key)=\(scalarSummary(value))")
            }
            return parts.joined(separator: ", ")
        default:
            return scalarSummary(value)
        }
    }

    private func scalarSummary(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return "\(value)"
        case .double(let value):
            return String(format: "%.2f", value)
        case .string(let value):
            // Long error/reason strings would reintroduce the wall-of-text the
            // collapse work just removed — cap the scalar, full value in the db.
            return value.count > 120 ? String(value.prefix(120)) + "…" : value
        case .array(let values):
            return "\(values.count) items"
        case .object(let object):
            return "\(object.count) fields"
        }
    }
}
