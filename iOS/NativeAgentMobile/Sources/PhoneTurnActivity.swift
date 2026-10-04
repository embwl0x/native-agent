import ActivityKit
import CryptoKit
import NativeAgentShared
import SwiftUI

@MainActor
final class PhoneTurnActivity: ObservableObject {
    static let shared = PhoneTurnActivity()
    @Published private(set) var workingIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "NativeAgentMobile.workActivityEnabled")
    var work: [String: MobileWorkActivity] = [:]
    var pushConfigured = false
    var workUpdates: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    var workPairing: String?
    var workExpirations: [String: Task<Void, Never>] = [:]
    var tokenObservers: [String: Task<Void, Never>] = [:]
    var activityObserver: Task<Void, Never>?
    var startTokenObserver: Task<Void, Never>?
    var registrationTask: Task<Void, Never>?
    var disableRegistrationInFlight = false
    var disableRegistrationPending = (UserDefaults.standard.object(forKey: "NativeAgentMobile.workActivityDisablePending") as? Bool)
        ?? !UserDefaults.standard.bool(forKey: "NativeAgentMobile.workActivityEnabled") {
        didSet { UserDefaults.standard.set(disableRegistrationPending, forKey: "NativeAgentMobile.workActivityDisablePending") }
    }
    var failedWorkStarts: Set<String> = []
    var activityPairing: String? { AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) }
    var activityPushPairing: String? {
        guard let secret = iCloudBridge.shared.pairingSecretForPhoneRequests else { return nil }
        return SHA256.hash(data: Data(secret.base64EncodedString().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func activityError(_ message: String?) { errorMessage = message }
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
    private var expirations: [String: Task<Void, Never>] = [:]
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
        resumeWorkActivities()
        let pairing = AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests)
        for turn in Array(turns.values) {
            if turn.pairing != pairing { finish(turn.id, status: "Activity ended") }
            else if turn.expired == true { continue }
            else if (turn.updatedAt ?? turn.startedAt).addingTimeInterval(staleInterval) <= Date() { expire(turn.id) }
            else if turn.status != nil {
                if !turn.replying, let at = turn.updatedAt, at > Date().addingTimeInterval(-120) { workingIDs.insert(turn.id) }
                else { workingIDs.remove(turn.id) }
            }
            expireWhenStale(turn.id)
        }
        trimExpiredTurns()
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
        case "final", "cancelled", "error", "rejection":
            let status = kind == "final" ? "Reply ready" : kind == "cancelled" ? "Stopped" : "Open NativeAgent for details"
            finish(id, status: status)
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
        expirations.removeValue(forKey: id)?.cancel()
        guard var turn = turns[id], turn.expired != true else { return }
        turn.expired = true
        turn.requested = false
        turns[id] = turn
        workingIDs.remove(id)
        trimExpiredTurns()
        save()
    }

    private func trimExpiredTurns() {
        let expired = turns.values.filter { $0.expired == true }
            .sorted { ($0.updatedAt ?? $0.startedAt) > ($1.updatedAt ?? $1.startedAt) }
        guard expired.count > 64 else { return }
        for turn in expired.dropFirst(64) {
            turns.removeValue(forKey: turn.id)
            expirations.removeValue(forKey: turn.id)?.cancel()
        }
        save()
    }

    func finish(_ id: String, status: String = "Turn ended") {
        expirations.removeValue(forKey: id)?.cancel()
        workingIDs.remove(id)
        guard turns.removeValue(forKey: id) != nil else { return }
        save()
    }

    func silence(_ id: String) { workingIDs.remove(id) }

}
