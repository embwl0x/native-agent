import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

private struct Wave4ChatFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-chat-wave4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite("App chat reports-only wave 4 lifecycle and mounted seams", .serialized)
struct AppChatReportsOnlyWave4LifecycleTests {
    private func appModel(root: URL) -> AppModel {
        let model = AppModel()
        model.dataRootOverride = root
        return model
    }

    // app.chat / ui.chat.sidebar.newChatButton
    @Test("new-chat action creates and selects a durable isolated session")
    func newChatCreatesDurableSessionThroughTheAppAction() async throws {
        let fixture = try Wave4ChatFixture()
        defer { fixture.remove() }
        let existing = try await NativeClient.createChatSession(title: "Existing", dataRoot: fixture.root)
        let model = appModel(root: fixture.root)
        model.chatSessions = [existing]
        model.activeChatSessionId = existing.id
        model.chatDrafts[""] = "carry this draft"

        await model.newChatSession()

        let persisted = try await NativeClient.getChatSessions(dataRoot: fixture.root)
        let created = try #require(persisted.first(where: { $0.id == model.activeChatSessionId }))
        #expect(persisted.count == 2)
        #expect(created.id != existing.id)
        #expect(created.title == "New Chat")
        #expect(created.source == "app")
        #expect(model.chatDraft(for: created.id) == "carry this draft")
        #expect(model.statusText == "New chat session ready")
    }

}
