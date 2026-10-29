import Foundation
import Cognition
import OSLog
import PersistenceCore
import StandingBots
import NativeAgentShared
import Desk
import TriggerScheduler
import WorkshopExecution
// Blueprint: | `WorkStatusPublication.swift` | Per-AppModel MainActor publication: one board read, coalesced requests, needs-owner push evaluation and change-suppressed widget status |
@MainActor
public final class WorkStatusPublication {
    private var widgetContainerUnavailableLogged = false
    private var workStatusInFlight = false
    private var workStatusDirty = false
    public init() {}

    /// One frozen Desk read runs the needs-you push and feeds the widget.
    /// Desk writes, refreshes and turn activity publish changes without polling.
    public func publishWorkStatus(engine: NativeAgentEngine, displayName: @MainActor () -> String,
                                  reloadWidget: @escaping @Sendable () -> Void) async {
        guard !workStatusInFlight else { workStatusDirty = true; return }
        workStatusInFlight = true
        defer { workStatusInFlight = false }
        repeat {
            workStatusDirty = false
            let board = await engine.desk.refreshPage().board!
            let overview = board.overview!
            let waiting = overview.unavailable.isEmpty ? overview.needsYouCount : nil
            if let items = board.deskState?.items { await engine.deviceSync?.evaluateNeedsUser(items: items) }
            if #available(macOS 27, *) { await publishWidgetStatus(board, engine: engine, name: displayName(), waiting: waiting, reload: reloadWidget) }
        } while workStatusDirty
    }

    @available(macOS 27, *)
    private func publishWidgetStatus(_ board: DeskBoardRead, engine: NativeAgentEngine, name: String,
                                     waiting: Int?, reload: @escaping @Sendable () -> Void) async {
        guard !widgetContainerUnavailableLogged else { return }
        let busy = engine.turns.visiblyWorkingSessionIDs
        let replying = engine.turns.replyingSessions
        let movements = Dictionary(uniqueKeysWithValues: busy.compactMap { id in
            engine.turns.lifecycle(for: id).map { (id, $0.presentation) }
        })
        let containerUnavailable = await Task.detached(priority: .utility) { () -> Bool in
            let url: URL
            do {
                url = try NativeAgentWidgetSnapshot.fileURL()
            } catch {
                Logger(subsystem: "NativeAgent", category: "Widget").notice("Widget status disabled: App Group container unavailable")
                return true
            }
            let status: String
            var activityExpiresAt: Date?
            if let count = waiting {
                let desk = board.items
                let executions = board.executions
                let now = Date()
                let active = busy.filter { id in
                    guard let movement = movements[id],
                          [.working, .tool, .delegation, .retrying].contains(movement.phase) else { return false }
                    return movement.lastMovementAt <= now && now.timeIntervalSince(movement.lastMovementAt) < DeskActivityState.movementWindow
                }
                let evidence = DeskMovementPresentation.evidence(executions.items)
                // Read each item's activity only when the status chain reaches it.
                lazy var activities = desk.map { ($0, DeskMovementPresentation.activity($0, evidence: evidence[$0.handle], now: now)) }
                let work = executions.items.filter({
                    DeskActivityState.execution(.init(deskHandle: $0.deskHandle, status: $0.status, updatedAt: $0.updatedAt, lastMovementAt: $0.lastMovementAt), now: now) == .working
                }).max(by: { ($0.lastMovementAt ?? "") < ($1.lastMovementAt ?? "") })
                if let latest = active.compactMap({ id -> (id: String, movement: Date)? in
                    guard let movement = movements[id]?.lastMovementAt else { return nil }
                    return (id, movement)
                }).max(by: { $0.movement < $1.movement }),
                   latest.movement >= (DeskActivityState.movementDate(work?.lastMovementAt) ?? .distantPast) {
                    status = replying.contains(latest.id) ? "Replying…" : "Thinking…"
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
                    name: name, status: status, waitingCount: waiting, updatedAt: Date(), activityExpiresAt: activityExpiresAt
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        let previous = try NativeAgentWidgetSnapshot.read()
                        if previous.name == snapshot.name, previous.status == status, previous.waitingCount == waiting,
                           previous.activityExpiresAt == activityExpiresAt {
                            return false
                        }
                    } catch {
                        // This projection is disposable; repair it from the checked owners.
                        Logger(subsystem: "NativeAgent", category: "Widget").error("Replacing unreadable status projection: \(error.localizedDescription, privacy: .public)")
                    }
                }
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(snapshot), to: url)
                reload()
            } catch {
                Logger(subsystem: "NativeAgent", category: "Widget").error("Status publication failed: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }.value
        if containerUnavailable { widgetContainerUnavailableLogged = true }
    }
}
