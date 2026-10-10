import Foundation
import BackgroundLoops
import NativeAgentShared
import PersistenceCore
import Connectors
import MemoryV2
import ApprovalInbox
import TrustCenter
import Browser
import SystemOps

// The Capabilities panel's NextGen probes: each backed id has a read-only
// executor here, gated by approval and recorded as a receipt.
extension AppModel {
    nonisolated func nextGenActionResponse(
        id: String,
        dryRun: Bool,
        surface: String = "nextgen_action"
    ) async throws -> NextGenActionResponse {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentNextGen", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "NextGen action id is empty."
            ])
        }
        // W6 fix-round (gpt-5.5 BLOCKING): an unbacked id previously sailed
        // into the dryRun branch and wrote a green "dry_run" receipt — a
        // success record for an action with no executor. Refuse EVERY entry
        // path for unbacked ids, not just the render filter.
        guard Self.isNextGenActionBacked(trimmed) else {
            throw NSError(domain: "NativeAgentNextGen", code: 410, userInfo: [
                NSLocalizedDescriptionKey:
                    "NextGen action \(trimmed) has no Swift executor; nothing was run or recorded."
            ])
        }
        // 2026-09-06: admission, approval and evidence must share the selected root.
        let dataRoot = engine.dataRoot
        let resolved = try await resolveNextGenAction(id: trimmed)
        let yoloAdmitted = !dryRun
            ? await ConnectorActions.fullMacYoloAdmitted(
                tool: "nextgen.action.\(trimmed)",
                surface: surface,
                dataRoot: dataRoot
            )
            : false
        if resolved.action?.requiresApproval == true, !dryRun, !yoloAdmitted {
            let approval = try await Self.createNextGenActionApproval(id: trimmed, resolved: resolved, dataRoot: dataRoot)
            return try await Self.appendNextGenActionReceipt(
                actionId: trimmed,
                phaseId: resolved.phase?.id ?? resolved.action?.phaseId,
                name: resolved.action?.displayName,
                status: "pending_approval",
                dryRun: false,
                approvalId: approval.id,
                detail: "NextGen action requires approval before execution.",
                output: .object([
                    "actionId": .string(trimmed),
                    "status": .string("pending_approval"),
                    "approvalId": .string(approval.id),
                ]),
                dataRoot: dataRoot
            )
        }

        if dryRun {
            return try await Self.appendNextGenActionReceipt(
                actionId: trimmed,
                phaseId: resolved.phase?.id ?? resolved.action?.phaseId,
                name: resolved.action?.displayName,
                status: "dry_run",
                dryRun: true,
                approvalId: nil,
                detail: resolved.action?.displayDetail,
                output: .object([
                    "actionId": .string(trimmed),
                    "status": .string("dry_run"),
                    "matchedPhase": resolved.phase.map { .string($0.id) } ?? .null,
                    "matchedAction": .bool(resolved.action != nil),
                ]),
                dataRoot: dataRoot
            )
        }

        let output = try await nextGenReadOnlyActionOutput(id: trimmed, resolved: resolved)
        return try await Self.appendNextGenActionReceipt(
            actionId: trimmed,
            phaseId: resolved.phase?.id ?? resolved.action?.phaseId,
            name: resolved.action?.displayName,
            status: "completed",
            dryRun: false,
            approvalId: nil,
            detail: resolved.action?.displayDetail,
            output: output,
            dataRoot: dataRoot
        )
    }

    private struct ResolvedNextGenAction {
        var action: NextGenAction?
        var phase: NextGenPhase?
    }

    private nonisolated func resolveNextGenAction(id: String) async throws -> ResolvedNextGenAction {
        let phases = try await NextGenStatusProjection(dataRoot: engine.dataRoot).getNextGenPhases()
        for phase in phases {
            if let action = phase.actions?.first(where: { $0.id == id }) {
                return ResolvedNextGenAction(action: action, phase: phase)
            }
            if phase.primaryDryRunActionId == id {
                return ResolvedNextGenAction(action: nil, phase: phase)
            }
        }
        return ResolvedNextGenAction(action: nil, phase: nil)
    }

    /// The exact id set `nextGenReadOnlyActionOutput(id:resolved:)` has a case
    /// for. L3#6 (2026-08-11): `nextgen_phases.json` is a data file, so the
    /// catalog's action list is unbounded while this executor is fixed — every
    /// id outside this set falls through to the `default:` 410 below. The
    /// rendered button set is intersected with this at the UI layer
    /// (`CapabilitiesView.nextGenActions` / `NextGenPhaseRow`) so the panel
    /// cannot offer a probe there is no executor for.
    ///
    /// Any new `case` in the switch MUST be added here — `nextGenBackedIDsCoverSwitch`
    /// in `tests/NativeAgentAppTests/NextGenBackedActionFilterTests.swift` pins
    /// the pairing.
    nonisolated static let nextGenBackedActionIDs: Set<String> = [
        "ops.health.snapshot",
        "connector.oauth.check", "connector.keychain.oauth.preflight",
        "tool.lazy.index",
        "planner.decompose", "context.route.preview", "capability.graph.route",
        "memory.explain",
        "truth.audit", "privacy.trust.audit", "mac.control.policy.audit",
        "personality.drift.audit",
        "release.gate",
        "execution.durable.checkpoint",
        "trace.failure.rootcause", "traces.grade",
        "capability.marketplace.audit", "capability.signature.verify",
        "browser.capture", "browser.receipt.capture",
    ]

    nonisolated static func isNextGenActionBacked(_ id: String) -> Bool {
        nextGenBackedActionIDs.contains(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private nonisolated func nextGenReadOnlyActionOutput(id: String, resolved: ResolvedNextGenAction) async throws -> JSONValue {
        switch id {
        case "ops.health.snapshot":
            var output: [String: JSONValue] = [
                "actionId": .string(id),
                "health": try JSONValue.fromEncodable(
                    engine.doctor.readHealth()
                ),
            ]
            do {
                var watchdog = await engine.doctor.readWatchdog(manager: backgroundLoopsManager.coreManager)
                // The per-loop rows are not part of this snapshot; it has
                // always carried the ten named watchdog fields only.
                watchdog.extras = nil
                output["watchdog"] = try? JSONValue.fromEncodable(watchdog)
            }
            if let card = try? await AppDoctorPort(
                dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager
            ).getHealthCard() {
                output["healthCard"] = try? JSONValue.fromEncodable(card)
            }
            return .object(output)

        case "connector.oauth.check", "connector.keychain.oauth.preflight":
            let connectors = try await ConnectorStatusProjection.readConnectorRecords(
                root: engine.dataRoot, platform: AppConnectorStatusPlatform()
            )
            let actions = try await ConnectorActionRegistry.read(dataRoot: engine.dataRoot)
            return .object([
                "actionId": .string(id),
                "connectors": try JSONValue.fromEncodable(connectors),
                "actionSummary": .object([
                    "status": .string(actions.status),
                    "actionCount": .int(Int64(actions.actions.count)),
                    "receiptCount": .int(Int64(actions.receiptCount ?? 0)),
                ]),
                "latestReceipt": actions.latestReceipt.map { (try? JSONValue.fromEncodable($0)) ?? .null } ?? .null,
            ])

        case "tool.lazy.index":
            let root = engine.dataRoot
            let tools = try await ToolsFacade(dataRoot: root).listAuthored()
            let capabilities = try await TrustFacade(dataRoot: root, connectorActionStatuses: {
                try await ConnectorActionRecord.checkedStatuses(root: root)
            }).loadCapabilities()
            return .object([
                "actionId": .string(id),
                "toolCount": .int(Int64(tools.count)),
                "tools": .array(tools.prefix(50).map { tool in
                    .object([
                        "id": .string(tool.id),
                        "name": .string(tool.name),
                        "status": .string(tool.status),
                        "language": tool.language.map(JSONValue.string) ?? .null,
                    ])
                }),
                "capabilities": try JSONValue.fromEncodable(capabilities.summary),
            ])

        case "planner.decompose", "context.route.preview", "capability.graph.route":
            let message = resolved.action?.displayDetail ?? "NextGen action \(id)"
            let plan = try IntentRoutePlan(await makeRouterPlanClient().planRoute(message: message))
            return .object([
                "actionId": .string(id),
                "route": try JSONValue.fromEncodable(plan),
            ])

        case "memory.explain":
            let query = resolved.action?.displayDetail == nil ? "nativeagent memory" : resolved.action?.displayDetail ?? "nativeagent memory"
            let response = try await SwiftNativeMemoryV2.resolvedOwner(
                dataRoot: engine.dataRoot
            ).recall(
                MemoryV2RecallRequest(text: query, topK: 5, persona: nil)
            )
            return .object([
                "actionId": .string(id),
                "query": .string(query),
                "total": .int(Int64(response.total)),
                "hits": try JSONValue.fromEncodable(response.hits),
            ])

        case "truth.audit", "privacy.trust.audit", "mac.control.policy.audit":
            return .object([
                "actionId": .string(id),
                "trustPolicy": try JSONValue.fromEncodable(try await engine.trust.load()),
            ])

        case "personality.drift.audit":
            return .object([
                "actionId": .string(id),
                "growth": try JSONValue.fromEncodable(try await AppModel.readPersonalityGrowth()),
            ])

        case "release.gate":
            return .object([
                "actionId": .string(id),
                "releaseChecklist": try JSONValue.fromEncodable(try await AppModel.readReleaseChecklist(dataRoot: engine.dataRoot)),
            ])

        case "execution.durable.checkpoint":
            return .object([
                "actionId": .string(id),
                "missions": try JSONValue.fromEncodable(try await engine.desk.taskRows()),
            ])

        case "trace.failure.rootcause", "traces.grade":
            return .object([
                "actionId": .string(id),
                "traces": try JSONValue.fromEncodable(Array((try await RuntimeReadProjection.getTraces(dataRoot: engine.dataRoot)).prefix(25))),
            ])

        case "capability.marketplace.audit", "capability.signature.verify":
            let catalog = try await engine.trust.catalog()
            return .object([
                "actionId": .string(id),
                "catalogCount": .int(Int64(catalog.count)),
                "catalog": try JSONValue.fromEncodable(Array(catalog.prefix(50))),
            ])

        case "browser.capture", "browser.receipt.capture":
            let run = try await BrowserActionRoutes.app.runBrowser(
                url: "https://example.com", dryRun: true, captureSource: false, captureScreenshot: false,
                dataRoot: engine.dataRoot
            )
            return .object([
                "actionId": .string(id),
                "browserRun": try JSONValue.fromEncodable(run),
            ])

        default:
            throw NSError(domain: "NativeAgentNextGen", code: 410, userInfo: [
                NSLocalizedDescriptionKey: "NextGen action \(id) is not backed by a Swift read-only executor yet."
            ])
        }
    }

    private nonisolated static func createNextGenActionApproval(id: String, resolved: ResolvedNextGenAction, dataRoot: URL) async throws -> ApprovalRecord {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let displayName = resolved.action?.displayName ?? id
        let risk = resolved.action?.risk ?? "medium"
        let phaseId = resolved.phase.map { JSONValue.string($0.id) } ?? .null
        let name = resolved.action.map { JSONValue.string($0.displayName) } ?? .null
        return try await inbox.create(.object([
            "title": .string("Approve NextGen action \(displayName)"),
            "action": .string("nextgen.action.\(id)"),
            "risk": .string(risk),
            "reason": .string("NextGen action \(id) requires approval before execution."),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
            "payload": .object([
                "surface": .string("nextgen_action"),
                "actionId": .string(id),
                "phaseId": phaseId,
                "name": name,
            ]),
        ]))
    }

    private nonisolated static func appendNextGenActionReceipt(
        actionId: String,
        phaseId: String?,
        name: String?,
        status: String,
        dryRun: Bool,
        approvalId: String?,
        detail: String?,
        output: JSONValue,
        dataRoot: URL
    ) async throws -> NextGenActionResponse {
        let receiptId = UUID().uuidString.lowercased()
        let createdAt = SwiftNativeManifestSigner.isoTimestamp(Date())
        let receipt: JSONValue = .object([
            "id": .string(receiptId),
            "receiptId": .string(receiptId),
            "actionId": .string(actionId),
            "phaseId": phaseId.map(JSONValue.string) ?? .null,
            "name": name.map(JSONValue.string) ?? .null,
            "status": .string(status),
            "dryRun": .bool(dryRun),
            "approvalId": approvalId.map(JSONValue.string) ?? .null,
            "detail": detail.map(JSONValue.string) ?? .null,
            "output": output,
            "createdAt": .string(createdAt),
        ])
        let path = dataRoot
            .appendingPathComponent("nextgen", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            try await persistence.appendJSONL(receipt, to: path)
        }
        let response: JSONValue = .object([
            "id": .string(receiptId),
            "responseId": .string(receiptId),
            "actionId": .string(actionId),
            "phaseId": phaseId.map(JSONValue.string) ?? .null,
            "name": name.map(JSONValue.string) ?? .null,
            "status": .string(status),
            "dryRun": .bool(dryRun),
            "detail": detail.map(JSONValue.string) ?? .null,
            "output": output,
            "receipt": receipt,
            "createdAt": .string(createdAt),
        ])
        let data = try response.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(NextGenActionResponse.self, from: data)
    }
}
