import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+SkillsIntegrations.swift` | Connector, Telegram, Doctor and Inbox acts; the body owns their effects |

@MainActor
extension AppModel {
    func updateConnector(id: String, enabled: Bool) async throws -> CommittedResult {
        try await committedFaceAct(.setConnectorEnabled(id: id, enabled: enabled))
    }
    func clearTelegramToken() async throws -> CommittedResult {
        try await committedFaceAct(.disconnectConnector(id: "telegram"))
    }
    @discardableResult
    func refreshTelegram() async -> Bool {
        do { _ = try await checkedFaceAct(.refresh(.panel("telegram"))); return true }
        catch { setFailureStatus(error, action: "read Telegram"); return false }
    }
    func testTelegram() async throws -> CommittedResult { try await committedFaceAct(.testTelegram) }
    func clearTelegramLogs() async throws -> CommittedResult { try await committedFaceAct(.clearTelegramLogs) }
    func runDoctor(repair: Bool, scope: String = "automatic") async throws -> FaceActReply {
        try await checkedFaceAct(.runDoctor(.init(scope: scope, repair: repair)))
    }
    func inboxAction(_ id: String, action: String) async throws {
        _ = try await committedFaceAct(.inboxAction(id: id, action: action, value: nil))
    }
}
