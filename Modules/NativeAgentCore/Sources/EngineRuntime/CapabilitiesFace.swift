import Foundation
import AuthoredCapabilities
import NativeAgentShared
import TrustCenter
// Blueprint: | `CapabilitiesFace.swift` | Capabilities reads cached inventory, workflows, catalog and guardrails into one face for every door |

@MainActor
enum CapabilitiesFace {
    static func reader(_ engine: NativeAgentEngine) -> PartFaces.Read {
        let changed: @MainActor @Sendable () async -> Void = { [weak pages = engine.pages] in
            _ = await pages?.refresh(page: "capabilities")
        }
        engine.trust.capabilitiesDidChange = changed
        engine.desk.capabilitiesDidChange = changed
        engine.tools.capabilitiesDidChange = changed
        engine.doctor.capabilitiesDidChange = changed
        engine.connectors.capabilitiesDidChange = changed
        return { [weak engine] in
            guard let engine else { throw PartCallError(code: "unavailable", message: "The Capabilities owner has closed.") }
            return read(engine)
        }
    }

    static func read(_ engine: NativeAgentEngine) -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let trust = engine.trust
        var sections: [PartFace.Section] = []
        if let failure = trust.capabilitySummaryError {
            sections.append(issue("inventory-read", "What I can do", failure))
        } else if trust.capabilitySummary == nil {
            sections.append(.init(id: "inventory-wait", title: "Reading what I can do", style: .waiting, rows: []))
        }
        if let summary = trust.capabilitySummary {
            let records = CapabilityRecord.displayRecords(summary.records)
            let review = records.filter { TrustFacade.capabilityNeedsReview($0.status) }
            if !review.isEmpty {
                sections.append(.init(id: "review", title: "Waiting for your review",
                    footer: trust.capabilitySummaryError == nil ? nil : "Review state is from the last successful read.", rows: review.map {
                    capabilityRow($0, tone: .attention)
                }))
            }
            sections.append(.init(id: "inventory", title: "What I can do",
                footer: trust.capabilitySummaryError == nil ? nil : "These are the last read capabilities; the read above failed.",
                rows: records.isEmpty ? [.init(id: "inventory-empty", title: "No capabilities in the read inventory", tone: .quiet)]
                    : records.map { capabilityRow($0) }))
        }
        sections.append(workflows(engine.desk))
        sections.append(catalog(trust))
        if let kernel = trust.autonomyKernel {
            let summary: [PartFace.Row] = [
                .init(id: "autonomy", title: "Autonomy", detail: kernel.disabledReason, value: kernel.status, tone: tone(kernel.status)),
                .init(id: "autonomy-mode", title: "Mode", value: kernel.mode ?? "Mode unavailable"),
            ]
            sections.append(.init(id: "guardrails", title: "Guardrails", style: .values, rows: summary + kernel.guardrails.map {
                .init(id: $0.id, title: $0.title, value: $0.status, tone: tone($0.status))
            }))
        } else if let failure = trust.policyReadError ?? trust.securityRefreshError {
            sections.append(issue("guardrails", "Guardrails", failure))
        } else {
            sections.append(.init(id: "guardrails", title: "Guardrails", style: .waiting,
                rows: [.init(id: "guardrails-unread", title: "Trust policy has not been read")]))
        }
        sections += actionSections(engine)
        return (.init(title: "Capabilities", line: line(trust, desk: engine.desk), sections: sections), epoch)
    }

    private static func line(_ trust: TrustFacade, desk: DeskFacade) -> String? {
        guard trust.capabilitySummaryError == nil, let counts = trust.capabilitySummary?.summary else { return nil }
        let ready = counts.active == counts.total ? "all ready to use" : "\(counts.active) ready to use"
        var line = "I have \(counts.total) \(counts.total == 1 ? "capability" : "capabilities")"
        if counts.total > 0 { line += ", " + ready }
        if desk.hasLoadedWorkflows, desk.workflowsReadError == nil, !desk.workflows.isEmpty {
            line += ", and \(desk.workflows.count) saved \(desk.workflows.count == 1 ? "workflow" : "workflows")"
        }
        return line + "."
    }

    private static func capabilityRow(_ record: CapabilityRecord, tone forced: PartFace.Tone? = nil) -> PartFace.Row {
        .init(id: record.id, title: CapabilityRecord.title(for: record), detail: CapabilityRecord.description(for: record),
            value: "\(record.kind ?? "Kind unavailable") · \(record.riskClass ?? "Risk unavailable") · \(record.status ?? "Status unavailable")",
            tone: forced ?? tone(record.status))
    }

    private static func workflows(_ desk: DeskFacade) -> PartFace.Section {
        var rows = desk.workflows.map { workflow in
            PartFace.Row(id: workflow.id, title: workflow.name, detail: workflow.description,
                value: "\(workflow.steps.count) steps · \(workflow.status ?? "Status unavailable")"
                    + (workflow.trigger.map { " · " + $0 } ?? ""), tone: tone(workflow.status))
        }
        if let failure = desk.workflowsReadError {
            rows.insert(.init(id: "workflows-read", title: "Workflows could not be read", detail: failure, tone: .failed), at: 0)
        } else if !desk.hasLoadedWorkflows {
            return .init(id: "workflows", title: "Workflows", style: .waiting, rows: [])
        } else if rows.isEmpty { rows.append(.init(id: "workflows-empty", title: "No saved workflows", tone: .quiet)) }
        return .init(id: "workflows", title: "Workflows",
            footer: desk.workflowsReadError == nil ? nil : "Any saved rows below are from the last successful read.", rows: rows)
    }

    private static func catalog(_ trust: TrustFacade) -> PartFace.Section {
        let sourceFailure = trust.catalogRefresh?.failedEndpoints.contains("catalog sources") == true
        let networkFailure = trust.catalogRefresh?.failedEndpoints.contains("capability trust") == true
        let sources = trust.catalogRefresh == nil || sourceFailure ? "Unavailable" : String(trust.capabilityCatalogSources.count)
        let trusted = networkFailure ? nil : trust.capabilityNetwork?.summary.map { String($0.trusted) }
        let evaluation = trust.latestCapabilityTrustEvaluation
        var rows: [PartFace.Row] = [
            .init(id: "catalog-sources", title: "Sources", value: sources, tone: sourceFailure ? .failed : .plain),
            .init(id: "catalog-trusted", title: "Trusted", value: trusted ?? "Not read", tone: networkFailure ? .failed : .plain),
        ]
        if let subject = trust.capabilitySummary?.records.first, trust.capabilitySummaryError == nil {
            rows.append(.init(id: subject.id, title: "Latest check", detail: evaluation.map {
                "\($0.name ?? $0.id): " + $0.reasons.joined(separator: " ")
            }, value: evaluation?.trustTier ?? "No check in this session", at: evaluation?.createdAt,
                actions: [.init(id: "capability.check_trust", label: "Check trust")]))
        } else {
            rows.append(.init(id: "catalog-check-unread", title: "Latest check", value: "Read the capabilities before checking trust"))
        }
        if let receipt = trust.catalogRefresh, receipt.isStale {
            rows.append(.init(id: "catalog-read", title: "Catalog read incomplete",
                detail: receipt.failedEndpoints.joined(separator: ", "), tone: .failed))
        }
        return .init(id: "catalog", title: "Catalog", style: .values, rows: rows)
    }

    static func issue(_ id: String, _ title: String, _ detail: String) -> PartFace.Section {
        .init(id: id, title: title, rows: [.init(id: id, title: "Could not read this", detail: detail, tone: .failed)])
    }

    static func tone(_ status: String?) -> PartFace.Tone {
        guard let status else { return .quiet }
        switch status.lowercased() {
        case "active", "installed", "ready", "configured", "ok", "passed", "succeeded", "completed", "trusted": return .done
        case "running": return .live
        case "failed", "error", "blocked": return .failed
        case "review", "proposal", "draft", "drafted", "needs_setup", "pending_approval", "untrusted", "unavailable": return .attention
        default: return .quiet
        }
    }
}
