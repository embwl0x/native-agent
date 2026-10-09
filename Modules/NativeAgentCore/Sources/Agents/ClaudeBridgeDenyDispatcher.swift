import Foundation
import PersistenceCore
import ChatOrchestration
import ProviderRouting
import NativeAgentCore

/// Compatibility wrapper for bridge construction. Capability discovery and
/// execution use the common consent, risk and Trust gates; the bridge does
/// not decide authority from a tool's namespace.
public final class ClaudeBridgeDenyDispatcher: ToolDispatchClient, BuiltInAgentLaneProviding, PreApprovalToolValidating, @unchecked Sendable {
    private let inner: any ToolDispatchClient

    public init(inner: any ToolDispatchClient) {
        self.inner = inner
    }

    public func builtInAgentLaneUsable(_ name: String) -> Bool {
        (inner as? any BuiltInAgentLaneProviding)?.builtInAgentLaneUsable(name) == true
    }

    public func preApprovalRefusal(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        if let validating = inner as? any PreApprovalToolValidating {
            return await validating.preApprovalRefusal(tool: tool, input: input, surface: surface)
        }
        return await (inner as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input)
    }

    public func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String? {
        await (inner as? any PreApprovalToolValidating)?.approvalCardReason(tool: tool, input: input, surface: surface)
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        try await inner.dispatch(tool: tool, input: input, surface: surface)
    }

    public func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }
}
