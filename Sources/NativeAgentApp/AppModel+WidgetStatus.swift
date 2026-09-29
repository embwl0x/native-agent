import Foundation
import OSLog
import Desk
import WidgetKit

extension AppModel {
    /// Existing refreshes and turn activity publish changes without polling.
    @available(macOS 27, *)
    func publishWidgetStatus() async {
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
        let waiting: Int?
        do {
            let approvals = try await engine.approvals.list()
            let memories = try await engine.memory.proposals(status: "pending")
            let desk = try await SwiftNativeDeskStore(dataRoot: engine.dataRoot).liveState().items
            let count = approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status) }.count
                + memories.count + OwnerAttentionPolicy.ownerDecisionCount(in: desk)
            waiting = count
            let active = engine.turns.visiblyWorkingSessionIDs
            if !active.subtracting(engine.turns.replyingSessions).isEmpty {
                status = "Thinking…"
            } else if !active.isEmpty {
                status = "Replying…"
            } else if count > 0 {
                status = "Waiting on you"
            } else if let work = desk.first(where: { $0.status == .now }) {
                status = "Working on \(work.title)"
            } else {
                status = "Here"
            }
        } catch {
            status = "Status unavailable"
            waiting = nil
        }
        do {
            let snapshot = NativeAgentWidgetSnapshot(
                name: agentDisplayName, status: status, waitingCount: waiting, updatedAt: Date()
            )
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let previous = try NativeAgentWidgetSnapshot.read()
                    if previous.name == snapshot.name, previous.status == status, previous.waitingCount == waiting {
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
