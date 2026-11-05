import NativeAgentCore
import AgentWorkspace
import ChatTurnContracts
import Desk
import Foundation
import NativeAgentShared
import Transcripts
// Blueprint: | `ChatOrchestration+Intentions.swift` | `SwiftNativeTurnEngine`; Bounded live intentions from their owner |

extension SwiftNativeTurnEngine {
    /// What the agent carries, read from its owner for this turn. Trust elevation
    /// does not make a peer's conversation the person's conversation.
    func intentionsContext(now: Date, sessionID: String?, turn: Turn) async throws -> String {
        guard let dataRoot = remPinsDataRoot else { return "" }
        let agent = [turn.origin?.agent, turn.envelope?.agent]
            .compactMap { $0 }.first { $0 != "self" }
        let steering = (turn.peerSteering?.checkpointSources ?? []).map { PeerDataTaint.principal($0) }
        let peerTurn = agent != nil || !steering.isEmpty || turn.originPrincipal.hasPrefix("agent:")
            || SessionConversation.kind(sessionID, dataRoot: dataRoot)?.isPeerConversation == true
        // A peer is known by its verified id, never by the generic "agent" origin a reply turn carries.
        let verified = peerTurn ? turn.envelope?.verifiedUserId.flatMap { $0.isEmpty ? nil : PeerDataTaint.principal($0) } : nil
        let peers = Set([verified].compactMap { $0 } + steering).subtracting([PeerDataTaint.principal("agent")])
        let state: DeskState
        do {
            state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            throw TurnEngineError.contextLoadFailed(underlying: error)
        }
        let entries = MyQueue.entries(state).filter { entry in
            guard MyQueue.migrationReady(entry.step, dataRoot: dataRoot) else { return false }
            if peerTurn {
                guard let origin = entry.step.origin, origin.hasPrefix("agent:") else { return false }
                return peers.contains(PeerDataTaint.principal(String(origin.dropFirst(6))))
            }
            return entry.step.origin == "self" || entry.owedToPerson
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "'next' EEE HH:mm"
        let moments = entries.map { entry -> (entry: MyQueue.Entry, moment: String, at: Date?) in
            if entry.step.status == "stopped" {
                return (entry, "stopped: " + (entry.step.reason ?? "reconcile before acting"), nil)
            }
            guard let condition = MyQueue.when(entry) else { return (entry, "condition unavailable; repair the saved condition", nil) }
            switch condition {
            case .every:
                let next = IntentionClock.next(entry.step, after: now)
                return (entry, next.map { format.string(from: $0) } ?? "no next clock moment", next)
            case .at(let date): return (entry, ResidentWake.shown(date), date)
            case .afterCard(let card): return (entry, "after card " + card, nil)
            case .userWrites(let door): return (entry, "when User writes" + (door.map { " on " + $0.rawValue } ?? ""), nil)
            case .nextTurn: return (entry, "next turn", nil)
            case .ownTurn: return (entry, "my own turn", nil)
            case .quiet: return (entry, "when it is quiet", nil)
            case .userHere: return (entry, "when User is here", nil)
            case .userAway: return (entry, "when User steps away", nil)
            case .news(let words): return (entry, "on news about " + words, nil)
            case .signal(let name): return (entry, "on " + name, nil)
            }
        }.sorted {
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
        let lines = moments.prefix(6).map { row in
            let until: String
            switch MyQueue.until(row.entry) {
            case .once: until = "done once"
            case .standing: until = "I let it go"
            case .time(let date): until = ResidentWake.shown(date)
            case .words(let words): until = words
            }
            // Carry the item's name so the shown work can be finished with `queue.done`.
            return "- " + row.entry.name + " · " + Self.intentionLine(row.entry.step.words) + " · " + Self.intentionLine(row.moment)
                + " · until " + Self.intentionLine(until)
        }
        return lines.isEmpty ? "" : "# What I mean to do\n" + lines.joined(separator: "\n")
    }

    private static func intentionLine(_ words: String) -> String {
        let line = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }
}
