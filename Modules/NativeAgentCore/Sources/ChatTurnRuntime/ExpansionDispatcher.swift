import Foundation
import  PersistenceCore
import NativeAgentCore
import NativeAgentShared
import ChatToolParsing
import ChatTurnContracts
import TurnTrace
import ChatToolRuntime
// Blueprint: | `ExpansionDispatcher.swift` | `ExpansionDispatcher`; `already_looked`; `ready_to_confirm`; Gated bounded reads and excluded act previews |

/// Wrap the gated chain once for practice feedback; nested calls re-enter below this node so the outer call owns them.
final class ExpansionDispatcher: ToolDispatchClient {
    /// Act proposals ride under this marker; learning readers exclude its subtree.
    static let previewResultsKey = "ready_to_confirm"
    private let work: ChatTurnWork
    private let inner: any ToolDispatchClient
    private let dataRoot: URL
    private let session: String?

    init(inner: any ToolDispatchClient, dataRoot: URL, session: String?, work: ChatTurnWork = .init()) {
        self.work = work
        self.inner = inner
        self.dataRoot = dataRoot
        self.session = session
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        // A preview decides and commits nothing, so it neither predicts nor teaches.
        guard !work.expansionInside, input["preview"] != .bool(true),
              let caller = Expansion.Caller.current(dataRoot: dataRoot, session: session, surface: surface, turn: turn) else {
            return try await inner.dispatch(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        }
        return try await holding(work.with(\.toolInvocation, invocation).with(\.expansionInside, true)) { work in
            try await self.expanding(caller, tool: tool, input: input, surface: surface, turn: turn, work: work)
        }
    }

    /// Opening reads bypass prediction only; the ordinary gate chain must still authorize them.
    func readAhead(surface: String, session: String?, turn: Turn, work: ChatTurnWork) async -> JSONValue? {
        guard !work.expansionInside, !Task.isCancelled,
              let caller = Expansion.Caller.current(dataRoot: dataRoot, session: session ?? self.session, surface: surface, turn: turn) else { return nil }
        return await holding(work.with(\.expansionInside, true)) { (work: ChatTurnWork) async -> JSONValue? in
            let plan = await Expansion.shared.start(caller, at: Date(), deliver: true)
            guard let plan, plan.nature == .read else { return nil }
            let input: [String: JSONValue] = if let session = session ?? self.session { ["__session_id": .string(session)] } else { [:] }
            let carried = await carry(caller, plan: plan, fields: [:], input: input, surface: surface, following: false, turn: turn, work: work)
            return carried.isEmpty ? nil : .object(carried)
        }
    }

    private func expanding(_ caller: Expansion.Caller, tool: String, input: [String: JSONValue],
                           surface: String, turn: Turn, work: ChatTurnWork) async throws -> JSONValue {
        let expansion = Expansion.shared
        let arrived = Date()
        let first = await expansion.arrive(caller, tool: tool, input: input, at: arrived)
        let result: JSONValue
        do {
            result = try await inner.dispatch(tool: tool, input: input, surface: surface, turn: turn, invocation: work.invocation)
        } catch {
            await expansion.broke(caller)
            throw error
        }
        let returned = Date()
        await expansion.ran(caller, seconds: returned.timeIntervalSince(arrived))
        let reply = ToolResult(result)
        // Only object results can carry predictions; waiting and stopped work cannot.
        let carries: Bool = if case .object = reply.payload {
            !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome) && !Task.isCancelled
        } else { false }
        let plan = await expansion.consider(caller, tool: tool, input: input, result: reply.payload, first: first,
                                            at: returned, deliver: carries)
        guard carries, case .object(let fields) = result else { return result }
        return .object(await carry(caller, plan: plan, fields: fields, input: input, surface: surface, turn: turn, work: work))
    }

    private func carry(_ caller: Expansion.Caller, plan: Expansion.Plan?, fields: [String: JSONValue],
                       input: [String: JSONValue], surface: String, following: Bool = true, turn: Turn, work: ChatTurnWork) async -> [String: JSONValue] {
        let expansion = Expansion.shared
        var plan = plan
        var fields = fields
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
            // Reserve half the remaining ceiling to return the original result, and spend no more than the saved round.
            // Do not start a predicted read whose measured runtime cannot fit.
            let budget = min(next.within, work.deadlines.secondsLeft.map { $0 / 2 } ?? .infinity)
            guard !Task.isCancelled, budget >= next.expected else {
                await expansion.delivered(caller, invocation: next.invocation, landed: nil, seconds: nil)
                break
            }
            let started = Date()
            let got: JSONValue?
            do {
                got = try await TurnDeadline.withThrowingDeadline(seconds: budget, clock: .wallClock, deadlines: work.deadlines) { deadlines in
                    try await TurnTraceContext.$automaticOrigin.withValue("expansion") {
                        return try await inner.dispatch(tool: "app", input: sent, surface: surface, turn: turn,
                            invocation: work.with(\.deadlines, deadlines).invocation)
                    }
                }
            } catch {
                let reason = error is TurnDeadline.DeadlineExceeded ? "deadline"
                    : error is CancellationError || Task.isCancelled ? "cancelled" : "dispatch_failed"
                fields["expansion_failure"] = .object(["call": .object(next.call),
                    "reason": .string(reason), "message": .string(error.localizedDescription)])
                got = nil
            }
            let seconds = Date().timeIntervalSince(started)
            let reply = got.map(ToolResult.init)
            var landed: JSONValue?
            if !Task.isCancelled, let reply, case .object(let receipt) = reply.payload,
               ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome),
               !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome), receipt["would_refuse"] == nil {
                var entry: [String: JSONValue] = ["call": .object(next.call)]
                // Display the steering principals whose turns supplied this practice so its authority stays explicit.
                if !caller.steered.isEmpty { entry["steered_by"] = .array(caller.steered.map(JSONValue.string)) }
                entry[next.nature == .act ? "preview" : "result"] = reply.payload
                var carried = fields
                if next.nature == .act { carried[Self.previewResultsKey] = .array(ready + [.object(entry)]) }
                else { carried["already_looked"] = .array(looked + [.object(entry)]) }
                // Attach only when the complete result fits the provider's inline ceiling.
                let size = (try? JSONValue.object(carried).serialize(pretty: false))?.utf8.count ?? .max
                if size <= ProviderToolResultPage.defaultMaxUTF8Bytes {
                    landed = reply.payload
                    fields = carried
                    if next.nature == .act { ready.append(.object(entry)) } else { looked.append(.object(entry)) }
                }
            }
            await expansion.delivered(caller, invocation: next.invocation, landed: landed, seconds: seconds)
            guard let landed else { break }
            TurnTraceBus.fireFromContext(kind: "mind.why", payload: next.why, turn: turn)
            guard following, next.nature == .read else { break }
            // The read the agent now has is the step its next call follows.
            plan = await expansion.consider(caller, tool: "app", input: next.call, result: landed, first: false, at: Date(),
                                            deliver: !Task.isCancelled && depth < Expansion.Law.chain)
        }
        return fields
    }

    func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await inner.listAvailableTools(turn: turn, surface: surface)
    }

    func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names, turn: turn, surface: surface)
    }

    func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(turn: turn, surface: surface)
    }
}
