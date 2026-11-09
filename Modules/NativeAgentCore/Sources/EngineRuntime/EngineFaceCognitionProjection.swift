import Cognition
import CognitiveSubstrate
import Foundation
import NativeAgentShared
import PersistenceCore
import Privacy
// Blueprint: | `EngineFaceCognitionProjection.swift` | Frozen Observatory detail becomes finished controls, sections, body signals and provenance rows |

public enum EngineFaceCognitionProjection {
    public static func face(_ detail: CognitiveObservatoryDetail) -> CognitionFace {
        do { return try reading(detail) }
        catch {
            return CognitionFace(sections: [], proposals: [], receipts: [], organism: [], capsule: [],
                state: .unavailable(EngineFaceMindProjection.failure("cognition_presentation_failed", error.localizedDescription)))
        }
    }

    private static func reading(_ detail: CognitiveObservatoryDetail) throws -> CognitionFace {
        let configuration = detail.configuration
        let summary = detail.summary
        let state = detail.substrate.persistenceHealth
        let overview = PartFace.Section(id: "overview", title: "Thinking", style: .values, rows: [
            value("enabled", "Inner life", configuration.enabled ? "On" : "Off"),
            value("nodes", "Nodes", String(summary.nodeCount)),
            value("workspace", "Workspace items", String(summary.workspaceCount)),
            value("episodes", "Episodes", String(summary.episodeCount)),
            value("reflections", "Reflections", String(summary.reflectionCount)),
            value("persistence", "Saved continuity", state.status.rawValue, detail: state.failureDetail),
            value("writes", "Continuity writes", configuration.persistenceEnabled ? (state.writesBlocked ? "Blocked" : "Available") : "Off",
                detail: state.failureStage)
        ])
        let workspace = PartFace.Section(id: "workspace", title: "Workspace", rows: detail.workspace.items.map { item in
            value(item.id.uuidString, item.node.summary, String(format: "%.2f", item.score),
                detail: ([item.node.kind.rawValue] + item.reasons).joined(separator: " · "))
        }, folded: true)
        let labels = detail.substrate.nodes.reduce(into: [UUID: String]()) { $0[$1.id] = $1.summary }
        let associations = PartFace.Section(id: "associations", title: "Associations", rows: detail.associations.map { edge in
            let from = labels[edge.fromNodeId].map(safe) ?? "Endpoint unavailable"
            let to = labels[edge.toNodeId].map(safe) ?? "Endpoint unavailable"
            return value(edge.id, from + " → " + to, String(format: "%.2f", edge.weight), detail: edge.reasons.joined(separator: " · "))
        }, folded: true)
        let affect = summary.affect
        let affectRows: [PartFace.Row]
        if !configuration.enabled { affectRows = [value("off", "Mood signals off", "My inner life is off.")] }
        else if !affect.observatoryValuesAreValid {
            affectRows = [value("invalid", "Affect unavailable", "The sample contains an invalid value and is withheld.")]
        } else {
            affectRows = [value("arousal", "Activation", String(format: "%.2f", affect.arousal)),
                value("uncertainty", "Uncertainty", String(format: "%.2f", affect.uncertainty)),
                value("pressure", "Task pressure", String(format: "%.2f", affect.taskPressure)),
                value("warmth", "Recent warmth", String(format: "%.2f", affect.socialWarmth),
                    detail: "Raw social warmth; an injected summary uses a separately remapped felt-warmth signal.")]
        }
        let feeling = PartFace.Section(id: "affect", title: "Affect", style: .values, rows: affectRows)
        let capacities = PartFace.Section(id: "capacities", title: "Capacity and pruning", style: .values, rows: [
            value("inhibited", "Inhibited workspace", String(detail.workspace.inhibitedNodeIds.count)),
            value("nodes", "Nodes", "\(summary.nodeCount) / \(configuration.maximumActiveNodes)"),
            value("workspace", "Workspace", "\(summary.workspaceCount) / \(configuration.maximumWorkspaceItems)")
        ])
        let timeline = PartFace.Section(id: "timeline", title: "Timeline", style: .timeline, rows: detail.developmentalTimeline.map { event in
            PartFace.Row(id: event.id.uuidString, title: safe(event.title), detail: safe(event.summary),
                value: event.kind.rawValue, at: ISO8601DateFormatter().string(from: event.occurredAt))
        }, folded: true)
        let reflections = PartFace.Section(id: "reflections", title: "Reflections", style: .timeline, rows: detail.reflections.map { reflection in
            PartFace.Row(id: reflection.id.uuidString, title: safe(reflection.resultSummary),
                detail: safe(reflection.request.reason),
                value: reflection.careIntegrationPending == true || reflection.dispositionSaveFailed || reflection.journalPending == true
                    ? "Settlement owed" : (reflection.cancelled ? "Cancelled" : "Recorded"),
                at: ISO8601DateFormatter().string(from: reflection.createdAt))
        }, folded: true)
        var sections = [PartFace(sections: [overview, workspace, associations, capacities, feeling, timeline, reflections])]
        let growth = detail.growthWeek.projection
        if growth.status == .ready, let face = growth.face { sections.append(try redacted(face)) }
        else {
            sections.append(PartFace(title: "Growth", sections: [PartFace.Section(id: "growth.unavailable", style: .note, rows: [
                value("unavailable", "Growth readout unavailable", growth.status.rawValue, detail: growth.error?.message)
            ])]))
        }
        let proposals = detail.schemaProposals.map { proposal in
            row(proposal.id.uuidString, proposal.title,
                [proposal.body, proposal.replacementDescription, proposal.target, String(format: "Confidence %.2f", proposal.confidence)]
                    .joined(separator: "\n"), state: proposal.status.rawValue, date: proposal.createdAt)
        }
        let receipts: [PartFace.Row]
        switch detail.receiptRead {
        case .available(let records):
            receipts = try records.map { row($0.id.uuidString, $0.kind, try text(NativeAppSecretRedactor.redactValue($0.payload)), date: $0.createdAt) }
        case .unavailable(let reason):
            receipts = [row("unavailable", "Records unavailable", reason.rawValue, state: "unavailable")]
        }
        let organism = bodyRows(detail.organism)
        var capsule: [PartFace.Row] = []
        if let preview = detail.capsulePreview {
            let source: String
            switch detail.capsulePreviewInfo?.source {
            case .liveInjected?: source = "Last injected summary"
            case .synthetic?: source = "Inspection preview"
            case nil: source = "Summary provenance unavailable"
            }
            capsule = [row("preview", source, preview.combined, state: preview.truncated ? "truncated" : nil, date: preview.generatedAt)]
            if let message = detail.capsulePreviewInfo?.userMessage { capsule.append(row("message", "For this message", message)) }
        }
        return CognitionFace(sections: sections, proposals: proposals,
            receipts: receipts, organism: organism, capsule: capsule, state: .ready)
    }

    private static func bodyRows(_ snapshot: OrganismSnapshot) -> [PartFace.Row] {
        guard snapshot.enabled else {
            return [row("off", "Body signals off", "Moods, energy, and a clock of my own are off in Settings; there is no live body readout.", state: "off")]
        }
        guard snapshot.observatorySampleIsCurrent(now: Date(), maximumSampleAge: 5 * 60) else {
            return [row("stale", "Body sample unavailable",
                "The sample is stale or has an invalid timestamp. Refresh before reading it.", state: "unavailable")]
        }
        guard snapshot.observatoryValuesAreValid else {
            return [row("invalid", "Body sample unavailable", "The sample contains an invalid value and is withheld.", state: "unavailable")]
        }
        var rows = [row("enabled", "Body signals", "On", date: snapshot.generatedAt),
            row("signals", "Signals", String(snapshot.signalCount), date: snapshot.lastSignalAt)]
        if let line = snapshot.projectedBodyLine { rows.append(row("line", "Body reading", line)) }
        let chemistry = snapshot.chemicalState
        rows += [decimal("Warmth", chemistry.warmth), decimal("Vigilance", chemistry.vigilance),
            decimal("Coherence", chemistry.coherence), decimal("Confidence", chemistry.confidence),
            decimal("Fatigue", chemistry.fatigue), decimal("Agency", chemistry.agency)]
        let field = snapshot.fieldSummary
        rows += [row("field.nodes", "Field nodes", String(field.nodeCount)), row("field.edges", "Field edges", String(field.edgeCount)),
            decimal("Strongest link", field.strongestEdgeWeight), decimal("Total charge", field.totalCharge),
            decimal("Field uncertainty", field.averageUncertainty)]
        let predictions = snapshot.predictionSummary
        rows += [row("predictions.pending", "Predictions pending", String(predictions.pendingCount)),
            row("predictions.errors", "Prediction errors", String(predictions.violatedCount)),
            row("predictions.expired", "Expired predictions", String(predictions.expiredCount)),
            decimal("Peripheral uncertainty", predictions.peripheralUncertainty), decimal("Strategy caution", predictions.strategyCaution),
            decimal("Tool confidence", predictions.bodyConfidence.toolPath), decimal("Provider confidence", predictions.bodyConfidence.providerPath),
            decimal("Phone confidence", predictions.bodyConfidence.phonePath)]
        if let belief = snapshot.bodySchema.providerPathBelief {
            rows += [row("provider.belief", "Provider belief", belief.state.rawValue), decimal("Provider belief estimate", belief.estimate),
                decimal("Provider belief uncertainty", belief.uncertainty), decimal("Provider evidence freshness", belief.freshness)]
        } else { rows.append(row("provider.absent", "Provider belief", "Absent")) }
        let repair = snapshot.dreamRepairSummary
        rows += [row("repair.receipts", "Dream repairs", String(repair.receiptCount)),
            row("repair.operations", "Last repair operations", String(repair.lastOperationCount)),
            row("repair.softened", "Softened nodes", String(repair.softenedNodes)),
            row("repair.warm", "Warm links", String(repair.strengthenedEdges)), row("repair.noisy", "Noisy links", String(repair.weakenedEdges)),
            row("repair.flags", "Flags", String(repair.flaggedContradictions)),
            decimal("Residual repair pressure", snapshot.residualRepairOpportunity.pressure),
            row("repair.evidence", "Residual evidence", String(snapshot.residualRepairOpportunity.evidenceCount)),
            row("repair.ready", "Residual repair ready", String(snapshot.residualRepairOpportunity.ready))]
        let body = snapshot.bodySchema
        rows += [row("body.mac", "Mac awake", String(body.macAwake)), row("body.phone", "iPhone reachable", String(body.iPhoneReachable)),
            row("body.providers", "Providers", body.providersHealthy ? "Healthy" : "Attention"),
            row("body.memory", "Memory", body.memoryHealthy ? "Healthy" : "Attention"),
            row("body.dreams", "Dreams", body.dreamHealthy ? "Healthy" : "Attention"),
            row("body.tools", "Tools", body.toolHandsAvailable ? "Available" : "Unavailable"),
            row("body.approvals", "Approvals", body.approvalChannelsOpen ? "Open" : "Closed"),
            row("body.notifications", "Notifications", body.notificationPathHealthy.map { $0 ? "Healthy" : "Attention" } ?? "Unknown"),
            row("body.pressure", "Resource pressure", body.resourcePressure.rawValue)]
        rows += snapshot.capabilityBeliefs.map { belief in
            row("capability." + belief.id, belief.kind.rawValue,
                "Success \(belief.successLikelihood) · uncertainty \(belief.uncertainty) · \(belief.evidenceCount) observations",
                state: belief.evidenceBasis.rawValue, date: belief.lastEvidenceAt)
        }
        return rows
    }

    private static func decimal(_ title: String, _ value: Double) -> PartFace.Row {
        row(title, title, String(format: "%.2f", value))
    }

    private static func text(_ value: JSONValue) throws -> String {
        if case .string(let words) = value { return words }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    private static func redacted(_ face: PartFace) throws -> PartFace {
        try NativeAppSecretRedactor.redactValue(JSONValue.fromEncodable(face)).decodedExactly(as: PartFace.self)
    }

    private static func value(_ id: String, _ title: String, _ value: String, detail: String? = nil) -> PartFace.Row {
        PartFace.Row(id: id, title: safe(title), detail: detail.map(safe), value: safe(value))
    }

    private static func safe(_ text: String) -> String { NativeAppSecretRedactor.redactText(text) }

    private static func row(_ id: String, _ title: String, _ detail: String?, state: String? = nil, date: Date? = nil) -> PartFace.Row {
        EngineFaceMindProjection.row(id, title, detail, state: state, date: date)
    }
}
