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
// Blueprint: | `AppDoorPrograms.swift` | Ordered gated calls; a failed, waiting or unexpected step bars later changes, not reads or cleanups; their `then_say` stands only when the deed came back wholly as said |
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
    /// Each batch entry re-enters all gates in order. Failure, person-waiting or a step not coming back as said bars later changes while independent
    /// reads and cleanups proceed. A step's found takes a whole value from what an earlier step returned; one not there stops the deed at that step.
    /// A shared page version advances after each write; Stop ends execution. The first person wait owns the batch envelope and card.
    /// Given then_say, the result always says whether the agent's closing words stand, filled from with, or why not.
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
        // A step's name is for found alone: one name, one step, never a number.
        var names: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            guard let given = entry.objectValue?["as"] else { continue }
            guard case .string(let name) = given, !name.isEmpty, !name.contains("."), !name.allSatisfy(\.isWholeNumber), names[name] == nil else {
                return Self.doorRefusal("invalid_actions",
                    "Step \(index + 1)'s as must be a name of its own: not empty, all digits, holding a dot, or one an earlier step took. Nothing was run.",
                    remedy: "correct_arguments", "Give each named step a distinct word, then call again.")
            }
            names[name] = index + 1
        }
        // The closing words are text, and each slot they take is one found.
        if let words = base["then_say"], (words.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.doorRefusal("invalid_actions",
                "then_say is the words to say when the deed comes back as said: text, not empty. Nothing was run.",
                remedy: "correct_arguments", "Give then_say as text, then call again.")
        }
        if let slots = base["with"] {
            guard base["then_say"] != nil, case .object(let fields) = slots,
                  fields.values.allSatisfy({ $0.objectValue?.count == 1 && $0.objectValue?["found"]?.stringValue != nil }) else {
                return Self.doorRefusal("invalid_actions",
                    "with fills the slots of then_say, beside it: an object whose every value is {found: \"<step>.<path>\"}. Nothing was run.",
                    remedy: "correct_arguments", "Give then_say with it, and each slot as {found: \"<step>.<path>\"}, then call again.")
            }
        }
        let named = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
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
        // The step each receipt is for: a step barred from running leaves none.
        var receiptSteps: [Int] = []
        var stopped = false
        var handedBack = false
        var barrier: (index: Int, action: String, reply: ToolResult)?
        var notRun: [(index: Int, action: String, because: String)] = []
        var readsAfter: [String] = []
        var nextIndex = 0
        // What came back from each step that ran and landed, as a script receives it; and the steps only previewed.
        var came: [Int: JSONValue] = [:]
        var previewed: Set<Int> = []
        var surprise: (index: Int, receipt: Int, at: [DoorMiss])?
        for (index, entry) in entries.enumerated() {
            if stopped || Task.isCancelled { stopped = true; break }
            if let session = turn.verifiedSessionID ?? turn.session, await ChatTurnSteering.shared.personWaiting(in: session) {
                handedBack = true
                break
            }
            var call = base.filter { $0.key != "expected_version" && !Self.doorDeedKeys.contains($0.key) }
            do {
                guard case .object(let fields) = entry else {
                    // Suggest only the refused entry: earlier entries may already have changed something, so the deed's closing words are not carried.
                    let advice = try Self.doorBatchAdvice(entry, input: base.filter { !Self.doorDeedKeys.contains($0.key) }
                        .merging(["actions": entry]) { _, entry in entry })
                    let reply = ToolResult(Self.doorRefusal("invalid_actions", "Each entry is one app call, an object. Nothing ran.",
                        remedy: "correct_arguments", "Write this entry using try_instead's declared shape; earlier entries keep their receipts.",
                        next: advice.objectValue, extra: ["try_instead": advice]))
                    receipts.append(reply)
                    receiptSteps.append(index + 1)
                    if barrier == nil { barrier = (index + 1, "app", reply) }
                    nextIndex = index + 1
                    continue
                }
                call.merge(fields) { $1 }
                // The step's own keys are the batch's; the door never sees them.
                let expect = call.removeValue(forKey: "expect")
                let cleanup = call.removeValue(forKey: "cleanup") == .bool(true)
                call.removeValue(forKey: "as")
                // A previewed list previews every entry; an entry's own preview:false never runs one.
                if base["preview"] == .bool(true) { call["preview"] = .bool(true) }
                let action = (try await AppActions.resolvedAction(Self.doorText(call["action"]),
                                                             dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(), turn: turn))?.action
                let name = action?.id ?? ["action", "page", "item"].map { Self.doorText(call[$0]) }.first(where: { !$0.isEmpty })
                    ?? (Self.doorText(call["find"]).isEmpty ? "app" : "find " + Self.doorText(call["find"]))
                // A value taken from an earlier step is in place before anything judges this one; one not there stops the deed here.
                if let args = call["args"] {
                    do { call["args"] = try Self.doorFound(args, came: came, names: names, previewed: previewed, before: index + 1) }
                    catch let unfound as DoorUnfound {
                        nextIndex = index + 1
                        if barrier != nil { notRun.append((index + 1, name, "found_not_there")); continue }
                        let reply = ToolResult(Self.doorRefusal("found_not_there",
                            "{found: \"\(unfound.reference)\"} is not there: \(unfound.why). Step \(index + 1) was not run.",
                            remedy: "correct_arguments", "Name an earlier step that came back and a place in what it returned; earlier steps keep their receipts."))
                        receipts.append(reply)
                        receiptSteps.append(index + 1)
                        barrier = (index + 1, name, reply)
                        continue
                    }
                }
                let readOnly = action?.readOnly(args: call["args"]?.objectValue ?? [:]) ?? Self.doorCertainRead(call)
                if barrier != nil, !readOnly, !cleanup {
                    notRun.append((index + 1, name, "stopped"))
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
                var reply = ToolResult(receipt)
                if call["expected_version"] != nil, case .object(let fields) = reply.payload, let after = fields["page_version"] { snapshot
                    .versions?[page] = after }
                let reads = readOnly || reply.payload.objectValue?["read_only"] == .bool(true)
                let landed = !(reply.outcome.isFailure || ChatToolOutcome.isWaitingApproval(reply.payload) || reply.isWaitingInteraction)
                // In a preview, a read that came back as a read ran live; everything else was only described.
                let ran = call["preview"] != .bool(true) || reads && reply.payload.objectValue?["status"] != .string("preview")
                if !ran { previewed.insert(index + 1) } else if landed { came[index + 1] = AppScriptRunner.answer(receipt) }
                // An expect that is not judged says so on its receipt.
                let unjudged: String? = !ran ? "this step was only previewed" : barrier != nil ? "the deed had already stopped" : nil
                if expect != nil, let unjudged, case .object(var fields) = reply.payload {
                    fields["expect"] = .string("not judged: " + unjudged)
                    reply = ToolResult(.object(fields))
                }
                receipts.append(reply)
                receiptSteps.append(index + 1)
                nextIndex = index + 1
                if barrier != nil, reads || cleanup {
                    let shown: String = named[index + 1].map { "\($0) (\(name))" } ?? name
                    readsAfter.append(shown + (reads ? "" : " as cleanup") + (landed ? "" : ", which did not land"))
                }
                if barrier == nil, !landed {
                    barrier = (index + 1, name, reply)
                } else if barrier == nil, ran, let expect, let value = came[index + 1] {
                    let misses = Self.doorMisses(expect, value, at: "result", said: Self.doorSaid(call["args"]))
                    if !misses.isEmpty {
                        barrier = (index + 1, name, reply)
                        surprise = (index + 1, receipts.count - 1, misses)
                    }
                }
            } catch {
                if error is CancellationError { stopped = true }
                let reply = ToolResult(ChatToolOutcome.failure(error: error, tool: "app"))
                receipts.append(reply)
                receiptSteps.append(index + 1)
                nextIndex = index + 1
                let requested = ["action", "page", "item"].map { Self.doorText(call[$0]) }
                    .first(where: { !$0.isEmpty }) ?? "app"
                if barrier == nil { barrier = (index + 1, requested, reply) }
            }
        }
        stopped = stopped || Task.isCancelled
        return await settle { @MainActor [receipts, receiptSteps, named, names, came, previewed, stopped, handedBack, barrier, notRun, readsAfter, nextIndex,
            surprise] in
            // Each receipt says which step it is for, by number and by her name for it.
            let shown: [JSONValue] = zip(receipts, receiptSteps).map { reply, step in
                guard case .object(var fields) = reply.payload else { return reply.payload }
                fields["step"] = .int(Int64(step))
                fields["as"] = named[step].map(JSONValue.string)
                return .object(fields)
            }
            func label(_ step: Int, _ action: String) -> String { named[step].map { "\($0) (\(action))" } ?? action }
            let failure = receipts.first { $0.carriesFailureEvidence }
            // A person wait speaks for the batch; a skipped permission card does so only if nothing ran, since answering replays it.
            let speaking = receipts.first { ChatToolOutcome.isWaitingApproval($0.payload) || $0.isWaitingInteraction }
                ?? (receipts.allSatisfy { ChatToolOutcome.neverRan($0.payload) }
                    ? receipts.first { InlineInteractionNeed.isWaiting($0.payload) } : nil)
            let (landed, partial, unresolved) = receipts.enumerated().reduce(into: (0, 0, 0)) { count, step in
                let reply = step.element
                // A step that came back otherwise than said landed only in part, for the deed.
                // This exact status-key check excludes state and unnormalized spellings; reply.status includes both.
                if step.offset == surprise?.receipt || reply.payload.objectValue?["status"] == .string("partial") || (reply.hasReadEvidence() && !reply
                    .hasReadEvidence(completeOnly: true)) { count.1 += 1 }
                else if reply.outcome == .succeeded { count.0 += 1 }
                else if reply.outcome == .unknown { count.2 += 1 }
            }
            var result: [String: JSONValue] = [
                "status": .string(stopped ? "partial" : landed == receipts.count ? "ok" : landed > 0 || partial > 0 ? "partial" : unresolved > 0
                    ? "outcome_unknown" : "failed"),
                "detail": .string("\(landed) of \(receipts.count) landed fully; \(partial) partially; each receipt, in order, says what happened."),
                "receipts": .array(shown),
            ]
            if stopped {
                result["outcome"] = .string("canceled")
                result["unrun"] = .array(notRun.map { entries[$0.index - 1] } + entries.dropFirst(nextIndex))
            }
            result["remedy"] = landed == 0 && partial == 0 ? .object(["kind": .string("per_receipt"),
                "instruction": .string("Each receipt says why it did not land and what to do next."), "next_call": .null]) : nil
            if !stopped, !handedBack, case .object(let waiting)? = speaking?.payload {
                result = waiting.merging(["receipts": .array(shown)]) { _, value in value }
            }
            if let barrier {
                let state = ChatToolOutcome.isWaitingApproval(barrier.reply.payload) || barrier.reply.isWaitingInteraction ? "is waiting on you" : "failed"
                let reason = ChatToolOutcome.explanation(barrier.reply.payload) ?? "The receipt gives no further reason."
                let stop: String = if let surprise {
                    "Step \(barrier.index) (\(label(barrier.index, barrier.action))) did not come back as expected: " + surprise.at.map { miss in
                        "at \(miss.place) expected \(Self.doorShown(miss.expected)), found \(miss.found.map(Self.doorShown) ?? "nothing")"
                    }.joined(separator: "; ") + "."
                } else { "Step \(barrier.index) (\(label(barrier.index, barrier.action))) \(state): \(reason)" + (reason.hasSuffix(".") ? "" : ".") }
                result["detail"] = .string(stop
                    + " Not run after it: " + (notRun.isEmpty ? "none." : notRun.map { label($0.index, $0.action) }.joined(separator: ", ") + ".")
                    + " Ran after it: " + (readsAfter.isEmpty ? "none." : readsAfter.joined(separator: ", ") + "."))
                // Where the deed stopped and why, in one place; failed_step is kept for a step that failed or waits.
                let because = surprise != nil ? "surprise" : state == "failed" ? "failed" : "waiting"
                var stoppedAt: [String: JSONValue] = ["step": .int(Int64(barrier.index)), "because": .string(because)]
                stoppedAt["as"] = named[barrier.index].map(JSONValue.string)
                result["stopped_at"] = .object(stoppedAt)
                if let surprise {
                    result["surprise"] = .array(surprise.at.map { miss in
                        .object(["place": .string(miss.place), "expected": miss.expected, "found": Self.doorBounded(miss.found)])
                    })
                } else { result["failed_step"] = .int(Int64(barrier.index)) }
                result["not_run"] = .array(notRun.map { skipped -> JSONValue in
                    var entry: [String: JSONValue] = ["step": .int(Int64(skipped.index)), "action": .string(skipped.action),
                                                      "because": .string(skipped.because)]
                    entry["as"] = named[skipped.index].map(JSONValue.string)
                    return .object(entry)
                })
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
            // The agent's closing words stand when every step ran, was expected and held, nothing in it is beyond undoing, and nothing else arrived.
            // Set last, so no step's payload can supply them.
            result["then_say"] = nil
            if case .string(let words)? = base["then_say"] {
                var filled: [String: String] = [:]
                var because: String?
                if base["preview"] == .bool(true) || !previewed.isEmpty {
                    because = "this was a preview"
                } else if stopped || handedBack || barrier != nil || receipts.count != entries.count || landed != receipts.count {
                    because = "the deed did not come back as said"
                } else if let bare = entries.firstIndex(where: { ($0.objectValue?["expect"] ?? .null) == .null }) {
                    because = "step \(bare + 1) carried no expect"
                } else if let final = zip(receipts, receiptSteps).first(where: { Self.doorFinal($0.0.payload) }) {
                    because = "step \(final.1) cannot be undone"
                } else if let session = turn.verifiedSessionID ?? turn.session, await ChatTurnSteering.shared.personWaiting(in: session) {
                    because = "a message from the person arrived"
                } else {
                    slots: for (name, slot) in (base["with"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                        let value: JSONValue
                        do { value = try Self.doorFound(slot, came: came, names: names, previewed: previewed, before: entries.count + 1) }
                        catch {
                            because = "slot \(name) is not there: " + ((error as? DoorUnfound)?.why ?? error.localizedDescription)
                            break slots
                        }
                        switch value {
                        case .int, .double, .bool: filled[name] = value.scalarText
                        case .string(let text) where text.count <= 120 && !text.contains(where: \.isNewline): filled[name] = text
                        case .string: because = "slot \(name) is more than one line of 120 characters"
                        case .array: because = "slot \(name) is a list, not a value"
                        case .object: because = "slot \(name) is an object, not a value"
                        case .null: because = "slot \(name) is null, not a value"
                        }
                        if because != nil { break slots }
                    }
                }
                var said: [String: JSONValue] = ["stands": .bool(because == nil)]
                said[because == nil ? "words" : "because"] = .string(because ?? Self.doorFilled(words, filled))
                result["then_say"] = .object(said)
            }
            return .object(result)
        }
    }
    /// A place that did not come back as said: where, the shape said there, and what was there (nil when nothing was).
    typealias DoorMiss = (place: String, expected: JSONValue, found: JSONValue?)
    /// A found reference with nothing behind it, and what was at the deepest place reached.
    struct DoorUnfound: Error {
        let reference: String
        let why: String
    }

    /// Every {found: "step.path"} in a step's arguments, replaced by that whole value from what an earlier step returned.
    static func doorFound(_ value: JSONValue, came: [Int: JSONValue], names: [String: Int], previewed: Set<Int>, before step: Int) throws -> JSONValue {
        switch value {
        case .object(let fields):
            guard fields.count == 1, case .string(let reference)? = fields["found"] else {
                return .object(try fields.mapValues { try doorFound($0, came: came, names: names, previewed: previewed, before: step) })
            }
            let segments = reference.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let head = segments[0]
            guard let source = names[head] ?? Int(head), (1..<step).contains(source) else {
                throw DoorUnfound(reference: reference, why: "no step \(head) comes before this one")
            }
            guard var place = came[source] else {
                throw DoorUnfound(reference: reference, why: previewed.contains(source)
                    ? "step \(source) was only previewed, so nothing came back from it"
                    : "step \(source) did not run or did not land, so nothing came back from it")
            }
            var reached = head
            for segment in segments.dropFirst() {
                let next: JSONValue? = switch place {
                case .object(let fields): fields[segment]
                case .array(let items): Int(segment).flatMap { items.indices.contains($0) ? items[$0] : nil }
                default: nil
                }
                guard let next else {
                    let there: String = switch place {
                    case .object(let fields): fields.isEmpty ? "it has no keys" : "its keys are " + fields.keys.sorted().prefix(30).joined(separator: ", ")
                    case .array(let items): "it is a list of \(items.count)"
                    default: "it is \(doorShown(place))"
                    }
                    throw DoorUnfound(reference: reference, why: "\(reached) has no \(segment); \(there)")
                }
                place = next
                reached += "." + segment
            }
            return place
        case .array(let items):
            return .array(try items.map { try doorFound($0, came: came, names: names, previewed: previewed, before: step) })
        default:
            return value
        }
    }

    /// A receipt is beyond undoing when it says so, or when a call its script made does.
    static func doorFinal(_ payload: JSONValue) -> Bool {
        guard case .object(var run) = payload else { return false }
        if run["irreversible"] == .bool(true) { return true }
        while run["calls"] == nil, let nested = run["result"]?.objectValue { run = nested }
        guard case .array(let calls)? = run["calls"] else { return false }
        return calls.contains { $0.objectValue?["irreversible"] == .bool(true) }
    }

    /// The closing words with each {name} that with fills replaced by its value; braces naming nothing stay as written.
    static func doorFilled(_ words: String, _ filled: [String: String]) -> String {
        var said = "", rest = Substring(words)
        while let open = rest.firstIndex(of: "{") {
            said += String(rest[..<open])
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = filled[String(after[..<close])] {
                said += value
                rest = after[after.index(after: close)...]
            } else {
                said += "{"
                rest = after
            }
        }
        return said + String(rest)
    }

    /// The places where what came back does not meet the shape laid over it; empty when it is as said.
    static func doorMisses(_ pattern: JSONValue, _ value: JSONValue?, at place: String, said: Set<String> = []) -> [DoorMiss] {
        let miss: [DoorMiss] = [(place, pattern, value)]
        switch pattern {
        case .null:
            return doorAbsent(value) ? [] : miss
        case .string(let text) where place == "result":
            // Bare text over the whole result is looked for in what the action returned, never in the receipt's bookkeeping or her own words.
            let returned = value.map(doorReturned)
            return text.isEmpty || returned.map { doorHolds($0, text, said: said) } == true ? [] : [(place, pattern, returned)]
        case .string(let text):
            return text.isEmpty || value.map { doorHolds($0, text, said: []) } == true ? [] : miss
        case .int, .double:
            return doorSameNumber(pattern, value, strings: true) ? [] : miss
        case .bool(let truth):
            return value == .bool(truth) || value?.stringValue?.lowercased() == (truth ? "true" : "false") ? [] : miss
        case .object(let shape) where shape.count == 1 && shape["exactly"] != nil:
            let whole = shape["exactly"] ?? .null
            let given = value ?? .null
            return given == whole || doorSameNumber(whole, given, strings: false) ? [] : miss
        case .object(let shape) where shape.count == 1 && shape["not"] != nil:
            return doorMisses(shape["not"] ?? .null, value, at: place, said: said).isEmpty ? miss : []
        case .object(let shape):
            guard case .object(let fields)? = value else { return miss }
            return shape.keys.sorted().flatMap { key in
                doorMisses(shape[key] ?? .null, fields[key], at: place == "result" ? key : place + "." + key)
            }
        case .array(let shapes):
            guard case .array(let items)? = value else { return miss }
            return shapes.compactMap { shape -> DoorMiss? in
                items.contains { doorMisses(shape, $0, at: place, said: said).isEmpty } ? nil : (place, shape, value)
            }
        }
    }

    /// Some text or scalar anywhere in the value contains the text, whatever the case. Field names are not text that came back, and neither is a
    /// value that is only one of the step's own arguments said back.
    static func doorHolds(_ value: JSONValue, _ text: String, said: Set<String>) -> Bool {
        switch value {
        case .object(let fields): fields.values.contains { doorHolds($0, text, said: said) }
        case .array(let items): items.contains { doorHolds($0, text, said: said) }
        default: value.scalarText.map { !said.contains($0) && $0.localizedCaseInsensitiveContains(text) } == true
        }
    }

    /// What the action returned, without the receipt's bookkeeping around it.
    static func doorReturned(_ value: JSONValue) -> JSONValue {
        guard case .object(let fields) = value else { return value }
        return .object(fields.filter { $0.key == "result" || !AppScriptRunner.formEnvelope.contains($0.key) })
    }

    /// Every scalar a step's arguments hold, as text.
    static func doorSaid(_ value: JSONValue?) -> Set<String> {
        switch value {
        case .object(let fields)?: fields.values.reduce(into: Set<String>()) { $0.formUnion(doorSaid($1)) }
        case .array(let items)?: items.reduce(into: Set<String>()) { $0.formUnion(doorSaid($1)) }
        default: Set([value?.scalarText].compactMap { $0 })
        }
    }

    /// The same number: whole numbers as whole numbers, so two that differ past a double's reach stay different.
    static func doorSameNumber(_ number: JSONValue, _ value: JSONValue?, strings: Bool) -> Bool {
        if case .int(let said) = number {
            if case .int(let came)? = value { return said == came }
            if strings, case .string(let text)? = value, let came = Int64(text) { return said == came }
        }
        guard let said = number.numberValue(coercingStrings: false, finiteOnly: true) else { return false }
        return value?.numberValue(coercingStrings: strings, finiteOnly: true) == said
    }

    /// Nothing is there: missing, null, empty text, an empty list or an empty object.
    static func doorAbsent(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: true
        case .string(let text)?: text.isEmpty
        case .array(let items)?: items.isEmpty
        case .object(let fields)?: fields.isEmpty
        default: false
        }
    }

    /// A value as compact JSON text, bounded to a few hundred characters.
    static func doorShown(_ value: JSONValue) -> String {
        let text = (try? value.serialize(pretty: false)) ?? "an unprintable value"
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    /// What was there, as itself when short and as bounded text when long.
    static func doorBounded(_ value: JSONValue?) -> JSONValue {
        guard let value else { return .null }
        return ((try? value.serialize(pretty: false))?.count ?? 0) > 300 ? .string(doorShown(value)) : value
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
