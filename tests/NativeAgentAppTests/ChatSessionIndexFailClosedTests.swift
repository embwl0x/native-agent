import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

@Suite("Shared chat session index fail-closed writers")
struct ChatSessionIndexFailClosedTests {
    @Test func macCreateUpdateAndReadPreserveMalformedIndex() async throws {
        let fixture = try Fixture(payload: Data(#"[{"id":"keep"},17]"#.utf8))
        defer { fixture.remove() }

        await #expect(throws: ChatSessionIndexFileError.self) {
            _ = try await NativeClient.createChatSession(title: "new", dataRoot: fixture.root)
        }
        try fixture.expectUnchanged()

        await #expect(throws: ChatSessionIndexFileError.self) {
            _ = try await NativeClient.updateChatSession(
                id: "keep",
                title: "changed",
                archived: nil,
                dataRoot: fixture.root
            )
        }
        try fixture.expectUnchanged()

        await #expect(throws: ChatSessionIndexFileError.self) {
            _ = try await NativeClient.getChatSessions(dataRoot: fixture.root)
        }
        try fixture.expectUnchanged()
    }

    @Test func iCloudAndSlackSessionCreationPreserveMalformedIndex() async throws {
        let fixture = try Fixture(payload: Data("{broken".utf8))
        defer { fixture.remove() }

        await #expect(throws: ChatSessionIndexFileError.self) {
            try await AppDelegate.ensureChatSessionIndex(sessionID: "ios-session", dataRoot: fixture.root)
        }
        try fixture.expectUnchanged()

        await #expect(throws: ChatSessionIndexFileError.self) {
            try await SlackSessionStore.ensureSessionRow(
                id: "slack-session",
                title: "Slack DM test",
                sourceKey: "conversation:T:C",
                dataRoot: fixture.root
            )
        }
        try fixture.expectUnchanged()
    }
}

private struct Fixture {
    let root: URL
    let path: URL
    let payload: Data

    init(payload: Data) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-session-index-\(UUID().uuidString)", isDirectory: true)
        path = root.appendingPathComponent("chat/sessions.json")
        self.payload = payload
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: path)
    }

    func expectUnchanged() throws {
        #expect(try Data(contentsOf: path) == payload)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
