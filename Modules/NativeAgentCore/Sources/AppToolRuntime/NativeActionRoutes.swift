import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import Dispatcher
import Browser
import TrustPersistence

public enum NativeActionRoutes {
    public static func runNativeAction(
        id: String, dryRun: Bool, input: [String: Any], dataRoot: URL?,
        browser: (NativeActionRecord, Bool, [String: Any]) async throws -> NativeActionReceipt
    ) async throws -> NativeActionReceipt {
        let actionId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actionId.isEmpty else {
            throw NativeActionRouteSupport.notImplemented(
                method: "runNativeAction",
                reason: "native action id is required",
                followup: "vault://nativeagent/zombie_stub_audit#runNativeAction"
            )
        }
        guard let action = Self.swiftRunnableNativeAction(id: actionId) else {
            throw NativeActionRouteSupport.notImplemented(
                method: "runNativeAction",
                reason: "Swift native action '\(actionId)' is not registered",
                followup: "vault://nativeagent/zombie_stub_audit#runNativeAction"
            )
        }
        if actionId.hasPrefix("browser.") {
            return try await browser(action, dryRun, input)
        }
        let result = try await NativeActionDispatch.dispatchNativeAction(
            tool: actionId,
            input: NativeActionRouteSupport.jsonValueBody(input),
            dryRun: dryRun,
            dataRoot: dataRoot
        )
        return try await Self.appendNativeActionReceipt(
            action: action,
            status: result.status,
            dryRun: dryRun,
            output: Self.dispatchResultJSON(result),
            dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()
        )
    }

    public static func swiftNativeActionRecords() -> [NativeActionRecord] {
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

    public static func swiftRunnableNativeAction(id: String) -> NativeActionRecord? {
        swiftNativeActionRecords().first { $0.id == id }
    }

    public static func nativeActionReceiptsPath(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        dataRoot
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    public static func appendNativeActionReceipt(
        action: NativeActionRecord,
        status: String,
        dryRun: Bool,
        output: JSONValue,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
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
        let path = nativeActionReceiptsPath(dataRoot: dataRoot)
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

    public static func dispatchResultJSON(_ result: Dispatcher.DispatchResult) -> JSONValue {
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
