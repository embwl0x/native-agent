import NativeAgentCore
import PersistenceCore

public struct ToolDispatchRecord: Sendable {
    /// Provider-issued tool-use identity when the transport supplied one.
    /// Outcome Tissue hashes this before persistence; nil remains an
    /// explicit sequence-only observation for legacy/direct dispatches.
    public let id: String?
    public let name: String
    public let input: [String: JSONValue]
    /// Resolved before execution; later registry changes cannot rewrite the call.
    public let ranCall: (tool: String, input: [String: JSONValue])
    public let result: JSONValue

    public init(
        id: String? = nil,
        name: String,
        input: [String: JSONValue],
        ranCall: (tool: String, input: [String: JSONValue]),
        result: JSONValue
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.ranCall = ranCall
        self.result = result
    }
}
