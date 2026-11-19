import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+TrustActions.swift` | Trust, approval, backup and Mac control requests through the body dispatcher |

@MainActor
extension AppModel {
    func resolveApproval(id: String, decision: String) async throws -> CommittedResult {
        guard let decision = FaceApprovalDecision(rawValue: decision) else {
            throw PartCallError(code: "invalid_decision", message: "Choose approve, deny or cancel for this approval.")
        }
        return try await committedFaceAct(.resolveApproval(id: id, decision: decision))
    }

    func createBackup(reason: String) async throws -> CommittedResult {
        try await committedFaceAct(.createBackup(reason: reason))
    }
    func restoreBackup(id: String, confirmed: Bool) async throws -> CommittedResult {
        var result = try await committedFaceAct(.restoreBackup(id: id, confirmed: confirmed))
        if case .object(let fields) = result.value, fields["requiresRestart"] == .bool(true) {
            do {
                guard case .acknowledged = try await checkedFaceAct(.restartBody) else {
                    throw PartCallError(code: "restore_restart_unconfirmed", message: "The restored backup needs a restart, which was not confirmed.")
                }
            } catch {
                result.publicationFailure = WireFailure(code: "restore_restart_failed",
                    message: "The backup is staged, but NativeAgent could not restart to install it.", cause: error.localizedDescription, effects: .known)
            }
        }
        return result
    }
    func saveMacIntegrationPreset(_ preset: String) async throws -> TrustSettingsFace {
        guard case .trust(let saved) = try await checkedFaceAct(.saveMacIntegrationPreset(preset)) else {
            throw PartCallError(code: "trust_unconfirmed", message: "The Mac policy has no committed readback.")
        }
        return saved
    }
    func saveMacControlPolicy(_ policy: MacControlPolicyWireSnapshot,
                              comparedTo baseline: MacControlPolicyWireSnapshot) async throws -> TrustSettingsFace {
        guard case .trust(let saved) = try await checkedFaceAct(.saveMacControlPolicy(.init(policy: policy, baseline: baseline))) else {
            throw PartCallError(code: "trust_unconfirmed", message: "The Mac policy has no committed readback.")
        }
        return saved
    }
    func macControlRun(action: String, body: [String: PartFace.Value]) async throws -> CommittedResult {
        try await committedFaceAct(.runMacControl(.init(action: action, arguments: body)))
    }
    func macControlRead(action: String, operation: UUID) async throws -> CommittedResult {
        try await committedFaceAct(.runMacControl(.init(action: action,
            arguments: ["operationId": .string(operation.uuidString)], checking: true)))
    }
}
