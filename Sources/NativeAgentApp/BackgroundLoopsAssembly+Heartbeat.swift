import Foundation
import NativeAgentCore
import BackgroundLoops
import BackgroundWork
import PersistenceCore
import Cognition
import ChatOrchestration
import SelfImprovement

// App composition delegates background decisions and receipts to Core.
extension BackgroundLoopsAssembly {
    static func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> HeartbeatLoop {
        HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).makeHeartbeatLoop(dataRoot: dataRoot, llm: llm)
    }

    static func repairHeartbeatInboxItem(
        id: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        try await HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).repairHeartbeatInboxItem(id: id, dataRoot: dataRoot)
    }

    static func stageEvolutionApprovals(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        onlyProposalId: String? = nil
    ) async {
        await HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).stageEvolutionApprovals(dataRoot: dataRoot, onlyProposalId: onlyProposalId)
    }

}

typealias InboxRewriteGuard = BackgroundWork.InboxRewriteGuard

struct AppBackgroundWorkPort: HeartbeatBackgroundWorkPort {
    var selfEvolutionAction: String { NativeClient.selfEvolutionAction }

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

    func applyFullMacAdmittedSelfEvolution(payload: JSONValue, dataRoot: URL) async {
        await NativeClient.applyFullMacAdmittedSelfEvolution(
            payload: payload, deps: NativeClient.selfEvolutionDeps(dataRoot: dataRoot)
        )
    }

    func evolutionRepoRoot(dataRoot: URL) -> URL {
        NativeClient.evolutionRepoRoot(dataRoot: dataRoot)
    }
}
