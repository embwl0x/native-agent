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
            throw ToolFailureError("MCP server not found: \(serverId)", argumentPath: "server_id", accepted: "an id from app {page:\"mcp\"}", effects: .none)
        }
        let effectiveRisk: String
        switch try await dispatcher.toolAdmission(server: server, toolName: toolName) {
        case .allowed(let risk):
            effectiveRisk = risk
        case .pinRequired:
            let path = await dispatcher.serversPath.path
            throw ToolFailureError("\(path): server '\(serverId)' has no pinned execution identity. Read its command and extras with next_call, then use files.patch to bind the executable and interpreter inputs to installed, versioned files. Reading does not pin it.",
                effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string("files.read"), "args": .object(["path": .string(path)])]))
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
            if let result = Self.localMCPFailure(error, serverId: serverId, toolName: toolName, endpoint: server.endpoint,
                                               configuration: await dispatcher.serversPath.path, read: read) {
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

    static func localMCPFailure(_ error: Error, serverId: String, toolName: String, endpoint: String?, configuration: String, read: Bool) -> JSONValue? {
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
                        "effects": .string(read ? "none" : "unknown"),
                        "detail": .string("Local server for \(serverId) at \(address) is not accepting connections. Its registration is \(configuration)."),
                        "remedy": .object(["kind": .string("inspect"),
                            "instruction": .string("Read the server registration with next_call. Correct a wrong endpoint with files.patch, or start the independently hosted service with its own launch command through shell.run. MCP restart does not start an HTTP service; do not guess its launch command."),
                            "next_call": .object(["tool": .string("app"), "input": .object([
                                "action": .string("files.read"), "args": .object(["path": .string(configuration)])])])])])
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
