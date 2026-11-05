import AgentConversations
import Desk
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `DeskFaceItem.swift` | The selected Desk item or execution's canonical details, dependencies, notes and references in the Desk face |

@MainActor extension NativeAgentEngine {
    @MainActor func deskItemFace(_ snapshot: DeskPageSnapshot) -> [PartFace.Section] {
        guard let handle = desk.faceItem else { return [] }
        let back = PartFace.Row(id: "desk-selection", title: "Board", actions: [.init(id: "board", label: "Back to the board")])
        if handle.hasPrefix("execution:") {
            let id = String(handle.dropFirst("execution:".count))
            if let job = snapshot.agentJobs.items.first(where: { $0.id == id }) {
                let row = WorkOverviewRead.row(for: job, now: snapshot.now)
                return [.init(id: "selected-execution", title: row.title, style: .values, rows: [
                    .init(id: "execution-detail:" + id, title: WorkOverviewRead.text(for: job),
                        detail: job.request.map { "Asking: " + $0.title }, value: row.stateLabel(at: snapshot.now),
                        at: row.updatedAt), back,
                ])]
            }
            return [.init(id: "selected-unavailable", title: "Work details", style: .values, rows: [
                .init(id: "selected-missing", title: snapshot.agentJobs.unavailableReason
                    ?? "This execution is not in the current reading. Refresh the Desk to read it again.", tone: .attention), back,
            ])]
        }
        guard let item = snapshot.items.first(where: { $0.handle == handle }) else {
            return [.init(id: "selected-unavailable", title: "Item details", style: .values, rows: [
                .init(id: "selected-missing", title: snapshot.deskUnavailable
                    ?? "This item is not in the current reading. Refresh the Desk to read it again.", tone: .attention), back,
            ])]
        }
        var rows: [PartFace.Row] = [
            .init(id: "item-detail:" + item.handle, title: item.title,
                value: "\(item.alias) · \(item.kind.rawValue) · \(item.status.displayLabel) · \(item.project) · added by \(item.origin.rawValue)",
                at: item.updatedAt),
        ]
        if let summary = item.summary, !summary.isEmpty { rows.append(.init(id: "summary", title: summary)) }
        if let assignee = item.assignee { rows.append(.init(id: "assignee", title: "Assigned to", value: assignee)) }
        if let progress = item.progress {
            rows.append(.init(id: "progress", title: "Progress", detail: progress.note, value: "\(progress.done) of \(progress.total)"))
        }
        if let reason = item.blockedReason, !reason.isEmpty {
            rows.append(.init(id: "blocked-reason", title: "Blocked: " + reason, tone: .attention))
        }
        if let waiting = item.waitingOn, !waiting.isEmpty {
            rows.append(.init(id: "waiting-on", title: "Waiting on " + waiting, tone: .attention))
        }
        if let plan = snapshot.plan.byHandle[item.handle] {
            if plan.totalCount > 0 {
                rows.append(.init(id: "rollup", title: "Steps closed", value: "\(plan.doneCount)/\(plan.totalCount)"))
            }
            for blocker in plan.effectiveBlockers {
                let source = snapshot.items.first { $0.handle == blocker }
                rows.append(.init(id: "blocker:" + blocker, title: "Waiting on " + (source?.alias ?? blocker), detail: source?.title,
                    tone: .attention, open: source == nil ? nil : "page:desk/" + blocker))
            }
            if plan.blockedByCycle {
                rows.append(.init(id: "cycle", title: "These items block each other.", tone: .attention))
            }
            if plan.isDeferred {
                rows.append(.init(id: "deferred", title: "Deferred until",
                    at: item.deferUntil.flatMap(DeskSequencing.parseDeferStamp).map(NativeTimestampFormat.fractionalZulu)))
            }
            if snapshot.plan.nextUp.contains(item.handle) { rows.append(.init(id: "next-up", title: "Start here")) }
        }
        if DeskBoardLayout.isPursuitLaneItem(item), !item.status.isTerminal {
            rows += deskPursuitFace(item, snapshot: snapshot)
        }
        rows += item.notes.enumerated().map {
            .init(id: "note:\($0.offset)", title: $0.element.text, at: $0.element.ts)
        }
        for ref in item.refs.sorted(by: { $0.priority < $1.priority }) {
            let action = DeskRefAffordance.action(for: ref)
            switch action {
            case .open(let url, let label) where PartFace.isLink("url:" + url):
                rows.append(.init(id: "ref:" + ref.refId, title: label, open: "url:" + url))
            case .open(let url, let label):
                rows.append(.init(id: "ref:" + ref.refId, title: label, detail: url,
                    actions: [.init(id: "copy-reference", label: "Copy reference")]))
            case .copy(let text, let label):
                rows.append(.init(id: "ref:" + ref.refId, title: label, detail: text,
                    actions: [.init(id: "copy-reference", label: "Copy reference")]))
            }
        }
        if snapshot.boardItems.contains(where: { $0.handle == handle }) {
            rows += Self.deskItemActions(item).map { .init(id: "item-action:" + $0.id, title: $0.label, actions: [$0]) }
            if !item.status.isTerminal {
                rows += DeskDeferPreset.allCases.map { preset in
                    .init(id: "item-action:defer:" + preset.rawValue, title: "Defer until",
                        at: DeskSequencing.parseDeferStamp(preset.day(from: snapshot.now)).map(NativeTimestampFormat.fractionalZulu),
                        actions: [.init(id: "defer:" + preset.rawValue, label: "Defer")])
                }
            }
        }
        rows.append(back)
        return [.init(id: "selected-item", title: item.title, style: .values, rows: rows)]
    }

    private func deskPursuitFace(_ item: DeskItem, snapshot: DeskPageSnapshot) -> [PartFace.Row] {
        guard let pursuit = item.pursuit else {
            return [.init(id: "pursuit-unavailable", title: "Project details unavailable",
                detail: "The saved project details need to be repaired before you can act on them.", tone: .attention)]
        }
        var rows: [PartFace.Row] = [
            .init(id: "pursuit-why", title: pursuit.why),
            .init(id: "pursuit-done", title: "Done when: " + pursuit.doneLooksLike),
            .init(id: "pursuit-sessions", title: "Sessions", value: "\(pursuit.sessionsUsed(in: item.workAttempts))/\(pursuit.maxSessions)"),
        ]
        if let count = snapshot.board?.deskState?.pursuitWorkSessions(on: DeskClock.dayStamp(snapshot.now), handle: item.handle) {
            rows.append(.init(id: "pursuit-today", title: "Sessions today", value: "\(count)"))
        } else {
            rows.append(.init(id: "pursuit-today", title: "Today's sessions unavailable", tone: .attention))
        }
        if let last = pursuit.lastWorkedAt { rows.append(.init(id: "pursuit-last", title: "Last worked", at: last)) }
        if let score = DeskPursuitChoice.score(for: item, now: snapshot.now) {
            rows.append(.init(id: "pursuit-score", title: "Score", value: String(format: "%.2f", score.total)))
        }
        return rows
    }
}
