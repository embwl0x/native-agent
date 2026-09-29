import Foundation
import BackgroundLoops
import Cognition
import GitHubConnector
import PersistenceCore

// GitHub tracking is event/deadline driven. Canonical config, snapshot, Desk,
// and GitHub Command changes wake a reread; the connector's learned cadence
// supplies the exact next network-refresh crossing. The periodic interval is
// only a slow missed-event repair sweep.
public enum GitHubTrackingBackgroundWork {
    public static func githubTrackingWatchedPaths(dataRoot: URL) -> [URL] {
        let commandDirectory = dataRoot
            .appendingPathComponent("workshop/github_command", isDirectory: true)
        let deskDirectory = dataRoot.appendingPathComponent("desk", isDirectory: true)
        return [
            dataRoot.appendingPathComponent("connectors/github/tracking.json"),
            dataRoot.appendingPathComponent("connectors/github/tracking_snapshot.json"),
            deskDirectory.appendingPathComponent("desk_ops.jsonl"),
            deskDirectory.appendingPathComponent("desk_ops_base.json"),
            commandDirectory.appendingPathComponent("ops.jsonl"),
            commandDirectory.appendingPathComponent("ops_base.json"),
        ]
    }

    public static func makeGitHubTrackingLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60,
        port: any GitHubTrackingWorkPort
    ) -> some EventDeadlineLoopRunner {
        GitHubTrackingRunner(interval: intervalSeconds, dataRoot: dataRoot, port: port)
    }
}

private struct GitHubTrackingRunner: EventDeadlineLoopRunner {
    let interval: TimeInterval
    let dataRoot: URL
    let port: any GitHubTrackingWorkPort

    var loopId: String { "github_tracking" }
    var eventCoalescingDelay: TimeInterval { 0.5 }
    // 120s dated from the original daily-refresh feature and starved the loop
    // once tracking grew to ~99 items at a 15-minute cadence: a full refresh
    // is hundreds of sequential GitHub calls (90s+ healthy, minutes under
    // upstream 504s), so the tick was cancelled mid-refresh on nearly every
    // attempt from 2026-07-12 onward (633 timeout receipts in
    // background_loop_failures.jsonl) and the snapshot froze. Ticks are
    // serialized per loop and the manager gate coalesces manual/periodic
    // calls, so a long timeout cannot overlap refreshes; stop() does not
    // wait for a tick to drain, so quit is unaffected.
    var tickTimeoutOverride: TimeInterval? { 600 }

    func tick() async {
        _ = await tickOutcome()
    }

    func physiologyEvents() -> AsyncStream<Void> {
        return EventDeadlinePhysiology.storeAndFileEvents(
            paths: GitHubTrackingBackgroundWork.githubTrackingWatchedPaths(dataRoot: dataRoot),
            stores: [.desk, .githubCommand],
            loopId: loopId
        )
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        do {
            return try await GitHubConnectorActions.nextTrackingRefreshDeadline(
                after: now,
                dataRoot: dataRoot
            )
        } catch {
            NSLog("GitHub tracking deadline unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    func tickOutcome() async -> LoopTickOutcome {
        do {
            let refreshed = try await GitHubConnectorActions.refreshTrackingIfDue(dataRoot: dataRoot)
            // A1/FIX-2: replay the command store only when the refresh wrote
            // something OR the op log changed underneath us. The runtime still
            // fingerprints both op-log files on EVERY tick, so an out-of-process
            // writer is still picked up within one 300s period — the tick just
            // no longer pays a 2MB decode + reducer replay to discover that
            // nothing moved.
            await port.processConnectorChangesIfChanged(refreshed: refreshed)
            if refreshed {
                await port.evaluateApprovalSnapshot(dataRoot: dataRoot)
                // Bots that wake on a GitHub event read the same refreshed
                // snapshot. No loop of its own (the count is pinned at 20).
                await port.evaluateBotSnapshot(dataRoot: dataRoot)
            }
            return refreshed
                ? .completed(result: "GitHub tracking refreshed")
                : .skipped(reason: "GitHub tracking not due or unchanged")
        } catch {
            // Typed GitHub errors never contain the PAT or request headers.
            NSLog("github_tracking: refresh failed: \(error.localizedDescription)")
            return .failed(error: error.localizedDescription)
        }
    }
}

public protocol GitHubTrackingWorkPort: Sendable {
    func processConnectorChangesIfChanged(refreshed: Bool) async
    func evaluateApprovalSnapshot(dataRoot: URL) async
    func evaluateBotSnapshot(dataRoot: URL) async
}
