import Experiences
import AgentWorkspace
import Agents
import TurnTrace
import AuthoredCapabilities
import AttentionRouting
import ChatTurnContracts
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
// Blueprint: | `AppDoorPrograms.swift` | Scripts and ordered batches re-enter the same gates |
extension AppToolExecutor {
    /// Every preview says who would receive a card, including refusals that
    /// stop before card filing and script previews of the calls reached.
    static func previewApproval(_ value: JSONValue, preview: Bool) -> JSONValue {
        guard preview, case .object(var fields) = value else { return value }
        fields["execution"] = .string("preview")
        fields["effects"] = .string("none")
        if fields["would_card"] == nil { fields["would_card"] = .bool(false) }
        fields["approver"] = fields["would_card"] == .bool(true) ? .string("owner") : .null
        return .object(fields)
    }
    /// `script`: each `app.*` call re-enters the chain as its own `app` call,
    /// so it passes the gates, User's floor, preview and expected_version
    /// exactly as a single action does (`AppScriptRunner`).
    @MainActor
    func doorScript(_ source: String, input: [String: JSONValue]) async -> JSONValue {
        guard let perform = AppDoorReentry.perform else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        let session = input["__session_id"]
        let preview = input["preview"] == .bool(true)
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return await DoorNotesSnapshot.$current.withValue(DoorNotesSnapshot()) {
            await AppScriptRunner.run(source: source, preview: preview, dataRoot: root) { call in
                var call = call
                if let session { call["__session_id"] = session }
                do { return try await perform("app", call) } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
            }
        }
    }
    /// Many in one call: each entry is its own app call, re-entering the whole
    /// chain as a script's calls do, in order, and every one runs and reports
    /// itself. A version given once guards each write on its page in turn,
    /// each taking the version the one before it left. A Stop ends it there.
    /// The first entry waiting on the person is the call's own envelope, so the
    /// turn waits and the card shows as for one action.
    @MainActor
    func doorMany(_ entries: [JSONValue], base: [String: JSONValue]) async throws -> JSONValue {
        guard let perform = AppDoorReentry.perform else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        guard (1...AppScriptRunner.actionLimit).contains(entries.count) else {
            return Self.doorRefusal("invalid_actions",
                "One call runs 1 to \(AppScriptRunner.actionLimit) actions; this one has \(entries.count). Nothing ran.",
                remedy: "correct_arguments", "Split it into calls of at most \(AppScriptRunner.actionLimit).")
        }
        let snapshot = DoorNotesSnapshot.current ?? DoorNotesSnapshot()
        let outerBatch = snapshot.versions == nil
        if outerBatch { snapshot.versions = [:] }
        defer { if outerBatch { snapshot.versions = nil } }
        let given = Self.doorText(base["expected_version"])
        if let scope = given.split(separator: "@").first?.split(separator: "/").first.map(String.init) {
            snapshot.versions?[doorPage(scope)?.id ?? scope] = .string(given)
        }
        var receipts: [JSONValue] = []
        var stopped = false
        // One inbox read per action, after itself, as in a script.
        await DoorNotesSnapshot.$current.withValue(snapshot) {
            for entry in entries {
                if stopped || Task.isCancelled { stopped = true; break }
                guard case .object(let fields) = entry else {
                    receipts.append(Self.doorRefusal("invalid_actions", "Each entry is one app call, an object. Nothing ran.",
                        remedy: "correct_arguments", "Write it as {action, args}, {page} or {item}."))
                    continue
                }
                var call = base.filter { $0.key != "expected_version" }.merging(fields) { $1 }
                // A previewed list previews every entry; an entry's own preview:false never runs one.
                if base["preview"] == .bool(true) { call["preview"] = .bool(true) }
                let action = (await AppActions.resolvedAction(Self.doorText(call["action"]),
                                                             dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()))?.action
                let page: String
                if action?.id == "setting.set", case .object(let args)? = call["args"] {
                    page = QuietSettings.setting(id: Self.doorText(args["setting"]), host: quietHost())?.page ?? ""
                } else { page = action?.page ?? "" }
                if call["expected_version"] == nil { call["expected_version"] = snapshot.versions?[page] }
                if Task.isCancelled { stopped = true; break }
                let receipt: JSONValue
                do { receipt = try await perform("app", call) }
                catch is CancellationError {
                    stopped = true
                    receipt = ChatToolOutcome.failure(error: CancellationError(), tool: "app")
                } catch { receipt = ChatToolOutcome.failure(error: error, tool: "app") }
                if call["expected_version"] != nil, case .object(let fields) = receipt, let after = fields["page_version"] { snapshot.versions?[page] = after }
                receipts.append(receipt)
            }
        }
        stopped = stopped || Task.isCancelled
        return await settle { @MainActor [receipts, stopped] in
            // A person wait speaks for the batch; a skipped permission card does so only if nothing ran, since answering replays it.
            let speaking = receipts.first { ChatToolOutcome.isWaitingOnPerson($0) }
                ?? (receipts.allSatisfy(ChatToolOutcome.neverRan) ? receipts.first(where: InlineInteractionNeed.isWaiting) : nil)
            if !stopped, case .object(var waiting)? = speaking {
                waiting["receipts"] = .array(receipts)
                return .object(waiting)
            }
            let (landed, partial, unresolved) = receipts.reduce(into: (0, 0, 0)) { count, receipt in
                let verdict = ChatToolOutcome.exactResultClass(receipt)
                if receipt.objectValue?["status"] == .string("partial") || (ChatToolOutcome.hasReadEvidence(receipt, verdict: verdict) && !ChatToolOutcome.hasReadEvidence(receipt, completeOnly: true, verdict: verdict)) { count.1 += 1 }
                else if verdict == .succeeded { count.0 += 1 }
                else if verdict == .unknown { count.2 += 1 }
            }
            var result: [String: JSONValue] = [
                "status": .string(stopped ? "partial" : landed == receipts.count ? "ok" : landed > 0 || partial > 0 ? "partial" : unresolved > 0 ? "outcome_unknown" : "failed"),
                "detail": .string("\(landed) of \(receipts.count) landed fully; \(partial) partially; each receipt, in order, says what happened."),
                "receipts": .array(receipts),
            ]
            if stopped {
                result["outcome"] = .string("canceled")
                result["unrun"] = .array(Array(entries.dropFirst(receipts.count)))
            }
            result["remedy"] = landed == 0 && partial == 0 ? .object(["kind": .string("per_receipt"),
                "instruction": .string("Each receipt says why it did not land and what to do next."), "next_call": .null]) : nil
            return .object(result)
        }
    }
    /// The one argument given a list where the action takes a single value,
    /// and its values; nil when there is none, or more than one. A key or
    /// token never fans out.
    static func doorPlural(_ action: AppAction, _ args: [String: JSONValue], discovery: [String: JSONValue]) -> (String, [JSONValue])? {
        guard let properties = discovery["args_schema"]?.objectValue?["properties"]?.objectValue else { return nil }
        let eligible = AppActions.pluralKeys(action, properties: properties)
        let plural = args.compactMap { key, value -> (String, [JSONValue])? in
            guard eligible.contains(key), case .array(let values) = value, !values.isEmpty,
                  let property = properties[key], value.schemaProblem(schema: property, path: key) != nil,
                  values.allSatisfy({ if case .array = $0 { false } else if case .object = $0 { false } else { true } })
            else { return nil }
            return (key, values)
        }
        return plural.count == 1 ? plural[0] : nil
    }
}
