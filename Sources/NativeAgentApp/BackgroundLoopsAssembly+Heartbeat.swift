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
    typealias DurableResidueSummary = HeartbeatBackgroundWork.DurableResidueSummary
    static func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> HeartbeatLoop {
        HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).makeHeartbeatLoop(dataRoot: dataRoot, llm: llm)
    }

    static func makeSelfHealingHook(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> some EventDeadlineLoopRunner {
        HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).makeSelfHealingHook(dataRoot: dataRoot, llm: llm)
    }

    static func closeResolvedDoctorSelfHealProposals(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Int {
        await HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).closeResolvedDoctorSelfHealProposals(dataRoot: dataRoot)
    }

    static func heartbeatEligibleDoctorRows(
        _ rows: [[String: Any]]
    ) -> (eligible: [[String: Any]], skipped: Int) {
        HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).heartbeatEligibleDoctorRows(rows)
    }

    static func gatherHeartbeatAssessment(
        dataRoot: URL,
        interval: TimeInterval = HeartbeatLoop.defaultInterval,
        closedResolvedDoctorProposals: Int = 0,
        now: Date = Date(),
        bridgeConfigRoot: URL? = nil
    ) async -> HeartbeatAssessment {
        await HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).gatherHeartbeatAssessment(dataRoot: dataRoot, interval: interval, closedResolvedDoctorProposals: closedResolvedDoctorProposals, now: now, bridgeConfigRoot: bridgeConfigRoot)
    }

    static func heartbeatCompactAge(_ seconds: TimeInterval) -> String {
        HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).heartbeatCompactAge(seconds)
    }

    static func heartbeatDurableResidueSummary(
        dataRoot: URL,
        bridgeConfigRoot: URL? = nil,
        now: Date = Date()
    ) async -> DurableResidueSummary {
        await HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).heartbeatDurableResidueSummary(dataRoot: dataRoot, bridgeConfigRoot: bridgeConfigRoot, now: now)
    }

    static func reconcileDurableResidueCard(
        dataRoot: URL,
        summary: DurableResidueSummary,
        now: Date = Date()
    ) async {
        await HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).reconcileDurableResidueCard(dataRoot: dataRoot, summary: summary, now: now)
    }

    static func upsertHeartbeatNoticeCard(dataRoot: URL, notice: HeartbeatNotice) async throws {
        try await HeartbeatBackgroundWork(port: AppBackgroundWorkPort()).upsertHeartbeatNoticeCard(dataRoot: dataRoot, notice: notice)
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
