import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import Research
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftToolDispatcher {
    static func parseMCPToolName(_ bridged: String) -> (serverId: String, toolName: String)? {
        guard bridged.hasPrefix("mcp__") else { return nil }
        let rest = String(bridged.dropFirst("mcp__".count))
        guard let sep = rest.range(of: "__") else { return nil }
        let serverId = String(rest[..<sep.lowerBound])
        let toolName = String(rest[sep.upperBound...])
        guard !serverId.isEmpty, !toolName.isEmpty else { return nil }
        return (serverId, toolName)
    }

    /// Remove chat-only routing metadata before a strict remote MCP schema sees
    /// the arguments. Kept as a pure production seam so this boundary can be
    /// proved without starting a server or touching the user's MCP config.
    static func forwardedMCPArguments(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var forwarded = input
        forwarded["__session_id"] = nil
        return forwarded
    }

    func impl_mcp_tool(
        serverId: String,
        toolName: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        // The detached catalog can be cold while a configured server is callable.
        // Validate authority here, then let the live path establish transport.
        let dispatcher = SwiftNativeMCPDispatcher(root: dataRoot)
        let servers = try await dispatcher.listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw AutonomyGateError.toolDenied(reason: "MCP server not found: \(serverId)")
        }
        guard server.status != "needs_setup", server.status != "error" else {
            throw AutonomyGateError.toolDenied(reason: "MCP server unavailable: \(serverId) (\(server.status))")
        }
        let admission = try await dispatcher.toolAdmission(
            server: server, toolName: toolName, surface: surface, presentsApproval: false
        ) { [self] tool, surface in
            await fullMacYoloAdmitted(tool: tool, surface: surface)
        }
        let effectiveRisk: String
        switch admission {
        case .allowed(let risk):
            effectiveRisk = risk
        case .revoked:
            throw AutonomyGateError.toolDenied(
                reason: "MCP tool '\(serverId)/\(toolName)' consent was revoked; explicitly grant consent before execution"
            )
        case .unpinned:
            throw AutonomyGateError.toolDenied(
                reason: "MCP tool '\(serverId)/\(toolName)' has unpinned consent; resolve/pin its implementation and explicitly grant consent again"
            )
        case .requiresApproval(let risk):
            let effectiveRisk = risk
            throw AutonomyGateError.toolDenied(
                reason: "MCP tool '\(serverId)/\(toolName)' requires approval before Swift execution (risk=\(effectiveRisk))"
            )
        case .pinRequired:
            throw AutonomyGateError.toolDenied(reason: "MCP server '\(serverId)' could not be pinned; resolve its implementation and explicitly grant consent again")
        case .unpinnedGrant:
            throw AutonomyGateError.toolDenied(reason: "MCP server '\(serverId)' could not be pinned; resolve its implementation and explicitly grant consent again. For a public web page, read_page needs no consent.")
        }
        // Strip the chat-surface session marker before forwarding: it's
        // injected into EVERY tool input for the lazy-load gate, and remote
        // MCP servers with strict schemas (additionalProperties: false)
        // reject calls carrying unknown keys.
        let forwarded = Self.forwardedMCPArguments(input)
        let read = !MCPToolBridge.riskRequiresApproval(effectiveRisk)
        do {
            let result = try await dispatcher.callToolLive(
                forServer: serverId, toolName: toolName, arguments: .object(forwarded)
            )
            return Self.explainedMCPFailure(result, serverId: serverId, toolName: toolName, read: read)
        } catch {
            if let result = Self.localMCPFailure(error, serverId: serverId, toolName: toolName, endpoint: server.endpoint) {
                return result
            }
            if read {
                return .object([
                    "status": .string("failed"), "effects": .string("none"),
                    "error": .string(ChatToolOutcome.errorMessage(error)),
                    "message": .string("MCP \(serverId)/\(toolName) failed: \(ChatToolOutcome.errorMessage(error)) \(Self.readFailureNextStep)"),
                ])
            }
            return .object([
                "status": .string("failed"),
                "error": .string(ChatToolOutcome.errorMessage(error)),
                "message": .string("MCP \(serverId)/\(toolName) failed: outcome unknown — inspect before retry. Check the server connection and its original receipt before another call."),
            ])
        }
    }

    /// A tool whose effect is a read changed nothing when it failed.
    static let readFailureNextStep = "Nothing changed (it only reads); retry it or try another way."

    static func explainedMCPFailure(_ result: JSONValue, serverId: String, toolName: String, read: Bool) -> JSONValue {
        guard MCPInvocationOutcome.classify(response: result).providerToolResultIsError,
              case .object(var outer) = result else { return result }
        if read { outer["effects"] = .string("none") }
        let payload: [String: JSONValue]
        if case .object(let nested)? = outer["result"] { payload = nested }
        else { payload = outer }
        // A remote refusal that already speaks for itself stays byte-for-byte intact.
        func hasOwnWords(_ value: [String: JSONValue]) -> Bool {
            ["spoken", "message"].contains {
                if case .string(let words)? = value[$0] {
                    let clean = words.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !clean.isEmpty && clean.range(of: "^[A-Za-z][A-Za-z0-9_.-]*$", options: .regularExpression) == nil
                }
                return false
            }
        }
        if hasOwnWords(outer) || hasOwnWords(payload) { return .object(outer) }
        func hasReadableText(_ value: JSONValue?) -> Bool {
            switch value {
            case .string(let words):
                let clean = words.trimmingCharacters(in: .whitespacesAndNewlines)
                return !clean.isEmpty && clean.range(of: "^[A-Za-z][A-Za-z0-9_.-]*$", options: .regularExpression) == nil
            case .object(let value):
                return hasReadableText(value["text"])
                    || hasReadableText(value["detail"])
            case .array(let values): return values.contains { hasReadableText($0) }
            default: return false
            }
        }
        let nextStep = read ? Self.readFailureNextStep
            : "outcome unknown — inspect before retry. Check the server's original result and current state before another call."
        if !hasReadableText(payload["content"]), !hasReadableText(payload["detail"]) {
            outer["message"] = .string("MCP \(serverId)/\(toolName) reported an error: \(nextStep)")
        } else if case .string(let code)? = outer["message"] ?? payload["message"],
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A bare code beside readable content still needs the next step.
            outer["message"] = .string("MCP \(serverId)/\(toolName) reported \(code.trimmingCharacters(in: .whitespacesAndNewlines)): \(nextStep)")
        }
        if outer["hint"] == nil { outer["hint"] = .string(nextStep) }
        return .object(outer)
    }

    static func localMCPFailure(_ error: Error, serverId: String, toolName: String, endpoint: String?) -> JSONValue? {
        let address: String
        if case ResearchClientError.localServerNotRunning(let url) = error {
            address = url
        } else if let endpoint, let url = URL(string: endpoint),
                  ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""),
                  (error as? URLError)?.code == .cannotConnectToHost {
            address = endpoint
        } else { return nil }
        return .object(["status": .string("failed"), "server": .string(serverId),
                        "reason": .string("server_not_running"),
                        "detail": .string("Local server for \(serverId) at \(address) is not running. Start or reconnect that server, then retry.")])
    }

    func fullMacYoloAdmitted(tool: String, surface: String) async -> Bool {
        await ChatFullMacYoloAdmission.admitted(
            tool: tool,
            surface: surface,
            dataRoot: dataRoot,
            source: "swift_tool_dispatcher"
        )
    }

}
