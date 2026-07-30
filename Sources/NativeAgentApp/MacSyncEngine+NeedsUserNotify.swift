import CryptoKit
import Foundation
import PersistenceCore

// Needs-User edge notifier (User, 2026-07-12: "if she ever does turn to needs
// User I should get an apns about it so I know").
//
// Fires ONE push on the false→true edge of an explicit owner-waiting Desk row.
// Pending approvals use their existing approval notification lanes; generic
// blocked work and organism trouble remain visible attention but are not a
// request for the owner. A changed why while already-true re-pings once (a NEW
// reason is a new fact); true→false clears silently. State persists at
// data/notify/needs_user_edge.json so restarts
// neither re-ping nor forget. The FIRST evaluation ever seeds the baseline
// without pinging — a cold start must not alarm User about a state he may
// already be looking at.
actor NeedsUserEdgeNotifier {
    static let shared = NeedsUserEdgeNotifier()

    typealias Sender = @Sendable (
        _ title: String,
        _ body: String,
        _ userInfo: [String: String]
    ) async throws -> Void

    private struct State: Codable {
        var seeded: Bool
        var lastNeedsUser: Bool
        var lastWhy: String
    }

    private let dataRoot: URL
    private let sender: Sender
    private var cached: State?

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        sender: @escaping Sender = { title, body, userInfo in
            _ = try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                title: title,
                body: body,
                userInfo: userInfo
            )
        }
    ) {
        self.dataRoot = dataRoot
        self.sender = sender
    }

    private var stateURL: URL {
        dataRoot
            .appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("needs_user_edge.json")
    }

    func evaluate(needsUser: Bool, why: String) async {
        let state = load()

        guard state.seeded else {
            persist(State(seeded: true, lastNeedsUser: needsUser, lastWhy: needsUser ? why : ""))
            return
        }
        let edgeUp = needsUser && !state.lastNeedsUser
        let newReason = needsUser && state.lastNeedsUser && !why.isEmpty && why != state.lastWhy
        let next = State(
            seeded: true,
            lastNeedsUser: needsUser,
            lastWhy: needsUser ? why : ""
        )
        guard edgeUp || newReason else {
            if next.lastNeedsUser != state.lastNeedsUser || next.lastWhy != state.lastWhy {
                persist(next)
            }
            return
        }

        do {
            try await sender(
                "\(NativeAgentNotificationDefaults.agentDisplayName(dataRoot: dataRoot)) needs you",
                why.isEmpty ? "The agent's status changed to needs-you — check the Today panel." : why,
                [
                    "kind": "agent_needs_user",
                    "dedupKey": "needs_user+\(Self.stableDigest(why))",
                ]
            )
            // Delivery is the commit point. A failed send leaves the previous
            // edge intact so the next snapshot pass retries instead of losing
            // the only signal that Agent needs the user.
            persist(next)
        } catch {
            NSLog("needs_user_notify: push failed, will retry: \(error.localizedDescription)")
        }
    }

    private func load() -> State {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State(seeded: false, lastNeedsUser: false, lastWhy: "")
        }
        cached = state
        return state
    }

    private func persist(_ state: State) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
            // Do not advance the process cache until the durable state landed.
            // A post-delivery persistence failure may cause a duplicate retry,
            // which is safer than permanently suppressing the edge.
            cached = state
        } catch {
            NSLog("needs_user_notify: state persistence failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
