import Foundation
import Testing
import ChatOrchestration
import MacIntegration
@testable import NativeAgentApp

@MainActor
struct MailConnectorVerificationTests {
    @Test func revokedReadCannotVerifyAnExistingConnectCard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail-card-verification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacIntegrationPermissionStore(dataRoot: root)
        try await store.set(integrationId: MacIntegrationID.mail, read: true, write: false)
        let card = try #require(await InlineInteractionResolver.raise(
            InlineInteractionRegistry.connector("mail", why: "Connect Mail", dataRoot: root),
            sessionID: "mail-card", resumable: false, dataRoot: root
        ))
        try await store.set(integrationId: MacIntegrationID.mail, read: false, write: false)

        let result = try await InlineInteractionResolver.complete(
            id: card.id, sessionID: "mail-card", dataRoot: root
        )
        #expect(result.state == .failed(
            reason: "Mail read access is off or unavailable in Settings → Mac Integration."
        ))
        let persisted = await InlineInteractionResolver.interaction(
            id: card.id, sessionID: "mail-card", dataRoot: root
        )
        #expect(persisted?.state == result.state)
    }
}
