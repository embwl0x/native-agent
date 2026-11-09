import Experiences
import AgentWorkspace
import Agents
import TurnTrace
import AuthoredCapabilities
import AttentionRouting
import ChatTurnContracts
import ChatTurnRuntime
import ChatToolRuntime
import AgentConversations
import ChatToolParsing
import CryptoKit
import Foundation
import Privacy
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
import ToolExecution
import TrustCenter
import Senses
import PersonaEngine
import Desk
// Blueprint: | `AppDoorPrograms.swift` | Ordered gated calls; failed/waiting steps bar changes, not independent reads |
extension AppToolExecutor {
    /// Every preview says who would receive a card, including refusals that stop before card filing and script previews of the calls reached.
    static func previewApproval(_ value: JSONValue, preview: Bool) -> JSONValue {
        guard preview, case .object(var fields) = value else { return value }
        fields["execution"] = .string("preview")
        fields["effects"] = .string("none")
        if fields["would_card"] == nil { fields["would_card"] = .bool(false) }
        fields["approver"] = fields["would_card"] == .bool(true) ? .string("owner") : .null
        return .object(fields)
    }
    /// Every scripted app call re-enters the same gates, user floor, preview and version checks as a single action.
    @MainActor
    func doorScript(_ source: String, input: [String: JSONValue], surface: String, turn: Turn, execution: AppActionExecution) async -> JSONValue {
        guard let perform = execution.perform else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        let session = input["__session_id"]
        let preview = input["preview"] == .bool(true)
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        var scriptExecution = execution
        scriptExecution.notesSnapshot = DoorNotesSnapshot()
        let heldExecution = scriptExecution
        return await AppScriptRunner.run(source: source, preview: preview, dataRoot: root, surface: surface, turn: turn, execution: heldExecution) { call,
            callTurn, callExecution in
            var call = call
            if let session { call["__session_id"] = session }
            do { return try await perform("app", call, callTurn, callExecution) } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
        }
    }
    /// After failure only proven reads proceed; paths and arguments may name effects, so they wait with changes.
    static func doorCertainRead(_ call: [String: JSONValue]) -> Bool {
        guard doorText(call["action"]).isEmpty, call["script"] == nil || call["script"] == .null,
              (call["args"]?.objectValue ?? [:]).isEmpty else { return false }
        let page = doorText(call["page"]), item = doorText(call["item"])
        if page.isEmpty, item.isEmpty { return !doorText(call["find"]).isEmpty }
        guard !page.isEmpty, !page.contains("/"), !page.contains(".") else { return false }
        return item.isEmpty || (page.lowercased() != "home" && !item.contains("."))
    }
    /// Each batch entry re-enters all gates in order. Failure or person-waiting bars later changes while independent reads proceed.
    /// A shared page version advances after each write; Stop ends execution. The first person wait owns the batch envelope and card.
    @MainActor
    func doorMany(_ entries: [JSONValue], base: [String: JSONValue], turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        guard let perform = execution.perform else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        guard (1...AppScriptRunner.actionLimit).contains(entries.count) else {
            let advice = try Self.doorBatchAdvice(.array(entries), input: base.merging(["actions": .array(entries)]) { _, entries in entries })
            return Self.doorRefusal("invalid_actions",
                "One call runs 1 to \(AppScriptRunner.actionLimit) actions; this one has \(entries.count). Nothing ran.",
                remedy: "correct_arguments", "Use try_instead's declared batch shape; split it into calls of at most \(AppScriptRunner.actionLimit).",
                extra: ["try_instead": advice])
        }
        let snapshot = execution.notesSnapshot ?? DoorNotesSnapshot()
        var batchExecution = execution
        batchExecution.notesSnapshot = snapshot
        let outerBatch = snapshot.versions == nil
        if outerBatch { snapshot.versions = [:] }
        defer { if outerBatch { snapshot.versions = nil } }
        let given = Self.doorText(base["expected_version"])
        if let scope = given.split(separator: "@").first?.split(separator: "/").first.map(String.init) {
            let pageID = await doorPage(scope)?.id ?? scope
            snapshot.versions?[pageID] = .string(given)
        }
        var receipts: [ToolResult] = []
        var stopped = false
        var handedBack = false
        var barrier: (index: Int, action: String, reply: ToolResult)?
        var notRun: [(index: Int, action: String)] = []
        var readsAfter: [String] = []
        var nextIndex = 0
        for (index, entry) in entries.enumerated() {
            if stopped || Task.isCancelled { stopped = true; break }
            if let session = turn.verifiedSessionID ?? turn.session, await ChatTurnSteering.shared.personWaiting(in: session) {
                handedBack = true
                break
            }
            var call = base.filter { $0.key != "expected_version" }
            do {
                guard case .object(let fields) = entry else {
                    // Suggest only the refused entry: earlier entries may already have changed something.
                    let advice = try Self.doorBatchAdvice(entry, input: base.merging(["actions": entry]) { _, entry in entry })
                    let reply = ToolResult(Self.doorRefusal("invalid_actions", "Each entry is one app call, an object. Nothing ran.",
                        remedy: "correct_arguments", "Write this entry using try_instead's declared shape; earlier entries keep their receipts.",
                        next: advice.objectValue, extra: ["try_instead": advice]))
                    receipts.append(reply)
                    if barrier == nil { barrier = (index + 1, "app", reply) }
                    nextIndex = index + 1
                    continue
                }
                call.merge(fields) { $1 }
                // A previewed list previews every entry; an entry's own preview:false never runs one.
                if base["preview"] == .bool(true) { call["preview"] = .bool(true) }
                let action = (try await AppActions.resolvedAction(Self.doorText(call["action"]),
                                                             dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(), turn: turn))?.action
                let name = action?.id ?? ["action", "page", "item"].map { Self.doorText(call[$0]) }.first(where: { !$0.isEmpty })
                    ?? (Self.doorText(call["find"]).isEmpty ? "app" : "find " + Self.doorText(call["find"]))
                let readOnly = action?.readOnly(args: call["args"]?.objectValue ?? [:]) ?? Self.doorCertainRead(call)
                if barrier != nil, !readOnly {
                    notRun.append((index + 1, name))
                    nextIndex = index + 1
                    continue
                }
                let page: String
                if action?.id == "setting.set", case .object(let args)? = call["args"] {
                    page = try await QuietSettings.setting(id: Self.doorText(args["setting"]), host: quietHost())?.page ?? ""
                } else { page = action?.page ?? "" }
                if call["expected_version"] == nil { call["expected_version"] = snapshot.versions?[page] }
                if Task.isCancelled { stopped = true; break }
                if let session = turn.verifiedSessionID ?? turn.session, await ChatTurnSteering.shared.personWaiting(in: session) {
                    handedBack = true
                    break
                }
                let receipt: JSONValue
                do { receipt = try await perform("app", call, turn, batchExecution) }
                catch is CancellationError {
                    stopped = true
                    receipt = ChatToolOutcome.failure(error: CancellationError(), tool: "app")
                } catch { receipt = ChatToolOutcome.failure(error: error, tool: "app") }
                let reply = ToolResult(receipt)
                if call["expected_version"] != nil, case .object(let fields) = reply.payload, let after = fields["page_version"] { snapshot
                    .versions?[page] = after }
                receipts.append(reply)
                nextIndex = index + 1
                if barrier != nil, readOnly || reply.payload.objectValue?["read_only"] == .bool(true) { readsAfter.append(name) }
                if barrier == nil, reply.outcome.isFailure || ChatToolOutcome.isWaitingApproval(reply.payload) || reply.isWaitingInteraction {
                    barrier = (index + 1, name, reply)
                }
            } catch {
                if error is CancellationError { stopped = true }
                let reply = ToolResult(ChatToolOutcome.failure(error: error, tool: "app"))
                receipts.append(reply)
                nextIndex = index + 1
                let requested = ["action", "page", "item"].map { Self.doorText(call[$0]) }
                    .first(where: { !$0.isEmpty }) ?? "app"
                if barrier == nil { barrier = (index + 1, requested, reply) }
            }
        }
        stopped = stopped || Task.isCancelled
        return await settle { @MainActor [receipts, stopped, handedBack, barrier, notRun, readsAfter, nextIndex] in
            let failure = receipts.first { $0.carriesFailureEvidence }
            // A person wait speaks for the batch; a skipped permission card does so only if nothing ran, since answering replays it.
            let speaking = receipts.first { ChatToolOutcome.isWaitingApproval($0.payload) || $0.isWaitingInteraction }
                ?? (receipts.allSatisfy { ChatToolOutcome.neverRan($0.payload) }
                    ? receipts.first { InlineInteractionNeed.isWaiting($0.payload) } : nil)
            let (landed, partial, unresolved) = receipts.reduce(into: (0, 0, 0)) { count, reply in
                // This exact status-key check excludes state and unnormalized spellings; reply.status includes both.
                if reply.payload.objectValue?["status"] == .string("partial") || (reply.hasReadEvidence() && !reply
                    .hasReadEvidence(completeOnly: true)) { count.1 += 1 }
                else if reply.outcome == .succeeded { count.0 += 1 }
                else if reply.outcome == .unknown { count.2 += 1 }
            }
            var result: [String: JSONValue] = [
                "status": .string(stopped ? "partial" : landed == receipts.count ? "ok" : landed > 0 || partial > 0 ? "partial" : unresolved > 0
                    ? "outcome_unknown" : "failed"),
                "detail": .string("\(landed) of \(receipts.count) landed fully; \(partial) partially; each receipt, in order, says what happened."),
                "receipts": .array(receipts.map(\.payload)),
            ]
            if stopped {
                result["outcome"] = .string("canceled")
                result["unrun"] = .array(notRun.map { entries[$0.index - 1] } + entries.dropFirst(nextIndex))
            }
            result["remedy"] = landed == 0 && partial == 0 ? .object(["kind": .string("per_receipt"),
                "instruction": .string("Each receipt says why it did not land and what to do next."), "next_call": .null]) : nil
            if !stopped, !handedBack, case .object(let waiting)? = speaking?.payload {
                result = waiting.merging(["receipts": .array(receipts.map(\.payload))]) { _, value in value }
            }
            if let barrier {
                let state = ChatToolOutcome.isWaitingApproval(barrier.reply.payload) || barrier.reply.isWaitingInteraction ? "is waiting on you" : "failed"
                let reason = ChatToolOutcome.explanation(barrier.reply.payload) ?? "The receipt gives no further reason."
                result["detail"] = .string("Step \(barrier.index) (\(barrier.action)) \(state): \(reason)"
                    + (reason.hasSuffix(".") ? "" : ".")
                    + " Not run after it: " + (notRun.isEmpty ? "none." : notRun.map { $0.action }.joined(separator: ", ") + " (they change something).")
                    + " Ran after it: " + (readsAfter.isEmpty ? "none." : readsAfter.joined(separator: ", ") + "."))
                result["failed_step"] = .int(Int64(barrier.index))
                result["not_run"] = .array(notRun.map { .object(["index": .int(Int64($0.index)), "action": .string($0.action)]) })
                result["steps_total"] = .int(Int64(entries.count))
            }
            if !stopped, handedBack {
                // An earlier step's real failure stays the batch's word, with its remedy; the hand-back only adds what did not start.
                if let failure {
                    result["remedy"] = failure.remedy ?? result["remedy"] ?? nil
                } else {
                    result["status"] = .string(receipts.isEmpty ? "skipped" : "partial")
                    result["remedy"] = nil
                }
                result["reason"] = .string("person_arrival")
                result["detail"] = .string(Self.doorText(result["detail"]) + " A message from the person is waiting. "
                    + "Steps \(nextIndex + 1) through \(entries.count) did not start; "
                    + "earlier steps keep their receipts. Read the message before deciding what to do next.")
                let skipped = Set(notRun.map(\.index))
                result["unrun"] = .array(entries.enumerated().compactMap { index, entry in
                    index >= nextIndex || skipped.contains(index + 1) ? entry : nil
                })
                result["next_step"] = .int(Int64(nextIndex + 1))
                if receipts.isEmpty {
                    result["execution"] = .string("not_run")
                    result["effects"] = .string("none")
                }
            }
            return .object(result)
        }
    }
    /// The one argument given a list where the action takes a single value, and its values; nil when there is none, or more than one. A key or token never fans
    /// out.
    static func doorPlural(_ action: AppAction, _ args: [String: JSONValue], discovery: [String: JSONValue]) -> (String, [JSONValue])? {
        guard let (key, values) = doorPlural(action, args.mapValues(OwnedProgram.Calls.Argument.value), discovery: discovery) else { return nil }
        return (key, values.compactMap(\.value))
    }

    /// Retain readable list elements for preflight, including unknown expressions. Their actual values still face the ordinary door checks.
    static func doorPlural(_ action: AppAction, _ args: [String: OwnedProgram.Calls.Argument], discovery: [String: JSONValue]) -> (String, [OwnedProgram.Calls
        .Argument])? {
        typealias Argument = OwnedProgram.Calls.Argument
        guard let properties = discovery["args_schema"]?.objectValue?["properties"]?.objectValue else { return nil }
        let eligible = AppActions.pluralKeys(action, properties: properties)
        let plural = args.compactMap { key, value -> (String, [Argument])? in
            let values: [Argument]?
            if case .array(let elements) = value { values = elements }
            else { values = value.value?.arrayValue?.map(Argument.value) }
            guard eligible.contains(key), let values, !values.isEmpty,
                  let property = properties[key], value.problem(schema: property, path: key) != nil,
                  values.allSatisfy({ element in
                      switch element {
                      case .array, .object: return false
                      case .unknown: return true
                      case .value(let value):
                          if case .array = value { return false }
                          if case .object = value { return false }
                          return true
                      }
                  })
            else { return nil }
            return (key, values)
        }
        return plural.count == 1 ? plural[0] : nil
    }
}
