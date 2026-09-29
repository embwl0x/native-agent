import Foundation
import BackgroundLoops
import Cognition
import PersistenceCore
import Desk
import WorkshopExecution

public struct WorkshopPumpLoopRunner: EventDeadlineLoopRunner {
    public let loopId = "workshop_pump"
    public let interval: TimeInterval = 24 * 60 * 60
    public var tickTimeoutOverride: TimeInterval? { 1800 }
    let dataRoot: URL
    let pump: WorkshopPump

    public init(dataRoot: URL, pump: WorkshopPump) {
        self.dataRoot = dataRoot
        self.pump = pump
    }

    public func physiologyEvents() -> AsyncStream<Void> {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        return EventDeadlinePhysiology.storeAndFileEvents(
            paths: [
                store.opsPath,
                store.statePath,
                dataRoot.appendingPathComponent("trust/policy.json"),
                dataRoot.appendingPathComponent("workshop/background_lease.json"),
            ],
            stores: [.desk],
            loopId: loopId
        )
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        guard let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() else {
            return nil
        }
        return WorkshopPump.nextMeaningfulDeadline(from: state, after: now)
    }

    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        switch await pump.tick() {
        case .disabled:
            return .skipped(reason: "Desk autonomy disabled")
        case .organismUnavailable:
            return .skipped(reason: "organism posture unavailable")
        case .postureNotNormal:
            return .skipped(reason: "organism posture not normal")
        case .resourcePressure:
            return .skipped(reason: "resource pressure")
        case .quiet:
            return .skipped(reason: "nothing due")
        case .leaseHeld:
            return .skipped(reason: "background-work lease held")
        case .reservationRefused:
            // The reservation could not be written, flushed or read back: the
            // lane is broken, not idle. Doctor must see it (GPT-5.6, 2026-09-10).
            return .failed(error: "Desk reservation refused: the attempt could not be persisted")
        case .ran(let status):
            return .completed(result: "Desk work session \(status.rawValue)")
        }
    }
}
