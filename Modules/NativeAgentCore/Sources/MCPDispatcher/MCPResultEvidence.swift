import Foundation
import CryptoKit
import PersistenceCore
import Privacy
import NativeAgentCore

enum MCPResultEvidence {
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
