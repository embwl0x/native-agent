import CryptoKit
import Foundation
import PersistenceCore
import Desk
import NativeAgentShared

// Needs-User edge notifier (User, 2026-07-12: "if she ever does turn to needs
// User I should get an apns about it so I know").
//
// Fires one push per new or changed explicit owner-waiting Desk question.
// Pending approvals use their existing approval notification lanes; generic
// blocked work and organism trouble remain visible attention but are not a
// request for the owner. Item identity and reason define the edge; cleared
// waits disappear silently. State persists at
// data/notify/needs_user_edge.json so restarts
// neither re-ping nor forget. The FIRST evaluation ever seeds the baseline
// without pinging — a cold start must not alarm User about a state he may
// already be looking at.
actor NeedsUserEdgeNotifier {
    typealias Sender = @Sendable (
        _ title: String,
        _ body: String,
        _ userInfo: [String: String]
    ) async throws -> Void

    private struct Wait: Codable {
        var fingerprint: String
        var episodeID: String
    }

    private struct State: Codable {
        var seeded: Bool
        // Missing in the old count-based format: seed without replaying waits.
        var requests: [String: Wait]?
    }

    private let dataRoot: URL
    private let sender: Sender
    private var cached: State?
    private var evaluating = false

    /// `sender` routes the knock (item 26: the edge decision stays here, the
    /// CHANNEL decision belongs to the attention router) and throws when it
    /// reached nobody, so the episode stays unwritten for the next pass.
    init(dataRoot: URL, sender: @escaping Sender) {
        self.dataRoot = dataRoot
        self.sender = sender
    }

    private var stateURL: URL {
        dataRoot
            .appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("needs_user_edge.json")
    }

    func evaluate(items: [DeskItem]) async {
        guard !evaluating else { return }
        evaluating = true
        defer { evaluating = false }
        var state = load()
        let items = items.filter(\.requiresOwnerInput).sorted { $0.handle < $1.handle }
        func fingerprint(_ item: DeskItem) -> String {
            Self.stableDigest(item.handle + "\n" + item.title + "\n" + (item.blockedReason ?? item.summary ?? ""))
        }
        guard state.seeded, state.requests != nil else {
            persist(State(seeded: true, requests: Dictionary(uniqueKeysWithValues: items.map {
                ($0.handle, Wait(fingerprint: fingerprint($0), episodeID: UUID().uuidString))
            })))
            return
        }
        let handles = Set(items.map(\.handle))
        let retained = state.requests?.filter { handles.contains($0.key) }
        if retained?.count != state.requests?.count {
            state.requests = retained
            guard persist(state) else { return }
        }
        for item in items {
            let digest = fingerprint(item)
            var current = load()
            let previous = current.requests?[item.handle]
            guard previous?.fingerprint != digest else { continue }
            let episode = previous?.episodeID ?? UUID().uuidString
            // Reserve the identity before sending; an empty fingerprint keeps
            // failed delivery eligible on the next pass with the same key.
            current.requests?[item.handle] = Wait(fingerprint: previous?.fingerprint ?? "", episodeID: episode)
            guard persist(current) else { return }
            let reason = (item.blockedReason ?? item.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = reason.isEmpty ? item.title : "\(item.title) — \(reason)"
            do {
                try await sender(
                    "\(NativeAgentNotificationDefaults.agentDisplayName(dataRoot: dataRoot)) needs you",
                    MobileDeskProjectionBounds.clipped(body, to: 500),
                    ["kind": "agent_needs_user", "screen": "desk", "taskId": item.handle,
                     "dedupKey": "needs_user+\(episode)+\(digest)"]
                )
                current = load()
                guard current.requests?[item.handle]?.episodeID == episode else { continue }
                current.requests?[item.handle] = Wait(fingerprint: digest, episodeID: episode)
                guard persist(current) else { return }
            } catch {
                NSLog("needs_user_notify: push failed, will retry: \(error.localizedDescription)")
            }
        }
    }

    private func load() -> State {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State(seeded: false, requests: nil)
        }
        cached = state
        return state
    }

    @discardableResult
    private func persist(_ state: State) -> Bool {
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
            return true
        } catch {
            NSLog("needs_user_notify: state persistence failed: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
