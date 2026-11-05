import ApprovalInbox
import Desk
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import StandingBots
import Transcripts
// Blueprint: | `HomeFace+Rows.swift` | Home's waits, queue, repairs and contacts as structured rows; cached condition evidence never becomes an empty verdict |

extension HomeFace {
    static func waits(_ world: AgentWorld, person: String) -> [PartFace.Row] {
        var rows = (world.desk?.items ?? []).filter(OwnerAttentionPolicy.waitsOnOwner).sorted { $0.updatedAt > $1.updatedAt }.map { item in
            PartFace.Row(id: "desk." + item.alias, title: AgentScreen.clip(item.title, 100), value: "Waits on " + person,
                at: item.updatedAt, tone: .attention, open: "page:desk/" + item.handle)
        }
        rows += world.approvals.map { approval in
            .init(id: "approval:" + approval.id,
                title: AgentScreen.clip(ApprovalWords.title(action: approval.action, title: approval.title, reason: approval.reason), 120),
                value: "Asking first", at: approval.lastRequestedAt ?? approval.createdAt, tone: .attention, open: "approval:" + approval.id)
        }
        rows += world.asksToOpen.map { item in
            .init(id: "ask:" + item.id, title: AgentScreen.clip(item.title, 100), detail: AgentScreen.clip(item.summary, 140),
                at: item.created_at, tone: .attention, open: "card:" + item.id)
        }
        rows += repairs(world, person: true)
        return rows
    }

    static func repairs(_ world: AgentWorld, person: Bool) -> [PartFace.Row] {
        world.repairs.filter { RepairOwed.isOwed($0) && ($0.owes["repair"]?.to == "person") == person }.map { act in
            let debt = RepairDebt(act)
            let verb = repairVerb(debt.nextCall).map { "repair with " + $0 }
            let words = [act.face?.words, debt.tap, verb].compactMap { $0 }.map(AgentScreen.failureReason).joined(separator: " · ")
            return .init(id: act.id, title: AgentScreen.failureReason(repairTitle(debt.operation)), detail: AgentScreen.clip(words, 240),
                value: act.outcome?.status, at: act.at, tone: .attention, open: "page:home/desk")
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
    static func repairVerb(_ call: String?) -> String? {
        guard let call, case .object(let fields)? = try? JSONValue.parse(Data(call.utf8)) else { return nil }
        if case .object(let input)? = fields["input"], case .string(let action)? = input["action"] { return action }
        if case .string(let tool)? = fields["tool"] { return tool }
        return nil
    }

    static func queue(_ world: AgentWorld, person: String, now: Date) -> [PartFace.Row] {
        var rows: [PartFace.Row] = []
        if let desk = world.desk {
            let plan = DeskSequencing.compute(desk, now: now)
            for entry in MyQueue.entries(desk) {
                var value = "Condition not read yet", tone = PartFace.Tone.attention
                let blockers = plan.byHandle[entry.item.handle]?.effectiveBlockers ?? []
                if let evidence = world.queueEvidence,
                   evidence.revision == desk.generatedTs, world.failures["queue evidence"] == nil {
                    if !blockers.isEmpty {
                        value = "Waits " + blockers.map { blocker in
                            guard blocker.hasPrefix("exp:") else {
                                return "on desk." + (desk.items.first { $0.handle == blocker }?.alias ?? blocker)
                            }
                            let id = String(blocker.dropFirst(4))
                            guard let condition = evidence.conditions[id] else { return "on experience \(id) (unavailable)" }
                            return "on " + MyQueueReady.conditionName(condition) + " " + id
                        }.joined(separator: ", ")
                    } else if plan.byHandle[entry.item.handle]?.isReady == false {
                        let step = plan.byHandle[entry.item.handle]
                        value = step?.blockedByCycle == true ? "Blocked by a cycle"
                            : step?.isDeferred == true ? "Deferred" : "Waits on its Desk conditions"
                        tone = .attention
                    } else if plan.byHandle[entry.item.handle] == nil {
                        value = "Desk conditions unavailable"; tone = .attention
                    } else {
                        var context = evidence.context
                        context.now = now
                        switch MyQueue.readiness(entry, context) {
                        case .ready: value = "Ready"; tone = .plain
                        case .waiting: value = entry.step.status == "stopped" ? "Stopped" : "Waits " + entry.step.when; tone = .quiet
                        case .unavailable(let detail): value = detail; tone = .failed
                        }
                    }
                }
                let note = entry.item.notes.max { $0.ts < $1.ts }
                let detail = entry.peerBorn ? "Peer-carried step; open it to read."
                    : AgentScreen.clip(entry.step.words, 140) + (entry.step.source == nil ? "" : " · inferred")
                // A peer's step froze the peer's id into its Desk title at filing; the contact list names that peer now.
                let title = entry.peerBorn ? "A step from " + (entry.step.peers + entry.step.elevated).map { peer in
                    world.contacts.first { $0.id == peer || $0.agents.contains(peer) }?.name ?? "an agent no longer in contacts"
                }.joined(separator: ", ") + "'s turn" : entry.item.title
                rows.append(.init(id: entry.name, title: AgentScreen.clip(title, 100),
                    detail: detail + (entry.item.blockedReason.map { " · " + AgentScreen.clip($0, 100) } ?? "")
                        + (note.map { " · note: " + AgentScreen.clip($0.text, 100) } ?? ""),
                    value: AgentScreen.failureReason(value), at: note?.ts ?? entry.item.updatedAt, tone: tone, open: "page:desk/" + entry.item.handle,
                    actions: [.init(id: "queue.done", label: "Done"), .init(id: "queue.drop", label: "Drop", role: .destructive)]))
            }
            for item in desk.items where item.assignee == "agent" && item.project != MyQueue.project
                && !item.status.isTerminal && !item.blockedOn.isEmpty {
                rows.append(.init(id: "blocked:desk." + item.alias, title: AgentScreen.clip(item.title, 100),
                    detail: item.blockedReason.map { AgentScreen.clip($0, 140) }, value: "Waits on " + item.blockedOn.joined(separator: ", "),
                    at: item.updatedAt, tone: .quiet, open: "page:desk/" + item.handle))
            }
            let harness = HarnessQueue.open(desk)
            for item in harness {
                rows.append(.init(id: "harness:desk." + item.alias, title: AgentScreen.clip(item.title, 100), detail: item.assignee,
                    value: "Open harness work", at: item.updatedAt, open: "page:desk/" + item.handle))
            }
        }
        for arrival in world.arrivals {
            let accepts = world.acceptableArrivals.contains(arrival.id)
            rows.append(.init(id: "arrival:" + arrival.id, title: AgentScreen.clip(arrival.line, 160), detail: AgentScreen.clip(arrival.reason, 100),
                value: arrival.state, at: clock(arrival.at), tone: accepts ? .attention : .quiet,
                open: arrival.session.map { "chat:" + $0 } ?? "page:home/arrivals",
                actions: accepts ? [.init(id: "home.accept", label: "Accept")] : nil))
        }
        if world.reviews.count > 0 {
            rows.append(.init(id: "memory.proposals", title: "Memories to review",
                detail: "app {action:\"memory.proposals\"}", value: "\(world.reviews.count)" + (world.reviews.capped ? "+" : ""),
                open: "page:memory_proposals"))
        }
        for contact in world.contacts {
            let record = AgentScreen.latest(contact, records: world.records)
            if record?.sendEvidence["needs_input"] == .bool(true) || record?.sendEvidence["needs_authentication"] == .bool(true) {
                rows.append(.init(id: "input:" + contact.id, title: AgentScreen.clip(contact.name, 60), value: "Asks for input",
                    at: record.map { clock($0.updatedAt) }, tone: .attention,
                    open: "page:home/agent/" + contact.id))
            }
        }
        rows += repairs(world, person: false)
        return rows
    }

    static func people(_ world: AgentWorld, now: Date) -> [PartFace.Row] {
        var rows = world.contacts.map { contact -> PartFace.Row in
            let record = AgentScreen.latest(contact, records: world.records), chat = world.threads[contact.id]
            let health = world.health[world.healthID(for: contact, record: record)]
            var value = "No recorded exchange", tone = PartFace.Tone.quiet
            // A contact's time is its last exchange, never the record's bookkeeping writes (a read schedule moves those every few seconds).
            var at = record.flatMap { $0.exchanges?.last.map { $0.settledAt ?? $0.sentAt } ?? $0.operationStartedAt }
            if world.unread.contains("people") {
                value = world.failures["people"] == nil ? "Exchange not read yet" : "Exchange unavailable"; tone = .attention
            } else if let record, record.phase != "sending", record.sendFailed {
                value = "Send failed"; tone = .failed
            } else if let problem = health?.problemWord {
                value = problem; tone = .failed; at = health?.checkedAt
            } else if let record, health?.resolves(record) == true {
                value = "Ready"; tone = .plain; at = health?.checkedAt
            } else if let heard = chat?.heard, heard > (record?.updatedAt ?? .distantPast) {
                value = "Replied in chat"; tone = .done; at = heard
            } else if let record {
                let receipt = record.sendEvidence
                let message = record.readInput?["message_id"]?.stringValue
                if ["sending", "waiting"].contains(record.phase) {
                    if let message, let answered = world.answered[message] {
                        value = "Replied"; tone = .done; at = answered
                    } else { value = "Waiting"; tone = .attention; at = record.operationStartedAt ?? record.updatedAt }
                } else if receipt["needs_input"] == .bool(true) || receipt["needs_authentication"] == .bool(true) {
                    value = "Asks for input"; tone = .attention
                } else if record.phase == "attention" {
                    value = receipt["status"] == .string("outcome_unknown") ? "Send unconfirmed" : "Needs attention"; tone = .attention
                } else if record.retainedReply?.text ?? record.exchanges?.last?.reply != nil {
                    value = "Replied"; tone = .done
                    at = record.exchanges?.last?.settledAt ?? record.exchanges?.last?.sentAt ?? at
                } else { value = "Sent"; tone = .plain }
            }
            let exchangeAt = record?.exchanges?.last?.settledAt ?? record?.operationStartedAt ?? record?.updatedAt ?? .distantPast
            if !world.unread.contains("people"), record?.sendFailed != true, health?.problem == nil,
               let job = world.jobs.first(where: { $0.agent == contact.id || contact.agents.contains($0.agent) }),
               let jobAt = (job.completedAt ?? job.startedAt ?? job.createdAt).flatMap(AgentScreen.date),
               jobAt > max(exchangeAt, chat?.at ?? .distantPast) {
                value = "Execution: " + (job.runStatus ?? job.status ?? job.state ?? "not recorded")
                    + (job.deliveryOutcome.map { " · delivery: " + $0 } ?? "")
                    + (job.executionError == nil ? "" : " · execution error recorded")
                    + (job.stalled(at: now) ? " · stalled" : "")
                tone = job.executionError == nil ? .plain : .failed
                at = jobAt
            }
            return .init(id: contact.id, title: AgentScreen.clip(contact.name, 60), detail: contact.kind,
                value: value, at: at.map(clock), tone: tone,
                open: "page:home/agent/" + contact.id)
        }
        rows.sort { ($0.at ?? "") > ($1.at ?? "") }
        rows += world.found.keys.sorted().compactMap { id in
            world.found[id].map { offer in
                .init(id: "found:" + id, title: "Found " + AgentScreen.clip(offer.name, 60),
                    detail: id.hasPrefix("app:") ? "No recipe yet; tell me in chat to look." : "Tell me in chat to connect.",
                    at: offer.offeredAt.map(clock), tone: .attention, open: "page:agents")
            }
        }
        return rows
    }
}
