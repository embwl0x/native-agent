import Foundation
import NativeAgentCore
import BackgroundLoops
import BackgroundWork
import PersistenceCore

// App composition delegates background decisions and receipts to Core.
extension BackgroundLoopsAssembly {
    static func trustPolicyPath(dataRoot: URL) -> URL {
        AutonomyBackgroundWork.trustPolicyPath(dataRoot: dataRoot)
    }

    static func makeAutonomyPromotionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some EventDeadlineLoopRunner {
        AutonomyBackgroundWork.makeAutonomyPromotionLoop(dataRoot: dataRoot, events: AppBackgroundWorkPort())
    }
}
