import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

extension NativeClient {
    func runNextGenAction(id: String, dryRun: Bool) async throws -> NextGenActionResponse {
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
        let resolved = try await resolveNextGenAction(id: trimmed)
        if resolved.action?.requiresApproval == true, !dryRun {
            let approval = try await Self.createNextGenActionApproval(id: trimmed, resolved: resolved)
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
                ])
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
                ])
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
            output: output
        )
    }

    struct ResolvedNextGenAction {
        var action: NextGenAction?
        var phase: NextGenPhase?
    }

    func resolveNextGenAction(id: String) async throws -> ResolvedNextGenAction {
        let phases = try await getNextGenPhases()
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
    static let nextGenBackedActionIDs: Set<String> = [
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

    static func isNextGenActionBacked(_ id: String) -> Bool {
        nextGenBackedActionIDs.contains(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func nextGenReadOnlyActionOutput(id: String, resolved: ResolvedNextGenAction) async throws -> JSONValue {
        switch id {
        case "ops.health.snapshot":
            var output: [String: JSONValue] = [
                "actionId": .string(id),
                "health": try Self.codableJSON(try await getHealth()),
            ]
            if let watchdog = try? await getWatchdog() {
                output["watchdog"] = try? Self.codableJSON(watchdog)
            }
            if let card = try? await getHealthCard() {
                output["healthCard"] = try? Self.codableJSON(card)
            }
            return .object(output)

        case "connector.oauth.check", "connector.keychain.oauth.preflight":
            let connectors = try await getConnectors()
            let actions = try await getConnectorActions()
            return .object([
                "actionId": .string(id),
                "connectors": try Self.codableJSON(connectors),
                "actionSummary": .object([
                    "status": .string(actions.status),
                    "actionCount": .int(Int64(actions.actions.count)),
                    "receiptCount": .int(Int64(actions.receiptCount ?? 0)),
                ]),
                "latestReceipt": actions.latestReceipt.map { (try? Self.codableJSON($0)) ?? .null } ?? .null,
            ])

        case "tool.lazy.index":
            let tools = try await getTools()
            let capabilities = try await getCapabilities()
            return .object([
                "actionId": .string(id),
                "toolCount": .int(Int64(tools.count)),
                "tools": .array(tools.prefix(50).map { tool in
                    .object([
                        "id": .string(tool.id),
                        "name": .string(tool.name),
                        "status": .string(tool.status ?? tool.phase ?? "unknown"),
                        "language": tool.language.map(JSONValue.string) ?? .null,
                    ])
                }),
                "capabilities": try Self.codableJSON(capabilities.summary),
            ])

        case "planner.decompose", "context.route.preview", "capability.graph.route":
            let message = resolved.action?.displayDetail ?? "NextGen action \(id)"
            let plan = try await planRoute(message: message)
            return .object([
                "actionId": .string(id),
                "route": try Self.codableJSON(plan),
            ])

        case "memory.explain":
            let query = resolved.action?.displayDetail == nil ? "nativeagent memory" : resolved.action?.displayDetail ?? "nativeagent memory"
            let response = try await SwiftNativeMemoryV2.shared.recall(
                MemoryV2RecallRequest(text: query, topK: 5, persona: nil)
            )
            return .object([
                "actionId": .string(id),
                "query": .string(query),
                "total": .int(Int64(response.total)),
                "hits": try Self.codableJSON(response.hits),
            ])

        case "truth.audit", "privacy.trust.audit", "mac.control.policy.audit":
            return .object([
                "actionId": .string(id),
                "trustPolicy": try Self.codableJSON(try await getTrustPolicy()),
            ])

        case "personality.drift.audit":
            return .object([
                "actionId": .string(id),
                "growth": try Self.codableJSON(try await getPersonalityGrowth()),
            ])

        case "release.gate":
            return .object([
                "actionId": .string(id),
                "releaseChecklist": try Self.codableJSON(try await getReleaseChecklist()),
            ])

        case "execution.durable.checkpoint":
            return .object([
                "actionId": .string(id),
                "missions": try Self.codableJSON(try await getWorkshopExecutions()),
            ])

        case "trace.failure.rootcause", "traces.grade":
            return .object([
                "actionId": .string(id),
                "traces": try Self.codableJSON(Array((try await getTraces()).prefix(25))),
            ])

        case "capability.marketplace.audit", "capability.signature.verify":
            let catalog = try await getCapabilityCatalog()
            return .object([
                "actionId": .string(id),
                "catalogCount": .int(Int64(catalog.count)),
                "catalog": try Self.codableJSON(Array(catalog.prefix(50))),
            ])

        case "browser.capture", "browser.receipt.capture":
            let run = try await runBrowser(url: "https://example.com", dryRun: true)
            return .object([
                "actionId": .string(id),
                "browserRun": try Self.codableJSON(run),
            ])

        default:
            throw NSError(domain: "NativeAgentNextGen", code: 410, userInfo: [
                NSLocalizedDescriptionKey: "NextGen action \(id) is not backed by a Swift read-only executor yet."
            ])
        }
    }

    static func createNextGenActionApproval(id: String, resolved: ResolvedNextGenAction) async throws -> ApprovalRecord {
        let inbox = SwiftNativeApprovalInbox(root: SwiftNativeApprovalInbox.defaultDataRoot())
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

    static func appendNextGenActionReceipt(
        actionId: String,
        phaseId: String?,
        name: String?,
        status: String,
        dryRun: Bool,
        approvalId: String?,
        detail: String?,
        output: JSONValue
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
        let path = PersistenceCore.defaultDataRoot()
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

    static func codableJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONValue.parse(data)
    }

}
