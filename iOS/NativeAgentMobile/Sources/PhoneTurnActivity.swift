import ActivityKit
import NativeAgentShared
import SwiftUI

/// Local sends alone authorize a Live Activity. Signed sync supplies its state;
/// no APNs activity token or push-to-start registration is requested.
@MainActor
final class PhoneTurnActivity: ObservableObject {
    static let shared = PhoneTurnActivity()
    @Published private(set) var workingIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    private struct Turn: Codable {
        let id: String
        let startedAt: Date
        let pairing: String
        var updatedAt: Date?
        var status: String?
        var requested = false
        var replying = false
        var expired: Bool?
    }
    private let key = "NativeAgentMobile.localLiveTurns"
    private var turns: [String: Turn] = [:]
    private var updates: [String: Task<Void, Never>] = [:]
    private var expirations: [String: Task<Void, Never>] = [:]
    private var failedStarts: Set<String> = []
    private let staleInterval: TimeInterval = 15 * 60

    private init() {
        if let data = UserDefaults.standard.data(forKey: key) {
            do { turns = try JSONDecoder().decode([String: Turn].self, from: data) }
            catch { errorMessage = "Live Activity state could not be read: \(error.localizedDescription)" }
        }
    }
    private func save() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(turns), forKey: key) }
        catch { errorMessage = "Live Activity state could not be saved: \(error.localizedDescription)" }
    }

    func sent(_ id: String) {
        resume()
        guard turns[id] == nil,
              let pairing = AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) else { return }
        turns[id] = Turn(id: id, startedAt: Date(), pairing: pairing)
        save()
        expireWhenStale(id)
    }

    func resume() {
        failedStarts.removeAll()
        let pairing = AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests)
        for turn in Array(turns.values) {
            if turn.pairing != pairing { finish(turn.id, status: "Activity ended") }
            else if turn.expired == true { continue }
            else if (turn.updatedAt ?? turn.startedAt).addingTimeInterval(staleInterval) <= Date() { expire(turn.id) }
            else if turn.status != nil {
                if !turn.replying, let at = turn.updatedAt, at > Date().addingTimeInterval(-120) { workingIDs.insert(turn.id) }
                else { workingIDs.remove(turn.id) }
                enqueue(turn.id) { self.start(turn.id) }
            }
            expireWhenStale(turn.id)
        }
        let orphans = Set(Activity<PhoneTurnAttributes>.activities.filter {
            turns[$0.attributes.correlationID] == nil && updates[$0.attributes.correlationID] == nil
                && $0.activityState != .ended && $0.activityState != .dismissed
        }.map(\.id))
        if !orphans.isEmpty { Task { await Self.endOrphans(orphans) } }
    }

    func receive(_ message: BridgeMessage) {
        guard let id = message.correlationID, var turn = turns[id],
              turn.pairing == AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests),
              message.timestamp >= turn.startedAt.addingTimeInterval(-60),
              message.timestamp >= (turn.updatedAt ?? .distantPast) else { return }
        let kind = message.metadata?["kind"] ?? "final"
        if kind == "progress", message.metadata?["stage"] == "received" { return }
        switch kind {
        case "progress", "tool_use", "tool_result", "text_delta", "notice":
            turn.expired = nil
            turn.status = kind == "text_delta" ? "Replying…" : "Working…"
            if kind == "text_delta", !message.text.isEmpty { turn.replying = true }
            turn.updatedAt = message.timestamp
            turns[id] = turn
            if turn.replying { workingIDs.remove(id) } else { workingIDs.insert(id) }
            save()
            expireWhenStale(id)
            let status = turn.status ?? "Working…"
            enqueue(id) {
                self.start(id)
                await Self.update(id, status: status, at: message.timestamp)
            }
        case "final", "cancelled", "error", "rejection":
            let status = kind == "final" ? "Reply ready" : kind == "cancelled" ? "Stopped" : "Open NativeAgent for details"
            let needsStart = turn.expired == true || (!turn.requested && turn.status != nil)
            finish(id, status: status, restoring: needsStart ? message.timestamp : nil)
        default: break
        }
    }

    private func expireWhenStale(_ id: String) {
        expirations.removeValue(forKey: id)?.cancel()
        guard let turn = turns[id], turn.expired != true else { return }
        let staleDate = (turn.updatedAt ?? turn.startedAt).addingTimeInterval(staleInterval)
        expirations[id] = Task {
            do { try await Task.sleep(for: .seconds(max(0, staleDate.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            expire(id)
        }
    }

    private func expire(_ id: String) {
        guard var turn = turns[id], turn.expired != true else { return }
        turn.expired = true
        turn.requested = false
        turns[id] = turn
        workingIDs.remove(id)
        failedStarts.remove(id)
        save()
        enqueue(id) { await Self.end(id, status: "Activity ended") }
    }

    private func enqueue(_ id: String, operation: @escaping @MainActor () async -> Void) {
        let previous = updates[id]
        updates[id] = Task { await previous?.value; await operation() }
    }

    private func start(_ id: String, restoring turn: Turn? = nil) {
        guard var current = turn ?? turns[id], current.expired != true, !current.requested, !failedStarts.contains(id),
              let status = current.status, let updatedAt = current.updatedAt,
              updatedAt > Date().addingTimeInterval(-120), UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if Activity<PhoneTurnAttributes>.activities.contains(where: {
            $0.attributes.correlationID == id && $0.activityState != .ended && $0.activityState != .dismissed
        }) {
            if turn == nil { current.requested = true; turns[id] = current; save() }
            return
        }
        do {
            _ = try Activity.request(attributes: PhoneTurnAttributes(correlationID: id,
                agentName: iCloudSyncEngine.shared.agentDisplayName, startedAt: current.startedAt),
                content: ActivityContent(state: .init(status: status, updatedAt: updatedAt),
                    staleDate: updatedAt.addingTimeInterval(120)), pushType: nil)
            if turn == nil { current.requested = true; turns[id] = current; save() }
            errorMessage = nil
        } catch {
            failedStarts.insert(id)
            errorMessage = "Live Activity could not start: \(error.localizedDescription)"
        }
    }

    func finish(_ id: String, status: String = "Turn ended", restoring at: Date? = nil) {
        expirations.removeValue(forKey: id)?.cancel()
        workingIDs.remove(id)
        failedStarts.remove(id)
        guard var turn = turns.removeValue(forKey: id) else { return }
        if let at {
            turn.expired = nil
            turn.requested = false
            turn.status = status
            turn.updatedAt = at
        }
        save()
        enqueue(id) {
            if at != nil { self.start(id, restoring: turn) }
            await Self.end(id, status: status)
            self.updates.removeValue(forKey: id)
        }
    }

    func silence(_ id: String) { workingIDs.remove(id) }

    // ActivityKit's activity handles are not Sendable. Create and use them on
    // the same nonisolated executor, passing only value data from the UI owner.
    @concurrent nonisolated private static func update(_ id: String, status: String, at: Date) async {
        for activity in Activity<PhoneTurnAttributes>.activities where activity.attributes.correlationID == id {
            await activity.update(ActivityContent(state: .init(status: status, updatedAt: at), staleDate: at.addingTimeInterval(120)))
        }
    }
    @concurrent nonisolated private static func end(_ id: String, status: String) async {
        for activity in Activity<PhoneTurnAttributes>.activities where activity.attributes.correlationID == id {
            await activity.end(ActivityContent(state: .init(status: status, updatedAt: Date()), staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(30)))
        }
    }
    @concurrent nonisolated private static func endOrphans(_ ids: Set<String>) async {
        for activity in Activity<PhoneTurnAttributes>.activities where ids.contains(activity.id)
            && activity.activityState != .ended && activity.activityState != .dismissed {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
