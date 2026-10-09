import Agents
import BackgroundWork
import EngineRuntime
import Foundation
import TelegramBot

extension BackgroundLoopsAssembly {
    static func makeTurnContinuationRuntime(dataRoot: URL) -> TurnContinuationRuntime {
        TurnContinuationRuntime(dataRoot: dataRoot, engine: NativeAgentEngine.live,
            telegramApprovalFiler: { TelegramApprovalFilerRef.shared.current() },
            makeSender: { LiveAgentBridgeCompletionSender(dataRoot: dataRoot, authorizeTelegramReply: $0) })
    }

    static func makeDeskContinuationScheduler(dataRoot: URL) -> DeskContinuationScheduler {
        makeTurnContinuationRuntime(dataRoot: dataRoot).makeDeskContinuationScheduler()
    }
}
