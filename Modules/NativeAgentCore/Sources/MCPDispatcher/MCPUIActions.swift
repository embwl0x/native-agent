import Foundation
import PersistenceCore
import TrustCenter

public struct MCPUIActionAuthority: Sendable {
    public let fullMacYoloAdmitted: @Sendable (String, String) async -> Bool
    public let deniedError: @Sendable (String) -> any Error
    public let fileApprovalRequest: @Sendable (String, String, JSONValue, String) async throws -> String
    public init(
        fullMacYoloAdmitted: @escaping @Sendable (String, String) async -> Bool,
        deniedError: @escaping @Sendable (String) -> any Error,
        fileApprovalRequest: @escaping @Sendable (String, String, JSONValue, String) async throws -> String
    ) {
        self.fullMacYoloAdmitted = fullMacYoloAdmitted
        self.deniedError = deniedError
        self.fileApprovalRequest = fileApprovalRequest
    }
}

public enum MCPUIActions {
    public static func evaluateMCPUIAdmission(
        serverId: String, toolName: String, arguments: [String: JSONValue], dataRoot: URL
    ) async -> SecurityToolEnvelope {
        let security = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        let envelope = await security.evaluateTool(
            tool: "mcp__\(serverId)__\(toolName)", input: arguments,
            origin: SecurityOriginContext(surface: "mcp_ui"), enforceAutonomy: true
        )
        try? await security.record(envelope)
        return envelope
    }

    public static func callMCPTool(serverId: String, toolName: String, input: [String: Any], dataRoot: URL, authority: MCPUIActionAuthority) async throws -> MCPCallResult {
        let callID = UUID().uuidString.lowercased()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let started = Date()
        let dispatcher = SwiftNativeMCPDispatcher(root: dataRoot)
        let servers = try await dispatcher.listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw NSError(domain: "NativeAgentMCP", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "MCP server not found: \(serverId)"
            ])
        }
        let consents = try await dispatcher.listConsents()
        let unpinnedGrant = consents.first {
            $0.serverId == serverId && $0.toolName == toolName && $0.unpinned
                && $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "granted"
        }
        let hasUnpinnedGrant = unpinnedGrant != nil
        let effectiveRisk = MCPToolBridge.effectiveRiskClass(
            serverId: serverId,
            toolName: toolName,
            serverRiskClass: server.riskClass,
            dataRoot: dataRoot
        )
        let hasConsent = consents.contains {
            $0.serverId == serverId
                && $0.toolName == toolName
                && MCPToolBridge.consent($0, matchesCurrentEffectiveRisk: effectiveRisk)
        }
        if !hasConsent {
            let yoloAdmitted = await authority.fullMacYoloAdmitted(
                "mcp__\(serverId)__\(toolName)",
                "mcp_ui"
            )
            // Full Mac already supplies authority for this call. Legacy metadata
            // may be repaired only by resolving the real current implementation.
            if hasUnpinnedGrant && !yoloAdmitted {
                throw authority.deniedError(
                    "MCP tool '\(serverId)/\(toolName)' has unpinned consent; resolve/pin its implementation and explicitly grant consent again"
                )
            }
            let explicitlyRevoked = consents.contains {
                $0.serverId == serverId && $0.toolName == toolName
                    && $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "revoked"
            }
            if explicitlyRevoked || (MCPToolBridge.riskRequiresApproval(effectiveRisk) && !yoloAdmitted) {
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
            if yoloAdmitted {
                guard try server.pinnedExecutionIdentity() != nil else {
                    throw authority.deniedError("MCP server '\(serverId)' could not be pinned; resolve its implementation and explicitly grant consent again")
                }
            }
            if !MCPToolBridge.riskRequiresApproval(effectiveRisk) || (yoloAdmitted && hasUnpinnedGrant) {
                let grant = try await dispatcher.grantConsent(MCPConsentGrant(
                    serverId: serverId,
                    toolName: toolName,
                    scope: unpinnedGrant?.scope ?? "server_tool",
                    risk: effectiveRisk,
                    permissions: unpinnedGrant?.permissions ?? [],
                    argumentSummary: hasUnpinnedGrant
                        ? "Renewed legacy MCP consent under admitted Full Mac authority using the current resolved implementation."
                        : "Auto-granted low-risk local Swift MCP call."
                ))
                guard !grant.unpinned else {
                    throw authority.deniedError("MCP server '\(serverId)' could not be pinned; resolve its implementation and explicitly grant consent again")
                }
            }
        }

        let parsed = try JSONValue.parse(JSONSerialization.data(withJSONObject: input, options: []))
        let args: [String: JSONValue]
        if case .object(let object) = parsed { args = object } else { args = [:] }
        let envelope = await Self.evaluateMCPUIAdmission(
            serverId: serverId, toolName: toolName, arguments: args, dataRoot: dataRoot
        )
        guard envelope.decision == .allow else {
            let approvalID: String?
            if envelope.decision == .ask {
                approvalID = try await authority.fileApprovalRequest(
                    envelope.tool, envelope.surface,
                    .object(args), envelope.primaryReason
                )
            } else {
                approvalID = nil
            }
            return MCPCallResult(
                id: callID, serverId: serverId, toolName: toolName,
                status: envelope.decision == .ask ? "needs_approval" : "blocked",
                approvalId: approvalID, durationSeconds: Date().timeIntervalSince(started),
                createdAt: createdAt, evidenceStatus: "not_required"
            )
        }
        let result = try await dispatcher.callToolLive(
            forServer: serverId, toolName: toolName, arguments: .object(args)
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
        let activityPath = dataRoot
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

}
