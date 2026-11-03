import Foundation
import ApprovalInbox
import ChatSessionWork
import Desk
import Experiences
import MacControl
import NativeAgentCore
import PersistenceCore
import Synchronization
// Blueprint: | `HerQueue.swift` | `MyQueueTurnProjectionProviding` over cognition's Desk-revision-checked candidates and refresh-pending-after-write state; checked approval/conversation evidence precedes queue conditions; `MyQueueReady` reads named experience conditions by primary key for unattended and recorded-session eligibility; `HerScreen.queueContext` reads PersonPresence transitions; `queueRows` lists waiting steps by desk.N; `resume` preserves unavailable follow-up evidence |

private let queueDoors: [String: Set<String>] = ["mac": ["app", "chat", "mac"], "phone": ["ios", "iphone", "mobile", "icloud"],
                                               "ios": ["ios", "iphone", "mobile", "icloud"]]

/// Nil candidates are unavailable; only a pending write refresh calls for a notice.
public protocol MyQueueTurnProjectionProviding: Sendable {
    func queueTurnCandidates() async -> (candidates: [DeskItem]?, refreshPendingAfterWrite: Bool)
}

/// Which MY QUEUE steps are ready now: the hook her wake asks (Wave 2 #7).
public enum MyQueueReady {
    /// Read only the named conditions, never scan her experience history.
    package static func conditions(items: [DeskItem], dataRoot: URL) async throws -> [String: Experience] {
        let ids = Set(items.flatMap(\.blockedOn).filter { $0.hasPrefix("exp:") }.map { String($0.dropFirst(4)) })
        var conditions: [String: Experience] = [:]
        for id in ids { conditions[id] = try await ExperienceStore.at(dataRoot).experience(id) }
        return conditions
    }

    /// A condition that no longer owes anything is written off the items that
    /// waited on it, with a note saying what released them: the Desk is the one
    /// truth every reader (her wake, home, continuations, the Desk views) sees.
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

    /// Carried work whose unattended condition is met. A peer-steered step
    /// retains its recorded peers when the wake admits it.
    package static func ready(items: [DeskItem], context: MyQueue.Context, dataRoot: URL) -> [DeskItem] {
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: ""), now: context.now)
        return items.filter { item in
            guard !item.isPursuit, plan.byHandle[item.handle]?.isReady == true,
                  item.project == MyQueue.project || item.assignee == "agent" else { return false }
            guard let entry = MyQueue.entry(item) else { return true }
            guard entry.step.status != "stopped", let when = MyQueue.when(entry) else { return false }
            switch when {
            case .nextTurn: return !entry.owedToPerson(dataRoot: dataRoot) && context.ownTurn
            case .userWrites: return false
            default: return MyQueue.isReady(entry, context)
            }
        }
    }

    /// Offered into the recorded conversation's next matching turn, including
    /// one that answers without tools. Its caller restores every recorded peer.
    package static func forTurn(items: [DeskItem], session: String, door: String, personTurn: Bool, at: Date, dataRoot: URL) -> [MyQueue.Entry] {
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: ""), now: at)
        return items.compactMap(MyQueue.entry).filter { entry in
            guard entry.step.status != "stopped",
                  entry.owedToPerson(dataRoot: dataRoot) == personTurn, entry.step.session == session, plan.byHandle[entry.item.handle]?.isReady == true,
                  let filed = DeskClock.parseISO(entry.step.filedAt ?? entry.item.openedAt), at > filed,
                  let when = MyQueue.when(entry) else { return false }
            switch when {
            case .nextTurn: return true
            case .userWrites(let wanted): return personTurn && (wanted.map { (queueDoors[$0] ?? [$0]).contains(door) } ?? true)
            default: return false
            }
        }
    }
}

extension HerScreen {
    package static func queueContext(dataRoot: URL, now: Date, ownTurn: Bool) throws -> MyQueue.Context {
        let completed = try SwiftNativeApprovalInbox(root: dataRoot).resolvedUnlocked().filter { record in
            guard record.decision == "approved", case .object(let result)? = record.executedAction else { return false }
            if let resultClass = result["resultClass"] {
                return resultClass == .string(ChatToolOutcome.ExactResultClass.succeeded.rawValue)
            }
            // These approval executors persist domain completion receipts.
            // Normalize only their success evidence, retaining failure fields.
            var evidence = result
            if record.action == SwiftNativeApprovalInbox.skillScriptInstallAction,
               result["installed"] == .bool(true), result["status"] == nil {
                evidence["status"] = .string("completed")
            } else if record.action == SwiftNativeApprovalInbox.procedureExactActivationApprovalAction,
                      result["status"] == .string("activated") {
                evidence["status"] = .string("completed")
            }
            return ChatToolOutcome.exactResultClass(.object(evidence)) == .succeeded
        }
        let rows = try HumanConversationIndex.rows(dataRoot: dataRoot).map { row in
            (id: row["id"]?.stringValue, source: row["source"]?.stringValue ?? "app",
             updatedAt: row["updatedAt"]?.stringValue.flatMap(date) ?? .distantPast)
        }
        // Read the three newest per actual door before creating a nonthrowing
        // condition callback. A failed evidence read cannot become false.
        var counts: [String: Int] = [:], latest: [String: Date] = [:]
        for row in rows where counts[row.source, default: 0] < 3 {
            counts[row.source, default: 0] += 1
            guard let id = row.id else { throw CocoaError(.fileReadCorruptFile) }
            let tail = try logTail(dataRoot.appendingPathComponent("chat/messages/\(id).jsonl"), bytes: 16_384, humanOnly: true)
            if let at = tail.filter({ !$0.mine }).compactMap(\.at).max() { latest[id] = at }
        }
        let observed = latest
        let presence = PersonPresence.read(dataRoot: dataRoot, now: now).transition
        return MyQueue.Context(now: now, ownTurn: ownTurn, completedCards: Set(completed.map(\.id))) { door, since in
                let wanted = door.map { queueDoors[$0] ?? [$0] }
                return rows.filter { row in
                    (wanted?.contains(row.source) ?? true) && row.updatedAt > since
                }.prefix(3).contains { row in
                    guard let id = row.id,
                          NativeAgentChatSessionID.normalizedPathComponent(id) != nil else { return false }
                    return observed[id].map { $0 > since } ?? false
                }
        } occurrence: { step, now in IntentionClock.occurrence(step, at: now) }
          presence: { presence }
    }

    /// MY QUEUE's steps on home: the ready ones in her words (one queued on a
    /// peer's turn says whose, and opening it reads it), then what the rest wait on.
    /// A step she wrote a note on since queuing it (a wake put it on hold) says
    /// so, so another chat of hers reads it before acting (User, 10-02).
    static func queueRows(_ world: HerWorld, dataRoot: URL, person: String, now: Date) async -> [String] {
        guard let desk = world.desk else { return [] }
        let entries = MyQueue.entries(desk)
        let otherWaits = desk.items.filter { $0.assignee == "agent" && $0.project != MyQueue.project && !$0.status.isTerminal && !$0.blockedOn.isEmpty }
        guard !entries.isEmpty || !otherWaits.isEmpty else { return [] }
        func noted(_ entry: MyQueue.Entry) -> String? {
            entry.item.notes.compactMap { DeskClock.parseISO($0.ts) }.max().map { "note " + age(now.timeIntervalSince($0)) }
        }
        let context: MyQueue.Context
        do { context = try queueContext(dataRoot: dataRoot, now: now, ownTurn: false) }
        catch { return ["Queue evidence unavailable: \(error.localizedDescription). Repair approval or conversation storage before evaluating these conditions."] }
        let conditions: [String: Experience]
        do { conditions = try await MyQueueReady.conditions(items: desk.items, dataRoot: dataRoot) }
        catch { return ["Wait conditions are unavailable: \(error.localizedDescription) · experiences/experiences.sqlite"] }
        let plan = DeskSequencing.compute(desk, now: now)
        func waitLine(_ item: DeskItem) -> String? {
            let blockers = plan.byHandle[item.handle]?.effectiveBlockers ?? []
            guard !blockers.isEmpty else { return nil }
            return "desk." + item.alias + " waits " + blockers.map { blocker in
                guard blocker.hasPrefix("exp:") else {
                    return "on " + (desk.items.first { $0.handle == blocker }?.alias ?? blocker)
                }
                let id = String(blocker.dropFirst(4))
                guard let experience = conditions[id] else { return "on experience " + id + " (unavailable)" }
                if experience.owes["decide"]?.phase.isSettled == false { return "on card \(id) (\(person) decides)" }
                if let answer = experience.owes["answer"], !answer.phase.isSettled, answer.to.hasPrefix("agent:") {
                    let agent = String(answer.to.dropFirst(6))
                    let peer = agent.hasPrefix("peer:") ? String(agent.dropFirst(5)) : agent
                    let name = world.identity.peers.first { $0["id"] == peer }?["name"] ?? peer
                    return "on \(name)'s answer to \(id)"
                }
                return "on " + MyQueueReady.conditionName(experience) + " " + id
            }.joined(separator: ", ")
        }
        var ready: [MyQueue.Entry] = [], waiting: [MyQueue.Entry] = [], unavailable: [String] = []
        for entry in entries {
            guard plan.byHandle[entry.item.handle]?.isReady == true else {
                waiting.append(entry); continue
            }
            switch MyQueue.readiness(entry, context) {
            case .ready: ready.append(entry)
            case .waiting: waiting.append(entry)
            case .unavailable(let detail): unavailable.append(pad(entry.name, 10) + " · " + detail)
            }
        }
        var rows = ready.prefix(4).map { entry in
            pad(entry.name, 10) + (entry.peerBorn ? clip(entry.item.title, 44) + " · open it to read"
                                                   : "\"" + clip(entry.step.words, 52) + "\"")
                + (entry.step.source == nil ? "" : " · inferred") + " · ready"
                + (DeskClock.parseISO(entry.item.openedAt).map { " " + age(now.timeIntervalSince($0)) } ?? "")
                + (noted(entry).map { " · " + $0 } ?? "")
        }
        rows += otherWaits.compactMap(waitLine)
        rows += unavailable
        if ready.count > 4 { rows.append("+\(ready.count - 4) more ready · app desk.read {query:\"\(MyQueue.project)\"}") }
        // Each waiting step by its name, so what she is shown she can finish or drop.
        var waits: [String] = [], notes: [String] = []
        for entry in waiting {
            if entry.step.status == "stopped" {
                waits.append(pad(entry.name, 10) + " · stopped: " + (entry.step.reason ?? "read its saved state before resuming"))
                continue
            }
            guard let when = MyQueue.when(entry) else {
                waits.append(pad(entry.name, 10) + " · condition unavailable: " + entry.step.when
                    + ". Repair the saved condition before continuing this step.")
                continue
            }
            if let line = waitLine(entry.item) { rows.append(line); continue }
            if let reason = nonEmpty(entry.item.blockedReason) {
                var blocked = entry.name + " blocked: " + reason
                    + ". Give it a condition with app {action:\"desk.wait\", args:{handle:\"\(entry.item.handle)\", on:\"<card, message or debt id>\"}}."
                for peer in entry.step.peers where peer.hasPrefix("peer:") && !CapabilityLifecycle.ownerTrusts(peer) {
                    let id = String(peer.dropFirst(5))
                    let name = world.identity.peers.first { $0["id"] == id }?["name"] ?? id
                    blocked += " Peer elevation is the person's: Trust > Connected agents > \(name) (\(id)) > Trusted."
                }
                notes.append(blocked)
            }
            let word = switch when {
            case .afterCard: "on a card"
            case .userWrites: "for \(person) to write"
            case .userHere: "for \(person) to be here"
            case .userAway: "for \(person) to step away"
            case .news(let words): "for news about " + words
            case .signal(let name): "on " + name
            case .ownTurn, .quiet: "for my own turn"
            case .at(let date): ResidentWake.shown(date)
            case .every: IntentionClock.next(entry.step, after: now).map { "next " + ResidentWake.shown($0) } ?? "with no next time"
            case .nextTurn: "for next turn"
            }
            waits.append(pad(entry.name, 10) + (entry.peerBorn ? clip(entry.item.title, 44) + " · open it to read"
                                                              : "\"" + clip(entry.step.words, 52) + "\"")
                + (entry.step.source == nil ? "" : " · inferred") + " · waits " + word
                + (noted(entry).map { " · " + $0 } ?? ""))
        }
        rows += waits.prefix(6)
        if waits.count > 6 { rows.append("+\(waits.count - 6) more waiting · app desk.read {query:\"\(MyQueue.project)\"}") }
        rows += notes.prefix(3)
        rows.append("done or dropped: app {action:\"queue.done\" or \"queue.drop\", args:{id:\"desk.N\"}}")
        return rows
    }

    /// Wave 2 #8: what an approval's follow-up hears about the steps queued
    /// for after its card, each read fresh now. A declined or canceled card
    /// drops only unchanged steps; a newer revision is kept and named. An approved card whose call completed
    /// hands her each step as she queued it, to run now; a failed call or a
    /// step changed since is brought to her, not run. Their peers join the
    /// card's steer.
    package static func resume(card: String, decision: String, completed: Bool, dataRoot: URL) async
        -> (text: String, sources: [String], elevated: [String]) {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let state: DeskState
        do { state = try await store.liveState() }
        catch { return ("Queued follow-up unavailable: \(error.localizedDescription). The card settled, but its queued work could not be read; repair Desk storage before continuing it.", [], []) }
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
            } else if !entry.peerBorn, entry.item.title != String(entry.step.words.prefix(200)) {
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
