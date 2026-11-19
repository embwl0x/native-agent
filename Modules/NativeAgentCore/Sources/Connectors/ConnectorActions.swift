import Foundation
import Experiences
import ChatToolParsing
import Darwin
import NativeAgentCore
import PersistenceCore
import Privacy
import TrustCenter
import ApprovalInbox
import ApprovalTransactions
import ChatToolRuntime
import TriggerScheduler
import MacControl
import AppToolRuntime
import DeviceSync
import AttentionRouting
import MacIntegration
// Blueprint: | `ConnectorActions.swift` | `ConnectorActions`: shared admission; CodexHandoff identity; redacted native reads; journal gaps |

/// Host adapters supply effects; connector policy and receipts stay here.
public struct ConnectorActions: Sendable {
    private let platform: any ConnectorActionPlatform

    public init(platform: any ConnectorActionPlatform) {
        self.platform = platform
    }

    public func runConnectorAction(
        id: String,
        dryRun: Bool,
        input: [String: JSONValue] = [:],
        surface: String = "connector_action",
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        turn: Turn
    ) async throws -> ConnectorActionReceipt {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let descriptor = connectorActionDescriptors().first(where: { $0.id == trimmed }) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                NSLocalizedDescriptionKey: "That action is gone; grow an ability for it."
            ])
        }

        return try await runConnectorAction(
            descriptor: descriptor,
            dryRun: dryRun,
            input: input,
            surface: surface,
            dataRoot: dataRoot, turn: turn
        )
    }

    public func runConnectorAction(
        descriptor: ConnectorActionDescriptor,
        dryRun: Bool,
        input: [String: JSONValue] = [:],
        approvedReplayApprovalID: String? = nil,
        surface: String = "connector_action",
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        turn: Turn
    ) async throws -> ConnectorActionReceipt {
        let yoloAdmitted = !dryRun && approvedReplayApprovalID == nil
            ? await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(
                origin: .currentTurn(turn: turn, surface: surface, source: "native_client_direct_action"), turn: turn).admitted
            : false
        if descriptor.requiresApproval, !dryRun, approvedReplayApprovalID == nil, !yoloAdmitted {
            let approval = try await Self.createConnectorActionApproval(
                descriptor,
                input: input,
                dataRoot: dataRoot,
                turn: turn
            )
            return try await Self.appendConnectorActionReceipt(
                descriptor: descriptor,
                dryRun: false,
                approvalId: approval.id,
                output: .object([
                    "actionId": .string(descriptor.id),
                    "connectorId": .string(descriptor.connectorId),
                    "status": .string("pending_approval"),
                    "approvalId": .string(approval.id),
                    "risk": .string(descriptor.risk),
                ]),
                dataRoot: dataRoot
            )
        }

        if !dryRun {
            if let approvalID = approvedReplayApprovalID {
                try await Self.validateApprovedConnectorReplay(
                    approvalID: approvalID,
                    descriptor: descriptor,
                    input: input,
                    dataRoot: dataRoot
                )
            }
            let output: JSONValue
            switch descriptor.id {
            case "codex.handoff":
                output = try Self.readCodexHandoff(input: input)
            case "mac_assistant.watch_templates":
                output = try await self.runMacAssistantWatchTemplates()
            case "scheduler.schedule_job", "scheduler.create_job":
                output = try await ScheduledReads.create(input, dataRoot: dataRoot)
            case "scheduler.list_jobs":
                output = try await ScheduledReads.list(dataRoot: dataRoot)
            case "scheduler.cancel_job":
                output = try await ScheduledReads.cancel(input["jobId"]?.scalarText ?? "", dataRoot: dataRoot)
            default:
                guard descriptor.id.hasSuffix(".status") else {
                    throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                        NSLocalizedDescriptionKey: """
                            Connector action \(descriptor.id) needs a live Swift provider executor. This action is registered but no Swift executor owns \
                            its effects yet.
                            """
                    ])
                }
                output = try await connectorStatusActionOutput(descriptor)
            }
            return try await Self.appendConnectorActionReceipt(
                descriptor: descriptor,
                dryRun: false,
                approvalId: approvedReplayApprovalID,
                output: output,
                dataRoot: dataRoot
            )
        }

        let output: JSONValue = .object([
            "actionId": .string(descriptor.id),
            "connectorId": .string(descriptor.connectorId),
            "status": .string("dry_run"),
            "dryRun": .bool(true),
        ])
        return try await Self.appendConnectorActionReceipt(
            descriptor: descriptor,
            dryRun: true,
            approvalId: nil,
            output: output,
            dataRoot: dataRoot
        )
    }

    public func runMacSpotlightSearch(input: [String: JSONValue], toolName: String, turn: Turn) async throws -> JSONValue {
        let query = input["query"]?.scalarText ?? ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "\(toolName) requires query"
            ])
        }
        let result = try await platform.spotlight(input: input, turn: turn)
        // A connector's search runs outside any owned program: there is no read capture to record into.
        return NativeAppSecretRedactor.redactValue(result.toJSON(readContent: nil))
    }

    public func runMacNotify(input: [String: JSONValue], toolName: String, turn: Turn) async throws -> JSONValue {
        let note = try NativeAgentNotificationDefaults.parseInput(input, toolName: toolName)
        var obj = await platform.postMessage(note, turn: turn)
        obj.merge(AppToolExecutor.notificationEcho(note)) { _, new in new }
        return .object(obj)
    }

    public func runMacAssistantWatchTemplates() async throws -> JSONValue {
        let impl = platform.macAssistantStatusClient()
        let status = try await impl.macAssistantStatus(lightweight: false)
        return status.toJSON()
    }

    public static func readCodexHandoff(input: [String: JSONValue]) throws -> JSONValue {
        let includeText = ConnectorInputValue.bool(input["includeText"], default: false)
        let maxChars = max(500, min(try Self.connectorInputInt(input["maxChars"], default: 8_000), 50_000))
        let maxEntries = max(1, min(try Self.connectorInputInt(input["maxEntries"], default: 5), 25))
        let maxEntryChars = max(500, min(try Self.connectorInputInt(input["maxEntryChars"], default: 2_000), 10_000))
        let path = CodexHandoff.path
        var entry = stat()
        let exists = stat(path.path, &entry) == 0
        if !exists, errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path.path])
        }
        let rawText = exists ? try String(contentsOf: path, encoding: .utf8) : ""
        let redacted = NativeAppSecretRedactor.redactText(rawText)
        let entries = Self.recentMarkdownEntries(redacted, maxEntries: maxEntries, maxEntryChars: maxEntryChars)
        var obj: [String: JSONValue] = [
            "status": .string(exists ? "available" : "missing"),
            "path": .string(path.path),
            "exists": .bool(exists),
            "updatedAt": exists ? .string(SwiftNativeManifestSigner.isoTimestamp(Date(
                timeIntervalSince1970: Double(entry.st_mtimespec.tv_sec) + Double(entry.st_mtimespec.tv_nsec) / 1_000_000_000))) : .null,
            "entryCount": .int(Int64(entries.count)),
            "entries": .array(entries.map { .string($0) }),
        ]
        if includeText {
            obj["text"] = .string(String(redacted.prefix(maxChars)))
        }
        return .object(obj)
    }

    public static func recentMarkdownEntries(_ text: String, maxEntries: Int, maxEntryChars: Int) -> [String] {
        let chunks = text
            .components(separatedBy: "\n## ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return chunks.suffix(maxEntries).map { chunk in
            let restored = chunk.hasPrefix("#") ? chunk : "## \(chunk)"
            return String(restored.prefix(maxEntryChars))
        }
    }

    public static func connectorInputInt(_ raw: JSONValue?, default defaultValue: Int) throws -> Int {
        try MacAppleScriptBridge.clampedInt(raw, defaultValue: defaultValue, min: Int.min, max: Int.max)
    }

    public func connectorStatusActionOutput(_ descriptor: ConnectorActionDescriptor) async throws -> JSONValue {
        let action = try await platform.statusEvidence(actionID: descriptor.id)
        return .object([
            "actionId": .string(descriptor.id),
            "connectorId": .string(descriptor.connectorId),
            "name": .string(descriptor.name ?? descriptor.id),
            "status": .string("completed"),
            "risk": .string(descriptor.risk),
            "connectorStatus": .string(action?.connectorStatus ?? "needs_setup"),
            "authState": .string(action?.authState ?? "not_connected"),
            "enabled": .bool(action?.enabled ?? false),
            "dryRunAvailable": .bool(descriptor.dryRunAvailable),
            "requiresApproval": .bool(descriptor.requiresApproval),
        ])
    }

    public static func createConnectorActionApproval(
        _ descriptor: ConnectorActionDescriptor,
        input: [String: JSONValue],
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        turn: Turn
    ) async throws -> ApprovalRecord {
        let payload: JSONValue = .object([
            "kind": .string("connector_action_v1"),
            "surface": .string("connector_action"),
            "actionId": .string(descriptor.id),
            "connectorId": .string(descriptor.connectorId),
            "name": .string(descriptor.name ?? descriptor.id),
            "risk": .string(descriptor.risk),
            "input": .object(input),
        ])
        let payloadBytes = try payload.serializedData(pretty: false)
        guard payloadBytes.count <= 65_536 else {
            throw NSError(domain: "NativeAgentConnectorApproval", code: 413, userInfo: [
                NSLocalizedDescriptionKey: "Connector approval input exceeds the 64 KiB replay limit."
            ])
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        return try await inbox.create(.object([
            "title": .string("Approve \(descriptor.name ?? descriptor.id)"),
            "action": .string("connector.action.\(descriptor.id)"),
            "risk": .string(descriptor.risk),
            "reason": .string("Connector action \(descriptor.id) requires approval before any external side effect can run."),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
            "payload": payload,
        ]), turn: turn)
    }

    public static func validateApprovedConnectorReplay(
        approvalID: String,
        descriptor: ConnectorActionDescriptor,
        input: [String: JSONValue],
        dataRoot: URL
    ) async throws {
        let record = try await SwiftNativeApprovalInbox(root: dataRoot).get(approvalID)
        guard record.status == "resolved", record.decision == "approved",
              let replay = ApprovalExecution.connectorActionApprovalReplay(from: record),
              replay.actionID == descriptor.id,
              replay.connectorID == descriptor.connectorId,
              replay.input == input else {
            throw NSError(domain: "NativeAgentConnectorApproval", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "Connector execution no longer matches the exact approved payload."
            ])
        }
    }

    public static func appendConnectorActionReceipt(
        descriptor: ConnectorActionDescriptor,
        dryRun: Bool,
        approvalId: String?,
        output: JSONValue,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws -> ConnectorActionReceipt {
        let reply = ToolResult(output)
        let directRead = !dryRun && output.objectValue?["status"] != .string(
            "pending_approval") && ["codex.handoff", "mac_assistant.watch_templates"].contains(descriptor.id)
        let facts = (directRead ? ChatToolOutcome.ExactResultClass.succeeded : reply.outcome).receipt
        let status = facts.ok == false ? facts.status : directRead ? "completed" : output.objectValue?["status"]?.stringValue ?? (
            facts.ok == true ? "completed" : facts.status)
        let createdAt = SwiftNativeManifestSigner.isoTimestamp(Date())
        let recorded: Result<ConnectorActionReceipt, Error> = await settle {
            do {
                return .success(try await ConnectorActionReceipt.append(
                    actionId: descriptor.id, connectorId: descriptor.connectorId,
                    name: descriptor.name, status: status, ok: facts.ok, dryRun: dryRun,
                    approvalId: approvalId, createdAt: createdAt,
                    output: reply.payload, dataRoot: dataRoot
                ))
            } catch {
                return .failure(NSError(domain: "NativeAgentConnectorSettlement", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Connector action returned \(status), but its receipt could not be saved: \(error.localizedDescription)",
                    NSUnderlyingErrorKey: error,
                    "actionId": descriptor.id,
                    "returnedStatus": status,
                    "returnedOutput": NativeAppSecretRedactor.redactValue(output),
                ]))
            }
        }
        return try recorded.get()
    }
}
