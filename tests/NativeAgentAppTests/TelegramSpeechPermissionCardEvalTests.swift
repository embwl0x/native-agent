import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / telegram.speechPermissionCard
@Suite("app.bridges · Telegram Speech permission card", .serialized)
struct TelegramSpeechPermissionCardEvalTests {
    @Test("a changed permission condition re-surfaces a dismissed card, while a grant retires it exactly once")
    func speechPermissionCardLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelegramSpeechPermissionCardEval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inbox = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()

        await BackgroundLoopsAssembly.fileSystemPermissionNotice(
            capability: SystemPermissionCapability.speechRecognition.rawValue,
            dataRoot: root,
            permissionStatus: { .denied }
        )
        var row = try #require(try await speechCard(inbox, using: persistence))
        #expect(row["status"] == .string("unread"))
        #expect(text(row, key: "detail")?.contains("current state: denied") == true)
        let settingsURL = try #require(SystemPermissionPreflight.settingsURL(for: .speechRecognition))
        #expect(row["related_paths"] == .array([.string(settingsURL.absoluteString)]))

        try await NativeClient(baseURL: "", dataRootOverride: root).inboxAction(
            BackgroundLoopsAssembly.systemPermissionsSpeechCardId,
            action: "dismiss"
        )
        row = try #require(try await speechCard(inbox, using: persistence))
        #expect(row["status"] == .string("dismissed"))
        let dismissedCard = try #require(try await visibleSpeechCard(root))
        #expect(dismissedCard.status == "dismissed",
                "a fresh inbox reader must observe the real dismiss write")

        await BackgroundLoopsAssembly.fileSystemPermissionNotice(
            capability: SystemPermissionCapability.speechRecognition.rawValue,
            dataRoot: root,
            permissionStatus: { .denied }
        )
        row = try #require(try await speechCard(inbox, using: persistence))
        #expect(row["status"] == .string("dismissed"),
                "an unchanged denial must preserve the user's dismissal")

        await BackgroundLoopsAssembly.fileSystemPermissionNotice(
            capability: SystemPermissionCapability.speechRecognition.rawValue,
            dataRoot: root,
            permissionStatus: { .notDetermined }
        )
        row = try #require(try await speechCard(inbox, using: persistence))
        #expect(row["status"] == .string("unread"),
                "a changed TCC condition is new information and must re-surface the card")
        #expect(text(row, key: "detail")?.contains("current state: notDetermined") == true)
        let resurfacedCard = try #require(try await visibleSpeechCard(root))
        #expect(resurfacedCard.status == "unread",
                "a fresh inbox reader must re-surface a changed permission condition")

        await BackgroundLoopsAssembly.fileSystemPermissionNotice(
            capability: SystemPermissionCapability.speechRecognition.rawValue,
            dataRoot: root,
            permissionStatus: { .granted }
        )
        row = try #require(try await speechCard(inbox, using: persistence))
        #expect(row["status"] == .string("archived"))
        let retiredCard = try #require(try await visibleSpeechCard(root))
        #expect(retiredCard.status == "archived",
                "a fresh inbox reader must observe the retired card")
        let retiredBytes = try Data(contentsOf: inbox)

        await BackgroundLoopsAssembly.fileSystemPermissionNotice(
            capability: SystemPermissionCapability.speechRecognition.rawValue,
            dataRoot: root,
            permissionStatus: { .granted }
        )
        #expect(try Data(contentsOf: inbox) == retiredBytes,
                "a repeated grant must not re-file or rewrite an already retired card")
        let rows = try await persistence.readJSONL(inbox)
        #expect(rows.count == 1)
    }

    private func speechCard(
        _ inbox: URL,
        using persistence: SwiftNativePersistenceCore
    ) async throws -> [String: JSONValue]? {
        for row in try await persistence.readJSONL(inbox) {
            guard case .object(let object) = row,
                  object["id"] == .string(BackgroundLoopsAssembly.systemPermissionsSpeechCardId) else {
                continue
            }
            return object
        }
        return nil
    }

    private func visibleSpeechCard(_ root: URL) async throws -> InboxItemRecord? {
        try await NativeClient(baseURL: "", dataRootOverride: root)
            .getInboxItems(unreadOnly: false)
            .first { $0.id == BackgroundLoopsAssembly.systemPermissionsSpeechCardId }
    }

    private func text(_ row: [String: JSONValue], key: String) -> String? {
        guard case .string(let value)? = row[key] else { return nil }
        return value
    }
}
