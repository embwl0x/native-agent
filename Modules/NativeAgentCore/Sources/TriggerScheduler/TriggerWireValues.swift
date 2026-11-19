import Foundation
// Blueprint: | `TriggerWireValues.swift` | Scheduler persistence errors |

public enum TriggerSchedulerError: Error, LocalizedError {
    case persistenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .persistenceFailure(let m):
            return """
                schedule_store_unavailable: \(m). Inspect the named scheduler file and repair its contents or access before changing \
                scheduled Desk tasks.
                """
        }
    }
}
