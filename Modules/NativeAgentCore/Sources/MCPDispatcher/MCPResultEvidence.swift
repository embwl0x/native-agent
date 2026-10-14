import Foundation
import CryptoKit
import PersistenceCore
import Privacy
import NativeAgentCore

public enum MCPResultEvidence {
    static let maxProjectionBytes = 8 * 1024
    static let maxPreviewBytes = 4 * 1024

    struct Projection: Sendable, Equatable {
        let result: JSONValue
        let preview: String
        let originalByteCount: Int
        let redactedByteCount: Int
        let truncated: Bool
        let digest: String
    }

    struct WriteOutcome: Sendable, Equatable {
        let status: String
        let error: String?
    }

    private static let sensitiveKeyFragments = [
        "api_key", "apikey", "authorization", "cookie", "credential",
        "password", "private_key", "secret", "session", "token",
    ]

    static func project(_ value: JSONValue) throws -> Projection {
        let originalData = try value.serializedData(pretty: false)
        let redacted = redact(value)
        let redactedData = try redacted.serializedData(pretty: false)
        let digest = SHA256.hash(data: redactedData)
            .map { String(format: "%02x", $0) }
            .joined()

        let projection: JSONValue
        let truncated: Bool
        if redactedData.count <= maxProjectionBytes {
            projection = redacted
            truncated = false
        } else {
            projection = boundedTruncationEnvelope(data: redactedData, digest: digest)
            truncated = true
        }
        let projectionData = try projection.serializedData(pretty: false)
        return Projection(
            result: projection,
            preview: validUTF8Prefix(projectionData, maxBytes: maxPreviewBytes),
            originalByteCount: originalData.count,
            redactedByteCount: redactedData.count,
            truncated: truncated,
            digest: digest
        )
    }

    static func activityReceipt(
        callID: String,
        receiptID: String,
        serverID: String,
        toolName: String,
        status: String,
        transportOutcome: MCPInvocationOutcome.Kind = .responseReceived,
        durationSeconds: Double,
        createdAt: String,
        projection: Projection
    ) -> JSONValue {
        .object([
            "id": .string(receiptID),
            "kind": .string("mcp_tool"),
            "title": .string("MCP tool call"),
            "detail": .string(String(projection.preview.prefix(400))),
            "status": .string(["error", "failed"].contains(status.lowercased()) ? "warn" : "ok"),
            "executionId": .null,
            "payload": .object([
                "callId": .string(callID),
                "serverId": .string(serverID),
                "toolName": .string(toolName),
                "toolStatus": .string(status),
                "transportOutcome": .string(transportOutcome.rawValue),
                "durationSeconds": .double(durationSeconds),
                "result": projection.result,
                "resultByteCount": .int(Int64(projection.originalByteCount)),
                "redactedByteCount": .int(Int64(projection.redactedByteCount)),
                "resultTruncated": .bool(projection.truncated),
                "resultDigest": .string(projection.digest),
            ]),
            "createdAt": .string(createdAt),
        ])
    }

    static func persist(
        _ receipt: JSONValue,
        to path: URL,
        using persistence: any PersistenceCoreProtocol
    ) async -> WriteOutcome {
        do {
            try await appendJSONLCapped(
                receipt,
                to: path,
                using: persistence,
                logLabel: "NativeClient.MCPToolCall"
            )
            return WriteOutcome(status: "recorded", error: nil)
        } catch {
            return WriteOutcome(
                status: "failed",
                error: NativeAgentSecretRedactor.redactText(error.localizedDescription)
            )
        }
    }

    private static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var redacted: [String: JSONValue] = [:]
            for (key, child) in object {
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                if sensitiveKeyFragments.contains(where: normalized.contains) {
                    redacted[key] = .string("[REDACTED_FIELD]")
                } else {
                    redacted[key] = redact(child)
                }
            }
            return .object(redacted)
        case .array(let values):
            return .array(values.map(redact))
        case .string(let value):
            let redacted = NativeAgentSecretRedactor.redactText(value)
            return .string(TurnSecretRedactor.redactText(redacted))
        default:
            return value
        }
    }

    private static func boundedTruncationEnvelope(data: Data, digest: String) -> JSONValue {
        var previewLimit = min(maxPreviewBytes, data.count)
        while previewLimit >= 0 {
            let candidate: JSONValue = .object([
                "truncated": .bool(true),
                "preview": .string(validUTF8Prefix(data, maxBytes: previewLimit)),
                "sha256": .string(digest),
            ])
            if let encoded = try? candidate.serializedData(pretty: false),
               encoded.count <= maxProjectionBytes {
                return candidate
            }
            if previewLimit == 0 { break }
            previewLimit = max(0, previewLimit - 256)
        }
        return .object([
            "truncated": .bool(true),
            "sha256": .string(digest),
        ])
    }

    private static func validUTF8Prefix(_ data: Data, maxBytes: Int) -> String {
        var end = min(max(0, maxBytes), data.count)
        while end > 0 {
            if let value = String(data: data.prefix(end), encoding: .utf8) {
                return value
            }
            end -= 1
        }
        return ""
    }
}

public enum MCPHubRecentCallState {
    case notLoaded
    case absent
    case durable(MCPCallResult)
    case partial(MCPCallResult?, rejectedRows: Int)
    case sessionOnly(MCPCallResult)
    case latestAttemptFailed(String)
    case unavailable(String)
}


extension MCPResultEvidence {
    private static let readChunkBytes = 65_536
    private static let maximumReceiptBytes = 1_048_576

    private struct ActivityReceiptRow: Decodable {
        let id: String
        let kind: String
        let detail: String?
        let createdAt: String
        let payload: JSONValue?
    }

    public static func readRecentCall(root: URL) throws -> MCPHubRecentCallState {
        let path = root
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return .absent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var rejectedRows = 0
        var reversedLine: [UInt8] = []
        var oversized = false
        func finishLine() -> MCPHubRecentCallState? {
            defer {
                reversedLine.removeAll(keepingCapacity: true)
                oversized = false
            }
            if oversized {
                rejectedRows += 1
                return nil
            }
            guard !reversedLine.isEmpty else { return nil }
            guard let row = try? decoder.decode(ActivityReceiptRow.self, from: Data(reversedLine.reversed())) else {
                rejectedRows += 1
                return nil
            }
            guard row.kind == "mcp_tool" else { return nil }
            guard let result = callResult(from: row) else {
                rejectedRows += 1
                return nil
            }
            return rejectedRows == 0 ? .durable(result) : .partial(result, rejectedRows: rejectedRows)
        }
        do {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            var offset = try handle.seekToEnd()
            // Start at the newest row and stop at the first usable MCP receipt.
            // Both each read and an individual row stay bounded.
            while offset > 0 {
                let count = Int(min(offset, UInt64(readChunkBytes)))
                offset -= UInt64(count)
                try handle.seek(toOffset: offset)
                guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                    return .unavailable("Activity changed while reading its receipts. Refresh to try again.")
                }
                for byte in chunk.reversed() {
                    if byte == 10 || byte == 13 {
                        if let result = finishLine() { return result }
                    } else if !oversized {
                        if reversedLine.count < maximumReceiptBytes { reversedLine.append(byte) }
                        else { oversized = true }
                    }
                }
            }
            if let result = finishLine() { return result }
        }
        return rejectedRows == 0 ? .absent : .partial(nil, rejectedRows: rejectedRows)
    }

    private static func callResult(from row: ActivityReceiptRow) -> MCPCallResult? {
        guard case .object(let payload)? = row.payload,
              case .string(let serverID)? = payload["serverId"],
              case .string(let toolName)? = payload["toolName"],
              case .string(let status)? = payload["toolStatus"]
        else { return nil }
        let callID: String
        if case .string(let value)? = payload["callId"] { callID = value } else { callID = row.id }
        return MCPCallResult(
            id: callID,
            serverId: serverID,
            toolName: toolName,
            status: status,
            approvalId: nil,
            durationSeconds: double(payload["durationSeconds"]),
            createdAt: row.createdAt,
            result: payload["result"],
            resultPreview: row.detail,
            resultByteCount: integer(payload["resultByteCount"]),
            redactedByteCount: integer(payload["redactedByteCount"]),
            resultTruncated: bool(payload["resultTruncated"]),
            resultDigest: string(payload["resultDigest"]),
            receiptId: row.id,
            evidenceStatus: "recorded",
            evidenceError: nil
        )
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let result)? = value else { return nil }
        return result
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let result)? = value else { return nil }
        return result
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let result): return Int(result)
        case .double(let result): return Int(exactly: result)
        default: return nil
        }
    }

    private static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let result): return Double(result)
        case .double(let result): return result
        default: return nil
        }
    }

}
