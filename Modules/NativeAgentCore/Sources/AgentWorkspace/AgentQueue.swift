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
// Blueprint: | `AgentQueue.swift` | `MyQueueTurnProjectionProviding`, `MyQueueReady`, `AgentScreen.queueContext`, `resume`: checked conditions |
// Use Desk-revision-checked queue candidates and pending-after-write state; read approval and conversation evidence before evaluating conditions.

/// Nil candidates are unavailable; only a pending write refresh calls for a notice.
public protocol MyQueueTurnProjectionProviding: Sendable {
    func queueTurnCandidates() async -> (candidates: [DeskItem]?, refreshPendingAfterWrite: Bool)
}

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

    /// Carried work whose unattended condition is met. A peer-steered step retains its recorded peers when the wake admits it.
    package static func ready(items: [DeskItem], context: MyQueue.Context) -> [DeskItem] {
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: ""), now: context.now)
        return items.filter { item in
            guard !item.isPursuit, plan.byHandle[item.handle]?.isReady == true,
                  item.project == MyQueue.project || item.assignee == "agent" else { return false }
            guard let entry = MyQueue.entry(item) else { return true }
            guard entry.step.status != "stopped", let when = MyQueue.when(entry) else { return false }
            switch when {
            case .nextTurn: return !entry.owedToPerson && context.ownTurn
            case .userWrites: return false
            default: return MyQueue.isReady(entry, context)
            }
        }
    }

    /// Offered into the recorded conversation's next matching turn, including one that answers without tools. Its caller restores every recorded peer.
    package static func forTurn(items: [DeskItem], session: String, door: String, personTurn: Bool, at: Date) -> [MyQueue.Entry] {
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: ""), now: at)
        return items.compactMap(MyQueue.entry).filter { entry in
            guard entry.step.status != "stopped",
                  entry.owedToPerson == personTurn, entry.step.session == session, plan.byHandle[entry.item.handle]?.isReady == true,
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
