import Foundation
import BackgroundLoops
import GitHubConnector
import PersistenceCore

// GitHub tracking is configuration- and due-driven: the manager may offer a
// five-minute tick, but the connector performs no network work until a project
// is configured and its persisted refresh interval has elapsed. The refresh
// compares material entity signatures before touching Desk, so unchanged GitHub
// state produces no Desk update and no notification.
extension BackgroundLoopsAssembly {
    static func makeGitHubTrackingLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 300
    ) -> some LoopRunner {
        GitHubTrackingRunner(interval: intervalSeconds, dataRoot: dataRoot)
    }
}

private struct GitHubTrackingRunner: LoopRunner {
    let interval: TimeInterval
    let dataRoot: URL
    // Bound to THIS loop's dataRoot. The loop writes observations under the
    // injected root, so the runtime that dispatches/verifies them must read the
    // same root — .shared (defaultDataRoot) would silently diverge under an
    // alternate root. Reuse .shared only when the roots are identical.
    let runtime: GitHubCommandRuntime

    init(interval: TimeInterval, dataRoot: URL) {
        self.interval = interval
        self.dataRoot = dataRoot
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            self.runtime = .shared
        } else {
            self.runtime = .live(dataRoot: dataRoot)
        }
    }

    var loopId: String { "github_tracking" }
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

    func tickOutcome() async -> LoopTickOutcome {
        do {
            let refreshed = try await GitHubConnectorActions.refreshTrackingIfDue(dataRoot: dataRoot)
            // A1/FIX-2: replay the command store only when the refresh wrote
            // something OR the op log changed underneath us. The runtime still
            // fingerprints both op-log files on EVERY tick, so an out-of-process
            // writer is still picked up within one 300s period — the tick just
            // no longer pays a 2MB decode + reducer replay to discover that
            // nothing moved.
            await runtime.processConnectorChangesIfChanged(refreshed: refreshed)
            if refreshed {
                await GitHubApprovalEdgeNotifier.shared.evaluateSnapshot(dataRoot: dataRoot)
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
