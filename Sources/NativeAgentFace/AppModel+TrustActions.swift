import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+TrustActions.swift` | Trust, backup and Mac control requests through the body dispatcher |

@MainActor
extension AppModel {
    func macControlRun(action: String, body: [String: PartFace.Value]) async throws -> CommittedResult {
        try await committedFaceAct(.runMacControl(.init(action: action, arguments: body)))
    }
    func macControlRead(action: String, operation: UUID) async throws -> CommittedResult {
        try await committedFaceAct(.runMacControl(.init(action: action,
            arguments: ["operationId": .string(operation.uuidString)], checking: true)))
    }
}
