import Foundation
import NativeAgentCore
import BackgroundLoops
import BackgroundWork
import PersistenceCore
import Cognition
import ChatOrchestration

// App composition delegates background decisions and receipts to Core.
extension BackgroundLoopsAssembly {
    static func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> HeartbeatLoop {
        HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).makeHeartbeatLoop(dataRoot: dataRoot)
    }

    static func repairHeartbeatInboxItem(
        id: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        try await HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).repairHeartbeatInboxItem(id: id, dataRoot: dataRoot)
    }


}

typealias InboxRewriteGuard = BackgroundWork.InboxRewriteGuard

struct AppBackgroundWorkPort: HeartbeatBackgroundWorkPort {

    func storeAndFileEvents(paths: [URL], loopId: String?) -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: paths, loopId: loopId)
    }

    func notifyIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String,
        summary: String, source: String, severity: String
    ) async {
        await InboxPushNotifier.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title,
            summary: summary, source: source, severity: severity
        )
    }


}
