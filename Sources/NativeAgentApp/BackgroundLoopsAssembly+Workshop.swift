import Foundation
import NativeAgentCore
import BackgroundLoops
import PersistenceCore
import CognitiveSubstrate
import TrustCenter

// Wave B — production wiring for the Workshop pump loop.
//
// The pump itself does ZERO LLM work (WorkshopPump.tick): a quiet day makes no
// provider call. The one bounded session it may run goes through WorkshopSession
// behind the WorkshopToolProfile membrane. All the app-layer dependencies the
// PersistenceCore-only pump can't import (organism posture, trust policy) are
// injected here, the same shape as makeMissionExecutorLoopRunner.

extension BackgroundLoopsAssembly {

    /// Build the fully wired Workshop pump. Injected: the Desk store (Wave A),
    /// the shared background-work lease + compact receipt log (H4/M8), the
    /// bounded session runner, the organism posture read (H4), and the
    /// enableAutonomy gate.
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
            sessionRunner: WorkshopSession(dataRoot: dataRoot, store: store),
            posture: { await cognition.organismBehaviorPosture() },
            isEnabled: { await workshopEnabledGate(dataRoot: dataRoot) }
        )
    }

    /// enableAutonomy gate — workshop is expensive autonomous work and only runs
    /// when the trust policy explicitly enables autonomy (mirror of the Workshop execution
    /// executor gate, minus the missionPolicy half which is Workshop execution-specific).
    static func workshopEnabledGate(dataRoot: URL) async -> Bool {
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policy = await trust.loadTrustPolicy()
        guard case .bool(true) = policy["enableAutonomy"] ?? .null else { return false }
        return true
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

struct WorkshopPumpLoopRunner: EventDeadlineLoopRunner {
    let loopId = "workshop_pump"
    let interval: TimeInterval = 24 * 60 * 60
    var tickTimeoutOverride: TimeInterval? { 1800 }
    let dataRoot: URL
    let pump: WorkshopPump

    func physiologyEvents() -> AsyncStream<Void> {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        return EventDeadlinePhysiology.storeAndFileEvents(
            paths: [
                store.opsPath,
                store.statePath,
                dataRoot.appendingPathComponent("trust/policy.json"),
                dataRoot.appendingPathComponent("cognition/organism_state.json"),
                dataRoot.appendingPathComponent("workshop/background_lease.json"),
            ],
            stores: [.desk]
        )
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        guard let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() else {
            return nil
        }
        return WorkshopPump.nextMeaningfulDeadline(from: state, after: now)
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        switch await pump.tick() {
        case .disabled:
            return .skipped(reason: "Workshop autonomy disabled")
        case .postureNotNormal:
            return .skipped(reason: "organism posture not normal")
        case .resourcePressure:
            return .skipped(reason: "resource pressure")
        case .quiet:
            return .skipped(reason: "nothing due")
        case .leaseHeld:
            return .skipped(reason: "background-work lease held")
        case .reservationRefused:
            return .skipped(reason: "Workshop reservation refused")
        case .ran(let status):
            return .completed(result: "Workshop session \(status.rawValue)")
        }
    }
}
