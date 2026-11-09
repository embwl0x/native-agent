import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+SchedulerActions.swift` | Desk creation through the body act owner |

@MainActor
extension AppModel {
    @MainActor
    func createDeskTask(title: String, objective: String) async -> NewDeskTaskOutcome {
        do {
            _ = try FaceWindowReply.committed(await client.act(.createDeskTask(title: title, objective: objective)))
            statusText = "Desk task created"
            return .created
        } catch {
            let message = "Task creation was not confirmed. \(error.localizedDescription)"
            setFailureStatus(message, cause: error)
            return .failed(.interrupted(error))
        }
    }

}
