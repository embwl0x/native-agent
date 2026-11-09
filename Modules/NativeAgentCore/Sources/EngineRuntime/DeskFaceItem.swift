import AgentConversations
import Desk
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `DeskFaceItem.swift` | The selected Desk item or execution's canonical details, dependencies, pursuit, notes and references as Desk packet facts |

extension NativeAgentEngine {
    /// The selection the Desk face opens on: nothing, an execution, or a Desk item, each found in the current reading or named as missing.
    func deskSelectedFacts(_ snapshot: DeskPageSnapshot, selected: String?) -> JSONValue {
        guard let handle = selected else { return .null }
        let now = snapshot.now
        if handle.hasPrefix("execution:") {
            let id = String(handle.dropFirst("execution:".count))
            guard let job = snapshot.agentJobs.items.first(where: { $0.id == id }) else {
                return .object(["kind": .string("execution"), "id": .string(id), "found": .bool(false),
                                "unavailable": faceText(snapshot.agentJobs.unavailableReason)])
            }
            let row = WorkOverviewRead.row(for: job, now: now)
            return .object(["kind": .string("execution"), "id": .string(id), "found": .bool(true), "title": .string(row.title),
                            "text": .string(WorkOverviewRead.text(for: job)), "asking": faceText(job.request?.title),
                            "state": .string(row.stateLabel(at: now)), "at": .string(row.updatedAt)])
        }
        guard let item = snapshot.items.first(where: { $0.handle == handle }) else {
            return .object(["kind": .string("item"), "handle": .string(handle), "found": .bool(false),
                            "unavailable": faceText(snapshot.deskUnavailable)])
        }
        var plan = JSONValue.null
        if let sequenced = snapshot.plan.byHandle[item.handle] {
            let blockers: [JSONValue] = sequenced.effectiveBlockers.map { blocker -> JSONValue in
                let source = snapshot.items.first { $0.handle == blocker }
                return .object(["handle": .string(blocker), "alias": faceText(source?.alias), "title": faceText(source?.title)])
            }
            plan = .object(["done": .int(Int64(sequenced.doneCount)), "total": .int(Int64(sequenced.totalCount)),
                            "blockers": .array(blockers), "cycle": .bool(sequenced.blockedByCycle), "deferred": .bool(sequenced.isDeferred)])
        }
        let progress: JSONValue = item.progress.map { measured -> JSONValue in
            .object(["done": .int(Int64(measured.done)), "total": .int(Int64(measured.total)), "note": faceText(measured.note)])
        } ?? .null
        let notes: [JSONValue] = item.notes.map { note -> JSONValue in .object(["text": .string(note.text), "at": .string(note.ts)]) }
        let refs: [JSONValue] = item.refs.map { ref -> JSONValue in
            let target: (text: String, label: String) = switch DeskRefAffordance.action(for: ref) {
            case .open(let url, let named): (url, named)
            case .copy(let copied, let named): (copied, named)
            }
            return .object(["id": .string(ref.refId), "priority": .int(Int64(ref.priority)), "label": .string(target.label),
                            "text": .string(target.text)])
        }
        let onBoard = snapshot.boardItems.contains { $0.handle == handle }
        return .object([
            "kind": .string("item"), "handle": .string(item.handle), "found": .bool(true), "onBoard": .bool(onBoard),
            "alias": .string(item.alias), "itemKind": .string(item.kind.rawValue), "status": .string(item.status.rawValue),
            "project": .string(item.project), "origin": .string(item.origin.rawValue), "title": .string(item.title),
            "updatedAt": .string(item.updatedAt), "summary": faceText(item.summary), "assignee": faceText(item.assignee),
            "progress": progress, "blockedReason": faceText(item.blockedReason), "waitingOn": faceText(item.waitingOn),
            "requiresOwnerInput": .bool(item.requiresOwnerInput), "plan": plan,
            "deferAt": faceText(item.deferUntil.flatMap(DeskSequencing.parseDeferStamp).map(NativeTimestampFormat.fractionalZulu)),
            "nextUp": .bool(snapshot.plan.nextUp.contains(item.handle)),
            "pursuit": deskPursuitFacts(item, snapshot: snapshot), "notes": .array(notes), "refs": .array(refs),
            "vetoable": .bool(onBoard && Self.deskItemActions(item).contains { $0.id == "veto" }),
        ])
    }

    /// A pursuit lane item still open carries its pursuit's measures, or names them unavailable; any other item carries none.
    private func deskPursuitFacts(_ item: DeskItem, snapshot: DeskPageSnapshot) -> JSONValue {
        guard DeskBoardLayout.isPursuitLaneItem(item), !item.status.isTerminal else { return .null }
        guard let pursuit = item.pursuit else { return .object(["state": .string("unavailable")]) }
        let today = snapshot.board?.deskState?.pursuitWorkSessions(on: DeskClock.dayStamp(snapshot.now), handle: item.handle)
        let score = DeskPursuitChoice.score(for: item, now: snapshot.now)
        return .object([
            "state": .string("available"), "why": .string(pursuit.why), "doneWhen": .string(pursuit.doneLooksLike),
            "sessionsUsed": .int(Int64(pursuit.sessionsUsed(in: item.workAttempts))), "maxSessions": .int(Int64(pursuit.maxSessions)),
            "sessionsToday": today.map { JSONValue.int(Int64($0)) } ?? .null, "lastWorkedAt": faceText(pursuit.lastWorkedAt),
            "score": score.map { JSONValue.double($0.total) } ?? .null,
        ])
    }
}
