import Foundation
import ApprovalInbox
import ChatSessionWork
import Desk
import Experiences
import NativeAgentCore
import PersistenceCore
import Synchronization
// Blueprint: | `HerQueue.swift` | `MyQueueTurnProjectionProviding` protocol over cognition's Desk-revision-checked candidates and explicit refresh-pending-after-write state; `MyQueueReady` reads named experience conditions by primary key for unattended and recorded-session eligibility; `HerScreen`: `queueContext`, async `queueRows` shows those obligations, `resume` |

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
            switch MyQueue.when(entry) {
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
            guard entry.owedToPerson(dataRoot: dataRoot) == personTurn, entry.step.session == session, plan.byHandle[entry.item.handle]?.isReady == true,
                  let filed = DeskClock.parseISO(entry.step.filedAt ?? entry.item.openedAt), at > filed else { return false }
            switch MyQueue.when(entry) {
            case .nextTurn: return true
            case .userWrites(let wanted): return personTurn && (wanted.map { (queueDoors[$0] ?? [$0]).contains(door) } ?? true)
            default: return false
            }
        }
    }
}

extension HerScreen {
    package static func queueContext(dataRoot: URL, now: Date, ownTurn: Bool) -> MyQueue.Context {
        let completed = ((try? SwiftNativeApprovalInbox(root: dataRoot).resolvedUnlocked()) ?? []).filter { record in
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
        // One observation per context; each entry still selects its own three
        // newest conversations after applying its door and timestamp filters.
        let observation = Mutex<(rows: [(id: String?, source: String, updatedAt: Date)]?, latest: [String: Date?])>((nil, [:]))
        return MyQueue.Context(now: now, ownTurn: ownTurn, completedCards: Set(completed.map(\.id))) { door, since in
            observation.withLock { observation in
                if observation.rows == nil {
                    observation.rows = ((try? HumanConversationIndex.rows(dataRoot: dataRoot)) ?? []).map { row in
                        (row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }), row["source"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "app",
                         row["updatedAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }).flatMap(date) ?? .distantPast)
                    }
                }
                let wanted = door.map { queueDoors[$0] ?? [$0] }
                return observation.rows!.filter { row in
                    (wanted?.contains(row.source) ?? true) && row.updatedAt > since
                }.prefix(3).contains { row in
                    guard let id = row.id,
                          NativeAgentChatSessionID.normalizedPathComponent(id) != nil else { return false }
                    if observation.latest[id] == nil {
                        let latest = logTail(dataRoot.appendingPathComponent("chat/messages/\(id).jsonl"), bytes: 16_384, humanOnly: true)
                            .filter { !$0.mine }.map { $0.at ?? .distantPast }.max()
                        observation.latest.updateValue(latest, forKey: id)
                    }
                    return (observation.latest[id] ?? nil).map { $0 > since } ?? false
                }
            }
        }
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
        let context = queueContext(dataRoot: dataRoot, now: now, ownTurn: false)
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
        var ready: [MyQueue.Entry] = [], waiting: [MyQueue.Entry] = []
        for entry in entries {
            if plan.byHandle[entry.item.handle]?.isReady == true && MyQueue.isReady(entry, context) { ready.append(entry) } else { waiting.append(entry) }
        }
        var rows = ready.prefix(4).map { entry in
            pad(entry.name, 10) + (entry.peerBorn ? clip(entry.item.title, 44) + " · open it to read"
                                                   : "\"" + clip(entry.step.words, 52) + "\"")
                + (entry.step.source == nil ? "" : " · inferred") + " · ready"
                + (DeskClock.parseISO(entry.item.openedAt).map { " " + age(now.timeIntervalSince($0)) } ?? "")
                + (noted(entry).map { " · " + $0 } ?? "")
        }
        rows += otherWaits.compactMap(waitLine)
        if ready.count > 4 { rows.append("+\(ready.count - 4) more ready · app desk.read {query:\"\(MyQueue.project)\"}") }
        var waits: [(String, Int)] = [], notes: [String] = []
        for entry in waiting {
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
            } else if let note = noted(entry) { notes.append(entry.name + " " + note) }
            let word = switch MyQueue.when(entry) {
            case .afterCard: "on a card"
            case .userWrites: "for \(person) to write"
            case .ownTurn, .quiet: "for my own turn"
            case .at: "for their time"
            case .nextTurn: "for next turn"
            }
            if let index = waits.firstIndex(where: { $0.0 == word }) { waits[index].1 += 1 } else { waits.append((word, 1)) }
        }
        if !waits.isEmpty {
            rows.append("\(waits.map(\.1).reduce(0, +)) waiting: " + waits.map { "\($0.1) \($0.0)" }.joined(separator: ", ")
                + notes.prefix(3).map { " · " + $0 }.joined())
        }
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
        guard let state = try? await store.liveState() else { return ("", [], []) }
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
                    + (entry.step.action.map { "\nPlanned call: " + $0 } ?? ""))
                lines.append("Do it now with your usual tools, then mark it done: "
                    + "app {action:\"queue.done\", args:{id:\"\(entry.name)\"}}.")
            }
        }
        return (lines.joined(separator: "\n"), sources, elevated)
    }
}
