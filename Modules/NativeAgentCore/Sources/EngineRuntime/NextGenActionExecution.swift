import Foundation
import BackgroundLoops
import NativeAgentShared
import PersistenceCore
import Connectors
import MemoryV2
import ApprovalInbox
import TrustCenter
import Browser
import DoctorChecks

// The Capabilities panel's NextGen probes: each backed id has a read-only
// executor here, gated by approval and recorded as a receipt.
extension NativeAgentEngine {
    public nonisolated func nextGenActionReceipt(
        id: String,
        dryRun: Bool,
        surface: String = "nextgen_action",
        backgroundLoopsManager: BackgroundLoopsManager,
        healthCard: @Sendable () async throws -> HealthCard,
        routePlan: @Sendable (String) async throws -> JSONValue
    ) async throws -> NextGenReceipt {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentNextGen", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "NextGen action id is empty."
            ])
        }
        // Preview and execution must reject ids with no executor.
        guard Self.isNextGenActionBacked(trimmed) else {
            throw NSError(domain: "NativeAgentNextGen", code: 410, userInfo: [
                NSLocalizedDescriptionKey:
                    "NextGen action \(trimmed) has no Swift executor; nothing was run or recorded."
            ])
        }
        // 2026-09-06: admission, approval and evidence must share the selected root.
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

        func readOnlyOutput(id: String, resolved: ResolvedNextGenAction) async throws -> JSONValue {
            switch id {
            case "ops.health.snapshot":
                var output: [String: JSONValue] = [
                    "actionId": .string(id),
                    "health": try JSONValue.fromEncodable(
                        doctor.readHealth()
                    ),
                ]
                do {
                    var watchdog = await doctor.readWatchdog(manager: backgroundLoopsManager)
                    // The per-loop rows are not part of this snapshot; it has
                    // always carried the ten named watchdog fields only.
                    watchdog.extras = nil
                    output["watchdog"] = try? JSONValue.fromEncodable(watchdog)
                }
                if let card = try? await healthCard() {
                    output["healthCard"] = try? JSONValue.fromEncodable(card)
                }
                return .object(output)

            case "connector.oauth.check", "connector.keychain.oauth.preflight":
                let connectors = try await ConnectorStatusProjection.readConnectorRecords(
                    root: dataRoot, platform: ports.connectorStatus
                )
                let actions = await ConnectorActionRegistry.read(dataRoot: dataRoot, connectors: connectors)
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
                let root = dataRoot
                let tools = try await self.tools.listAuthored()
                let capabilities = try await TrustFacade(dataRoot: root, connectorActionStatuses: {
                    try await ConnectorActionRecord.checkedStatuses(root: root, platform: self.ports.connectorStatus)
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
                let plan = try await routePlan(message)
                return .object([
                    "actionId": .string(id),
                    "route": plan,
                ])

            case "memory.explain":
                let query = resolved.action?.displayDetail == nil ? "nativeagent memory" : resolved.action?.displayDetail ?? "nativeagent memory"
                let response = try await SwiftNativeMemoryV2.resolvedOwner(
                    dataRoot: dataRoot
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
                    "trustPolicy": try JSONValue.fromEncodable(try await trust.load()),
                ])

            case "personality.drift.audit":
                return .object([
                    "actionId": .string(id),
                    "growth": try JSONValue.fromEncodable(try await RuntimeReadProjection.swiftPersonalityGrowth(runtime: NativeAgentEngine.liveCognition)),
                ])

            case "release.gate":
                return .object([
                    "actionId": .string(id),
                    "releaseChecklist": try JSONValue.fromEncodable(try RuntimeReadProjection.readLocalJSON(
                        dataRoot.appendingPathComponent("release/checklist.json"), fallbackJSON: "{}"
                    ) as ReleaseChecklist),
                ])

            case "execution.durable.checkpoint":
                return .object([
                    "actionId": .string(id),
                    "missions": try JSONValue.fromEncodable(try await desk.taskRows()),
                ])

            case "trace.failure.rootcause", "traces.grade":
                return .object([
                    "actionId": .string(id),
                    "traces": try JSONValue.fromEncodable(Array((try await RuntimeReadProjection.getTraces(dataRoot: dataRoot)).prefix(25))),
                ])

            case "capability.marketplace.audit", "capability.signature.verify":
                let catalog = try await trust.catalog()
                return .object([
                    "actionId": .string(id),
                    "catalogCount": .int(Int64(catalog.count)),
                    "catalog": try JSONValue.fromEncodable(Array(catalog.prefix(50))),
                ])

            case "browser.capture", "browser.receipt.capture":
                let run = try await ports.browserRoutes.runBrowser(
                    url: "https://example.com", dryRun: true, captureSource: false, captureScreenshot: false,
                    dataRoot: dataRoot
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


        let output = try await readOnlyOutput(id: trimmed, resolved: resolved)
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
        let phases = try await NextGenStatusProjection(dataRoot: dataRoot).getNextGenPhases()
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

    /// The fixed executor set also bounds the panel's catalog-driven buttons.
    public nonisolated static let nextGenBackedActionIDs: Set<String> = [
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

    public nonisolated static func isNextGenActionBacked(_ id: String) -> Bool {
        nextGenBackedActionIDs.contains(id.trimmingCharacters(in: .whitespacesAndNewlines))
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
    ) async throws -> NextGenReceipt {
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
        return NextGenReceipt(
            receiptId: receiptId,
            actionId: actionId,
            phaseId: phaseId,
            name: name,
            status: status,
            dryRun: dryRun,
            approvalId: approvalId,
            detail: detail,
            output: output.nextGenDisplayString,
            createdAt: createdAt
        )
    }
}
