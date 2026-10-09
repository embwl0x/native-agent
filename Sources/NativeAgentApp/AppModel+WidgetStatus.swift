import Foundation
import OSLog
import Desk
import WidgetKit
import NativeAgentShared
import EngineRuntime
import WorkshopExecution

extension AppModel {
    /// One read of the overview sets the one "needs you" count, runs the
    /// needs-you push and feeds the widget. Desk writes, refreshes and turn
    /// activity publish changes without polling.
    func publishWorkStatus() async {
        guard !workStatusInFlight else { workStatusDirty = true; return }
        workStatusInFlight = true
        defer { workStatusInFlight = false }
        repeat {
            workStatusDirty = false
            let board = await engine.desk.loadBoard(includeOverview: true)
            let overview = board.overview!
            setIfChanged(\.ownerWaitingCount, overview.unavailable.isEmpty ? overview.needsYouCount : nil)
            setIfChanged(\.ownerWaitingKinds, overview.unavailable.isEmpty && overview.omittedNeedsYou == 0
                ? Dictionary(grouping: overview.needsYou, by: \.reference.kind).mapValues(\.count) : nil)
            if let items = board.deskState?.items { await engine.deviceSync?.evaluateNeedsUser(items: items) }
            if #available(macOS 27, *) { await publishWidgetStatus(board) }
        } while workStatusDirty
    }

    @available(macOS 27, *)
    private func publishWidgetStatus(_ board: DeskBoardRead) async {
        guard !widgetContainerUnavailableLogged else { return }
        let url: URL
        do {
            url = try NativeAgentWidgetSnapshot.fileURL()
        } catch {
            widgetContainerUnavailableLogged = true
            Logger(subsystem: "NativeAgent", category: "Widget").notice("Widget status disabled: App Group container unavailable")
            return
        }
        let status: String
        let waiting = ownerWaitingCount
        var activityExpiresAt: Date?
        if let count = waiting {
            let desk = board.items
            let executions = board.executions
            let now = Date()
            let busy = engine.turns.visiblyWorkingSessionIDs
            let active = busy.filter { id in
                guard let movement = engine.turns.lifecycle(for: id)?.presentation,
                      [.working, .tool, .delegation, .retrying].contains(movement.phase) else { return false }
                return movement.lastMovementAt <= now && now.timeIntervalSince(movement.lastMovementAt) < DeskActivityState.movementWindow
            }
            let evidence = DeskMovementPresentation.evidence(executions.items)
            // Each item's activity once, and only if the chain below gets that
            // far; it was re-derived for every item in each of six passes.
            lazy var activities = desk.map { ($0, DeskMovementPresentation.activity($0, evidence: evidence[$0.handle], now: now)) }
            let work = executions.items.filter({
                DeskActivityState.execution(.init(deskHandle: $0.deskHandle, status: $0.status, updatedAt: $0.updatedAt, lastMovementAt: $0.lastMovementAt), now: now) == .working
            }).max(by: { ($0.lastMovementAt ?? "") < ($1.lastMovementAt ?? "") })
            if let latest = active.compactMap({ id -> (id: String, movement: Date)? in
                guard let movement = engine.turns.lifecycle(for: id)?.presentation.lastMovementAt else { return nil }
                return (id, movement)
            }).max(by: { $0.movement < $1.movement }),
               latest.movement >= (DeskActivityState.movementDate(work?.lastMovementAt) ?? .distantPast) {
                status = engine.turns.replyingSessions.contains(latest.id) ? "Replying…" : "Thinking…"
                activityExpiresAt = latest.movement.addingTimeInterval(DeskActivityState.movementWindow)
            } else if count > 0 {
                status = "Waiting on you"
            } else if let work {
                status = "Working on \(work.title)"
                activityExpiresAt = DeskActivityState.movementDate(work.lastMovementAt)?.addingTimeInterval(DeskActivityState.movementWindow)
            } else if !busy.isEmpty {
                status = "Activity unconfirmed"
            } else if activities.contains(where: { $0.1 == .stale }) {
                status = "Stale work — activity unconfirmed"
            } else if activities.contains(where: { !$0.0.status.isTerminal && $0.1 == .unknown }) {
                status = "Activity unknown"
            } else if activities.contains(where: { $0.1 == .queued }) {
                status = "Work queued"
            } else if activities.contains(where: { $0.1 == .watching }) {
                status = "Watching"
            } else if activities.contains(where: { $0.1 == .deferred }) {
                status = "Work deferred"
            } else if activities.contains(where: { $0.1 == .blocked }) {
                status = "Work blocked"
            } else {
                status = "Activity unknown"
            }
        } else {
            status = "Status unavailable"
        }
        do {
            let snapshot = NativeAgentWidgetSnapshot(
                name: agentDisplayName, status: status, waitingCount: waiting, updatedAt: Date(), activityExpiresAt: activityExpiresAt
            )
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let previous = try NativeAgentWidgetSnapshot.read()
                    if previous.name == snapshot.name, previous.status == status, previous.waitingCount == waiting,
                       previous.activityExpiresAt == activityExpiresAt {
                        return
                    }
                } catch {
                    // This projection is disposable; repair it from the checked owners.
                    Logger(subsystem: "NativeAgent", category: "Widget").error("Replacing unreadable status projection: \(error.localizedDescription, privacy: .public)")
                }
            }
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: NativeAgentWidgetSnapshot.kind)
        } catch {
            Logger(subsystem: "NativeAgent", category: "Widget").error("Status publication failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
