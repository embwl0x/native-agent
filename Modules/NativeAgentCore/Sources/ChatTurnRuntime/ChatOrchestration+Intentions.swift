import NativeAgentCore
import AgentWorkspace
import ChatTurnContracts
import Desk
import Experiences
import Foundation
import MemoryV2
import NativeAgentShared
import Transcripts
// Blueprint: | `ChatOrchestration+Intentions.swift` | `SwiftNativeTurnEngine`; Bounded live intentions from their owner |

extension SwiftNativeTurnEngine {
    struct IntentionsContextUnavailable: Error, LocalizedError {
        let underlying: any Error
        let operation: String
        let owner: String
        var errorDescription: String? { underlying.localizedDescription }
    }

    /// What the agent carries, read from its owner for this turn. Trust elevation
    /// does not make a peer's conversation the person's conversation.
    func intentionsContext(now: Date, sessionID: String?, surface: String, turn: Turn) async throws -> String {
        guard let dataRoot = remPinsDataRoot else { return "" }
        let agent = [turn.origin?.agent, turn.envelope?.agent]
            .compactMap { $0 }.first { $0 != "self" }
        let steering = (turn.peerSteering?.checkpointSources ?? []).map { PeerDataTaint.principal($0) }
        let peerTurn = agent != nil || !steering.isEmpty || turn.originPrincipal.hasPrefix("agent:")
            || SessionConversation.kind(sessionID, dataRoot: dataRoot)?.isPeerConversation == true
        // A peer is known by its verified id, never by the generic "agent" origin a reply turn carries.
        let verified = peerTurn ? turn.envelope?.verifiedUserId.flatMap { $0.isEmpty ? nil : PeerDataTaint.principal($0) } : nil
        let peers = Set([verified].compactMap { $0 } + steering).subtracting([PeerDataTaint.principal("agent")])
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let state: DeskState
        do {
            state = try await store.liveState()
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            throw IntentionsContextUnavailable(underlying: error, operation: "desk.intentions", owner: store.opsPath.path)
        }
        RepairOwed.settle(dataRoot, operation: "desk.intentions",
            evidence: .init(source: store.opsPath.path, id: "liveState"))
        let due: Set<String>
        if let sessionID, turn.execution?.transcriptRowKind == nil {
            due = Set(MyQueueReady.forTurn(items: state.items, session: sessionID, door: surface,
                personTurn: turn.originPrincipal == "person", at: now)
                .filter { turn.envelope?.workIdentity != "carry." + $0.item.handle }.map { $0.item.handle })
        } else {
            due = []
        }
        let entries = MyQueue.entries(state).filter { entry in
            if peerTurn {
                guard let origin = entry.step.origin, origin.hasPrefix("agent:") else { return false }
                return peers.contains(PeerDataTaint.principal(String(origin.dropFirst(6))))
            }
            return entry.step.origin == "self" || entry.owedToPerson
        }
        // Name-dependent lines are withheld when the profile cannot be read; an unsaved name reads "the person".
        let waitsOnPerson = entries.contains { entry in
            switch MyQueue.when(entry) {
            case .userWrites?, .userHere?, .userAway?: return true
            default: return false
            }
        }
        let person: String
        let profile = dataRoot.appendingPathComponent("memory/profile.json").path
        do {
            person = try waitsOnPerson ? Self.personName(dataRoot: dataRoot) : ""
            if waitsOnPerson {
                RepairOwed.settle(dataRoot, operation: "desk.intentions.person_name",
                    evidence: .init(source: profile, id: "names"))
            }
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            throw IntentionsContextUnavailable(underlying: error, operation: "desk.intentions.person_name", owner: profile)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "'next' EEE HH:mm"
        let moments = entries.map { entry -> (entry: MyQueue.Entry, moment: String, at: Date?) in
            if due.contains(entry.item.handle) { return (entry, "due now", nil) }
            if entry.step.status == "stopped" {
                return (entry, "stopped: " + (entry.step.reason ?? "reconcile before acting"), nil)
            }
            guard let condition = MyQueue.when(entry) else { return (entry, "condition unavailable; repair the saved condition", nil) }
            switch condition {
            case .every:
                let next = IntentionClock.next(entry.step, after: now)
                return (entry, next.map { format.string(from: $0) } ?? "no next clock moment", next)
            case .at(let date): return (entry, MyQueue.shown(date), date)
            case .afterCard(let card): return (entry, "after card " + card, nil)
            case .userWrites(let door): return (entry, "when \(person) writes" + (door.map { " on " + $0.rawValue } ?? ""), nil)
            case .nextTurn: return (entry, "next turn", nil)
            case .ownTurn: return (entry, "my own turn", nil)
            case .quiet: return (entry, "when it is quiet", nil)
            case .userHere: return (entry, "when \(person) is here", nil)
            case .userAway: return (entry, "when \(person) steps away", nil)
            case .news(let words): return (entry, "on news about " + words, nil)
            case .signal(let name): return (entry, "on " + name, nil)
            }
        }.sorted {
            let leftDue = due.contains($0.entry.item.handle), rightDue = due.contains($1.entry.item.handle)
            if leftDue != rightDue { return leftDue }
            switch ($0.at, $1.at) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if $0.entry.item.updatedAt != $1.entry.item.updatedAt {
                    return $0.entry.item.updatedAt > $1.entry.item.updatedAt
                }
                return $0.entry.item.handle < $1.entry.item.handle
            }
        }
        // A person's turn carries only the steps due on it: handed the whole list every turn, she recited it to the person. The rest ride her own turns.
        let personTurn = !peerTurn && turn.originPrincipal == "person"
        let shown = personTurn ? moments.filter { due.contains($0.entry.item.handle) } : moments
        let later = moments.count - shown.count
        let lines = shown.prefix(6).map { row in
            if due.contains(row.entry.item.handle) {
                let line = MyQueueReady.line(row.entry.item, at: now)
                return "- " + row.entry.name + " · due now · " + line.head + " " + line.rest
            }
            let until: String
            switch MyQueue.until(row.entry) {
            case .once: until = "done once"
            case .standing: until = "I let it go"
            case .time(let date): until = MyQueue.shown(date)
            case .words(let words): until = words
            }
            // Carry the item's name so the shown work can be finished with `queue.done`.
            return "- " + row.entry.name + " · " + Self.intentionLine(row.entry.step.words) + " · " + Self.intentionLine(row.moment)
                + " · until " + Self.intentionLine(until)
        }
        let heading = "# What I mean to do (mine; I do what's safe now, and raise one only when it's done, it needs someone, or I'm asked)"
        let rest = later > 0 ? ["+\(later) more for my own turns; queue.list reads them when I need to."] : []
        return lines.isEmpty && rest.isEmpty ? "" : ([heading] + lines + rest).joined(separator: "\n")
    }

    /// The saved name through the one cached reader the turn's context already uses; unsaved reads as "the person".
    private static func personName(dataRoot: URL) throws -> String {
        try MemoryRecallQueryExpansion.names(storeDirectory: dataRoot.appendingPathComponent("memory", isDirectory: true)).user ?? "the person"
    }

    private static func intentionLine(_ words: String) -> String {
        let line = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }
}
