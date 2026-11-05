import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ToolTurnContracts.swift` | `ToolDispatchClient`: `dispatch`, `listAvailableTools`, `listAvailableToolSchemas` |

/// One dispatch shape for catalogs, gates and profiles. The caller supplies
/// its operation explicitly; no smaller overload can discard it in a wrapper.
public protocol ToolDispatchClient: Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue
    func listAvailableTools(turn: Turn?, surface: String) async throws -> [String]
    /// Every dispatcher supplies its actual schema contract, including an explicit empty contract, so the model sees only offered tools.
    func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema]
    func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema]
}

extension ToolDispatchClient {
    public func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await listAvailableToolSchemas(turn: turn, surface: surface).filter { names.contains($0.name) }
    }
}

/// Engine incompleteness preserves the reply for the caller's retained-output cap; it is not a transport failure.
public struct EphemeralToolTurnIncomplete: Error, Sendable {
    public let output: String
    public let reason: String

    public init(output: String, reason: String) {
        self.output = output
        self.reason = reason
    }
}
