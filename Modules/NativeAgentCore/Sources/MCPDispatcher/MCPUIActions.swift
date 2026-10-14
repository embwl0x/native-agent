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
    public static func consentRisk(server: MCPServer, toolName: String, dataRoot: URL) -> String {
        MCPToolBridge.effectiveRiskClass(
            serverId: server.id, toolName: toolName,
            serverRiskClass: server.riskClass, dataRoot: dataRoot
        )
    }

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

    public static func callMCPTool(serverId: String, toolName: String, input: [String: JSONValue], dataRoot: URL, authority: MCPUIActionAuthority) async throws -> MCPCallResult {
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
        let parsed = try JSONValue.parse(JSONEncoder().encode(input))
        let args: [String: JSONValue]
        if case .object(let object) = parsed { args = object } else { args = [:] }
        let admission = try await dispatcher.toolAdmission(
            server: server, toolName: toolName, surface: "mcp_ui", presentsApproval: true,
            fullMacYoloAdmitted: authority.fullMacYoloAdmitted
        )
        switch admission {
        case .allowed:
            break
        case .unpinned:
            throw authority.deniedError(
                "MCP tool '\(serverId)/\(toolName)' has unpinned consent; resolve/pin its implementation and explicitly grant consent again"
            )
        case .revoked, .requiresApproval:
            let explicitlyRevoked: Bool
            if case .revoked = admission { explicitlyRevoked = true } else { explicitlyRevoked = false }
            let approvalID = explicitlyRevoked ? nil : try await authority.fileApprovalRequest(
                "mcp__\(serverId)__\(toolName)", "mcp_ui", .object(args),
                "This MCP tool requires approval."
            )
            return MCPCallResult(
                id: callID,
                serverId: serverId,
                toolName: toolName,
                status: explicitlyRevoked ? "blocked" : "needs_approval",
                approvalId: approvalID,
                durationSeconds: Date().timeIntervalSince(started),
                createdAt: createdAt,
                evidenceStatus: "not_required"
            )
        case .pinRequired, .unpinnedGrant:
            throw authority.deniedError("MCP server '\(serverId)' could not be pinned; resolve its implementation and explicitly grant consent again")
        }

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

extension MCPUIActions {
    public static func validationMessage(
        schema: JSONValue?,
        values: [String: JSONValue]
    ) -> String? {
        guard let schema else { return nil }
        guard case .object(let root) = schema else {
            return "This tool's input schema is unavailable because it is not an object."
        }

        let properties: [String: JSONValue]
        if let rawProperties = root["properties"] {
            guard case .object(let decodedProperties) = rawProperties else {
                return "This tool's input schema has malformed properties."
            }
            properties = decodedProperties
        } else {
            properties = [:]
        }

        let required: [String]
        if let rawRequired = root["required"] {
            guard case .array(let values) = rawRequired,
                  values.allSatisfy({ if case .string = $0 { return true } else { return false } })
            else {
                return "This tool's input schema has malformed required fields."
            }
            required = values.compactMap { if case .string(let field) = $0 { return field } else { return nil } }
        } else {
            required = []
        }

        for field in required {
            guard values[field] != nil else {
                return "Enter a value for required field ‘\(displayField(field))’."
            }
        }

        for (field, value) in values {
            let propertySchema: JSONValue
            if let declaredSchema = properties[field] {
                propertySchema = declaredSchema
            } else {
                switch root["additionalProperties"] {
                case nil, .bool(true)?:
                    continue
                case .bool(false)?:
                    return "Input field ‘\(displayField(field))’ is not accepted by this tool."
                case .object(let additionalSchema)?:
                    propertySchema = .object(additionalSchema)
                default:
                    return "This tool's input schema has malformed additional properties."
                }
            }
            if let reason = propertyValidationMessage(value: value, schema: propertySchema) {
                return "Input ‘\(displayField(field))’ \(reason)."
            }
        }
        return nil
    }

    private static func propertyValidationMessage(
        value: JSONValue,
        schema: JSONValue
    ) -> String? {
        guard case .object(let object) = schema else {
            return "has an unavailable schema"
        }

        for keyword in ["anyOf", "oneOf"] {
            if let union = object[keyword] {
                guard case .array(let branches) = union, !branches.isEmpty else {
                    return "has a malformed \(keyword) schema"
                }
                let matches = branches.filter { propertyValidationMessage(value: value, schema: $0) == nil }.count
                guard keyword == "oneOf" ? matches == 1 : matches > 0 else {
                    return "does not match the \(keyword) schema"
                }
            }
        }

        if case .array(let options)? = object["enum"], !options.isEmpty,
           !options.contains(value) {
            return "is not one of the allowed values"
        }

        guard let rawType = object["type"] else { return nil }
        let types: [String]
        switch rawType {
        case .string(let type):
            types = [type]
        case .array(let values):
            guard values.allSatisfy({ if case .string = $0 { return true } else { return false } }) else {
                return "has a malformed type schema"
            }
            types = values.compactMap { if case .string(let type) = $0 { return type } else { return nil } }
        default:
            return "has a malformed type schema"
        }

        guard !types.isEmpty,
              types.count <= 8,
              types.allSatisfy({ !$0.isEmpty && $0.count <= 40 }),
              types.allSatisfy({ ["null", "boolean", "string", "integer", "number", "array", "object"].contains($0) })
        else { return "has an unavailable type schema" }
        guard types.contains(where: { valueMatchesType(value, type: $0) }) else {
            return "must be \(types.joined(separator: " or "))"
        }
        if types.contains("integer"), case .int(let integer) = value,
           let (minimum, maximum) = integerBounds(schema),
           !(Int64(minimum)...Int64(maximum)).contains(integer) {
            return "must be between \(minimum) and \(maximum)"
        }
        return nil
    }

    private static func valueMatchesType(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string),
             ("integer", .int), ("number", .int), ("array", .array), ("object", .object):
            return true
        case ("number", .double(let value)):
            return value.isFinite
        default:
            return false
        }
    }

    private static func displayField(_ field: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "unnamed" : trimmed).prefix(80))
    }


    public static func integerBounds(_ propSchema: JSONValue) -> (Int, Int)? {
        guard case .object(let obj) = propSchema else { return nil }
        func asInt(_ v: JSONValue?) -> Int? {
            guard let v = v else { return nil }
            switch v {
            case .int(let i): return Int(i)
            case .double(let d): return Int(exactly: d.rounded(.towardZero))
            default: return nil
            }
        }
        guard let lo = asInt(obj["minimum"]), let hi = asInt(obj["maximum"]), lo <= hi else { return nil }
        return (lo, hi)
    }
}
