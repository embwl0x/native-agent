import Foundation
import PersistenceCore
import StandingBots

// Event waking for bots (0.4.12). Two listeners, no loop of their own: the
// GitHub watcher runs on the existing github_tracking tick, right after the
// connector refreshed its snapshot, and the Slack entry point is called by the
// socket-mode runner on a message it already accepted. Both hand the event to
// BotEventRouter, which matches triggers and admits runs through the ordinary
// run queue under the master Autonomy switch.
enum BotEventIntake {
    static func router(dataRoot: URL) -> BotEventRouter {
        BotEventRouter(dataRoot: dataRoot, isAutonomyEnabled: {
            await BackgroundLoopsAssembly.workshopEnabledGate(dataRoot: dataRoot)
        })
    }

    /// Called by the Slack socket-mode runner for each message it accepted, so
    /// only channels the runner already receives can wake a bot.
    static func slackMessage(
        channelId: String,
        text: String,
        userId: String,
        dataRoot: URL
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let summary = "Slack message in \(channelId): " + String(trimmed.prefix(200))
        let event = BotIncomingEvent(
            source: .slack,
            target: channelId,
            summary: summary,
            detail: "From \(userId) in \(channelId):\n" + trimmed
        )
        _ = await router(dataRoot: dataRoot).deliver(event)
    }
}

/// GitHub side: after each tracking refresh, every tracked item the snapshot
/// reports as new is one event. The snapshot already computes `newKeys`, so
/// there is nothing to poll. The first evaluation seeds silently — a cold start
/// must not wake bots for every item tracking has ever seen.
///
/// Exactly-once, in this order: the entity key is CLAIMED on disk before the
/// event is delivered, and a claim that cannot be written stops the pass instead
/// of delivering unclaimed (a crash between the two then re-delivers nothing; it
/// can only lose an event, never repeat one). `refreshedAt` advances only after
/// the whole pass, so an interrupted pass is retried against the same snapshot
/// and skips the keys already claimed. A claimed key is never evicted while its
/// entity is still in the snapshot, so a trim cannot let the same item fire
/// twice.
actor BotGitHubEventWatcher {
    static let shared = BotGitHubEventWatcher()

    private struct State: Codable {
        var seeded: Bool
        var refreshedAt: String
        var fired: [String]
    }

    /// Keyed by data root so a temp-root test run never bleeds into the live root.
    private var cached: [String: State] = [:]
    private static let firedLimit = 500

    private func stateURL(_ dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("bot_github_events.json")
    }

    private func snapshotURL(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("connectors/github/tracking_snapshot.json")
    }

    func evaluateSnapshot(dataRoot: URL = PersistenceCore.defaultDataRoot()) async {
        guard let data = try? Data(contentsOf: snapshotURL(dataRoot)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = raw["entities"] as? [[String: Any]] else { return }
        let refreshedAt = (raw["refreshedAt"] as? String) ?? ""
        let newKeys = Set((raw["newKeys"] as? [String]) ?? [])
        let present = Set(entities.compactMap { $0["key"] as? String })

        var state = load(dataRoot)
        guard state.seeded else {
            // A cold start records the snapshot as seen and wakes nothing.
            try? save(State(seeded: true, refreshedAt: refreshedAt, fired: []), dataRoot)
            return
        }
        // The same snapshot is read again on any tick that did not refresh.
        guard refreshedAt != state.refreshedAt else { return }

        var claimed = Set(state.fired)
        for entity in entities {
            guard let key = entity["key"] as? String, newKeys.contains(key),
                  let repo = entity["repository"] as? String else { continue }
            guard !claimed.contains(key) else { continue }
            claimed.insert(key)
            state.fired.append(key)
            // Claim first. An unwritable claim ends the pass: the next refresh
            // retries this snapshot rather than delivering what is not recorded.
            do { try save(state, dataRoot) } catch {
                NSLog("bot_github_events: claim unwritable, pass abandoned: \(error.localizedDescription)")
                return
            }
            let kind = (entity["kind"] as? String) == "pull_request" ? "pull request" : "issue"
            let number = (entity["number"] as? Int).map { "#\($0) " } ?? ""
            let title = (entity["title"] as? String) ?? ""
            let url = (entity["url"] as? String) ?? ""
            let summary = "New \(kind) in \(repo): \(number)\(title)"
            let event = BotIncomingEvent(
                source: .github,
                target: repo,
                summary: summary,
                detail: [summary, url].filter { !$0.isEmpty }.joined(separator: "\n")
            )
            _ = await BotEventIntake.router(dataRoot: dataRoot).deliver(event)
        }
        // Trim only keys the snapshot no longer carries: evicting a key whose
        // entity is still tracked would let that item fire a second time.
        if state.fired.count > Self.firedLimit {
            var kept: [String] = []
            var allowedDrops = state.fired.count - Self.firedLimit
            for key in state.fired {
                if allowedDrops > 0, !present.contains(key) { allowedDrops -= 1; continue }
                kept.append(key)
            }
            state.fired = kept
        }
        state.refreshedAt = refreshedAt
        do { try save(state, dataRoot) } catch {
            // The claims above are already durable; only the snapshot stamp is
            // behind, which costs one repeated (and fully deduped) pass.
            NSLog("bot_github_events: state save failed: \(error.localizedDescription)")
        }
    }

    private func load(_ dataRoot: URL) -> State {
        let key = dataRoot.standardizedFileURL.path
        if let cached = cached[key] { return cached }
        guard let data = try? Data(contentsOf: stateURL(dataRoot)),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State(seeded: false, refreshedAt: "", fired: [])
        }
        cached[key] = state
        return state
    }

    /// Durable, and the in-memory copy advances only on a written file.
    private func save(_ state: State, _ dataRoot: URL) throws {
        let url = stateURL(dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        cached[dataRoot.standardizedFileURL.path] = state
    }
}
