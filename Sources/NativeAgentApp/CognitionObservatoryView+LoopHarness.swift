// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

/// The Association Graph is only meaningful when at least one of its edge
/// endpoints can be resolved from the same cognitive snapshot. A single
/// evicted node is ordinary decay and stays visible on its row; every endpoint
/// missing at once is a broken/partial snapshot, not a graph of forgotten
/// memories.
enum CognitiveAssociationGraphPresentation {
    static let visibleEdgeLimit = 8

    struct Row: Identifiable, Equatable {
        let id: String
        let fromLabel: String
        let toLabel: String
        let weight: Double
        let reasons: [String]
    }

    enum State: Equatable {
        case empty
        case endpointResolutionFailure(edgeCount: Int)
        case rows([Row])
    }

    static func state(
        edges: [CognitiveAssociationEdge],
        nodes: [CognitiveNode]
    ) -> State {
        guard !edges.isEmpty else { return .empty }
        let labelsByID = Dictionary(
            nodes.compactMap { node in
                normalizedSummary(node.summary).map { (node.id, $0) }
            },
            uniquingKeysWith: { first, _ in first })
        let hasResolvableEndpoint = edges.contains { edge in
            labelsByID[edge.fromNodeId] != nil || labelsByID[edge.toNodeId] != nil
        }
        guard hasResolvableEndpoint else {
            return .endpointResolutionFailure(edgeCount: edges.count)
        }

        return .rows(edges.prefix(visibleEdgeLimit).map { edge in
            Row(
                id: edge.id,
                fromLabel: nodeSnippet(labelsByID[edge.fromNodeId]),
                toLabel: nodeSnippet(labelsByID[edge.toNodeId]),
                weight: edge.weight,
                reasons: edge.reasons)
        })
    }

    private static func normalizedSummary(_ summary: String) -> String? {
        let oneLine = summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? nil : oneLine
    }

    private static func nodeSnippet(_ summary: String?) -> String {
        guard let summary else { return "(forgotten)" }
        return summary.count > 44 ? String(summary.prefix(44)) + "…" : summary
    }
}

extension CognitionObservatoryView {

    @ViewBuilder
    func loopActivity(_ read: CognitiveReceiptRead) -> some View {
        switch CognitionLoopActivityPresentation.state(for: read) {
        case .unavailable(let detail):
            Label(detail, systemImage: "exclamationmark.triangle.fill")
                .font(NativeAgentFont.label)
                .foregroundStyle(.orange)
        case .empty:
            Text("No cognition loop receipts.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        case .receipts(let receipts):
            loopReceiptRows(receipts)
        }
    }

    @ViewBuilder
    private func loopReceiptRows(_ receipts: [CognitiveReceiptRecord]) -> some View {
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
        let presentation = CognitiveAssociationGraphPresentation.state(edges: edges, nodes: nodes)
        return VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            switch presentation {
            case .empty:
                Text("No association edges.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            case .endpointResolutionFailure(let edgeCount):
                Label("Association endpoints unavailable", systemImage: "exclamationmark.triangle")
                    .font(NativeAgentFont.label.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Couldn't resolve either endpoint for \(edgeCount) association \(edgeCount == 1 ? "edge" : "edges") from the current node snapshot.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .rows(let rows):
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(row.fromLabel) ↔ \(row.toLabel)")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(String(format: "%.2f", row.weight))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("why: \(row.reasons.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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

/// Presentation policy for the mounted Loop Activity panel.  An empty array
/// is a real, observable quiet loop only when its receipt read succeeded.
enum CognitionLoopActivityPresentation {
    enum State: Equatable, Sendable {
        case receipts([CognitiveReceiptRecord])
        case empty
        case unavailable(String)
    }

    static func state(for read: CognitiveReceiptRead) -> State {
        switch read {
        case .available(let receipts):
            return receipts.isEmpty ? .empty : .receipts(receipts)
        case .unavailable(let reason):
            return .unavailable(unavailabilityText(reason))
        }
    }

    static func receiptCount(for read: CognitiveReceiptRead) -> Int? {
        guard case .available(let receipts) = read else { return nil }
        return receipts.count
    }

    static func collapsedHint(for read: CognitiveReceiptRead) -> String? {
        switch state(for: read) {
        case .receipts(let receipts):
            guard let latest = receipts.first else { return nil }
            return "\(latest.kind) · \(latest.createdAt.formatted(date: .omitted, time: .shortened))"
        case .empty:
            return "quiet"
        case .unavailable(let detail):
            return detail
        }
    }

    private static func unavailabilityText(_ reason: CognitiveReceiptReadUnavailability) -> String {
        switch reason {
        case .cognitionDisabled:
            return "Loop activity is unavailable while cognition is off."
        case .persistenceDisabled:
            return "Loop activity is unavailable because receipt persistence is off."
        case .storeUnavailable:
            return "Loop activity is unavailable because the receipt store is unavailable."
        case .readFailed:
            return "Loop activity could not be read from the receipt store."
        }
    }
}
