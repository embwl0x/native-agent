import Foundation
import NativeAgentCore
import PersistenceCore

public protocol ToolDispatchClient: Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue
    func listAvailableTools() async throws -> [String]
    /// Tool-schema variant. Returns full JSON-Schema descriptors for the same
    /// tools `listAvailableTools()` exposes by name. Threaded through the
    /// LLMClient so the model can emit tool calls. Default implementation
    /// returns `[]` so dispatchers that only know names compile unchanged
    /// (the LLM then sees no tools — pre-tools behavior).
    func listAvailableToolSchemas() async throws -> [LLMToolSchema]
    /// Select the offered contract without collecting unused internal schemas.
    func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema]
}

extension ToolDispatchClient {
    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await listAvailableToolSchemas().filter { names.contains($0.name) }
    }
}

/// Narrow protocol so tests can substitute the trust source without
/// constructing a full SwiftNativeTrustCenter actor.
public protocol AutonomyResolver: Sendable {
    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String
}

/// An engine-owned incomplete terminal, not a provider/transport failure.
/// Preserve the existing reply for the caller's ordinary retained-output cap.
public struct EphemeralToolTurnIncomplete: Error, Sendable {
    public let output: String
    public let reason: String

    public init(output: String, reason: String) {
        self.output = output
        self.reason = reason
    }
}
