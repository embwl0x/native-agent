import Foundation
import Observation
import Darwin
import AppKit
import CryptoKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
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
                error: WorkflowRedaction.redactText(error.localizedDescription)
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
            return .string(WorkflowRedaction.redactText(value))
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

// W-H Band (U5 decomposition, move-only): MCP live ops
// (callMCPTool / warm / restart / refreshCache / consent grant+revoke),
// relocated verbatim into a same-module extension. Four documented
// fileprivate/private→internal lifts in the root file keep the moved code
// reaching its helpers: jsonValueBody, swiftGrantMCPConsent,
// swiftListMCPSessions, swiftRevokeMCPConsent.
extension NativeClient {
    func callMCPTool(serverId: String, toolName: String, input: [String: Any]) async throws -> MCPCallResult {
        let callID = UUID().uuidString.lowercased()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let started = Date()
        let dispatcher = SwiftNativeMCPDispatcher(root: PersistenceCore.defaultDataRoot())
        let servers = try await dispatcher.listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw NSError(domain: "NativeAgentMCP", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "MCP server not found: \(serverId)"
            ])
        }
        let consents = try await dispatcher.listConsents()
        let effectiveRisk = MCPToolBridge.effectiveRiskClass(
            serverId: serverId,
            toolName: toolName,
            serverRiskClass: server.riskClass,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
        let hasConsent = consents.contains {
            $0.serverId == serverId
                && $0.toolName == toolName
                && MCPToolBridge.consent($0, matchesCurrentEffectiveRisk: effectiveRisk)
        }
        if !hasConsent {
            if MCPToolBridge.riskRequiresApproval(effectiveRisk) {
                return MCPCallResult(
                    id: callID,
                    serverId: serverId,
                    toolName: toolName,
                    status: "needs_approval",
                    approvalId: nil,
                    durationSeconds: Date().timeIntervalSince(started),
                    createdAt: createdAt,
                    evidenceStatus: "not_required"
                )
            }
            _ = try await dispatcher.grantConsent(MCPConsentGrant(
                serverId: serverId,
                toolName: toolName,
                risk: effectiveRisk,
                argumentSummary: "Auto-granted low-risk local Swift MCP call."
            ))
        }

        let args = try Self.jsonValueBody(input)
        let result = try await dispatcher.callToolLive(
            forServer: serverId,
            toolName: toolName,
            arguments: .object(args)
        )
        let outcome = MCPInvocationOutcome.classify(response: result)
        let status = outcome.displayStatus
        let duration = Date().timeIntervalSince(started)
        let projection = try MCPResultEvidence.project(result)
        let receiptID = UUID().uuidString.lowercased()
        let receipt = MCPResultEvidence.activityReceipt(
            callID: callID,
            receiptID: receiptID,
            serverID: serverId,
            toolName: toolName,
            status: status,
            transportOutcome: outcome.kind,
            durationSeconds: duration,
            createdAt: createdAt,
            projection: projection
        )
        let activityPath = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        // The external/local MCP call may already have produced effects.
        // Never relabel it as failed merely because its evidence append failed;
        // carry the distinct evidence outcome back to the UI.
        let evidence = await MCPResultEvidence.persist(
            receipt,
            to: activityPath,
            using: SwiftNativePersistenceCore()
        )
        return MCPCallResult(
            id: callID,
            serverId: serverId,
            toolName: toolName,
            status: status,
            approvalId: nil,
            durationSeconds: duration,
            createdAt: createdAt,
            result: projection.result,
            resultPreview: projection.preview,
            resultByteCount: projection.originalByteCount,
            redactedByteCount: projection.redactedByteCount,
            resultTruncated: projection.truncated,
            resultDigest: projection.digest,
            receiptId: evidence.status == "recorded" ? receiptID : nil,
            evidenceStatus: evidence.status,
            evidenceError: evidence.error
        )
    }

    func warmMCPServer(serverId: String) async throws -> MCPSessionStatus {
        let dispatcher = SwiftNativeMCPDispatcher(root: SwiftNativeMCPDispatcher.defaultDataRoot())
        _ = try await dispatcher.listToolsLive(forServer: serverId, cached: false)
        return try await swiftMCPSessionStatus(serverId: serverId)
    }

    func restartMCPServer(serverId: String) async throws -> MCPSessionStatus {
        await SwiftNativeMCPDispatcher.sharedPool.stop(serverId: serverId)
        let dispatcher = SwiftNativeMCPDispatcher(root: SwiftNativeMCPDispatcher.defaultDataRoot())
        _ = try await dispatcher.listToolsLive(forServer: serverId, cached: false)
        return try await swiftMCPSessionStatus(serverId: serverId)
    }

    func refreshMCPCache(serverId: String) async throws -> MCPSessionStatus {
        let dispatcher = SwiftNativeMCPDispatcher(root: SwiftNativeMCPDispatcher.defaultDataRoot())
        _ = try await dispatcher.listToolsLive(forServer: serverId, cached: false)
        _ = try? await dispatcher.listResourcesLive(forServer: serverId, cached: false)
        return try await swiftMCPSessionStatus(serverId: serverId)
    }

    private func swiftMCPSessionStatus(serverId: String) async throws -> MCPSessionStatus {
        let rows = try await swiftListMCPSessions()
        if let row = rows.first(where: { $0.serverId == serverId }) {
            return row
        }
        return MCPSessionStatus(
            id: serverId,
            serverId: serverId,
            serverName: nil,
            transport: nil,
            status: "idle",
            healthStatus: "not_checked",
            toolCount: 0,
            resourceCount: 0,
            lastWarmedAt: nil,
            lastError: nil,
            updatedAt: nil
        )
    }

    func grantMCPConsent(serverId: String, toolName: String, risk: String?) async throws -> MCPConsentRecord {
        // Wave 31 W02: RE-ENABLED. The W31 prereq closer wrapped the full
        // read-modify-write of mcp/consent/ledger.json in a cross-process
        // flock on BOTH sides — SwiftNativeMCPDispatcher._grantImpl now runs
        // under persistence.withFileLock(consentLedgerPath) and the daemon's
        // grant_mcp_consent / revoke_mcp_consent run under
        // file_lock(self.mcp_consent_path) (file_lock.py <->
        // PersistenceCore+FileLock.swift, same `<path>.lock` sibling). With
        // one lock spanning read→write on every writer, concurrent app-side
        // grants AND the daemon's auto-grant on tool execution serialize
        // instead of clobbering — so per-call dispatcher instances (each with
        // their own mutationTail) are safe. Gate consent grant through
        // SwiftNativeMCPDispatcher when .mcpDispatcher is on. The module writes
        // the SAME record shape the daemon's grant_mcp_consent produces
        // (id = "<serverId>:<toolName>", verified vs the retired daemon).
        return try await swiftGrantMCPConsent(serverId: serverId, toolName: toolName, risk: risk)
    }

    func revokeMCPConsent(id: String, serverId: String?, toolName: String?) async throws -> MCPConsentRecord {
        // Wave 31 W02: RE-ENABLED alongside grantMCPConsent — the cross-process
        // flock now spans the full R-M-W on both sides (see grantMCPConsent's
        // comment for the prereq detail). Gate consent revoke through
        // SwiftNativeMCPDispatcher when .mcpDispatcher is on. The module resolves
        // the ledger row by id == "<serverId>:<toolName>" only — it has NO
        // revoke-by-arbitrary-id path. The daemon's revoke_mcp_consent
        // resolves by body.id FIRST, falling back to
        // mcp_consent_key(server,tool). For every record the current daemon
        // creates these are identical (grant stamps id = "<serverId>:<toolName>",
        // the retired daemon — verified against a live daemon boot). To
        // guarantee the Swift path can NEVER revoke a different row than the HTTP
        // path would, gate ONLY when the caller's `id` exactly equals the
        // reconstructed key. Any stale/legacy record whose id diverges from
        // "<serverId>:<toolName>" (or a caller that knows only `id`) falls
        // through to HTTP, which resolves by id. (gpt-5.5 review MAJOR, wave 30 W09.)
        if let serverId, !serverId.isEmpty,
           let toolName, !toolName.isEmpty,
           id == "\(serverId):\(toolName)" {
            return try await swiftRevokeMCPConsent(serverId: serverId, toolName: toolName)
        }
        // Swift-native cutover sweep s3: id-only form — list consents and resolve the
        // row by id (matching the daemon's body.id-first fallback). The ledger
        // R-M-W is already flock-guarded inside swiftRevokeMCPConsent.
        let disp = makeMCPDispatcher()
        let consents = try await disp.listConsents()
        guard let match = consents.first(where: { $0.id == id }),
              !match.serverId.isEmpty,
              !match.toolName.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -404,
                          userInfo: [NSLocalizedDescriptionKey: "revokeMCPConsent: consent id \(id) not found"])
        }
        return try await swiftRevokeMCPConsent(serverId: match.serverId, toolName: match.toolName)
    }
}
