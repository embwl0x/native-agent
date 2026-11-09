import ApprovalInbox
import ChatTurnContracts
import AgentWorkspace
import Desk
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import TriggerScheduler
// Blueprint: | `AppToolExecutor+MyQueue.swift` | `runMyQueue`, `runHouseFile`; Exact-id intentions, schedules, habits and closure receipts |

extension AppToolExecutor {
    @MainActor
    func runHouseFile(input: [String: JSONValue], surface: String, turn: Turn) async -> JSONValue {
        guard let title = input["title"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let summary = input["summary"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
              let owner = ["me": BodyFinding.Owner.agent, "builder": .builder, "user": .owner][input["owner"]?.scalarText ?? ""] else {
            return Self.doorRefusal("invalid_input", "Nothing was filed.", remedy: "fix_args",
                                    "Pass title, summary and owner: me, builder or user.")
        }
        let refs: [DeskRef]
        if let value = input["refs"] {
            guard case .array(let values) = value else {
                return Self.doorRefusal("invalid_input", "Nothing was filed.", remedy: "fix_args", "refs takes an array of Desk refs.")
            }
            refs = values.compactMap { value -> DeskRef? in
                if case .string(let text) = value { return DeskRef(kind: .note(text: text)) }
                guard case .object(var fields) = value else { return nil }
                // Creation supplies the new ref's identity. The stored reader never invents an identity for an incomplete saved record.
                if fields["refId"] == nil { fields["refId"] = .string(DeskClock.newRefId()) }
                return DeskRef.fromJSON(.object(fields))
            }
            guard refs.count == values.count else {
                return Self.doorRefusal("invalid_input", "Nothing was filed.", remedy: "fix_args",
                    "Each ref is a string (a note) or {kind: file|url|note|commit|gh_issue|gh_pr|agent|approval|trace, …}.")
            }
        } else { refs = [] }
        do {
            let key = "agent:" + title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let steer = PeerDataTaint.carried(turn: turn, peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                              peerID: turn.envelope?.verifiedUserId)
            let carried = DeskRef(kind: .step(DeskStep(words: summary, when: "own_turn",
                peers: steer.sources, elevated: steer.elevated, session: turn.verifiedSessionID,
                origin: turn.originPrincipal, replyRoute: TurnEnvelope.current(turn: turn, surface: surface).persistedMetadata())))
            let item = try await BodyQueue.file(BodyFinding(key: key, title: title,
                summary: summary, owner: owner,
                // Carry only agent-owned items; builder and user items stay with their owners.
                refs: refs.filter { $0.kind.token != "step" } + (owner == .agent ? [carried] : []), source: .agent),
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            let filedOwner = ["agent": "me", "builder": "builder", "owner": "user"][item.assignee ?? ""] ?? item.assignee
            let ownership = item.assignee == owner.rawValue ? "" : " Owner unchanged: \(filedOwner ?? "unassigned")."
            return .object(["status": .string("ok"), "id": .string("desk." + item.alias),
                            "owner": filedOwner.map(JSONValue.string) ?? .null,
                            "confirmation": .string("Filed: " + item.title + ownership)])
        } catch { return Self.ownedFailure(error, code: "house_file_failed", owner: "Desk",
            instruction: "Read the Desk to reconcile this filing and resolve the reported storage error before filing again.",
            next: ["page": .string("desk")], effects: .unknown) }
    }

    static func relativeMoment(_ text: String) -> TimeInterval? {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard words.count == 3, words[0] == "in", let count = Double(words[1]), count > 0,
              let unit = ["minute": 60.0, "minutes": 60, "min": 60, "mins": 60, "hour": 3_600, "hours": 3_600,
                          "day": 86_400, "days": 86_400][words[2]] else { return nil }
        return count * unit
    }

    /// Queued steps retain peer steering so later execution cannot outrank the originating turn.
    @MainActor
    func runMyQueue(verb: String, input: [String: JSONValue], surface: String, turn: Turn) async -> JSONValue {
        let store = SwiftNativeDeskStore(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        let named = Set(input.keys)
        var input = input
        func text(_ key: String) -> String? {
            input[key]?.scalarText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func completion(_ id: String, done: Bool, at: String?, summary: String?, evidence: [String: JSONValue]) -> JSONValue {
            let change = done ? "done" : "dropped"
            let when = at.map { " at " + $0 } ?? "; completion time is not recorded"
            let outcome = summary.map { " Saved outcome: " + $0 + "." } ?? " No outcome summary was recorded."
            var fields = evidence
            fields["id"] = .string(id)
            fields["completed_at"] = at.map(JSONValue.string) ?? .null
            fields["outcome_summary"] = summary.map(JSONValue.string) ?? .null
            return Self.doorRefusal(done ? "already_done" : "already_dropped",
                "\(id) is already \(change)\(when)." + outcome, remedy: "none",
                "Read the saved completion evidence; this step needs no further closure.", extra: fields)
        }
        func terminalStep(_ id: String, alias: String, in state: DeskState) async throws -> JSONValue? {
            if let item = state.items.first(where: { $0.alias == alias || $0.handle == id }) {
                guard let step = item.step, item.project == MyQueue.project || !step.promiseCaptures.isEmpty,
                      item.status.isTerminal else { return nil }
                return completion("desk." + item.alias, done: item.status == .done, at: item.closedAt, summary: item.summary,
                    evidence: ["notes": .array(item.notes.map { $0.toJSON() }), "refs": .array(item.refs.map { $0.toJSON() })])
            }
            // The archive retains exact handles, not visible numbers or the full live step. Never infer an alias or require discarded refs.
            guard let archived = try await store.archivedRecords().first(where: { $0.handle == id }),
                  archived.project == MyQueue.project || archived.refs.contains(where: {
                      if case .step(let step) = $0.kind { return !step.promiseCaptures.isEmpty }; return false
                  }), archived.finalStatus != .superseded else { return nil }
            return completion(archived.handle, done: archived.finalStatus == .done, at: archived.closedAt, summary: archived.summary,
                evidence: ["refs": .array(archived.refs.map { $0.toJSON() }),
                           "decisions": .array(archived.decisions.map(JSONValue.string)),
                           "artifacts": .array(archived.artifacts.map(JSONValue.string))])
        }
        func missingStep(_ id: String, alias: String, in state: DeskState) async throws -> JSONValue {
            if let terminal = try await terminalStep(id, alias: alias, in: state) { return terminal }
            return Self.doorRefusal("not_found", "\(id) is not an open MY QUEUE step; nothing changed.", remedy: "fix_args",
                "Read the Desk for its exact desk.N or handle. Missing work is not proof of completion.")
        }
        func receipt(_ entry: MyQueue.Entry, _ change: String) -> JSONValue {
            var fields: [String: JSONValue] = ["status": .string("ok"), "id": .string(entry.name), "queue": .string(change), "owner": .string("agent"),
                     "peerSteering": .object(["sources": .array(entry.step.peers.map(JSONValue.string)),
                                               "elevated": .array(entry.step.elevated.map(JSONValue.string))]),
                     "when": .string(entry.step.when + (entry.step.card.map { " " + $0 } ?? "")),
                     "confirmation": .string("\(entry.name) \(change): \"\(entry.step.words)\"")]
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
            if let say = entry.step.say { fields["say"] = .string(say) }
            fields["habit"] = entry.step.action ?? .null
            return .object(fields)
        }
        do {
            if verb == "add" || verb == "update" {
                var editing: MyQueue.Entry?
                if verb == "update" {
                    guard let id = text("id") else {
                        return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args", "Pass id: the step's desk.N.")
                    }
                    let alias = id.hasPrefix("desk.") ? String(id.dropFirst(5)) : id
                    let state = try await store.liveState()
                    guard let entry = MyQueue.entries(state).first(where: { $0.item.alias == alias || $0.item.handle == id }) else {
                        return try await missingStep(id, alias: alias, in: state)
                    }
                    if let conflict = try await store.runHold(entry.item.handle) {
                        return conflict.refusal(entry.name)
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
                guard let words = text("text") else {
                    return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args", "Pass text: the step in your own words.")
                }
                let rhythm = input["when"].flatMap { value -> JSONValue? in
                    if case .string(let raw) = value, !["every", "cron"].contains(raw.split(separator: " ").first.map { $0.lowercased() } ?? "") { return nil }
                    return SchedulerJobNormalizer.rhythm(value)
                }
                // Schedule objects with once/at and relative times are single moments, not repeating rhythms.
                var whenText = text("when")
                if let relative = whenText.flatMap(Self.relativeMoment) {
                    whenText = "at " + ISO8601DateFormatter().string(from: Date().addingTimeInterval(relative))
                }
                if rhythm == nil, case .object(let fields)? = input["when"],
                   let at = (fields["at"] ?? fields["run_at"] ?? fields["runAt"])?.scalarText {
                    whenText = "at " + at
                } else if rhythm == nil, case .object? = input["when"] {
                    return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                        """
                            A when object is a rhythm in the scheduler's grammar: {type: hourly|daily|weekly|monthly|cron|every, …}, e.g. {type:\"cron\", \
                            expression:\"0 9,16 * * *\"}. A single time is at <ISO time>.
                            """)
                }
                guard let when = rhythm == nil ? MyQueue.When(whenText) : .every else {
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
                            on_news <words>, on <signal>, after_card <id>, in N minutes|hours|days, or a rhythm (every N hours, every <cron>, or a schedule \
                            object).
                            """)
                }
                var untilText = text("until")
                if let relative = untilText.flatMap(Self.relativeMoment) {
                    untilText = "at " + ISO8601DateFormatter().string(from: Date().addingTimeInterval(relative))
                }
                if case .object(let fields)? = input["until"],
                   let at = (fields["at"] ?? fields["run_at"] ?? fields["runAt"])?.stringValue,
                   let moment = MyQueue.When("at " + at), case .at = moment {
                    untilText = "at " + at
                } else if let value = input["until"], value != .null, value.stringValue == nil {
                    return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                        "until is a moment {at:\"<ISO time>\"}, at <ISO time>, in N minutes|hours|days, words for when it is done, or standing.")
                }
                let until = untilText.map { MyQueue.Until($0) } ?? (rhythm == nil ? .once : .standing)
                if case .time(let ends) = until, ends <= Date(), editing == nil || named.contains("until") {
                    return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                        "until \(untilText ?? "") has already passed. Give a time ahead, words for when it is done, or standing.")
                }
                if let card = when.card, editing == nil || named.contains("when") {
                    do { _ = try await SwiftNativeApprovalInbox(root: store.dataRoot).get(card) } catch {
                        return Self.doorRefusal("not_found", "No card \(card); nothing was queued.", remedy: "fix_args",
                            "after_card takes the approvalId a carded call returned.")
                    }
                }
                let steer = PeerDataTaint.carried(turn: turn, peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                                  peerID: turn.envelope?.verifiedUserId)
                let proposed = DeskStep(words: words, when: when.stored, card: when.card, action: action,
                                                            peers: steer.sources, elevated: steer.elevated,
                                                            session: turn.verifiedSessionID,
                                                            origin: turn.originPrincipal,
                                                            replyRoute: TurnEnvelope.current(turn: turn, surface: surface).persistedMetadata(),
                                                            rhythm: rhythm, until: until.stored, say: text("say"))
                if let editing {
                    var step = editing.step
                    if named.contains("action") { step.action = proposed.action }
                    if named.contains("say") { step.say = proposed.say }
                    if named.contains("when") { step.when = proposed.when; step.card = proposed.card; step.rhythm = proposed.rhythm; step.clockStart = nil }
                    if named.contains("until") { step.until = input["until"] == .null ? nil : proposed.until }
                    step.peers = steer.sources; step.elevated = steer.elevated
                    return receipt(try await MyQueue.update(editing, step: step, store: store), "updated")
                }
                let queued = try await MyQueue.add(proposed, store: store)
                return receipt(queued.entry, queued.change.rawValue)
            }
            guard let id = text("id") else {
                return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args", "Pass id: the step's desk.N from home.")
            }
            let alias = id.lowercased().hasPrefix("desk.") ? String(id.dropFirst(5)) : id
            let state = try await store.liveState()
            let open = MyQueue.entries(state)
            guard let entry = open.first(where: { $0.item.alias == alias || $0.item.handle == id }) else {
                return try await missingStep(id, alias: alias, in: state)
            }
            if let conflict = try await store.runHold(entry.item.handle) {
                return conflict.refusal(entry.name)
            }
            let dropped = verb == "drop"
            try await MyQueue.finish(entry, dropped: dropped, why: text("reason") ?? (dropped ? "dropped" : "done"), store: store)
            return receipt(entry, dropped ? "dropped" : "done")
        } catch let error as MyQueue.RunCleanupFailure {
            return .object(Self.partSettlementFailure(Self.partFields(receipt(error.entry, verb == "drop" ? "dropped" : "done")),
                error: error.underlying, operation: "ability.queue_checkpoint_cleanup",
                id: error.runID, root: store.dataRoot))
        } catch is MyQueue.Superseded {
            do {
                let state = try await store.liveState()
                if let id = text("id") {
                    let alias = id.lowercased().hasPrefix("desk.") ? String(id.dropFirst(5)) : id
                    if let terminal = try await terminalStep(id, alias: alias, in: state) { return terminal }
                }
                return Self.doorRefusal("queue_changed", "The queued step changed before this operation; nothing changed.",
                    remedy: "fix_args", "Read its current Desk record before changing it.")
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
}
