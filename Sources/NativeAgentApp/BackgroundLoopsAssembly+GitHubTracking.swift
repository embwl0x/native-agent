import Foundation
import BackgroundLoops
import BackgroundWork
import GitHubConnector
import StandingBots
import PersistenceCore

extension BotGitHubEventWatcher {
    static let shared = BotGitHubEventWatcher { dataRoot in
        await BackgroundLoopsAssembly.unattendedWorkAllowed(dataRoot: dataRoot)
    }
}

extension BackgroundLoopsAssembly {
    static func githubTrackingWatchedPaths(dataRoot: URL) -> [URL] {
        GitHubTrackingBackgroundWork.githubTrackingWatchedPaths(dataRoot: dataRoot)
    }

    static func makeGitHubTrackingLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some EventDeadlineLoopRunner {
        GitHubTrackingBackgroundWork.makeGitHubTrackingLoop(
            dataRoot: dataRoot, intervalSeconds: intervalSeconds,
            port: AppGitHubTrackingWorkPort(dataRoot: dataRoot)
        )
    }
}

private struct AppGitHubTrackingWorkPort: GitHubTrackingWorkPort {
    let runtime: GitHubCommandRuntime

    init(dataRoot: URL) {
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            self.runtime = .shared
        } else {
            self.runtime = .live(dataRoot: dataRoot)
        }
    }

    func processConnectorChangesIfChanged(refreshed: Bool) async {
        await runtime.processConnectorChangesIfChanged(refreshed: refreshed)
    }

    func evaluateApprovalSnapshot(dataRoot: URL) async {
        await GitHubApprovalEdgeNotifier.shared.evaluateSnapshot(dataRoot: dataRoot)
    }

    func evaluateBotSnapshot(dataRoot: URL) async {
        await BotGitHubEventWatcher.shared.evaluateSnapshot(dataRoot: dataRoot)
    }
}
