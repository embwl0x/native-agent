import ApprovalInbox
import ChromeControl
import Desk
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
import Transcripts
// Blueprint: | `HomeFace+Rows.swift` | Home's sections as keyed facts with the stem's verdict codes; approvals and the night's trials as the person's levers |

extension HomeFace {
    /// The person's say over the agent on Home: each approval waiting on the person, and the night's trials, drawn by the stem beside whatever
    /// the face draws. A read that has not landed or failed stands here too, so a missing reading never reads as nothing to decide.
    static func levers(_ world: AgentWorld, now: Date) -> [PartFace.Section] {
        let night = trials(world, now: now)
        return approvals(world) + refusedRuns(world)
            + (night.isEmpty ? [] : [.init(id: TrialLevers.sectionID, title: TrialLevers.sectionTitle, style: .list, rows: night)])
    }

    /// A refused run is an answer with a cause, not a repair debt. Home reads its accounting owner directly.
    private static func refusedRuns(_ world: AgentWorld) -> [PartFace.Section] {
        var rows = world.abilityRuns.compactMap { id, value -> (id: String, run: [String: JSONValue])? in
            guard let run = value.objectValue?["lastRun"]?.objectValue, run["outcome"] == .string("refused") else { return nil }
            return (id, run)
        }.sorted { ($0.run["at"]?.stringValue ?? "", $0.id) > ($1.run["at"]?.stringValue ?? "", $1.id) }.prefix(5).map { entry in
            let run = entry.run, fault = run["error"]?.objectValue ?? run["stopped"]?.objectValue ?? run
            let cause = run["detail"]?.stringValue ?? fault["detail"]?.stringValue ?? fault["message"]?.stringValue ?? fault["reason"]?.stringValue
                ?? "The cause was not retained for this run; inspect its dispatch receipt."
            return PartFace.Row(id: "ability-run:" + entry.id, title: entry.id,
                detail: AgentScreen.failureReason(ContextSecretContentPolicy.redactedFragment(cause)),
                value: "Refused", at: run["at"]?.stringValue, tone: .attention, open: "page:tools/" + entry.id)
        }
        if let failure = world.failures["ability runs"] {
            rows.append(.init(id: "ability-runs:failed", title: "Ability runs unavailable", detail: failure, tone: .failed))
        } else if world.unread.contains("ability runs") {
            rows.append(.init(id: "ability-runs:unread", title: "Ability runs not read yet", tone: .attention))
        }
        return rows.isEmpty ? [] : [.init(id: "ability-runs", title: "Refused ability runs", style: .list, rows: rows)]
    }

    /// The night's trials (`TrialLevers`, the producer every page shares), or the stem's words for a record not read yet or failed.
    static func trials(_ world: AgentWorld, now: Date) -> [PartFace.Row] {
        var rows = TrialLevers.rows(world.trials, agent: world.profile.map { AgentScreen.clip($0.name, 40) } ?? "The agent", now: now)
        if let failure = world.failures["trials"] {
            rows.append(.init(id: "trials:failed", title: "Trials unavailable", detail: failure, tone: .failed))
        } else if world.unread.contains("trials") {
            rows.append(.init(id: "trials:unread", title: "Trials not read yet", tone: .attention))
        }
        return rows
    }

    /// Each approval waiting on the person.
    static func approvals(_ world: AgentWorld) -> [PartFace.Section] {
        var rows = world.approvals.map { approval in
            let matter = approval.matter
            return PartFace.Row(id: "approval:" + approval.id,
                title: AgentScreen.clip(matter.title, 120),
                value: "Asking first", at: approval.lastRequestedAt ?? approval.createdAt, tone: .attention, open: "approval:" + approval.id)
        }
        if let failure = world.failures["approvals"] {
            rows.append(.init(id: "approvals:failed", title: "Approvals unavailable", detail: failure, tone: .failed))
        } else if world.unread.contains("approvals") {
            rows.append(.init(id: "approvals:unread", title: "Approvals not read yet", tone: .attention))
        }
        return rows.isEmpty ? [] : [.init(id: "approvals", title: "Asking first", style: .list, rows: rows)]
    }

    /// The agent's latest thoughts: when, how each settled, whether a care moved after it, and what it attended.
    static func thoughts(_ world: AgentWorld) -> [JSONValue] {
        world.thoughts.map { line -> JSONValue in
            let thought = line.thought
            return fact([
                "id": .string(thought.id), "at": recorded(thought.at), "outcome": text(thought.outcome?.status),
                "mattered": .bool(thought.claims.contains { $0.claim == Thought.careMoved }),
                "node": text(thought.thought?.node), "kind": text(thought.thought?.kind),
                "through": .array((thought.thought?.through ?? []).map(JSONValue.string)),
                "count": .int(Int64(thought.thought?.happenings.count ?? 0)),
                "attended": .array(line.attended.compactMap { $0.happening.map(happening) }),
            ])
        }
    }

    /// What is owed, newest twelve, and how many in all.
    static func owed(_ world: AgentWorld) -> JSONValue {
        .object(["count": .int(Int64(world.owedToMe.count)), "rows": .array(world.owedToMe.prefix(12).compactMap { owed -> JSONValue? in
            guard case .object(var fields)? = owed.happening.map(happening) else { return nil }
            fields["id"] = .string(owed.id)
            fields["at"] = recorded(owed.at) ?? .null
            return .object(fields)
        })])
    }

    /// A happening as the face reads it; `quoted`: an agent's words are among its words.
    private static func happening(_ happening: Happening) -> JSONValue {
        fact(["kind": .string(happening.kind.rawValue), "door": .string(happening.door), "words": .string(happening.words),
              "quoted": .bool(happening.peers != nil || happening.elevated != nil), "returns": .bool(happening.route != nil)])
    }

    static func waits(_ world: AgentWorld, keys: inout RowKeys) -> [JSONValue] {
        var rows: [JSONValue] = []
        for item in (world.desk?.items ?? []).filter(OwnerAttentionPolicy.waitsOnOwner).sorted(by: { $0.updatedAt > $1.updatedAt }) {
            keys.add("desk." + item.alias, open: "page:desk/" + item.handle)
            rows.append(fact(["key": .string("desk." + item.alias), "kind": .string("desk"), "title": .string(AgentScreen.clip(item.title, 100)),
                "at": .string(item.updatedAt)]))
        }
        for item in world.asksToOpen {
            keys.add("ask:" + item.id, open: "card:" + item.id)
            rows.append(fact(["key": .string("ask:" + item.id), "kind": .string("ask"), "title": .string(AgentScreen.clip(item.title, 100)),
                "detail": .string(AgentScreen.clip(item.summary, 140)), "at": .string(item.created_at)]))
        }
        return rows
    }

    static func repairs(_ open: [Experience], person: Bool, keys: inout RowKeys, cache: inout [String: RepairRow]) -> [JSONValue] {
        open.filter { ($0.owes["repair"]?.to == "person") == person }.map { act -> JSONValue in
            keys.add(act.id, open: "page:home/desk")
            if let kept = cache[act.id], kept.source == act { return kept.facts }
            let debt = RepairDebt(act)
            let verb: String?
            do { verb = try repairVerb(debt.nextCall).map { "repair with " + $0 } }
            catch { verb = "Repair call unreadable: " + error.localizedDescription }
            let words = [act.face?.words, debt.tap, verb].compactMap { $0 }.map(AgentScreen.failureReason).joined(separator: " · ")
            let row = fact(["key": .string(act.id), "kind": .string("repair"), "title": .string(AgentScreen.failureReason(repairTitle(debt.operation))),
                "detail": .string(AgentScreen.clip(words, 240)), "state": text(act.outcome?.status), "at": .string(act.at)])
            cache[act.id] = RepairRow(source: act, facts: row)
            return row
        }
    }

    /// An owed repair named in words: its operation's head and any word-shaped subject. Ids and counters stay in the row's id, where the
    /// door's repair verbs read them.
    static func repairTitle(_ operation: String?) -> String {
        guard let operation, let head = operation.split(separator: ":").first, !head.isEmpty else { return "A repair with no recorded operation" }
        func words(_ part: Substring) -> String { part.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") }
        let subject = operation.split(separator: ":").dropFirst().filter { part in
            part.count <= 40 && !part.contains(where: { $0.isNumber || $0 == "/" })
        }.map(words)
        let named = words(head)
        let title = named.prefix(1).uppercased() + named.dropFirst() + " failed"
        return subject.isEmpty ? title : title + ": " + subject.joined(separator: ", ")
    }

    /// The repair call's verb alone (its action, else its tool); the call's arguments stay with the debt.
    static func repairVerb(_ call: String?) throws -> String? {
        guard let call else { return nil }
        guard case .object(let fields) = try JSONValue.parse(Data(call.utf8)) else {
            throw PersistenceCoreError.ioFailure("The recorded repair call is not an object; repair its next_call claim.")
        }
        if case .object(let input)? = fields["input"], case .string(let action)? = input["action"] { return action }
        if case .string(let tool)? = fields["tool"] { return tool }
        throw PersistenceCoreError.ioFailure("The recorded repair call names neither an input.action nor a tool; repair its next_call claim.")
    }

    /// MY QUEUE's steps with the stem's verdict on each (`state`): `unread` (its condition evidence has not landed), `blocked` (with `blockers`),
    /// `cycle`, `deferred`, `conditions`, `conditions_unavailable`, `ready`, `stopped`, `waits` (with `when`) or `unavailable` (with `detail`).
    static func queue(_ world: AgentWorld, now: Date, keys: inout RowKeys) -> [JSONValue] {
        var rows: [JSONValue] = []
        if let desk = world.desk {
            let plan = DeskSequencing.compute(desk, now: now)
            for entry in MyQueue.entries(desk) {
                var state = "unread", blockers: [String] = [], when: String?, detail: String?
                let blocked = plan.byHandle[entry.item.handle]?.effectiveBlockers ?? []
                if let evidence = world.queueEvidence,
                   evidence.revision == desk.generatedTs, world.failures["queue evidence"] == nil {
                    if !blocked.isEmpty {
                        state = "blocked"
                        blockers = blocked.map { blocker in
                            guard blocker.hasPrefix("exp:") else {
                                return "on desk." + (desk.items.first { $0.handle == blocker }?.alias ?? blocker)
                            }
                            let id = String(blocker.dropFirst(4))
                            guard let condition = evidence.conditions[id] else { return "on experience \(id) (unavailable)" }
                            return "on " + MyQueueReady.conditionName(condition) + " " + id
                        }
                    } else if plan.byHandle[entry.item.handle]?.isReady == false {
                        let step = plan.byHandle[entry.item.handle]
                        state = step?.blockedByCycle == true ? "cycle" : step?.isDeferred == true ? "deferred" : "conditions"
                    } else if plan.byHandle[entry.item.handle] == nil {
                        state = "conditions_unavailable"
                    } else {
                        var context = evidence.context
                        context.now = now
                        switch MyQueue.readiness(entry, context) {
                        case .ready: state = "ready"
                        case .waiting:
                            if entry.step.status == "stopped" { state = "stopped" } else { state = "waits"; when = entry.step.when }
                        case .unavailable(let reason): state = "unavailable"; detail = AgentScreen.failureReason(reason)
                        }
                    }
                }
                let note = entry.item.notes.max { $0.ts < $1.ts }
                // A peer's step froze the peer's id into its Desk title at filing; the contact list names that peer now.
                let from = entry.peerBorn ? (entry.step.peers + entry.step.elevated).map { peer in
                    world.contacts.first { $0.id == peer || $0.agents.contains(peer) }?.name ?? "an agent no longer in contacts"
                } : nil
                let step = PartFace.Value.string(entry.name)
                keys.add(entry.name, open: "page:desk/" + entry.item.handle,
                    actions: [(PartFace.Call("queue.done", ["id": step]), false), (PartFace.Call("queue.drop", ["id": step]), true)])
                rows.append(fact([
                    "key": .string(entry.name), "kind": .string("step"), "title": .string(AgentScreen.clip(entry.item.title, 100)),
                    "from": from.map { JSONValue.array($0.map(JSONValue.string)) },
                    "words": entry.peerBorn ? nil : JSONValue.string(AgentScreen.clip(entry.step.words, 140)),
                    "inferred": .bool(entry.step.source != nil),
                    "blockedReason": text(entry.item.blockedReason.map { AgentScreen.clip($0, 100) }),
                    "note": text(note.map { AgentScreen.clip($0.text, 100) }),
                    "state": .string(state), "blockers": blockers.isEmpty ? nil : JSONValue.array(blockers.map(JSONValue.string)), "when": text(when),
                    "detail": text(detail), "at": .string(note?.ts ?? entry.item.updatedAt),
                ]))
            }
            for item in desk.items where item.assignee == "agent" && item.project != MyQueue.project
                && MyQueue.entry(item) == nil && !item.status.isTerminal && !item.blockedOn.isEmpty {
                keys.add("blocked:desk." + item.alias, open: "page:desk/" + item.handle)
                rows.append(fact(["key": .string("blocked:desk." + item.alias), "kind": .string("blocked"),
                    "title": .string(AgentScreen.clip(item.title, 100)), "detail": text(item.blockedReason.map { AgentScreen.clip($0, 140) }),
                    "waitsOn": .array(item.blockedOn.map(JSONValue.string)), "at": .string(item.updatedAt)]))
            }
            for item in BodyQueue.open(desk) where MyQueue.entry(item) == nil {
                keys.add("body:desk." + item.alias, open: "page:desk/" + item.handle)
                rows.append(fact(["key": .string("body:desk." + item.alias), "kind": .string("body"),
                    "title": .string(AgentScreen.clip(item.title, 100)), "assignee": text(item.assignee), "at": .string(item.updatedAt)]))
            }
        }
        if world.reviews.count > 0 {
            keys.add("memory.proposals", open: "page:memory_proposals")
            rows.append(fact(["key": .string("memory.proposals"), "kind": .string("reviews"), "count": .int(Int64(world.reviews.count)),
                "capped": .bool(world.reviews.capped)]))
        }
        for contact in world.contacts {
            let record = AgentScreen.latest(contact, records: world.records)
            if record?.sendEvidence["needs_input"] == .bool(true) || record?.sendEvidence["needs_authentication"] == .bool(true) {
                keys.add("input:" + contact.id, open: "page:home/agent/" + contact.id)
                rows.append(fact(["key": .string("input:" + contact.id), "kind": .string("input"), "name": .string(AgentScreen.clip(contact.name, 60)),
                    "at": record.map { JSONValue.string(clock($0.updatedAt)) }]))
            }
        }
        return rows
    }

    /// The agents in conversation with this agent, newest exchange first, with the stem's verdict on each (`state`): `unread`, `unavailable`,
    /// `send_failed`, `problem` (with `problem`), `ready`, `replied_in_chat`, `replied`, `waiting`, `asks_input`, `send_unconfirmed`,
    /// `needs_attention`, `sent`, `none`, or `execution` (with `run`, `delivery`, `failed`); then discovery offers.
    static func people(_ world: AgentWorld, keys: inout RowKeys) -> [JSONValue] {
        var rows = world.contacts.map { contact -> (at: String?, fact: JSONValue) in
            let record = AgentScreen.latest(contact, records: world.records), chat = world.threads[contact.id]
            let health = world.health[world.healthID(for: contact, record: record)]
            var state = "none", problem: String?, execution: [String: JSONValue?] = [:]
            // A contact's time is its last exchange, never the record's bookkeeping writes (a read schedule moves those every few seconds).
            var at = record.flatMap { $0.exchanges?.last.map { $0.settledAt ?? $0.sentAt } ?? $0.operationStartedAt }
            if world.unread.contains("people") {
                state = world.failures["people"] == nil ? "unread" : "unavailable"
            } else if let record, record.phase != "sending", record.sendFailed {
                state = "send_failed"
            } else if let word = health?.problemWord {
                state = "problem"; problem = word; at = health?.checkedAt
            } else if let record, health?.resolves(record) == true {
                state = "ready"; at = health?.checkedAt
            } else if let heard = chat?.heard, heard > (record?.updatedAt ?? .distantPast) {
                state = "replied_in_chat"; at = heard
            } else if let record {
                let receipt = record.sendEvidence
                let message = record.readInput?["message_id"]?.stringValue
                if ["sending", "waiting"].contains(record.phase) {
                    if let message, let answered = world.answered[message] {
                        state = "replied"; at = answered
                    } else { state = "waiting"; at = record.operationStartedAt ?? record.updatedAt }
                } else if receipt["needs_input"] == .bool(true) || receipt["needs_authentication"] == .bool(true) {
                    state = "asks_input"
                } else if record.phase == "attention" {
                    state = receipt["status"] == .string("outcome_unknown") ? "send_unconfirmed" : "needs_attention"
                } else if record.retainedReply?.text ?? record.exchanges?.last?.reply != nil {
                    state = "replied"
                    at = record.exchanges?.last?.settledAt ?? record.exchanges?.last?.sentAt ?? at
                } else { state = "sent" }
            }
            let exchangeAt = record?.exchanges?.last?.settledAt ?? record?.operationStartedAt ?? record?.updatedAt ?? .distantPast
            if !world.unread.contains("people"), record?.sendFailed != true, health?.problem == nil,
               let job = world.jobs.first(where: { $0.agent == contact.id || contact.agents.contains($0.agent) }),
               let jobAt = (job.completedAt ?? job.startedAt ?? job.createdAt).flatMap(AgentScreen.date),
               jobAt > max(exchangeAt, chat?.at ?? .distantPast) {
                state = "execution"
                execution = ["run": .string(job.runStatus ?? job.status ?? job.state ?? "not recorded"), "delivery": text(job.deliveryOutcome),
                    "failed": .bool(job.executionError != nil)]
                at = jobAt
            }
            keys.add(contact.id, open: "page:home/agent/" + contact.id)
            let shown = at.map(clock)
            return (shown, fact(["key": .string(contact.id), "kind": .string("contact"), "name": .string(AgentScreen.clip(contact.name, 60)),
                "about": text(contact.kind), "state": .string(state), "problem": text(problem),
                "execution": execution.isEmpty ? nil : fact(execution), "at": text(shown)]))
        }
        rows.sort { ($0.at ?? "") > ($1.at ?? "") }
        var found: [JSONValue] = []
        for id in world.found.keys.sorted() {
            guard let offer = world.found[id] else { continue }
            keys.add("found:" + id, open: "page:agents")
            found.append(fact(["key": .string("found:" + id), "kind": .string("found"), "name": .string(AgentScreen.clip(offer.name, 60)),
                "app": .bool(id.hasPrefix("app:")), "at": text(offer.offeredAt.map(clock))]))
        }
        return rows.map(\.fact) + found
    }

    /// Helpers, running ones first then by latest run, with the stem's verdict (`state`): `unread` (the run queue is not read), `running`,
    /// `never`, or the latest run's status (with `failed`).
    static func helpers(_ world: AgentWorld, keys: inout RowKeys) -> [JSONValue] {
        world.bots.sorted {
            (world.running.contains($0.id) ? 1 : 0, world.latest[$0.id]?.runAt ?? .distantPast)
                > (world.running.contains($1.id) ? 1 : 0, world.latest[$1.id]?.runAt ?? .distantPast)
        }.map { bot -> JSONValue in
            let entry = world.latest[bot.id], running = world.running.contains(bot.id)
            var state = "never", failed = false
            if world.unread.contains("running helpers") { state = "unread" }
            else if running { state = "running" }
            else if let entry {
                state = entry.runtimeStatus.rawValue
                failed = entry.runtimeStatus == .failed || entry.runtimeStatus == .interrupted
            }
            let key = "bot:" + bot.id.uuidString
            keys.add(key, open: "page:home/agent/" + key)
            return fact(["key": .string(key), "name": .string(AgentScreen.clip(bot.name, 60)),
                "detail": .string(entry.map { AgentScreen.clip($0.headline, 120) } ?? StandingBotSchedule.words(bot.cadence)),
                "state": .string(state), "failed": .bool(failed), "paused": .bool(bot.paused),
                "at": running ? nil : text(entry.map { clock($0.runAt) })])
        }
    }

    static func senses(_ world: AgentWorld, keys: inout RowKeys) -> [JSONValue] {
        var rows: [JSONValue] = []
        for (index, words) in world.senses.enumerated() {
            keys.add("sense:" + String(index), open: "page:home/senses")
            rows.append(fact(["key": .string("sense:" + String(index)), "words": .string(words)]))
        }
        for (index, failure) in world.senseFailures.enumerated() {
            keys.add("sense:failed:" + String(index), open: "page:home/senses")
            rows.append(fact(["key": .string("sense:failed:" + String(index)), "failure": .string(failure)]))
        }
        return rows
    }

    /// The newest speaker on each door (each bridge conversation its own), five at most.
    static func elsewhere(_ world: AgentWorld, person: String, keys: inout RowKeys) -> [JSONValue] {
        var doors: Set<String> = []
        let peers = Dictionary(world.routes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return world.doors.filter { doors.insert($0.door == "bridge" ? $0.session : $0.door).inserted }.prefix(5).map { line -> JSONValue in
            keys.add("elsewhere:" + line.session, open: "chat:" + line.session)
            return fact(["key": .string("elsewhere:" + line.session), "door": .string(line.door),
                "who": .string(AgentScreen.who(line, person: person, peers: peers)), "at": .string(clock(line.at))])
        }
    }

    static func places(_ world: AgentWorld, dataRoot: URL, layout: SurfaceLayoutAvailability, keys: inout RowKeys) -> [JSONValue] {
        layout.contentNames("places", profile: SurfaceLayoutStore.profile).map(AppDoorNames.resolve).map { place -> JSONValue in
            let badge = AgentReadBadges.shared.latest(place, dataRoot: dataRoot)
            let detail: String?
            if place == "browser" {
                detail = BrowserConnectionMirror.connected.map { $0 ? "Chrome connected" : "Chrome not connected" } ?? "Chrome connection unobserved"
            } else if place == "desk", let state = world.desk {
                detail = "\(world.split.active.count) active · \(world.split.parked.count) parked · \(world.split.waiting.count) waiting · "
                    + state.boardCountSummary
            } else { detail = badge?.words }
            keys.add(place, open: "page:home/" + place)
            return fact(["key": .string(place), "name": .string(place.capitalized), "detail": text(detail),
                "at": text(badge.map { clock($0.at) })])
        }
    }

    static func mac(_ world: AgentWorld, keys: inout RowKeys) -> [JSONValue] {
        world.touched.map { item -> JSONValue in
            let key = "mac:" + item.app + ":" + (item.kind ?? "")
            keys.add(key, open: "page:home/mac")
            return fact(["key": .string(key), "app": .string(item.app), "about": text(item.kind), "readout": text(item.readout),
                "at": .string(clock(Date(timeIntervalSince1970: item.at)))])
        }
    }
}
