import Foundation
import AttentionRouting
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
}

extension AppBackgroundWorkPort: DelegationBackgroundWorkPort {
    func retryRequestedResults(dataRoot: URL) async throws {
        try await AttentionRouter.shared.retryRequestedResults(dataRoot: dataRoot)
    }

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
