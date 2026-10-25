import ChatTurnRuntime
import ChatTurnContracts
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
// Blueprint: | `PartThoughtTools.swift` | Restricted app-tool dispatcher for a part's thought, through its exact ToolHost and originating gate chain, with no independent effect authority; aggregates canonical nested receipt effects, including unknown in-flight effects, through thought failure/cancellation |

/// The model reaches exactly the same host as the part's JavaScript. An app
/// schema advertises a vocabulary, never authority; ToolHost still checks the
/// selected version, declared dependencies and originating gate at every effect.
actor PartThoughtTools: ToolDispatchClient {
    let host: any OwnedProgramHostProfile
    let names: [String]
    let userText: String?
    private var inFlight = 0
    private var observed: Set<String> = []

    init(host: any OwnedProgramHostProfile, names: [String], userText: String?) {
        self.host = host; self.names = names; self.userText = userText
    }

    /// Receipt evidence survives a failed/cancelled provider turn. An effect
    /// still awaiting its receipt cannot truthfully be reported as absent.
    var effects: String {
        inFlight > 0 ? "unknown" : ["unknown", "partial", "occurred"].first(where: observed.contains) ?? "none"
    }

    func listAvailableTools() async throws -> [String] {
        guard Set(names).isSubset(of: ["app"]) else {
            throw SenseFailure(code: "bad_input", message: "model.call tools names the app tool; actions remain the part's declared reach.")
        }
        return names
    }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let offered = Set(try await listAvailableTools())
        return AppToolExecutor.appToolSchemas().filter { offered.contains($0.name) }
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        try Task.checkCancellation()
        guard names.contains(tool), tool == "app" else {
            throw SenseFailure(code: "undeclared_dependency", message: "The thought requested a tool it was not offered.")
        }
        var input = input
        if !host.scriptKey.isEmpty { input[host.scriptKey] = .bool(true) }
        let args = if case .object(let args)? = input["args"] { args } else { [String: JSONValue]() }
        let read = if let id = input["action"]?.stringValue {
            host.action(id)?.readOnly(args) == true
        } else { input["page"] != nil || input["find"] != nil }
        inFlight += 1
        let receipt = await ChatToolSessionContext.$userText.withValue(userText) { await host.perform(input) }
        let fields = if case .object(let fields) = receipt { fields } else { [String: JSONValue]() }
        let effects = OwnedProgramRunner.effects(fields)?.stringValue
        observed.insert(effects.flatMap { ["none", "occurred", "partial", "unknown"].contains($0) ? $0 : nil }
            ?? (read ? "none" : "unknown"))
        inFlight -= 1
        return receipt
    }
}
