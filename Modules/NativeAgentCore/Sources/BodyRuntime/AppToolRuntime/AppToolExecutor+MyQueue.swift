import MindCore
import DeskCore
import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `AppToolExecutor+MyQueue.swift` | `runMyQueue`; Exact-id intentions, schedules, habits and closure receipts |

extension AppToolExecutor {
    /// A relative amount of time is one moment from now, in words ("in 2 minutes") or as amount fields ({seconds:120}).
    static func relativeMoment(_ text: String) -> TimeInterval? {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard words.count == 3, words[0] == "in", let count = Double(words[1]), count > 0,
              let unit = ["second": 1.0, "seconds": 1, "sec": 1, "secs": 1, "minute": 60, "minutes": 60, "min": 60, "mins": 60,
                          "hour": 3_600, "hours": 3_600, "day": 86_400, "days": 86_400][words[2]] else { return nil }
        return count * unit
    }

    /// Amount fields the timing schema names, with no repeat kind (none, once or at), are one moment that far from now; any other field is not.
    static func relativeMoment(_ fields: [String: JSONValue]) -> TimeInterval? {
        let units: [String: TimeInterval] = ["seconds": 1, "interval_seconds": 1, "intervalSeconds": 1, "minutes": 60, "hours": 3_600,
                                             "days": 86_400]
        let kind = (fields["type"] ?? fields["kind"]).map { ($0.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard kind.map(SchedulerJobNormalizer.momentKinds.contains) ?? true else { return nil }
        let amounts = fields.filter { $0.key != "type" && $0.key != "kind" }
        guard !amounts.isEmpty else { return nil }
        var total: TimeInterval = 0
        for (name, value) in amounts {
            guard let unit = units[name], let count = value.scalarText.flatMap(Double.init), count.isFinite, count >= 0 else { return nil }
            total += count * unit
        }
        return total > 0 ? total : nil
    }

    /// Queued steps retain peer steering so later execution cannot outrank the originating turn.
    @MainActor
    func runMyQueue(verb: String, input: [String: JSONValue], surface: String, turn: Turn) async -> JSONValue {
        let store = SwiftNativeDeskStore(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        let named = Set(input.keys).subtracting(["verb", "__session_id", "__sense_address"])
        do {
            if verb == "add" || verb == "update" {
                return try await addOrUpdateQueueStep(verb: verb, input: input, named: named, surface: surface, turn: turn, store: store)
            }
            return try await closeQueueStep(verb: verb, input: input, store: store)
        } catch let conflict as DeskHoldConflict {
            return conflict.refusal()
        } catch let error as MyQueue.RunCleanupFailure {
            return .object(Self.partSettlementFailure(JSONValue.objectOrEmpty(queueReceipt(error.entry, error.dropped ? "dropped" : "done")),
                error: error.underlying, operation: "ability.queue_checkpoint_cleanup",
                id: error.runID, root: store.dataRoot))
        } catch is MyQueue.Superseded {
            do {
                let state = try await store.liveState()
                if let id = queueText("id", in: input) {
                    let alias = id.lowercased().hasPrefix("desk.") ? String(id.dropFirst(5)) : id
                    if let terminal = try await terminalQueueStep(id, alias: alias, in: state, verb: verb, store: store) { return terminal }
                }
                return Self.failure("queue_changed", "The queued step changed before this operation; nothing changed.",
                    extra: ["remedy": .object(["kind": .string("fix_args"),
                        "instruction": .string("Read its current Desk record before changing it."), "next_call": .null])])
            } catch {
                return Self.ownedFailure(error, code: "queue_failed", owner: "MY QUEUE",
                    instruction: "Read the Desk and resolve the reported storage error before another change.",
                    next: ["page": .string("desk")], effects: .none)
            }
        } catch {
            return Self.ownedFailure(error, code: "queue_failed", owner: "MY QUEUE",
                instruction: "Read home to reconcile the queue and resolve the reported cause before another change.",
                next: ["page": .string("home")], effects: .unknown)
        }
    }

    @MainActor
    private func queueText(_ key: String, in input: [String: JSONValue]) -> String? {
        input[key]?.scalarText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Interpret and save a new or updated queue step.
    @MainActor
    private func addOrUpdateQueueStep(verb: String, input: [String: JSONValue], named: Set<String>, surface: String,
                                      turn: Turn, store: SwiftNativeDeskStore) async throws -> JSONValue {
        var input = input
        var editing: MyQueue.Entry?
        if verb == "update" {
            guard let id = queueText("id", in: input) else {
                return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args", "Pass id: the step's desk.N.")
            }
            if let value = input["wait_for"] {
                let trigger = DeskStep.CausalWait.Trigger(value)
                guard named == ["id", "wait_for"], value == .null || trigger != nil else {
                    return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args",
                        "Pass id and wait_for alone. Use {at:<ISO time>}, {happening:{kind:<kind>,subject:<exact subject>}}, {desk:<id>}, or null.")
                }
                let steer = PeerDataTaint.carried(turn: turn, surface: surface)
                let (entry, change) = try await MyQueue.setCausalWait(trigger, on: id, peers: steer.sources,
                    fileAccess: turn.fileAccessCeiling, store: store)
                var receipt = JSONValue.objectOrEmpty(queueReceipt(entry, change.rawValue))
                receipt["wait_for"] = entry.step.causalWait?.trigger.json ?? .null
                return .object(receipt)
            }
            let alias = id.hasPrefix("desk.") ? String(id.dropFirst(5)) : id
            let state = try await store.liveState()
            guard let entry = MyQueue.entries(state).first(where: { $0.item.alias == alias || $0.item.handle == id }) else {
                return try await missingQueueStep(id, alias: alias, in: state, verb: verb, store: store)
            }
            editing = entry
            // Parse the requested fields using add's grammar, keeping omitted fields exact below.
            input["text"] = .string(entry.step.words)
            if input["when"] == nil { input["when"] = entry.step.rhythm ?? .string(entry.step.when + (entry.step.card.map { " " + $0 } ?? "")) }
            if input["until"] == nil { input["until"] = entry.step.until.map(JSONValue.string) ?? .string("once") }
            if input["say"] == nil { input["say"] = entry.step.say.map(JSONValue.string) ?? .null }
            if input["action"] == nil { input["action"] = entry.step.action ?? .null }
        }
        let action = DeskStep.plannedAction(input["action"])
        if let value = input["action"], value != .null, action == nil {
            return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args",
                "A habit is action:{action:\"authored.<id>\",args:{…}} (or an action id string); action:null drops it.")
        }
        if let value = input["say"], value != .null, value.stringValue == nil {
            return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args", "say is fixed words or null.")
        }
        guard let words = queueText("text", in: input) else {
            return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args", "Pass text: the step in your own words.")
        }
        let rhythm = input["when"].flatMap(SchedulerJobNormalizer.rhythm)
        // Schedule objects with once/at and relative times are single moments, not repeating rhythms.
        var whenText = queueText("when", in: input)
        if let relative = whenText.flatMap(Self.relativeMoment) {
            whenText = "at " + ISO8601DateFormatter().string(from: Date().addingTimeInterval(relative))
        }
        if rhythm == nil, case .object(let fields)? = input["when"],
           let at = (fields["at"] ?? fields["run_at"] ?? fields["runAt"])?.scalarText {
            whenText = "at " + at
        } else if rhythm == nil, case .object(let fields)? = input["when"], let relative = Self.relativeMoment(fields) {
            whenText = "at " + ISO8601DateFormatter().string(from: Date().addingTimeInterval(relative))
        } else if rhythm == nil, case .object? = input["when"] {
            return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                """
                    A when object is a rhythm in the scheduler's grammar: {type: hourly|daily|weekly|monthly|cron|every, …}, e.g. {type:\"cron\", \
                    expression:\"0 9,16 * * *\"}. A single time is at <ISO time> or {at:\"<ISO time>\"}; an amount with no rhythm type, e.g. \
                    {seconds:120}, is one moment that far from now.
                    """)
        }
        let condition = rhythm == nil ? MyQueue.When(whenText) : .every
        if condition == .every, rhythm == nil, editing == nil || named.contains("when") {
            return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                "Use every N minutes, hours or days, a five-field cron expression, or a recurring schedule object such as {type:\"weekly\", …}.")
        }
        guard let when = condition else {
            let supplied = whenText ?? ""
            let words = supplied.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == ":" })
            if words.first?.lowercased() == "when_user_messages", words.count > 1 {
                return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                    "No door \"\(words[1])\". A door is where the person writes from: \(MyQueue.Door.listed); omit it for any door.")
            }
            let moment = supplied.lowercased().hasPrefix("at ") ? String(supplied.dropFirst(3)) : supplied
            return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                """
                    Read when \"\(supplied)\": \(MyQueue.When.timeReading(moment).interpretation). Use a complete local date/time (e.g. Sun Nov 1 at \
                    06:00) or at <ISO time with offset>. Other moments: next_turn, own_turn, when_user_messages [\(MyQueue.Door.listed)], \
                    when_user_here, when_user_away, \
                    on_news <words>, on <signal>, after_card <id>, in N seconds|minutes|hours|days, an amount such as {seconds:120}, or a rhythm \
                    (every N hours, every <cron>, or a schedule object).
                    """)
        }
        var untilText = queueText("until", in: input)
        if let relative = untilText.flatMap(Self.relativeMoment) {
            untilText = "at " + ISO8601DateFormatter().string(from: Date().addingTimeInterval(relative))
        }
        if case .object(let fields)? = input["until"],
           let at = (fields["at"] ?? fields["run_at"] ?? fields["runAt"])?.stringValue,
           let moment = MyQueue.When("at " + at), case .at = moment {
            untilText = "at " + at
        } else if case .object(let fields)? = input["until"], let relative = Self.relativeMoment(fields) {
            untilText = "at " + ISO8601DateFormatter().string(from: Date().addingTimeInterval(relative))
        } else if let value = input["until"], value != .null, value.stringValue == nil {
            return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                """
                    until is a moment {at:\"<ISO time>\"}, at <ISO time>, in N seconds|minutes|hours|days, an amount such as {seconds:120}, words \
                    for when it is done, or standing.
                    """)
        }
        let until = untilText.map { MyQueue.Until($0) } ?? (rhythm == nil ? .once : .standing)
        if case .time(let ends) = until, ends <= Date(), editing == nil || named.contains("until") {
            return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                "until \(untilText ?? "") has already passed. Give a time ahead, words for when it is done, or standing.")
        }
        // Only a known approval or interaction can own an after_card condition.
        if let card = when.card, editing == nil || named.contains("when") {
            guard try await AgentScreen.queueCard(card, dataRoot: store.dataRoot) != nil else {
                return Self.doorRefusal("not_found", "No card \(card); nothing was queued.", remedy: "fix_args",
                    "after_card takes the id of a card: the approvalId or card_id a carded call returned.")
            }
        }
        let steer = PeerDataTaint.carried(turn: turn, surface: surface)
        let proposed = DeskStep(words: words, when: when.stored, card: when.card, action: action,
                                                    peers: steer.sources,
                                                    session: turn.verifiedSessionID,
                                                    origin: turn.originPrincipal,
                                                    replyRoute: TurnEnvelope.current(turn: turn, surface: surface).persistedMetadata(),
                                                    rhythm: rhythm, until: until.stored, say: queueText("say", in: input),
                                                    fileAccessCeiling: turn.fileAccessCeiling)
        if let editing {
            if editing.step.causalWait != nil, !named.isDisjoint(with: ["action", "say", "when"]) {
                return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args",
                    "Clear wait_for before changing this step's habit, speech or timing.")
            }
            if let conflict = try await store.runHold(editing.item.handle) { return conflict.refusal(editing.name) }
            var step = editing.step
            if named.contains("action") { step.action = proposed.action }
            if named.contains("say") { step.say = proposed.say }
            if named.contains("when") { step.when = proposed.when; step.card = proposed.card; step.rhythm = proposed.rhythm; step.clockStart = nil }
            if named.contains("until") { step.until = input["until"] == .null ? nil : proposed.until }
            // An edit adds its own steerers and never erases the step's: a peer's words stay marked as a peer's.
            step.peers = Array(Set(step.peers + steer.sources)).sorted()
            step.fileAccessCeiling = proposed.fileAccessCeiling
            let updated = try await MyQueue.update(editing, step: step, store: store)
            let change: MyQueue.Change = updated.item.updatedAt == editing.item.updatedAt ? .reused : .updated
            return await queueFilingReceipt(updated, change: change, reportedChange: .updated, store: store)
        }
        let queued = try await MyQueue.add(proposed, store: store)
        turn.execution?.noteFiledPromise()
        return await queueFilingReceipt(queued.entry, change: queued.change, store: store)
    }

    @MainActor
    private func queueFilingReceipt(_ entry: MyQueue.Entry, change: MyQueue.Change, reportedChange: MyQueue.Change? = nil,
                                    store: SwiftNativeDeskStore) async -> JSONValue {
        let filed = queueReceipt(entry, (reportedChange ?? change).rawValue)
        guard case .afterCard? = MyQueue.when(entry) else { return filed }
        var receipt = JSONValue.objectOrEmpty(filed)
        let result: Result<AgentScreen.CardFollowUp?, any Error> = await settle {
            do { return .success(try await AgentScreen.reconcileFiledCard(entry, store: store)) }
            catch { return .failure(error) }
        }
        switch result {
        case .success(let followUp):
            if let followUp { receipt["card_follow_up"] = .string(followUp.rawValue) }
        case .failure(let error):
            let failure = Self.ownedFailure(error, code: "queue_card_settlement_failed", owner: "MY QUEUE",
                instruction: "Read the saved step and card outcome, then resolve the reported settlement error.",
                next: ["page": .string("desk")], effects: change == .reused ? .unknown : .occurred)
            receipt.merge(JSONValue.objectOrEmpty(failure)) { _, value in value }
        }
        return .object(receipt)
    }

    /// Close the exact open step and return its receipt.
    @MainActor
    private func closeQueueStep(verb: String, input: [String: JSONValue], store: SwiftNativeDeskStore) async throws -> JSONValue {
        guard let id = queueText("id", in: input) else {
            return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args", "Pass id: the step's desk.N from home.")
        }
        let alias = id.lowercased().hasPrefix("desk.") ? String(id.dropFirst(5)) : id
        let state = try await store.liveState()
        let open = MyQueue.entries(state)
        guard let entry = open.first(where: { $0.item.alias == alias || $0.item.handle == id }) else {
            return try await missingQueueStep(id, alias: alias, in: state, verb: verb, store: store)
        }
        if let conflict = try await store.runHold(entry.item.handle) {
            return conflict.refusal(entry.name)
        }
        let dropped = verb == "drop"
        let ending = try await MyQueue.finish(entry, dropped: dropped,
            why: queueText("reason", in: input) ?? (dropped ? "dropped" : "done"), store: store)
        var receipt = JSONValue.objectOrEmpty(queueReceipt(entry, dropped && ending == .requested ? "dropped" : "done"))
        receipt["effects"] = .string("occurred")
        if ending == .finishedHabit { receipt["outcome_summary"] = .string("habit finished") }
        return .object(receipt)
    }

    /// Return saved completion evidence or the exact-id refusal.
    @MainActor
    private func missingQueueStep(_ id: String, alias: String, in state: DeskState, verb: String,
                                  store: SwiftNativeDeskStore) async throws -> JSONValue {
        if let terminal = try await terminalQueueStep(id, alias: alias, in: state, verb: verb, store: store) { return terminal }
        return Self.doorRefusal("not_found", "\(id) is not an open MY QUEUE step; nothing changed.", remedy: "fix_args",
            "Read the Desk for its exact desk.N or handle. Missing work is not proof of completion.")
    }

    /// Read terminal evidence from the live Desk or its archive.
    @MainActor
    private func terminalQueueStep(_ id: String, alias: String, in state: DeskState, verb: String,
                                   store: SwiftNativeDeskStore) async throws -> JSONValue? {
        if let item = state.items.first(where: { $0.alias == alias || $0.handle == id }) {
            let resume = MyQueue.resumeRun(findingKey: item.findingKey)
            let queueRow = item.project == MyQueue.project && (item.step != nil || resume != nil)
            guard item.status.isTerminal, queueRow || item.step?.promiseCaptures.isEmpty == false else { return nil }
            let receipt = queueCompletion(verb: verb, "desk." + item.alias, done: item.status == .done, at: item.closedAt, summary: item.summary,
                evidence: ["notes": .array(item.notes.map { $0.toJSON() }), "refs": .array(item.refs.map { $0.toJSON() })])
            return await settleDroppedQueueRun(receipt, findingKey: item.findingKey, store: store)
        }
        // The archive retains exact handles, not visible numbers or the full live step. Never infer an alias or require discarded refs.
        guard let archived = try await store.archivedRecords().first(where: { $0.handle == id }),
              archived.project == MyQueue.project || archived.refs.contains(where: {
                  if case .step(let step) = $0.kind { return !step.promiseCaptures.isEmpty }; return false
              }), archived.finalStatus != .superseded else { return nil }
        let receipt = queueCompletion(verb: verb, archived.handle, done: archived.finalStatus == .done, at: archived.closedAt, summary: archived.summary,
            evidence: ["refs": .array(archived.refs.map { $0.toJSON() }),
                       "notes": .array(archived.carriedNotes.map { $0.toJSON() }),
                       "decisions": .array(archived.decisions.map(JSONValue.string)),
                       "artifacts": .array(archived.artifacts.map(JSONValue.string))])
        return await settleDroppedQueueRun(receipt, findingKey: archived.findingKey, store: store)
    }

    private func settleDroppedQueueRun(_ receipt: JSONValue, findingKey: String?, store: SwiftNativeDeskStore) async -> JSONValue {
        guard let saved = receipt.objectValue, saved["queue"] == .string("dropped"), saved["status"] == .string("no_change"),
              let run = MyQueue.resumeRun(findingKey: findingKey) else { return receipt }
        return await settle {
            var fields = saved
            do {
                if try MyQueue.abandonDroppedRun(run, store: store) {
                    fields["status"] = .string("ok")
                    fields["effects"] = .string("occurred")
                    fields["checkpoint_released"] = .bool(true)
                }
                return .object(fields)
            } catch {
                return .object(Self.partSettlementFailure(fields, error: error, operation: "ability.queue_checkpoint_cleanup",
                                                          id: run, root: store.dataRoot))
            }
        }
    }

    /// Interpret saved completion evidence in the context of the requested verb.
    @MainActor
    private func queueCompletion(verb: String, _ id: String, done: Bool, at: String?, summary: String?,
                                 evidence: [String: JSONValue]) -> JSONValue {
        let change = done ? "done" : "dropped"
        let when = at.map { " at " + $0 } ?? "; completion time is not recorded"
        let outcome = summary.map { " Saved outcome: " + $0 + "." } ?? " No outcome summary was recorded."
        var fields = evidence
        fields["id"] = .string(id)
        fields["completed_at"] = at.map(JSONValue.string) ?? .null
        fields["outcome_summary"] = summary.map(JSONValue.string) ?? .null
        // Asking for the ending a step already has is granted: nothing changes and its saved completion is the receipt.
        if verb == (done ? "done" : "drop") {
            fields["status"] = .string("no_change"); fields["queue"] = .string(change); fields["effects"] = .string("none")
            fields["confirmation"] = .string("\(id) is already \(change)\(when)." + outcome)
            return .object(fields)
        }
        return Self.failure(done ? "already_done" : "already_dropped", "\(id) is already \(change)\(when)." + outcome,
            extra: fields.merging(["remedy": .object(["kind": .string("none"),
                "instruction": .string("Read the saved completion evidence; this step needs no further closure."), "next_call": .null])]) { _, value in value })
    }

    /// Return the saved step, including the schedule and effective ending.
    @MainActor
    private func queueReceipt(_ entry: MyQueue.Entry, _ change: String) -> JSONValue {
        var fields: [String: JSONValue] = ["status": .string("ok"), "id": .string(entry.name), "handle": .string(entry.item.handle),
                 "queue": .string(change), "owner": .string("agent"),
                 "peerSteering": .object(["sources": .array(entry.step.peers.map(JSONValue.string)),
                                           "elevated": .array(entry.step.elevated.map(JSONValue.string))]),
                 "when": .string(entry.step.causalWait?.trigger.words ?? (entry.step.when + (entry.step.card.map { " " + $0 } ?? ""))),
                 "confirmation": .string("\(entry.name) \(change): \"\(entry.step.words)\"")]
        if change == MyQueue.Change.reused.rawValue { fields["effects"] = .string("none") }
        // Return the interpreted local moments so the caller can verify the schedule.
        if entry.step.rhythm != nil, change != "done", change != "dropped" {
            var times: [JSONValue] = [], cursor = Date()
            while times.count < 3, let next = IntentionClock.next(entry.step, after: cursor) {
                times.append(.string(MyQueue.shown(next))); cursor = next
            }
            fields["next"] = .array(times)
        }
        // Return the effective ending, including defaults, so the caller can confirm what was set.
        fields["until"] = .string({ switch MyQueue.until(entry) {
            case .once: return "once"
            case .standing: return "standing"
            case .time(let date): return "at " + MyQueue.shown(date)
            case .words(let words): return words
        } }())
        if let say = entry.step.say { fields["say"] = .string(say); if entry.step.action == nil, change != "done", change != "dropped" {
            fields["at_its_moment"] = .string(MyQueue.spoken(entry) == nil ? "comes back to you with these words to say"
                : "said to the person, then it comes back to you") } }
        fields["habit"] = entry.step.action ?? .null
        return .object(fields)
    }
}
