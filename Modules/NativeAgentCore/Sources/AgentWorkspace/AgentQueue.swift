import Foundation
import ApprovalInbox
import ChatToolParsing
import ChatTurnContracts
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
    package static func once(_ item: DeskItem, _ occurrence: Date) -> String {
        "queue:" + item.handle + ":" + String(occurrence.timeIntervalSince1970)
            + (item.step?.habitRevision.map { ":" + $0 } ?? "")
    }

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
                case .afterCard(let card):
                    occurrence = MyQueue.cardIsReleased(entry, card: card, completedCards: context.completedCards) ? filed : nil
                case .userHere, .userAway:
                    guard let presence = context.presence(), presence.since > filed, presence.here == (when == .userHere) else { continue }
                    occurrence = presence.since
                // The earliest unhandled release runs first; its Ran note raises the floor only to it, so a second signal still runs.
                case .news, .signal: occurrence = MyQueue.releaseNotes(for: entry).compactMap { DeskClock.parseISO($0.ts) }.min()
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

    /// The opening names the row. For a step without a rhythm, the detail says it is open on the Desk.
    package static func line(_ item: DeskItem, at: Date) -> (head: String, rest: String) {
        let step = item.step
        let peers = (step?.peers ?? []).filter { !CapabilityLifecycle.ownerTrusts($0) }
        let provenance = peers.isEmpty ? "" : " Peer steering retained: " + peers.joined(separator: ", ")
            + ". The answer covers this turn and its carried steps, without permanently trusting the peer."
        let released = MyQueue.entry(item).map { MyQueue.releaseNotes(for: $0).map { $0.text + " " }.joined() } ?? ""
        let words = step?.words ?? item.summary ?? item.title
        let name = "desk." + item.alias
        let doIt = "Do it now if it is safe, reversible and within what you are allowed. "
        let wait = " If it can't move yet, desk.wait {handle:\"\(name)\", on:<what it needs>} holds it until that settles."
        let head: String
        var rest: String
        if let step, step.rhythm != nil {
            // A rhythm is never done by one occurrence: it comes back at its next time.
            head = "You meant to, now (" + MyQueue.shown(IntentionClock.occurrence(step, at: at) ?? at) + "): \(words) (\(name))."
            rest = IntentionClock.next(step, after: at).map { "It comes back " + MyQueue.shown($0) + "." } ?? "This is its last time."
        } else if step != nil {
            head = "You meant to (\(name)): \(words)."
            rest = doIt + "\(name) is open on your Desk." + wait
        } else {
            // A carried row with no step is outside the after-turn settlement: say only that it stays hers.
            head = "Yours to carry, \(name): \(item.title) — \(words)."
            rest = doIt + "It stays yours until it is done." + wait
        }
        switch step.map({ MyQueue.Until($0.until) }) ?? .once {
        case .words(let until): rest += " It is done when: \(until)."
        case .time(let ends): rest += " It ends by itself " + MyQueue.shown(ends) + "."
        case .once, .standing: break
        }
        if let say = step?.say {
            rest += item.notes.contains { $0.author == "agent" && $0.text.hasPrefix("Said ") && $0.text.hasSuffix(": \"\(say)\"") }
                ? " These words were said to the person for you at its moment; do not say them again: \"\(say)\""
                : " Say this as it is, nothing added: \"\(say)\""
        }
        return (head, released + rest + provenance)
    }
}

extension AgentScreen {
    private static func approvalCompleted(_ record: ApprovalRecord) -> Bool {
        guard record.decision == "approved", let result = record.executedAction?.objectValue else { return false }
        if let resultClass = result["resultClass"] {
            return resultClass == .string(ChatToolOutcome.ExactResultClass.succeeded.rawValue)
        }
        if record.action == SwiftNativeApprovalInbox.skillScriptInstallAction,
           result["status"] == nil {
            return result["installed"] == .bool(true)
        }
        return record.executionResultClass == .succeeded
    }

    package static func queueContext(items: [DeskItem], dataRoot: URL, now: Date, ownTurn: Bool) async throws -> MyQueue.Context {
        let legacyCards = Set(items.compactMap(MyQueue.entry).compactMap(MyQueue.cardNeedingReleaseEvidence))
        var completed: Set<String> = []
        for id in legacyCards {
            if let card = try await queueCard(id, dataRoot: dataRoot), card.completed { completed.insert(id) }
        }
        // The index records each conversation's source; a door is the surface it arrives on.
        let rows = try HumanConversationIndex.rows(dataRoot: dataRoot).map { row -> (id: String?, door: String, updatedAt: Date) in
            guard let source = row["source"]?.stringValue else { throw CocoaError(.fileReadCorruptFile) }
            return (id: row["id"]?.stringValue, door: ChatThreadKind.surface(transcriptSource: source),
                    updatedAt: row["updatedAt"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst) ?? .distantPast)
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
        return MyQueue.Context(now: now, ownTurn: ownTurn, completedCards: completed) { door, since in
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

    package struct QueueCard: Sendable {
        let decision: String?
        let completed: Bool

        static let waiting = Self(decision: nil, completed: false)
    }

    package static func queueApprovalSteering(_ record: ApprovalRecord) throws -> (sources: [String], elevated: [String]) {
        try PeerDataTaint.steer(in: record.payload.objectValue?["peer"], scope: record.decision == "approved" ? record.scope : nil)
    }

    /// Read the durable decision and execution evidence from the owner of the named card.
    package static func queueCard(_ card: String, dataRoot: URL) async throws -> QueueCard? {
        do {
            let approval = try await SwiftNativeApprovalInbox(root: dataRoot).get(card)
            guard approval.status == "resolved", let decision = approval.decision,
                  decision != "approved" || approval.executedAction != nil else {
                return .waiting
            }
            if approval.payload.objectValue?["kind"] == .string("chat_tool_approval") {
                _ = try queueApprovalSteering(approval)
                if SwiftNativeApprovalInbox.continuationIsPending(approval) { return .waiting }
            }
            return QueueCard(decision: decision, completed: approvalCompleted(approval))
        } catch ApprovalInboxError.notFound {
            guard let matter = try await ExperienceStore.at(dataRoot).experience("interaction:" + card) else { return nil }
            guard let ref = matter.evidence.first(where: { $0.id == card && $0.source.hasPrefix(Matter.conversations) }),
                  let session = NativeAgentChatSessionID.normalizedPathComponent(String(ref.source.dropFirst(Matter.conversations.count))) else {
                throw PersistenceCoreError.ioFailure("Interaction \(card) has no originating conversation evidence.")
            }
            let path = dataRoot.appendingPathComponent(Matter.messages(session) + ".jsonl")
            let life = try DataRootLife.current(in: dataRoot)
            let rows = try await SwiftNativePersistenceCore.readJSONL(path)
            guard let row = rows.first(where: {
                let metadata = $0.objectValue?["metadata"]?.objectValue
                return metadata?["kind"] == .string(InlineInteractionWire.transcriptKind)
                    && metadata?[InlineInteractionWire.metadataKey]?.objectValue?["id"] == .string(card)
            }), let saved = try InlineInteractionWire.checkedCard(in: row, lifeID: life) else {
                throw PersistenceCoreError.ioFailure("Interaction \(card) is missing from its originating conversation.")
            }
            if let state = saved.continuation?.state, [.waiting, .claimed, .replaying].contains(state) { return .waiting }
            switch saved.state {
            case .settled: return QueueCard(decision: "approved", completed: true)
            case .declined, .superseded: return QueueCard(decision: "declined", completed: false)
            default: return .waiting
            }
        }
    }

    package enum CardFollowUp: String, Sendable {
        case waiting, released, dropped, taken, changed, finishedHabit
    }

    /// Re-read after filing so either the card's scan or this exact filing sees the other's committed write.
    package static func reconcileFiledCard(_ entry: MyQueue.Entry, store: SwiftNativeDeskStore) async throws -> CardFollowUp? {
        guard case .afterCard(let id)? = MyQueue.when(entry) else { return nil }
        return try await SwiftNativePersistenceCore.withFileLock(store.opsPath) { () -> CardFollowUp in
            guard let current = try await MyQueue.entry(entry.item.handle, store: store),
                  MyQueue.when(current) == .afterCard(id), current.step.filedAt == entry.step.filedAt else { return .changed }
            if MyQueue.cardIsReleased(current, card: id) { return .released }
            guard let card = try await queueCard(id, dataRoot: store.dataRoot) else { throw ApprovalInboxError.notFound(id) }
            guard let decision = card.decision else { return .waiting }
            // A step a stopped run holds is that run's to settle; the card's own scan reaches it when the hold lets go.
            if try await store.runHold(current.item.handle) != nil { return .waiting }
            return try await settleCardStep(current, card: id, decision: decision, completed: card.completed,
                                            handOff: false, store: store)
        }
    }

    private static func droppedAfterCard(_ decision: String, dataRoot: URL) -> String {
        decision == "denied" ? "dropped by \(names(dataRoot).person)" : "dropped: the card was \(decision)"
    }

    private static func settleCardStep(_ entry: MyQueue.Entry, card: String, decision: String, completed: Bool, handOff: Bool,
                                       store: SwiftNativeDeskStore) async throws -> CardFollowUp {
        if decision != "approved" {
            let ending = try await MyQueue.finish(entry, dropped: true, why: droppedAfterCard(decision, dataRoot: store.dataRoot), store: store)
            return ending == .finishedHabit ? .finishedHabit : .dropped
        }
        guard completed, entry.step.status != "stopped" else { return .waiting }
        if MyQueue.cardIsReleased(entry, card: card) { return .released }
        guard entry.peerBorn || entry.item.title == entry.step.title else { return .changed }
        if handOff {
            let ending = try await MyQueue.finish(entry, dropped: false, why: "Taken by the card's continued turn.", store: store)
            return ending == .finishedHabit ? .finishedHabit : .taken
        }
        var released = entry.step
        released.status = MyQueue.cardReleaseStatus(card)
        _ = try await MyQueue.update(entry, step: released, store: store)
        return .released
    }

    /// Settle the card's open follow-ups. If its turn continues, take the still-waiting steps into that turn.
    package static func resume(card: String, decision: String, completed: Bool, handOff: Bool, dataRoot: URL) async
        -> (text: String, sources: [String], elevated: [String]) {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let state: DeskState
        do { state = try await store.liveState() }
        catch { return ("""
            Queued follow-up unavailable: \(error.localizedDescription). The card settled, but its queued work could not be read; repair Desk storage \
            before continuing it.
            """, [], []) }
        var lines: [String] = [], sources: [String] = [], elevated: [String] = []
        for entry in MyQueue.entries(state) where MyQueue.when(entry) == .afterCard(card) {
            sources += entry.step.peers
            elevated += entry.step.elevated
            let queued = "\(entry.name) \"\(entry.step.words)\""
            do {
                switch try await settleCardStep(entry, card: card, decision: decision, completed: completed, handOff: handOff, store: store) {
                case .dropped:
                    let why = droppedAfterCard(decision, dataRoot: dataRoot)
                    lines.append("The step you queued for after this card was \(why): \(queued).")
                case .waiting:
                    let cause = completed ? "The queued step is stopped" : "The approved call did not confirm success"
                    lines.append(cause + ", so the step was not run and is still in MY QUEUE: \(queued).")
                case .changed:
                    lines.append("You queued \(entry.name) for after this card as \"\(entry.step.words)\", but it reads "
                        + "\"\(entry.item.title)\" now. It was not run; look at it and decide.")
                case .taken:
                    lines.append("Queued after this card (\(entry.name), now taken from MY QUEUE): \"\(entry.step.words)\""
                        + (entry.step.actionText.map { "\nHabit: " + $0 } ?? ""))
                    lines.append("Do it now with your usual actions, in this turn.")
                case .released: break
                case .finishedHabit:
                    lines.append("The habit already finished and its queued step is now done: \(queued).")
                }
            } catch is MyQueue.Superseded {
                lines.append("The step you queued for after this card, \(queued), changed or closed before the card settled. The newer state was kept.")
            } catch {
                lines.append("Settlement needs repair for the step queued after this card, \(queued): " + error.localizedDescription + ".")
            }
        }
        return (lines.joined(separator: "\n"), sources, elevated)
    }
}
