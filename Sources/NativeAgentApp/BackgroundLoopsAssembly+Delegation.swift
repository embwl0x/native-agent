import Foundation
import NativeAgentCore
import BackgroundLoops
import BackgroundWork
import PersistenceCore
import ChatOrchestration

// App composition delegates background decisions and receipts to Core.
extension BackgroundLoopsAssembly {
    static func makeDelegationOutcomeLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configRoot: URL? = nil
    ) -> some EventDeadlineLoopRunner {
        DelegationBackgroundWork(port: AppBackgroundWorkPort()).makeDelegationOutcomeLoop(dataRoot: dataRoot, configRoot: configRoot)
    }

    static func delegationJobSnapshot(from row: DelegationJobProjection) -> DelegationJobSnapshot {
        DelegationBackgroundWork.delegationJobSnapshot(from: row)
    }

    static func recordBoundDelegationSettlement(
        dataRoot: URL,
        job: DelegationJobSnapshot
    ) async -> Bool {
        await DelegationBackgroundWork(port: AppBackgroundWorkPort()).recordBoundDelegationSettlement(dataRoot: dataRoot, job: job)
    }

    static func fileDelegationOutcomeNotice(
        dataRoot: URL,
        card: DelegationOutcomeCard
    ) async -> Bool {
        await DelegationBackgroundWork(port: AppBackgroundWorkPort()).fileDelegationOutcomeNotice(dataRoot: dataRoot, card: card)
    }

    static func reconcileStaleAdverseDelegationNotices(
        dataRoot: URL,
        now: Date = Date()
    ) async throws -> Int {
        try await DelegationBackgroundWork(port: AppBackgroundWorkPort()).reconcileStaleAdverseDelegationNotices(dataRoot: dataRoot, now: now)
    }

    static func reconcileLegacySuccessfulDelegationNotices(
        dataRoot: URL,
        now: Date = Date()
    ) async throws -> Int {
        try await DelegationBackgroundWork(port: AppBackgroundWorkPort()).reconcileLegacySuccessfulDelegationNotices(dataRoot: dataRoot, now: now)
    }
}

extension AppBackgroundWorkPort: DelegationBackgroundWorkPort {
    var agentSubject: String { AgentVoice.live.subject }

    func observeMotorActionState(_ model: MotorActionReadModel) async {
        await NativeAgentEngine.liveCognition.observeMotorActionState(model)
    }

    func reconcileAgentConversations() async throws {
        try await NativeAgentEngine.live.agents.continuation.tick()
    }

    func nextConversationDeadline(after now: Date) -> Date? {
        NativeAgentEngine.live.agents.continuation.nextDeadline(after: now)
    }
}
