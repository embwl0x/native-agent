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

extension NativeClient {
    func runNativeAction(id: String, dryRun: Bool) async throws -> NativeActionReceipt {
        try await runNativeAction(id: id, dryRun: dryRun, input: [:])
    }

    func runNativeAction(id: String, dryRun: Bool, input: [String: Any]) async throws -> NativeActionReceipt {
        let actionId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actionId.isEmpty else {
            throw NativeClient.notImplemented(
                method: "runNativeAction",
                reason: "native action id is required",
                followup: "vault://nativeagent/zombie_stub_audit#runNativeAction"
            )
        }
        guard let action = Self.swiftRunnableNativeAction(id: actionId) else {
            throw NativeClient.notImplemented(
                method: "runNativeAction",
                reason: "Swift native action '\(actionId)' is not registered",
                followup: "vault://nativeagent/zombie_stub_audit#runNativeAction"
            )
        }
        if actionId == "workflow.launch" {
            return try await runWorkflowNativeAction(action: action, dryRun: dryRun, input: input)
        }
        if actionId.hasPrefix("browser.") {
            return try await runBrowserNativeAction(action: action, dryRun: dryRun, input: input)
        }
        let result = try await Self.dispatchNativeAction(
            tool: actionId,
            input: Self.jsonValueBody(input),
            dryRun: dryRun
        )
        return try await Self.appendNativeActionReceipt(
            action: action,
            status: result.status,
            dryRun: dryRun,
            output: Self.dispatchResultJSON(result)
        )
    }

    static func swiftNativeActionRecords() -> [NativeActionRecord] {
        [
            NativeActionRecord(
                id: "time_now",
                name: "Current Time",
                kind: "dispatcher",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "system_info",
                name: "System Info",
                kind: "dispatcher",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "workspace_list",
                name: "List Workspace",
                kind: "dispatcher",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "persona_list_skills",
                name: "List Persona Skills",
                kind: "dispatcher",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "workflow.launch",
                name: "Launch Workflow",
                kind: "workflow",
                risk: "medium",
                requiresApproval: true,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "persona_read",
                name: "Read Persona File",
                kind: "dispatcher",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "read_file",
                name: "Read File",
                kind: "dispatcher",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "file_excerpt",
                name: "Read File Excerpt",
                kind: "dispatcher",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "browser.open_url",
                name: "Open Browser URL",
                kind: "browser",
                risk: "medium",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "browser.navigate",
                name: "Navigate Browser",
                kind: "browser",
                risk: "medium",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "browser.read_text",
                name: "Read Browser Text",
                kind: "browser",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "browser.read_links",
                name: "Read Browser Links",
                kind: "browser",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
            NativeActionRecord(
                id: "browser.screenshot",
                name: "Capture Browser Screenshot",
                kind: "browser",
                risk: "low",
                requiresApproval: false,
                dryRunAvailable: true
            ),
        ]
    }

    static func swiftRunnableNativeAction(id: String) -> NativeActionRecord? {
        swiftNativeActionRecords().first { $0.id == id }
    }

    static func swiftNativeDispatcherActions() -> LocalConnectorActions {
        var handlers: [String: ConnectorActionHandler] = [:]
        var sideEffecting: Set<String> = []
        var trivialVerify: Set<String> = []
        func merge(_ reg: LocalConnectorActions) {
            for name in reg.toolNames {
                handlers[name] = { input, ctx in reg.run(name, input: input, ctx: ctx) ?? .null }
                if reg.isSideEffecting(name) { sideEffecting.insert(name) }
                if reg.isTrivialVerify(name) { trivialVerify.insert(name) }
            }
        }
        merge(.personaReadOnly)
        merge(.workspaceListReadOnly)
        merge(.timeNowReadOnly)
        merge(.personaListSkillsReadOnly)
        merge(.readFileReadOnly)
        merge(.fileExcerptReadOnly)
        merge(.systemInfoReadOnly)
        return LocalConnectorActions(
            handlers: handlers,
            sideEffecting: sideEffecting,
            trivialVerify: trivialVerify
        )
    }

    static func dispatchNativeAction(
        tool: String,
        input: [String: JSONValue],
        dryRun: Bool
    ) async throws -> Dispatcher.DispatchResult {
        let dispatcher = makeDispatcher(localActions: swiftNativeDispatcherActions())
        let ctx = try strictDispatchContextForTool(tool, surface: "native_actions")
        return try await dispatcher.dispatch(tool: tool, input: input, ctx: ctx, dryRun: dryRun)
    }

    static func strictDispatchContextForTool(_ tool: String, surface: String) throws -> DispatchContext {
        guard tool == "read_file" || tool == "file_excerpt" else {
            return DispatchContext.defaultForSurface(surface)
        }
        let dataRoot = PersistenceCore.defaultDataRoot()
        guard let repoRootURL = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot) else {
            throw NSError(domain: "NativeAgentNativeActions", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "Cannot run \(tool): Swift file sandbox root is unavailable"
            ])
        }
        let repoRoot = repoRootURL.path
        var extra: [String: JSONValue] = [
            "file_access": .object([
                "mode": .string("read_only"),
                "sandbox": .string("read_only"),
            ]),
        ]
        let dataRootPath = dataRoot.path
        if !dataRootPath.isEmpty {
            extra["_na_data_root"] = .string(dataRootPath)
        }
        return DispatchContext(
            repoRoot: repoRoot,
            cwd: repoRoot,
            surface: surface,
            sessionId: "",
            persona: "",
            activeProvider: "",
            extra: extra
        )
    }

    func runWorkflowNativeAction(
        action: NativeActionRecord,
        dryRun: Bool,
        input: [String: Any]
    ) async throws -> NativeActionReceipt {
        let workflowId = Self.stringInput(input, "workflowId")
            ?? Self.stringInput(input, "workflow_id")
            ?? Self.stringInput(input, "id")
            ?? ""
        let objective = Self.stringInput(input, "objective") ?? ""
        guard !workflowId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NativeAgentNativeActions", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "workflow.launch requires workflowId"
            ])
        }
        let run = try await runWorkflow(id: workflowId, objective: objective, execute: !dryRun)
        let data = try JSONEncoder().encode(run)
        let output = try JSONValue.parse(data)
        return try await Self.appendNativeActionReceipt(
            action: action,
            status: dryRun ? "dry_run" : run.status,
            dryRun: dryRun,
            output: output
        )
    }

    func runBrowserNativeAction(
        action: NativeActionRecord,
        dryRun: Bool,
        input: [String: Any]
    ) async throws -> NativeActionReceipt {
        let jsonInput = try Self.jsonValueBody(input)
        switch action.id {
        case "browser.open_url", "browser.navigate":
            let url = Self.stringInput(input, "url")
                ?? Self.stringInput(input, "href")
                ?? Self.stringInput(input, "target")
                ?? ""
            let captureSource = Self.connectorInputBool(
                jsonInput["captureSource"] ?? jsonInput["capture_source"],
                default: false
            )
            let captureScreenshot = Self.connectorInputBool(
                jsonInput["captureScreenshot"] ?? jsonInput["capture_screenshot"],
                default: false
            )
            let run = try await runBrowser(
                url: url,
                dryRun: dryRun,
                captureSource: captureSource,
                captureScreenshot: captureScreenshot
            )
            // Browser Core projects the one canonical terminal transition into
            // the native-action receipt feed for both public aliases. Do not
            // append a second app-owned receipt for browser.navigate.
            if action.id == "browser.open_url" || action.id == "browser.navigate" {
                return NativeActionReceipt(
                    id: run.id,
                    actionId: action.id,
                    name: action.name,
                    kind: action.kind,
                    status: run.status,
                    dryRun: run.dryRun,
                    approvalId: run.approvalId,
                    createdAt: run.createdAt
                )
            }
            return try await Self.appendNativeActionReceipt(
                action: action,
                status: run.status,
                dryRun: dryRun,
                output: try Self.codableJSON(run)
            )

        case "browser.read_text":
            if dryRun {
                return try await Self.appendNativeActionReceipt(
                    action: action,
                    status: "dry_run",
                    dryRun: true,
                    output: .object(["actionId": .string(action.id), "status": .string("dry_run")])
                )
            }
            let capture = try await Self.captureCurrentVisibleBrowser(
                readText: true,
                readLinks: false,
                screenshot: false
            )
            let receipt = try await Self.persistBrowserTextCapture(
                id: "browser-text-\(UUID().uuidString.lowercased())",
                url: capture.url,
                text: capture.text ?? "",
                links: nil
            )
            return try await Self.appendNativeActionReceipt(
                action: action,
                status: "completed",
                dryRun: false,
                output: .object(receipt)
            )

        case "browser.read_links":
            if dryRun {
                return try await Self.appendNativeActionReceipt(
                    action: action,
                    status: "dry_run",
                    dryRun: true,
                    output: .object(["actionId": .string(action.id), "status": .string("dry_run")])
                )
            }
            let capture = try await Self.captureCurrentVisibleBrowser(
                readText: false,
                readLinks: true,
                screenshot: false
            )
            let receipt = try await Self.persistBrowserLinksCapture(
                id: "browser-links-\(UUID().uuidString.lowercased())",
                url: capture.url,
                links: capture.links ?? []
            )
            return try await Self.appendNativeActionReceipt(
                action: action,
                status: "completed",
                dryRun: false,
                output: .object(receipt)
            )

        case "browser.screenshot":
            if dryRun {
                return try await Self.appendNativeActionReceipt(
                    action: action,
                    status: "dry_run",
                    dryRun: true,
                    output: .object(["actionId": .string(action.id), "status": .string("dry_run")])
                )
            }
            let capture = try await Self.captureCurrentVisibleBrowser(
                readText: false,
                readLinks: false,
                screenshot: true
            )
            guard let png = capture.screenshot else {
                throw NSError(domain: "NativeAgentBrowser", code: -500, userInfo: [
                    NSLocalizedDescriptionKey: "Browser screenshot capture returned no image data"
                ])
            }
            let receipt = try await Self.persistBrowserScreenshotCapture(
                id: "browser-shot-\(UUID().uuidString.lowercased())",
                url: capture.url,
                png: png
            )
            return try await Self.appendNativeActionReceipt(
                action: action,
                status: "completed",
                dryRun: false,
                output: .object(receipt)
            )

        default:
            throw NativeClient.notImplemented(
                method: "runNativeAction",
                reason: "Swift browser action '\(action.id)' is not implemented",
                followup: "vault://nativeagent/zombie_stub_audit#runNativeAction"
            )
        }
    }

    static func stringInput(_ input: [String: Any], _ key: String) -> String? {
        guard let raw = input[key] else { return nil }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let n = raw as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    static func nativeActionReceiptsPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    static func appendNativeActionReceipt(
        action: NativeActionRecord,
        status: String,
        dryRun: Bool,
        output: JSONValue
    ) async throws -> NativeActionReceipt {
        let createdAt = SwiftNativeManifestSigner.isoTimestamp(Date())
        let id = UUID().uuidString.lowercased()
        var record: [String: JSONValue] = [
            "id": .string(id),
            "actionId": .string(action.id),
            "name": .string(action.name),
            "kind": .string(action.kind ?? "native"),
            "status": .string(status),
            "dryRun": .bool(dryRun),
            "approvalId": .null,
            "output": output,
            "createdAt": .string(createdAt),
        ]
        copyNativeActionOutputSummary(output, into: &record)
        if action.requiresApproval == true {
            record["requiresApproval"] = .bool(true)
        }
        let recordValue = JSONValue.object(record)
        let path = nativeActionReceiptsPath()
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            try await persistence.appendJSONL(recordValue, to: path)
        }
        let data = try recordValue.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(NativeActionReceipt.self, from: data)
    }

    private static func copyNativeActionOutputSummary(
        _ output: JSONValue,
        into record: inout [String: JSONValue]
    ) {
        guard case .object(let obj) = output else { return }
        for key in ["url", "textPath", "textPreview", "linksPath", "pngPath"] {
            if case .string(_)? = obj[key] {
                record[key] = obj[key]
            }
        }
        for key in ["textChars", "linkCount"] {
            if case .int(_)? = obj[key] {
                record[key] = obj[key]
            }
        }
        if case .array(_)? = obj["linksPreview"] {
            record["linksPreview"] = obj["linksPreview"]
        }
    }

    static func dispatchResultJSON(_ result: Dispatcher.DispatchResult) -> JSONValue {
        var obj: [String: JSONValue] = [
            "ok": .bool(result.ok),
            "tool": .string(result.tool),
            "status": .string(result.status),
            "executed": .bool(result.executed),
            "durationUs": .int(Int64(result.durationUs)),
            "durationMs": .int(Int64(result.durationMs)),
            "argsHash": .string(result.argsHash),
            "effectiveAutonomy": .string(result.effectiveAutonomy),
            "autonomySource": .string(result.autonomySource),
            "providerMatch": .bool(result.providerMatch),
            "traceEventId": .string(result.traceEventId),
            "runId": .string(result.runId),
            "startedAt": .string(result.startedAt),
            "output": result.output?.value ?? .null,
            "verifyPassed": result.verifyPassed.map { .bool($0) } ?? .null,
        ]
        if let err = result.error {
            obj["error"] = .object([
                "code": .string(err.code),
                "message": .string(err.message),
                "tool": err.tool.map { .string($0) } ?? .null,
                "argsHash": err.argsHash.map { .string($0) } ?? .null,
                "recoverable": .bool(err.recoverable),
            ])
        } else {
            obj["error"] = .null
        }
        return .object(obj)
    }

}
