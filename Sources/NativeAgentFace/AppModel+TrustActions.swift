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

    func saveMemoryPolicy(crossSessionRecall: Bool) async {
        await saveTrustAct { .saveMemoryPolicy(.init(fields: ["cross_session_recall": .bool(crossSessionRecall)],
            expectedRevision: try trustEditRevision())) }
    }

    @discardableResult
    func patchMemoryPolicy(knowledgeGraphEnabled: Bool? = nil, adaptivePromotion: Bool? = nil) async -> Bool {
        var fields: [String: PartFace.Value] = [:]
        if let knowledgeGraphEnabled { fields["knowledge_graph_enabled"] = .bool(knowledgeGraphEnabled) }
        if let adaptivePromotion { fields["adaptive_promotion"] = .bool(adaptivePromotion) }
        return await saveTrustAct { .saveMemoryPolicy(.init(fields: fields, expectedRevision: try trustEditRevision())) }
    }

    @discardableResult
    func saveAutonomyEnabled(_ enabled: Bool) async -> Bool { await saveTrustAct { .setAutonomyEnabled(enabled) } }
    @discardableResult
    func saveChromeControlEnabled(_ enabled: Bool) async -> Bool { await saveTrustAct { .setChromeControlEnabled(enabled) } }
    @discardableResult
    func saveKillSwitchEnabled(_ enabled: Bool) async -> Bool { await saveTrustAct { .setKillSwitchEnabled(enabled) } }

    func recordTrustActionFailure(_ message: String, cause: Error? = nil) {
        statusText = message
        statusCause = cause?.localizedDescription
        trustCenterActionOutcome = .failed(message)
    }

    func trustEditRevision() throws -> String {
        guard let policy = face.slot(.settings).select("trust.editBaseline", as: SettingsFace.self, { $0?.trust.policy }) else {
            throw PartCallError(code: "trust_baseline_unavailable", message: "Read Trust before editing its policy.")
        }
        return try policy.editRevision()
    }

    @discardableResult
    private func saveTrustAct(_ makeAct: () throws -> FaceAct) async -> Bool {
        do {
            let reply = try await checkedFaceAct(makeAct())
            guard case .trust = reply else {
                throw PartCallError(code: "trust_unconfirmed", message: "The policy has no committed readback.")
            }
            trustCenterActionOutcome = .saved("Trust policy saved.")
            return true
        } catch {
            recordTrustActionFailure(error.localizedDescription, cause: error)
            return false
        }
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
    func macControlNotify(title: String, message: String) async throws -> CommittedResult {
        try await committedFaceAct(.notify(title: title, message: message))
    }
    func macControlRun(action: String, body: [String: PartFace.Value]) async throws -> CommittedResult {
        try await committedFaceAct(.runMacControl(.init(action: action, arguments: body)))
    }
    func macControlRead(action: String, operation: UUID) async throws -> CommittedResult {
        try await committedFaceAct(.runMacControl(.init(action: action,
            arguments: ["operationId": .string(operation.uuidString)], checking: true)))
    }
}
