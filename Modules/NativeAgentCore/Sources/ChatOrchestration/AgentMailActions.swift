import Foundation
import ApprovalInbox
import NativeAgentCore
import PersistenceCore

public enum AgentMailActions {
    private static let defaultBaseURL = "https://api.agentmail.to"
    private static let requestTimeout: TimeInterval = 20

    public static func listRecent(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> JSONValue {
        await run(actionId: "agentmail.list_inbox", dataRoot: dataRoot) {
            let config = try loadConfig(dataRoot: dataRoot)
            let limit = clampedInt(input["limit"] ?? input["max"], defaultValue: 20, min: 1, max: 50)
            let data = try await api(
                method: "GET",
                path: "/inboxes/\(percentEncode(config.inboxID, safe: "@"))/messages",
                query: [("limit", String(limit))],
                dataRoot: dataRoot
            )
            let rawMessages = objectArray(data["messages"]) ?? objectArray(data["items"]) ?? []
            let rows: [JSONValue] = rawMessages.prefix(limit).compactMap { message in
                let messageID = string(message["message_id"]) ?? string(message["id"]) ?? ""
                guard !messageID.isEmpty else { return nil }
                return .object([
                    "message_id": .string(messageID),
                    "sender": .string(string(message["from"]) ?? string(message["from_"]) ?? string(message["sender"]) ?? ""),
                    "subject": .string(string(message["subject"]) ?? ""),
                    "date": .string(string(message["received_at"]) ?? string(message["timestamp"]) ?? string(message["created_at"]) ?? ""),
                    "snippet": .string(String((string(message["preview"]) ?? string(message["snippet"]) ?? "").prefix(240))),
                    "thread_id": string(message["thread_id"]).map(JSONValue.string) ?? .null,
                ])
            }
            return completed(actionId: "agentmail.list_inbox", fields: [
                "inbox": .string(config.inboxID),
                "display_name": .string(config.displayName),
                "messages": .array(rows),
                "count": .int(Int64(rows.count)),
            ])
        }
    }

    public static func readMessage(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> JSONValue {
        await run(actionId: "agentmail.read", dataRoot: dataRoot) {
            let config = try loadConfig(dataRoot: dataRoot)
            let messageID = (string(input["message_id"]) ?? string(input["messageId"]) ?? string(input["id"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !messageID.isEmpty else {
                throw AgentMailError("missing_input", detail: "agentmail_read requires message_id.")
            }
            let data = try await api(
                method: "GET",
                path: "/inboxes/\(percentEncode(config.inboxID, safe: "@"))/messages/\(percentEncode(messageID, safe: ""))",
                dataRoot: dataRoot
            )
            let resolvedID = string(data["message_id"]) ?? string(data["id"]) ?? messageID
            let text = string(data["text"]) ?? string(data["body_text"]) ?? ""
            let html = string(data["html"]) ?? string(data["body_html"]) ?? ""
            return completed(actionId: "agentmail.read", fields: [
                "inbox": .string(config.inboxID),
                "display_name": .string(config.displayName),
                "message_id": .string(resolvedID),
                "thread_id": string(data["thread_id"]).map(JSONValue.string) ?? .null,
                "sender": .string(string(data["from"]) ?? string(data["from_"]) ?? string(data["sender"]) ?? ""),
                "to": data["to"] ?? .array([]),
                "cc": data["cc"] ?? .null,
                "subject": .string(string(data["subject"]) ?? ""),
                "date": .string(string(data["received_at"]) ?? string(data["timestamp"]) ?? string(data["created_at"]) ?? ""),
                "body": .string(text.isEmpty ? html : text),
                "text": .string(text),
                "html": .string(html),
                "labels": data["labels"] ?? .array([]),
            ])
        }
    }

    public static func stageSendApproval(
        input: [String: JSONValue],
        surface: String = "connector_action",
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> JSONValue {
        await ExternalSendApprovalLifecycle.stageToolResult(
            invokedAs: "agentmail.send",
            input: input,
            surface: surface,
            dataRoot: dataRoot
        )
    }

    public static func executeApprovedSend(
        from record: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> JSONValue {
        guard record.action == "agentmail.send",
              record.status == "resolved",
              record.decision == "approved" else {
            return failure(
                actionId: "agentmail.send",
                short: "not_approved_agentmail_send",
                detail: "Approval record is not a resolved approved agentmail.send."
            )
        }
        guard case .object(let payload) = record.payload,
              case .object(let input)? = payload["input"] else {
            let output = failure(
                actionId: "agentmail.send",
                short: "missing_payload",
                detail: "Approval payload is missing input."
            )
            await appendReceipt(
                actionId: "agentmail.send",
                status: "failed",
                dryRun: false,
                approvalId: record.id,
                output: output,
                dataRoot: dataRoot
            )
            return output
        }
        return await sendNow(input: input, approvalId: record.id, dataRoot: dataRoot)
    }

    public static func sendNow(
        input: [String: JSONValue],
        approvalId: String?,
        idempotencyKey: String? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        recordReceipt: Bool = true
    ) async -> JSONValue {
        do {
            let config = try loadConfig(dataRoot: dataRoot)
            let normalized = try normalizeSendInput(input, config: config)
            let result = try await api(
                method: "POST",
                path: "/inboxes/\(percentEncode(config.inboxID, safe: "@"))/messages/send",
                body: normalized.apiBody,
                idempotencyKey: idempotencyKey ?? approvalId.map { "agentmail.send.\($0)" },
                dataRoot: dataRoot
            )
            let output = completed(actionId: "agentmail.send", status: "succeeded", fields: [
                "sent": .bool(true),
                "messageId": .string(string(result["message_id"]) ?? string(result["id"]) ?? ""),
                "message_id": .string(string(result["message_id"]) ?? string(result["id"]) ?? ""),
                "threadId": string(result["thread_id"]).map(JSONValue.string) ?? .null,
                "thread_id": string(result["thread_id"]).map(JSONValue.string) ?? .null,
                "inboxId": .string(config.inboxID),
                "from": .string(config.inboxID),
                "to": .array(normalized.to.map { .string($0) }),
                "subject": .string(normalized.subject),
            ])
            if recordReceipt {
                await appendReceipt(
                    actionId: "agentmail.send",
                    status: "succeeded",
                    dryRun: false,
                    approvalId: approvalId,
                    output: output,
                    dataRoot: dataRoot
                )
            }
            return output
        } catch {
            let output = failure(actionId: "agentmail.send", error: error)
            if recordReceipt {
                await appendReceipt(
                    actionId: "agentmail.send",
                    status: "failed",
                    dryRun: false,
                    approvalId: approvalId,
                    output: output,
                    dataRoot: dataRoot
                )
            }
            return output
        }
    }

    public static func succeededReceiptForApproval(
        _ approvalId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> JSONValue? {
        guard !approvalId.isEmpty else { return nil }
        let path = receiptsPath(dataRoot: dataRoot)
        let rows = (try? await SwiftNativePersistenceCore().readJSONL(path)) ?? []
        for row in rows.suffix(500).reversed() {
            guard case .object(let obj) = row,
                  string(obj["actionId"]) == "agentmail.send",
                  string(obj["approvalId"]) == approvalId,
                  ["succeeded", "ok"].contains(string(obj["status"]) ?? "") else {
                continue
            }
            return row
        }
        return nil
    }

    private static func run(
        actionId: String,
        dataRoot: URL,
        _ body: () async throws -> JSONValue
    ) async -> JSONValue {
        do {
            let output = try await body()
            let status = stringFromObject(output, key: "status") ?? "completed"
            await appendReceipt(
                actionId: actionId,
                status: status == "completed" ? "succeeded" : status,
                dryRun: false,
                approvalId: nil,
                output: output,
                dataRoot: dataRoot
            )
            return output
        } catch {
            let output = failure(actionId: actionId, error: error)
            await appendReceipt(
                actionId: actionId,
                status: "failed",
                dryRun: false,
                approvalId: nil,
                output: output,
                dataRoot: dataRoot
            )
            return output
        }
    }

    private struct Config {
        let apiKey: String
        let apiBase: URL
        let inboxID: String
        let displayName: String
    }

    private struct SendInput {
        let to: [String]
        let subject: String
        let text: String
        let cc: [String]
        let payload: JSONValue
        let apiBody: [String: JSONValue]
    }

    private static func loadConfig(dataRoot: URL) throws -> Config {
        let path = dataRoot
            .appendingPathComponent("secrets", isDirectory: true)
            .appendingPathComponent("agentmail.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw AgentMailError("agentmail_not_configured", detail: "Missing data/secrets/agentmail.json.")
        }
        let raw = try Data(contentsOf: path)
        let parsed = try JSONValue.parse(raw)
        guard case .object(let obj) = parsed else {
            throw AgentMailError("agentmail_secret_invalid", detail: "AgentMail secret is not a JSON object.")
        }
        let apiKey = (string(obj["api_key"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw AgentMailError("agentmail_secret_invalid", detail: "AgentMail secret is missing api_key.")
        }
        let inboxID = (
            string(obj["inbox_id"])
                ?? string(obj["inbox"])
                ?? string(obj["email"])
                ?? string(obj["address"])
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inboxID.isEmpty else {
            throw AgentMailError(
                "agentmail_secret_invalid",
                detail: "AgentMail secret is missing inbox_id."
            )
        }
        let displayName = (
            string(obj["display_name"])
                ?? string(obj["name"])
                ?? "AgentMail"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase = (string(obj["base_url"]) ?? defaultBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let withVersion = rawBase.hasSuffix("/v0") ? rawBase : "\(rawBase)/v0"
        guard let apiBase = URL(string: withVersion) else {
            throw AgentMailError("agentmail_secret_invalid", detail: "AgentMail base_url is invalid.")
        }
        return Config(
            apiKey: apiKey,
            apiBase: apiBase,
            inboxID: inboxID,
            displayName: displayName.isEmpty ? "AgentMail" : displayName
        )
    }

    private static func api(
        method: String,
        path: String,
        body: [String: JSONValue]? = nil,
        query: [(String, String)] = [],
        idempotencyKey: String? = nil,
        dataRoot: URL
    ) async throws -> [String: JSONValue] {
        let config = try loadConfig(dataRoot: dataRoot)
        guard var components = URLComponents(url: config.apiBase, resolvingAgainstBaseURL: false) else {
            throw AgentMailError("invalid_url", detail: "Could not build AgentMail request URL.")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, requestPath].filter { !$0.isEmpty }.joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw AgentMailError("invalid_url", detail: "Could not build AgentMail request URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("NativeAgent/Swift", forHTTPHeaderField: "User-Agent")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONValue.object(body).serializedData(pretty: false)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentMailError("invalid_response", detail: "AgentMail returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentMailError(
                "http_\(http.statusCode)",
                detail: "AgentMail API HTTP \(http.statusCode): \(bodyExcerpt(data))"
            )
        }
        guard !data.isEmpty else { return [:] }
        let value = try JSONValue.parse(data)
        guard case .object(let obj) = value else {
            throw AgentMailError("invalid_json", detail: "AgentMail returned non-object JSON.")
        }
        return obj
    }

    private static func normalizeSendInput(_ input: [String: JSONValue], config: Config) throws -> SendInput {
        let to = stringList(input["to"] ?? input["recipients"])
        guard !to.isEmpty else {
            throw AgentMailError("missing_input", detail: "agentmail_send requires to.")
        }
        let subject = (string(input["subject"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else {
            throw AgentMailError("missing_input", detail: "agentmail_send requires subject.")
        }
        let text = (string(input["body"]) ?? string(input["text"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgentMailError("missing_input", detail: "agentmail_send requires body.")
        }
        let cc = stringList(input["cc"])
        guard to.count <= 50, cc.count <= 50 else {
            throw AgentMailError("input_too_large", detail: "AgentMail supports at most 50 to/cc recipients per approved send.")
        }
        guard (to + cc).allSatisfy({ $0.utf8.count <= 320 }) else {
            throw AgentMailError("input_too_large", detail: "AgentMail recipient values must be at most 320 bytes.")
        }
        guard subject.utf8.count <= 998 else {
            throw AgentMailError("input_too_large", detail: "AgentMail subject must be at most 998 bytes.")
        }
        guard text.utf8.count <= 100_000 else {
            throw AgentMailError("input_too_large", detail: "AgentMail body must be at most 100000 bytes.")
        }
        if let approvedInbox = string(input["inboxId"] ?? input["inbox_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !approvedInbox.isEmpty,
           approvedInbox != config.inboxID {
            throw AgentMailError(
                "stale_sender",
                detail: "The configured AgentMail inbox changed after approval staging."
            )
        }

        var payload: [String: JSONValue] = [
            "to": to.count == 1 ? .string(to[0]) : .array(to.map { .string($0) }),
            "subject": .string(subject),
            "text": .string(text),
            "inboxId": .string(config.inboxID),
        ]
        if !cc.isEmpty {
            payload["cc"] = cc.count == 1 ? .string(cc[0]) : .array(cc.map { .string($0) })
        }

        var apiBody: [String: JSONValue] = [
            "to": .array(to.map { .string($0) }),
            "subject": .string(subject),
            "text": .string(text),
        ]
        if !cc.isEmpty {
            apiBody["cc"] = .array(cc.map { .string($0) })
        }
        return SendInput(to: to, subject: subject, text: text, cc: cc, payload: .object(payload), apiBody: apiBody)
    }

    static func prepareSendApprovalInput(
        _ input: [String: JSONValue],
        dataRoot: URL
    ) throws -> ExternalSendPreparedInput {
        let config = try loadConfig(dataRoot: dataRoot)
        let normalized = try normalizeSendInput(input, config: config)
        guard case .object(let replayInput) = normalized.payload else {
            throw AgentMailError("invalid_replay_input", detail: "Could not build bounded AgentMail replay input.")
        }
        return ExternalSendPreparedInput(
            input: replayInput,
            destinationCount: normalized.to.count + normalized.cc.count,
            contentByteCount: normalized.text.utf8.count
        )
    }

    private static func appendReceipt(
        actionId: String,
        status: String,
        dryRun: Bool,
        approvalId: String?,
        output: JSONValue,
        dataRoot: URL
    ) async {
        let path = receiptsPath(dataRoot: dataRoot)
        let receipt: JSONValue = .object([
            "ok": .bool(status != "failed"),
            "id": .string(UUID().uuidString.lowercased()),
            "actionId": .string(actionId),
            "connectorId": .string("agentmail"),
            "name": .string(name(for: actionId)),
            "status": .string(status),
            "dryRun": .bool(dryRun),
            "approvalId": approvalId.map(JSONValue.string) ?? .null,
            "output": receiptSafeOutput(actionId: actionId, output: output),
            "createdAt": .string(nowISO()),
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await persistence.appendJSONL(receipt, to: path)
            }
        } catch {
            // Connector receipts are audit-only. The tool result should still
            // reach chat if receipt persistence has a transient IO failure.
        }
    }

    private static func receiptSafeOutput(actionId: String, output: JSONValue) -> JSONValue {
        guard actionId == "agentmail.read", case .object(var obj) = output else { return output }
        if case .string(let text)? = obj["text"] {
            obj["textRedacted"] = .bool(true)
            obj["textByteCount"] = .int(Int64(Data(text.utf8).count))
            obj["text"] = .null
        }
        if case .string(let html)? = obj["html"] {
            obj["htmlRedacted"] = .bool(true)
            obj["htmlByteCount"] = .int(Int64(Data(html.utf8).count))
            obj["html"] = .null
        }
        if case .string(let body)? = obj["body"] {
            obj["bodyRedacted"] = .bool(true)
            obj["bodyByteCount"] = .int(Int64(Data(body.utf8).count))
            obj["body"] = .null
        }
        return .object(obj)
    }

    private static func receiptsPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    private static func completed(
        actionId: String,
        status: String = "completed",
        fields: [String: JSONValue]
    ) -> JSONValue {
        var obj: [String: JSONValue] = [
            "status": .string(status),
            "actionId": .string(actionId),
            "connectorId": .string("agentmail"),
            "provider": .string("agentmail"),
        ]
        for (key, value) in fields {
            obj[key] = value
        }
        return .object(obj)
    }

    private static func failure(actionId: String, error: Error) -> JSONValue {
        if let agentMailError = error as? AgentMailError {
            return failure(actionId: actionId, short: agentMailError.message, detail: agentMailError.detail)
        }
        return failure(actionId: actionId, short: "failed", detail: error.localizedDescription)
    }

    private static func failure(actionId: String, short: String, detail: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "actionId": .string(actionId),
            "connectorId": .string("agentmail"),
            "provider": .string("agentmail"),
            "error": .string(short),
            "detail": .string(detail),
        ])
    }

    private static func objectArray(_ value: JSONValue?) -> [[String: JSONValue]]? {
        guard case .array(let arr)? = value else { return nil }
        return arr.compactMap {
            guard case .object(let obj) = $0 else { return nil }
            return obj
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    private static func stringFromObject(_ value: JSONValue, key: String) -> String? {
        guard case .object(let obj) = value else { return nil }
        return string(obj[key])
    }

    private static func stringList(_ value: JSONValue?) -> [String] {
        switch value {
        case .string(let s):
            return s
                .split { $0 == "," || $0 == ";" }
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .array(let arr):
            return arr
                .compactMap { string($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }

    private static func clampedInt(_ value: JSONValue?, defaultValue: Int, min: Int, max: Int) -> Int {
        let raw: Int
        switch value {
        case .int(let i): raw = Int(i)
        case .double(let d): raw = Int(d)
        case .string(let s): raw = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        default: raw = defaultValue
        }
        return Swift.max(min, Swift.min(max, raw))
    }

    private static func bodyExcerpt(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return "" }
        return String(text.prefix(500))
    }

    private static func percentEncode(_ value: String, safe: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~\(safe)".unicodeScalars)
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    out += String(format: "%%%02X", byte)
                }
            }
        }
        return out
    }

    private static func name(for actionId: String) -> String {
        switch actionId {
        case "agentmail.list_inbox": return "AgentMail List Inbox"
        case "agentmail.read": return "AgentMail Read Message"
        case "agentmail.send": return "AgentMail Send"
        default: return actionId
        }
    }

    private static func nowISO() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'+00:00'"
        return formatter.string(from: Date())
    }
}

public struct AgentMailError: Error, Sendable {
    public let message: String
    public let detail: String

    public init(_ message: String, detail: String) {
        self.message = message
        self.detail = detail
    }
}
