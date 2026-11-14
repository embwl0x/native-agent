import ChatTurnRuntime
import ChatTurnContracts
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
// Blueprint: | `PartThoughtTools.swift` | Part thought shares the originating ToolHost and gate chain; retains uncertain effects |

/// Model calls share the JavaScript ToolHost; advertised schemas grant no authority beyond version, dependency and origin gates.
actor PartThoughtTools: ToolDispatchClient {
    let host: any OwnedProgramHostProfile
    let names: [String]
    let execution: OwnedProgramExecution
    private var inFlight = 0
    private var observed: Set<String> = []

    init(host: any OwnedProgramHostProfile, names: [String], execution: OwnedProgramExecution) {
        self.host = host; self.names = names; self.execution = execution
    }

    /// Receipt evidence survives a failed/cancelled provider turn. An effect still awaiting its receipt cannot truthfully be reported as absent.
    var effects: String {
        inFlight > 0 ? "unknown" : ["unknown", "partial", "occurred"].first(where: observed.contains) ?? "none"
    }

    func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        guard Set(names).isSubset(of: ["app"]) else {
            throw SenseFailure(code: "bad_input", message: "model.call's tools names only app; actions remain the part's declared reach.")
        }
        return names
    }
    func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        let offered = Set(try await listAvailableTools(turn: turn, surface: surface))
        return AppToolExecutor.appToolSchemas().filter { offered.contains($0.name) }
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        try Task.checkCancellation()
        guard names.contains(tool), tool == "app" else {
            throw SenseFailure(code: "undeclared_dependency", message: "The thought asked to call something it was not offered.")
        }
        var input = input
        if !host.scriptKey.isEmpty { input[host.scriptKey] = .bool(true) }
        let args = if case .object(let args)? = input["args"] { args } else { [String: JSONValue]() }
        let read = if let id = input["action"]?.stringValue {
            try host.action(id)?.readOnly(args) == true
        } else { input["page"] != nil || input["find"] != nil }
        inFlight += 1
        let userText = execution.turn?.userText
        var execution = execution
        // The thought's prompt is not the originating request's words.
        execution.turn = turn.with(\.userText, userText)
        execution.toolInvocation = invocation
        let receipt = await host.perform(input, execution: execution)
        let fields = if case .object(let fields) = receipt { fields } else { [String: JSONValue]() }
        let effects = OwnedProgramRunner.effects(fields)?.stringValue
        observed.insert(effects.flatMap { ["none", "occurred", "partial", "unknown"].contains($0) ? $0 : nil }
            ?? (read ? "none" : "unknown"))
        inFlight -= 1
        return receipt
    }
}
