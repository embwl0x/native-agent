import Foundation
import  PersistenceCore
import NativeAgentCore
import NativeAgentShared
import ChatToolParsing
import ChatTurnContracts
import TurnTrace
// Blueprint: | `ExpansionDispatcher.swift` | `ExpansionDispatcher`: outermost gated door; bounded speculative reads and act previews from the caller’s own admitted practice |

/// The outermost node of every gated chain: a mind's call goes through the
/// whole chain as before, and its result comes back carrying what its own
/// practice says it looks at next. Calls made inside a call (a batch, a
/// script, a part) re-enter the chain below this node and are the call's own.
final class ExpansionDispatcher: ToolDispatchClient {
    private let inner: any ToolDispatchClient
    private let dataRoot: URL
    private let session: String?
    /// Inside a call this node already took: a chain built within it is that call's.
    @TaskLocal static var inside = false

    init(inner: any ToolDispatchClient, dataRoot: URL, session: String?) {
        self.inner = inner
        self.dataRoot = dataRoot
        self.session = session
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard !Self.inside, let caller = Expansion.Caller.current(dataRoot: dataRoot, session: session, surface: surface) else {
            return try await inner.dispatch(tool: tool, input: input, surface: surface)
        }
        return try await Self.$inside.withValue(true) {
            try await self.expanding(caller, tool: tool, input: input, surface: surface)
        }
    }

    private func expanding(_ caller: Expansion.Caller, tool: String, input: [String: JSONValue],
                           surface: String) async throws -> JSONValue {
        let expansion = Expansion.shared
        let arrived = Date()
        let first = await expansion.arrive(caller, tool: tool, input: input, at: arrived)
        let result: JSONValue
        do {
            result = try await inner.dispatch(tool: tool, input: input, surface: surface)
        } catch {
            await expansion.broke(caller)
            throw error
        }
        let returned = Date()
        await expansion.ran(caller, seconds: returned.timeIntervalSince(arrived))
        // Only an object result can carry anything, and not one parked on a person or a stopped turn.
        let carries: Bool = if case .object = result { !ChatToolOutcome.isWaitingOnPerson(result) && !Task.isCancelled } else { false }
        var plan = await expansion.consider(caller, tool: tool, input: input, result: result, first: first,
                                            at: returned, deliver: carries)
        guard carries, case .object(var fields) = result else { return result }
        var looked: [JSONValue] = []
        var ready: [JSONValue] = []
        var depth = 0
        while let next = plan {
            depth += 1
            plan = nil
            var call = next.call
            if let session = input["__session_id"] { call["__session_id"] = session }
            if next.nature == .act { call["preview"] = .bool(true) }
            let sent = call
            let inner = self.inner
            // The call's own result is never lost or late: a delivery takes at
            // most half of what the enclosing ceiling still leaves (the other
            // half returns the result), never more than the round it saves,
            // and does not start when its usual run would not fit.
            let budget = min(next.within, TurnDeadline.secondsLeft.map { $0 / 2 } ?? .infinity)
            guard budget >= next.expected else {
                await expansion.delivered(caller, invocation: next.invocation, landed: nil, seconds: nil)
                break
            }
            let started = Date()
            let got = await TurnDeadline.withDeadline(seconds: budget, clock: .wallClock) {
                try await TurnTraceContext.$automaticOrigin.withValue("expansion") {
                    try await inner.dispatch(tool: "app", input: sent, surface: surface)
                }
            }
            let seconds = Date().timeIntervalSince(started)
            var landed: JSONValue?
            if let got, case .object(let receipt) = got, ChatToolOutcome.outputLooksSuccessful(got),
               !ChatToolOutcome.isWaitingOnPerson(got), receipt["would_refuse"] == nil {
                var entry: [String: JSONValue] = ["call": .object(next.call)]
                // Learned only from turns these principals steered: said so wherever it is shown.
                if !caller.steered.isEmpty { entry["steered_by"] = .array(caller.steered.map(JSONValue.string)) }
                entry[next.nature == .act ? "preview" : "result"] = got
                var carried = fields
                if next.nature == .act { carried["ready_to_confirm"] = .array(ready + [.object(entry)]) }
                else { carried["already_looked"] = .array(looked + [.object(entry)]) }
                // It rides only where the whole result still fits the provider's inline ceiling.
                let size = (try? JSONValue.object(carried).serialize(pretty: false))?.utf8.count ?? .max
                if size <= ProviderToolResultPage.defaultMaxUTF8Bytes {
                    landed = got
                    fields = carried
                    if next.nature == .act { ready.append(.object(entry)) } else { looked.append(.object(entry)) }
                }
            }
            await expansion.delivered(caller, invocation: next.invocation, landed: landed, seconds: seconds)
            guard let landed else { break }
            TurnTraceBus.fireFromContext(kind: "mind.why", payload: next.why)
            guard next.nature == .read else { break }
            // The read she now has is the step her next call follows.
            plan = await expansion.consider(caller, tool: "app", input: next.call, result: landed, first: false, at: Date(),
                                            deliver: !Task.isCancelled && depth < Expansion.Law.chain)
        }
        return .object(fields)
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }
}
