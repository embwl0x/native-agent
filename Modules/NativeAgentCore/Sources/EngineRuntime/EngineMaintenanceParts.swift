import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundWork
import ToolExecution
// Blueprint: | `EngineMaintenanceParts.swift` | Effect-free authored maintenance words, deadlines and trigger choices |

extension EngineBackgroundWorkPort {
    func assistanceCard(dataRoot: URL, input: JSONValue) async throws -> AssistanceCardContent {
        try await maintenancePart(dataRoot: dataRoot, id: "native-diagnostics", input: input,
            origin: "maintenance:assistance-card", as: AssistanceCardContent.self)
    }

    func backupDeadline(dataRoot: URL, input: JSONValue) async throws -> Double? {
        try await maintenancePart(dataRoot: dataRoot, id: "backup-cadence", input: input,
            origin: "maintenance:backup-cadence", as: Double?.self)
    }

    func backupTrigger(dataRoot: URL, input: JSONValue) async throws -> BackupTrigger {
        try await maintenancePart(dataRoot: dataRoot, id: "backup-cadence", input: input,
            origin: "maintenance:backup-cadence", as: BackupTrigger.self)
    }

    private func maintenancePart<Value: Codable & Sendable>(dataRoot: URL, id: String, input: JSONValue,
        origin: String, as type: Value.Type) async throws -> Value {
        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native(origin)) { door in
            switch await Parts(root: dataRoot).call(id: id, input: input, invocation: door.invocation, as: type) {
            case .success(let content): return content
            case .failure(let error) where error.code == "cancelled": throw CancellationError()
            case .failure(let error): throw error
            }
        }
    }
}
