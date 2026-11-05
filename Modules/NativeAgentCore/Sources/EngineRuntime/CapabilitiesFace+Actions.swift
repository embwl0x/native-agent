import AppToolRuntime
import AuthoredCapabilities
import Foundation
import NativeAgentCore
import NativeAgentShared
import ToolRegistry
import TrustCenter
// Blueprint: | `CapabilitiesFace+Actions.swift` | Cached Mac, connector and check rows; every face action returns to its native owner |

@MainActor
extension CapabilitiesFace {
    static func answer(_ engine: NativeAgentEngine) -> PartFaces.ActBy {
        { [weak engine] row, action, value, by in
            guard let engine else { throw PartCallError(code: "unavailable", message: "The Capabilities owner has closed.") }
            // The person's click runs a Mac action as the person's own; the agent runs one through the agent's own verb and Trust posture.
            if case .agent = by, !["native.dry_run", "connector.dry_run", "capability.check_trust"].contains(action) {
                throw PartCallError(code: "person_only", message: "Running this from the page belongs to the person; in your turn, use your own tools for it.")
            }
            return try await act(engine, row, action, value)
        }
    }

    static func actionSections(_ engine: NativeAgentEngine) -> [PartFace.Section] {
        let tools = engine.tools
        let fullMac = engine.trust.policy.map { TrustAccessModeCapabilityCatalog.fullMacGrantIsActive($0) } == true
        let nativeRows = tools.nativeActions.map { action in
            let receipt = tools.nativeActionReceipts.last { $0.actionId == action.id }
            var details = [action.kind, nativeGate(action, fullMac: fullMac), receipt?.detail].compactMap { $0 }
            if action.dryRunAvailable == false { details.append("Dry run is unavailable for this action.") }
            return PartFace.Row(id: action.id, title: action.name, detail: details.joined(separator: " "),
                value: [action.risk, receipt?.status].compactMap { $0 }.joined(separator: " · "), at: receipt?.createdAt,
                tone: receipt.map { tone($0.status) }, actions: [
                    .init(id: "native.dry_run", label: "Dry run"), .init(id: runActionID(action), label: "Run"),
                ])
        }
        var connectorRows: [PartFace.Row] = []
        if let failure = engine.connectors.actionsReadError {
            connectorRows.append(.init(id: "connector-read", title: "Connector actions could not be read", detail: failure, tone: .failed))
        }
        if let registry = engine.connectors.actions {
            connectorRows += registry.actions.map { action in
                .init(id: action.id, title: action.name,
                    detail: [action.connectorId, action.authState, action.dryRunAvailable == false ? "Dry run is unavailable." : nil]
                        .compactMap { $0 }.joined(separator: " · "),
                    value: action.connectorStatus ?? "Status unavailable", tone: tone(action.connectorStatus),
                    actions: [.init(id: "connector.dry_run", label: "Dry run")])
            }
            if registry.actions.isEmpty { connectorRows.append(.init(id: "connector-empty", title: "No registered connector actions")) }
            if let receipt = registry.latestReceipt {
                connectorRows.append(.init(id: "connector-receipt", title: "Latest connector action", detail: receipt.actionId,
                    value: receipt.status, at: receipt.createdAt, tone: tone(receipt.status)))
            }
        }
        let nativeReadFailure = tools.nativePowerRefresh.flatMap { receipt in
            receipt.isStale ? "Some action receipts or browser status could not be read: " + receipt.failedEndpoints.joined(separator: ", ") : nil
        }
        return [
            .init(id: "mac-actions", title: "Mac actions", footer: nativeReadFailure, rows: nativeRows),
            .init(id: "connector-actions", title: "Connector actions",
                style: engine.connectors.actions == nil && engine.connectors.actionsReadError == nil ? .waiting : .list, rows: connectorRows),
            checks(engine),
        ]
    }

    private static func checks(_ engine: NativeAgentEngine) -> PartFace.Section {
        let doctor = engine.doctor, tools = engine.tools
        let gauntlet = doctor.latestImprovementGauntletRun
        let checks = gauntlet?.checks
        let checkDetail = checks.map { checks in
            if checks.isEmpty { return "No checks recorded" }
            let failures = checks.filter { !$0.passed }.map(\.title)
            return failures.isEmpty ? "All recorded checks passed" : failures.joined(separator: ", ")
        }
        let unread = doctor.hardeningRefresh == nil
        let missingGauntlet = unread || doctor.hardeningRefresh?.failedEndpoints.contains("improvement gauntlet") == true
        let missingExports = unread || doctor.hardeningRefresh?.failedEndpoints.contains("production exports") == true
        let browser = tools.browserDryRunPreview
        var rows: [PartFace.Row] = [
            .init(id: "improvement", title: "Improvement checks",
                detail: doctor.improvementRunError ?? checkDetail,
                value: doctor.improvementRunStartedAt != nil ? "Running" : doctor.improvementRunError != nil ? "Failed"
                    : gauntlet?.status ?? (missingGauntlet ? "Not read" : "No recorded run"),
                at: stamp(doctor.improvementRunStartedAt) ?? (doctor.improvementRunError == nil ? gauntlet?.createdAt : nil),
                tone: doctor.improvementRunStartedAt != nil ? .live : doctor.improvementRunError == nil ? tone(gauntlet?.status) : .failed,
                actions: [.init(id: "improvement.run", label: "Run")]),
            .init(id: "browser-preview", title: "Browser dry run", detail: tools.browserDryRunError ?? browser?.url,
                value: tools.browserDryRunStartedAt != nil ? "Running" : tools.browserDryRunError != nil ? "Failed"
                    : browser?.status ?? "No preview in this session",
                at: stamp(tools.browserDryRunStartedAt) ?? (tools.browserDryRunError == nil ? browser?.createdAt : nil),
                tone: tools.browserDryRunStartedAt != nil ? .live : tools.browserDryRunError == nil ? tone(browser?.status) : .failed,
                actions: [.init(id: "browser.open", label: "Run")]),
        ]
        for run in tools.browserStatus?.activeRuns ?? [] {
            rows.append(.init(id: run.id, title: "Browser run", detail: run.url, value: run.status, at: run.createdAt,
                tone: .live, actions: [.init(id: "browser.cancel", label: "Cancel")]))
        }
        if let receipt = tools.browserStatus?.latestReceipt {
            rows.append(.init(id: "browser-receipt", title: "Latest browser run", detail: receipt.url,
                value: receipt.status, at: receipt.createdAt, tone: tone(receipt.status)))
        }
        for (id, title) in [("export", "Export"), ("support", "Support bundle")] {
            let latest = doctor.productionExports.first { $0.kind == id }
            let work = doctor.productionExportWork.flatMap { $0.support == (id == "support") ? $0.startedAt : nil }
            let failure = doctor.productionExportFailure.flatMap { $0.support == (id == "support") ? $0.detail : nil }
            rows.append(.init(id: id, title: title, detail: failure ?? latest?.path,
                value: work != nil ? "Creating" : failure != nil ? "Failed"
                    : latest.map { $0.sizeBytes.map { "\($0) bytes" } ?? "Size unavailable" }
                        ?? (missingExports ? "Not read" : "No recorded export"),
                at: stamp(work) ?? (failure == nil ? latest?.createdAt : nil),
                tone: work != nil ? .live : failure == nil ? .quiet : .failed,
                actions: [.init(id: "export.bundle", label: title)]))
        }
        if let hardening = doctor.productionHardening {
            rows.append(.init(id: "hardening", title: "Release checks", detail: hardening.detail,
                value: hardening.status, at: hardening.createdAt, tone: tone(hardening.status)))
            rows += (hardening.release?.items ?? []).map {
                .init(id: "release:" + $0.id, title: $0.title, detail: $0.detail, value: $0.status, tone: tone($0.status))
            }
        }
        if let receipt = doctor.hardeningRefresh, receipt.isStale {
            rows.append(.init(id: "checks-read", title: "Checks read incomplete",
                detail: receipt.failedEndpoints.joined(separator: ", "), tone: .failed))
        } else if doctor.hardeningRefresh == nil {
            rows.append(.init(id: "checks-unread", title: "Recorded checks and exports have not been read", tone: .quiet))
        }
        return .init(id: "checks", title: "Checks", rows: rows)
    }

    private static func stamp(_ date: Date?) -> String? { date.map { ISO8601DateFormatter().string(from: $0) } }

    static func runActionID(_ action: NativeActionRecord) -> String { ToolNameAliases.appAction(action.id) ?? "native.run" }

    static func nativeGate(_ action: NativeActionRecord, fullMac: Bool) -> String? {
        action.requiresApproval != false && !fullMac ? "Approval is required before this action can run. Use Trust to review its access." : nil
    }

    static func act(_ engine: NativeAgentEngine, _ row: String, _ action: String, _ value: String?) async throws -> String? {
        switch action {
        case "capability.check_trust":
            guard engine.trust.capabilitySummaryError == nil,
                  engine.trust.capabilitySummary?.records.contains(where: { $0.id == row }) == true else { throw stale() }
            let result = try await engine.trust.checkCapabilityTrust(id: row)
            return "\(result.name ?? result.id): \(result.trustTier). " + result.reasons.joined(separator: " ")
        case "connector.dry_run":
            guard let record = engine.connectors.actions?.actions.first(where: { $0.id == row }) else { throw stale() }
            guard record.dryRunAvailable != false else {
                throw PartCallError(code: "dry_run_unavailable", message: "Dry run is unavailable for this connector action.")
            }
            let receipt = try await engine.runConnectorAction(id: row, dryRun: true,
                origin: "mac_ui:connector_action:" + row, platform: engine.ports.connectorActions(engine))
            _ = try await engine.connectors.refreshActions()
            return "\(record.name): \(receipt.status)."
        case "improvement.run" where row == "improvement":
            let run = try await engine.doctor.runImprovementChecks()
            return "Improvement checks: \(run.status)."
        case "browser.open" where row == "browser-preview":
            let run = try await engine.tools.previewBrowser(using: engine.ports.browserRoutes)
            return "Browser dry run: \(run.status) · \(run.url ?? "URL unavailable")."
        case "browser.cancel":
            guard engine.tools.browserStatus?.activeRuns?.contains(where: { $0.id == row }) == true else { throw stale() }
            let run = try await engine.ports.browserRoutes.cancelBrowserRun(id: row, dataRoot: engine.dataRoot)
            _ = await engine.tools.refreshNativePower()
            return "Browser run: \(run.status)."
        case "export.bundle" where row == "export" || row == "support":
            let export = try await engine.doctor.createProductionExport(support: row == "support")
            return "Created and verified: \(export.path)."
        default:
            guard let record = engine.tools.nativeActions.first(where: { $0.id == row }),
                  action == "native.dry_run" || action == runActionID(record) else { throw stale() }
            let receipt = try await engine.tools.runNativeAction(record, dryRun: action == "native.dry_run",
                trust: engine.trust, browser: engine.ports.browserRoutes)
            return "\(record.name): \(receipt.status)" + (receipt.detail.map { ": " + $0 } ?? ".")
        }
    }

    private static func stale() -> PartCallError {
        .init(code: "stale_action", message: "This capability action is no longer available. Read Capabilities again before acting.")
    }
}
