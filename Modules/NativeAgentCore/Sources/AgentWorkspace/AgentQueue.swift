import Foundation
import ApprovalInbox
import ChatToolParsing
import ChatSessionWork
import Desk
import Experiences
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Synchronization
// Blueprint: | `AgentQueue.swift` | `MyQueueReady` (`due`, `next`, `line`), `AgentScreen.queueContext`, `resume`: checked conditions and moments |
// Read approval and conversation evidence before evaluating conditions.

/// Read readiness through the wake's shared queue hook.
public enum MyQueueReady {
    /// Read only the named conditions, never scan the agent's experience history.
    package static func conditions(items: [DeskItem], dataRoot: URL) async throws -> [String: Experience] {
        let ids = Set(items.flatMap(\.blockedOn).filter { $0.hasPrefix("exp:") }.map { String($0.dropFirst(4)) })
        var conditions: [String: Experience] = [:]
        for id in ids { conditions[id] = try await ExperienceStore.at(dataRoot).experience(id) }
        return conditions
    }

    /// Write released conditions to Desk so wake, Home, continuations and views share one truth.
    @discardableResult
    package static func release(items: [DeskItem], dataRoot: URL) async throws -> Bool {
        let waiting = items.filter { !$0.status.isTerminal && $0.blockedOn.contains { $0.hasPrefix("exp:") } }
        guard !waiting.isEmpty else { return false }
        let conditions = try await conditions(items: waiting, dataRoot: dataRoot)
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        var released = false
        for item in waiting {
            let settled = item.blockedOn.compactMap { blocker -> Experience? in
                guard blocker.hasPrefix("exp:"), let experience = conditions[String(blocker.dropFirst(4))],
                      !experience.isOpen else { return nil }
                return experience
            }
            guard !settled.isEmpty else { continue }
            let ids = Set(settled.map { "exp:" + $0.id })
            let words = settled.map { experience -> String in
                let phase = experience.outcome?.status
                    ?? Set(experience.owes.values.map { $0.reason?.rawValue ?? $0.phase.rawValue }).sorted().joined(separator: ", ")
                return "Released: \(conditionName(experience)) \(experience.id) settled (\(phase))."
            }.joined(separator: " ")
            try await store.releaseBlockers(item.handle, removing: ids, note: words, author: "system")
            released = true
        }
        return released
    }

    package static func conditionName(_ experience: Experience) -> String {
        if experience.owes["repair"] != nil { return "repair" }
        return experience.kind == .decision ? "card" : experience.kind.rawValue
    }

    /// Due in the recorded conversation's next matching turn, including one that answers without tools. The agent's own next turn is its next
    /// thought. The changing moment shows these steps without activating their peer steering.
    package static func forTurn(items: [DeskItem], session: String, door: String, personTurn: Bool, at: Date) -> [MyQueue.Entry] {
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: ""), now: at)
        let thought = session == Happening.stream && !personTurn
        return items.compactMap(MyQueue.entry).filter { entry in
            guard entry.step.status != "stopped",
                  entry.owedToPerson == personTurn, thought || entry.step.session == session, plan.byHandle[entry.item.handle]?.isReady == true,
                  let filed = DeskClock.parseISO(entry.step.filedAt ?? entry.item.openedAt), at > filed,
                  let when = MyQueue.when(entry) else { return false }
            switch when {
            case .nextTurn: return true
            // A door is the surface the person writes on, the same word as this turn's surface.
            case .userWrites(let wanted): return personTurn && (wanted.map { $0.rawValue == door } ?? true)
            default: return false
            }
        }
    }

    // MARK: - Moments

    /// The one clock's owner of MY QUEUE's times: `moment:<handle>` for a step's next time, `moment:free` for when the agent is next free.
    package static let owner = "moment"
    package static let freeTime = owner + ":free"
    package static func time(_ handle: String) -> String { owner + ":" + handle }

    /// A moment's key. The same occurrence of a step always gets the same key, so it is posted once; a new occurrence gets a new key.
    package static func once(_ handle: String, _ occurrence: Date) -> String { "queue:" + handle + ":" + String(occurrence.timeIntervalSince1970) }

    /// Carried work whose condition came, and the occurrence that names it.
    package struct Moment: Sendable {
        package let item: DeskItem
        package let occurrence: Date
    }

    /// The agent's own carried work: MY QUEUE steps and Desk items assigned to the agent, never pursuits.
    package static func carried(_ item: DeskItem) -> Bool {
        MyQueue.carries(item)
    }

    /// Carried work owed to the agent now: its time or rhythm's occurrence came, its event released it (a signal, news, the person arriving or leaving,
    /// its card succeeding), or it is work for when the agent is free and the agent is free. Next-turn and message steps join turns instead. Work for
    /// when free that is ready while the agent is not free is reported as waiting.
    package static func due(items: [DeskItem], context: MyQueue.Context, free: Bool) -> (moments: [Moment], waitingForFree: Bool) {
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: ""), now: context.now)
        var moments: [Moment] = [], waiting = false
        for item in items where carried(item) && plan.byHandle[item.handle]?.isReady == true {
            let occurrence: Date?
            if let entry = MyQueue.entry(item) {
                guard entry.step.status != "stopped", !MyQueue.isOver(entry, at: context.now), let when = MyQueue.when(entry),
                      let filed = DeskClock.parseISO(entry.step.filedAt ?? item.openedAt) else { continue }
                switch when {
                case .nextTurn, .userWrites: continue
                case .ownTurn, .quiet:
                    guard free else { waiting = true; continue }
                    occurrence = freeOccurrence(item, filed: filed)
                case .at(let date): occurrence = context.now >= date ? date : nil
                case .every: occurrence = context.occurrence(entry.step, context.now)
                case .afterCard(let card): occurrence = context.completedCards.contains(card) ? filed : nil
                case .userHere, .userAway:
                    guard let presence = context.presence(), presence.since > filed, presence.here == (when == .userHere) else { continue }
                    occurrence = presence.since
                case .news, .signal: occurrence = MyQueue.releaseNotes(for: entry).compactMap { DeskClock.parseISO($0.ts) }.max()
                }
            } else {
                guard let opened = DeskClock.parseISO(item.openedAt) else { continue }
                guard free else { waiting = true; continue }
                occurrence = freeOccurrence(item, filed: opened)
            }
            if let occurrence { moments.append(Moment(item: item, occurrence: occurrence)) }
        }
        return (moments, waiting)
    }

    /// Work for when free comes again when it changes: refiled, a note from anyone but the agent, or a defer that ended.
    private static func freeOccurrence(_ item: DeskItem, filed: Date) -> Date {
        let notes = item.notes.filter { $0.author != "agent" }.compactMap { DeskClock.parseISO($0.ts) }
        return (notes + [item.deferUntil.flatMap(DeskSequencing.parseDeferStamp)].compactMap { $0 }).reduce(filed, max)
    }

    /// When a carried item's condition next comes on the clock: its time, its rhythm's next occurrence, its end, or the end of its defer.
    package static func next(_ item: DeskItem, after now: Date) -> Date? {
        guard carried(item) else { return nil }
        var times = [item.deferUntil.flatMap(DeskSequencing.parseDeferStamp)]
        if let entry = MyQueue.entry(item) {
            guard entry.step.status != "stopped" else { return nil }
            times.append(MyQueue.until(entry).endsAt)
            switch MyQueue.when(entry) {
            case .at(let date)?: times.append(date)
            case .every?: times.append(IntentionClock.next(entry.step, after: now))
            default: break
            }
        }
        return times.compactMap { $0 }.filter { $0 > now }.min()
    }

    /// A rhythm step's rhythm, which its clock time carries.
    package static func rhythm(_ item: DeskItem) -> JSONValue? {
        guard let entry = MyQueue.entry(item), case .every? = MyQueue.when(entry) else { return nil }
        return entry.step.rhythm
    }

    /// What the agent meant, as the agent reads it when it comes: `head` names it by the id it is finished with, `rest` says how to finish it.
    package static func line(_ item: DeskItem, at: Date) -> (head: String, rest: String) {
        let step = item.step
        let peers = (step?.peers ?? []).filter { !CapabilityLifecycle.ownerTrusts($0) }
        let provenance = peers.isEmpty ? "" : " Peer steering retained: " + peers.joined(separator: ", ")
            + ". The answer covers this turn and its carried steps, without permanently trusting the peer."
        let released = MyQueue.entry(item).map { MyQueue.releaseNotes(for: $0).map { $0.text + " " }.joined() } ?? ""
        let words = step?.words ?? item.summary ?? item.title
        let name = "desk." + item.alias
        let done = "app {action:\"queue.done\", args:{id:\"\(name)\"}}"
        let wait = "desk.wait {handle:\"\(name)\", on: <the card, message or debt id it needs>}: it comes back when that settles, not before."
        let head: String
        var rest: String
        if let step, step.rhythm != nil {
            // A rhythm is never done by one occurrence: it comes back at its next time.
            head = "You meant to, now (" + MyQueue.shown(IntentionClock.occurrence(step, at: at) ?? at) + "): \(words) (\(name))."
            rest = (IntentionClock.next(step, after: at).map { "It comes back " + MyQueue.shown($0) + "." } ?? "This is its last time.")
                + " Keep it open unless it is finished for good; then \(done)."
        } else if step != nil {
            head = "You meant to (\(name)): \(words)."
            rest = "Do it now if it is safe, reversible and within what you are allowed, then say it is done. "
                + "Once it is done, \(done); if it can't move yet, say what it waits on with \(wait)"
        } else {
            head = "Yours to carry, \(name): \(item.title) — \(words)."
            rest = "Do it now if it is safe, reversible and within what you are allowed, then say it is done. "
                + "Close it with desk.close {handle:\"\(name)\", reason} only once it is actually done. "
                + "If it can't move yet, say what it waits on with \(wait)"
        }
        switch step.map({ MyQueue.Until($0.until) }) ?? .once {
        case .words(let until): rest += " It is done when: \(until). Once it is, \(done)."
        case .time(let ends): rest += " It ends by itself " + MyQueue.shown(ends) + "."
        case .once, .standing: break
        }
        if let say = step?.say { rest += " Say this as it is, nothing added: \"\(say)\"" }
        return (head, released + rest + provenance)
    }
}

extension AgentScreen {
    package static func queueContext(dataRoot: URL, now: Date, ownTurn: Bool) throws -> MyQueue.Context {
        let completed = try SwiftNativeApprovalInbox(root: dataRoot).resolvedUnlocked().filter { record in
            guard record.decision == "approved", case .object(let result)? = record.executedAction else { return false }
            if let resultClass = result["resultClass"] {
                return resultClass == .string(ChatToolOutcome.ExactResultClass.succeeded.rawValue)
            }
            // These approval executors persist domain completion receipts. Normalize only their success evidence, retaining failure fields.
            var evidence = result
            if record.action == SwiftNativeApprovalInbox.skillScriptInstallAction,
               result["installed"] == .bool(true), result["status"] == nil {
                evidence["status"] = .string("completed")
            }
            let reply = ToolResult(.object(evidence))
            return reply.outcome == .succeeded
        }
        // The index records each conversation's source; a door is the surface it arrives on.
        let rows = try HumanConversationIndex.rows(dataRoot: dataRoot).map { row -> (id: String?, door: String, updatedAt: Date) in
            guard let source = row["source"]?.stringValue else { throw CocoaError(.fileReadCorruptFile) }
            return (id: row["id"]?.stringValue, door: ChatThreadKind.surface(transcriptSource: source),
                    updatedAt: row["updatedAt"]?.stringValue.flatMap(date) ?? .distantPast)
        }
        // Read the three newest per actual door before creating a nonthrowing condition callback. A failed evidence read cannot become false.
        var counts: [String: Int] = [:], latest: [String: Date] = [:]
        for row in rows where counts[row.door, default: 0] < 3 {
            counts[row.door, default: 0] += 1
            guard let id = row.id else { throw CocoaError(.fileReadCorruptFile) }
            let tail = try logTail(dataRoot.appendingPathComponent("chat/messages/\(id).jsonl"), bytes: 16_384, humanOnly: true)
            if let at = tail.filter({ !$0.mine }).compactMap(\.at).max() { latest[id] = at }
        }
        let observed = latest
        let presence = PersonPresence.read(dataRoot: dataRoot, now: now).transition
        return MyQueue.Context(now: now, ownTurn: ownTurn, completedCards: Set(completed.map(\.id))) { door, since in
                return rows.filter { row in
                    (door.map { $0.rawValue == row.door } ?? true) && row.updatedAt > since
                }.prefix(3).contains { row in
                    guard let id = row.id,
                          NativeAgentChatSessionID.normalizedPathComponent(id) != nil else { return false }
                    return observed[id].map { $0 > since } ?? false
                }
        } occurrence: { step, now in IntentionClock.occurrence(step, at: now) }
          presence: { presence }
    }

    /// Read approval follow-ups fresh; decline drops only unchanged steps, successful calls release them, and changed or failed work needs judgment.
    package static func resume(card: String, decision: String, completed: Bool, dataRoot: URL) async
        -> (text: String, sources: [String], elevated: [String]) {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let state: DeskState
        do { state = try await store.liveState() }
        catch { return ("""
            Queued follow-up unavailable: \(error.localizedDescription). The card settled, but its queued work could not be read; repair Desk storage \
            before continuing it.
            """, [], []) }
        var lines: [String] = [], sources: [String] = [], elevated: [String] = []
        for entry in MyQueue.entries(state) where entry.step.card == card {
            sources += entry.step.peers
            elevated += entry.step.elevated
            let queued = "\(entry.name) \"\(entry.step.words)\""
            if decision != "approved" {
                let why = decision == "denied" ? "dropped by \(names(dataRoot).person)" : "dropped: the card was \(decision)"
                do {
                    try await MyQueue.finish(entry, dropped: true, why: why, store: store)
                    lines.append("The step you queued for after this card was \(why): \(queued).")
                } catch is MyQueue.Superseded {
                    lines.append("The step you queued for after this card, \(queued), changed or closed before the card settled. The newer state was kept.")
                } catch {
                    lines.append("The step you queued for after this card, \(queued), could not be dropped: "
                        + error.localizedDescription + ". It is still in MY QUEUE.")
                }
            } else if !completed {
                lines.append("The approved call did not confirm success, so the step you queued for after it was not run "
                    + "and is still in MY QUEUE: \(queued).")
            } else if !entry.peerBorn, entry.item.title != entry.step.title {
                lines.append("You queued \(entry.name) for after this card as \"\(entry.step.words)\", but it reads "
                    + "\"\(entry.item.title)\" now. It was not run; look at it and decide.")
            } else {
                lines.append("You queued this step for after this card (\(entry.name) in MY QUEUE): \"\(entry.step.words)\""
                    + (entry.step.actionText.map { "\nHabit: " + $0 } ?? ""))
                lines.append("Do it now with your usual tools, then mark it done: "
                    + "app {action:\"queue.done\", args:{id:\"\(entry.name)\"}}.")
            }
        }
        return (lines.joined(separator: "\n"), sources, elevated)
    }
}
