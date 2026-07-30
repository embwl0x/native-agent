import Foundation
import Testing
@testable import TelegramBot
import PersistenceCore

@Test
func telegramSessionCreationRejectsMalformedSharedIndexWithoutRewritingIt() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("telegram-session-index-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("chat/sessions.json")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let malformed = Data(#"{"not":"an array"}"#.utf8)
    try malformed.write(to: path)

    await #expect(throws: ChatSessionIndexFileError.self) {
        _ = try await TelegramSessionStore(dataRoot: root).startNewSession(chatId: 42)
    }

    #expect(try Data(contentsOf: path) == malformed)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("telegram/session_map.json").path))
}
