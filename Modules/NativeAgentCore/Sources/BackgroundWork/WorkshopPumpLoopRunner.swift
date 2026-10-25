import Foundation
import BackgroundLoops
import Cognition
import PersistenceCore
import Desk
import WorkshopExecution
// Blueprint: | `WorkshopPumpLoopRunner.swift` | `WorkshopPumpLoopRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |

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
                store.basePath,
                dataRoot.appendingPathComponent("trust/policy.json"),
                dataRoot.appendingPathComponent("workshop/background_lease.json"),
            ],
            stores: [.desk],
            loopId: loopId
        )
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        do {
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
            return WorkshopPump.nextMeaningfulDeadline(from: state, after: now)
        } catch {
            nativeLog("[workshop] deadline projection unavailable: %@", String(error.localizedDescription.prefix(600)))
            return nil
        }
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let pass = await pump.tick()
        let unknown = pass.unknownTiming.isEmpty ? "" : "; timing unknown for "
            + pass.unknownTiming.joined(separator: ", ") + " (its next-refresh time is unreadable; set the item's cadence again)"
        switch pass.outcome {
        case .disabled:
            return .off("Desk autonomy disabled")
        case .organismUnavailable:
            return .skipped(reason: "organism posture unavailable")
        case .postureNotNormal:
            return .skipped(reason: "organism posture not normal")
        case .quiet:
            return unknown.isEmpty ? .skipped(reason: "nothing due") : .failed(error: "nothing else due" + unknown)
        case .unavailable(let cause):
            return .failed(error: "Workshop storage unavailable: \(cause)")
        case .leaseHeld:
            return .skipped(reason: "background-work lease held")
        case .reservationRefused:
            // The reservation could not be written, flushed or read back: the
            // lane is broken, not idle. Doctor must see it (GPT-5.6, 2026-09-10).
            return .failed(error: "Desk reservation refused: the attempt could not be persisted")
        case .ran(let status):
            return .completed(result: "Desk work session \(status.rawValue)" + unknown)
        }
    }
}
