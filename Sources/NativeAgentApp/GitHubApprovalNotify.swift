import Foundation
import PersistenceCore

// PR-approval edge notifier (User, 2026-07-12: an approval landing on a tracked
// pull request should reach his phone — it's news, not work, so it never
// creates a Desk row or dispatches codex; it pings).
//
// After each tracking refresh, evaluateSnapshot() reads the persisted tracking
// snapshot and compares every open pull request's reviewState against the map
// persisted at data/notify/github_approvals.json. A transition INTO "approved"
// pings once; restarts neither re-ping nor forget. The FIRST evaluation ever
// seeds the baseline silently — a cold start must not blast pushes for PRs
// approved long ago.
actor GitHubApprovalEdgeNotifier {
    static let shared = GitHubApprovalEdgeNotifier()

    private struct State: Codable {
        var seeded: Bool
        var reviewStates: [String: String]
    }

    // Keyed by data root: a temp-root test run must never bleed cached state
    // into the live root's map (review finding).
    private var cached: [String: State] = [:]

    private func stateURL(_ dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("github_approvals.json")
    }

    private func snapshotURL(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("connectors/github/tracking_snapshot.json")
    }

    func evaluateSnapshot(dataRoot: URL = PersistenceCore.defaultDataRoot()) async {
        guard let data = try? Data(contentsOf: snapshotURL(dataRoot)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = raw["entities"] as? [[String: Any]] else { return }

        var open: [String: (reviewState: String, title: String)] = [:]
        var closed: Set<String> = []
        for entity in entities {
            guard (entity["kind"] as? String) == "pull_request",
                  let repo = entity["repository"] as? String,
                  let number = (entity["number"] as? Int) ?? (entity["number"] as? String).flatMap(Int.init) else { continue }
            let itemId = "\(repo.lowercased())#\(number)"
            if (entity["state"] as? String) == "open", let reviewState = entity["reviewState"] as? String {
                open[itemId] = (reviewState, (entity["title"] as? String) ?? "PR #\(number)")
            } else {
                closed.insert(itemId)
            }
        }

        var state = load(dataRoot)
        defer { save(state, dataRoot) }

        guard state.seeded else {
            state = State(seeded: true, reviewStates: open.mapValues(\.reviewState))
            return
        }

        // Merge, never wholesale-replace: an entry vanishing from a subset or
        // scope-limited snapshot is UNKNOWN, not un-approved — wiping it would
        // re-ping every approved PR when the full snapshot returns (review
        // finding). Entries drop only when the snapshot explicitly shows the
        // PR closed/merged; a reopened PR then re-earns its edge.
        for itemId in closed { state.reviewStates.removeValue(forKey: itemId) }
        for (itemId, info) in open {
            let prior = state.reviewStates[itemId]?.lowercased()
            let isNewApproval = info.reviewState.lowercased() == "approved" && prior != "approved"
            if isNewApproval {
                do {
                    _ = try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                        title: "PR approved",
                        body: "\(info.title) (\(itemId)) was approved.",
                        userInfo: [
                            "kind": "github_pr_approved",
                            "dedupKey": "pr_approved+\(itemId)",
                        ]
                    )
                } catch {
                    // The contract is "the phone gets the edge": keep the prior
                    // entry so the next cycle retries instead of losing the
                    // approval forever (review finding).
                    NSLog("github_approval_notify: push failed, will retry: \(error.localizedDescription)")
                    continue
                }
            }
            state.reviewStates[itemId] = info.reviewState
        }
    }

    private func load(_ dataRoot: URL) -> State {
        let key = dataRoot.standardizedFileURL.path
        if let cached = cached[key] { return cached }
        guard let data = try? Data(contentsOf: stateURL(dataRoot)),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State(seeded: false, reviewStates: [:])
        }
        cached[key] = state
        return state
    }

    private func save(_ state: State, _ dataRoot: URL) {
        cached[dataRoot.standardizedFileURL.path] = state
        let url = stateURL(dataRoot)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
