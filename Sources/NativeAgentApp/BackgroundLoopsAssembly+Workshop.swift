import BackgroundWork
import Foundation
import NativeAgentCore
import BackgroundLoops
import Cognition
import PersistenceCore
import Desk
import CognitiveSubstrate
import TrustCenter
import WorkshopExecution

// Wave B — production wiring for the Workshop pump loop.
//
// The pump itself does ZERO LLM work (WorkshopPump.tick): a quiet day makes no
// provider call. The one bounded session it may run goes through WorkshopSession
// behind the WorkshopToolProfile membrane. All the app-layer dependencies the
// Core pump receives from the app (organism posture, trust policy) are
// injected here, the same shape as makeMissionExecutorLoopRunner.

extension BackgroundLoopsAssembly {

    /// Build the fully wired Workshop pump. Injected: the Desk store (Wave A),
    /// the shared background-work lease + compact receipt log (H4/M8), the
    /// bounded session runner, the organism posture read (H4), and the
    /// shared unattended-work gate.
    static func makeWorkshopPump(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> WorkshopPump {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let cognition = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        return WorkshopPump(
            dataRoot: dataRoot,
            store: store,
            lease: BackgroundWorkLease(dataRoot: dataRoot),
            receiptLog: WorkshopReceiptLog(dataRoot: dataRoot),
            sessionRunner: WorkshopSession(
                dataRoot: dataRoot, store: store,
                platform: AppWorkshopPumpPlatform(), effects: AppWorkshopSessionEffects()
            ),
            platform: AppWorkshopPumpPlatform(),
            posture: { await cognition.organismBehaviorPosture() },
            isEnabled: { await unattendedWorkAllowed(dataRoot: dataRoot) }
        )
    }

    static func unattendedWorkAllowed(dataRoot: URL) async -> Bool {
        await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
    }

    static func isFullMacPolicy(_ policy: [String: JSONValue]) -> Bool {
        WorkshopBackgroundWork.isFullMacPolicy(policy)
    }

    /// Event/deadline wrapper. Desk/trust/body mutations reconcile after one
    /// coalesced edge; the next persisted cadence or two-hour Workshop window
    /// owns one exact deadline. The daily interval is only missed-event
    /// integrity recovery. tickTimeoutOverride remains 1800s because a run may
    /// execute one multi-minute bounded LLM session.
    static func makeWorkshopPumpLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> some LoopRunner {
        WorkshopPumpLoopRunner(dataRoot: dataRoot, pump: makeWorkshopPump(
            dataRoot: dataRoot,
            cognitionRuntime: cognitionRuntime
        ))
    }
}
