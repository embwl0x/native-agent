import Foundation
import NotificationInbox
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Desk inbox visible actions behavior", .serialized)
struct DeskInboxVisibleActionsHideListBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-inbox-actions-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func action(_ id: String, _ label: String) -> JSONValue {
        .object([
            "id": .string(id),
            "label": .string(label),
            "description": .string("Persisted inbox action"),
        ])
    }

    private func persistedItem(
        root: URL,
        id: String,
        actions: [JSONValue]
    ) async throws -> InboxItemRecord {
        let path = NativeClient.visibleNotificationInboxPath(dataRoot: root)
        let inbox = LiveNotificationInbox(path: path)
        try await inbox.appendUnique(.object([
            "id": .string(id),
            "created_at": .string("2026-08-24T12:00:00Z"),
            "source": .string("trigger:morning_brief"),
            "severity": .string("actionable"),
            "title": .string("Persisted action card"),
            "summary": .string("Read through the real inbox reader."),
            "status": .string("unread"),
            "actions": .array(actions),
        ]), id: id)
        let items = try await NativeClient(baseURL: "", dataRootOverride: root)
            .getInboxItems(unreadOnly: false)
        return try #require(items.first { $0.id == id })
    }

    // app.desk / desk.inbox.visibleActionsHideList
    @Test("the persisted action list keeps only supported direct controls and canonicalizes legacy deny")
    func realInboxReaderProjectsExecutableActions() async throws {
        let root = try temporaryRoot("supported")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await persistedItem(root: root, id: "supported", actions: [
            action("view", "View"),
            action(" READ ", "Read"),
            action("reply", "Reply"),
            action(" APPROVE ", "Approve"),
            action("deny", "Deny"),
            action("ARCHIVE", "Archive"),
            action("archive", "Archive again"),
            action("open_doctor", "Open Doctor"),
        ])

        let visible = InboxVisibleActionsPresentation.actions(for: item)
        #expect(visible.map(\.id) == ["approve", "reject", "archive"])
        #expect(visible.map(\.label) == ["Approve", "Deny", "Archive"])
    }

    // app.desk / desk.inbox.visibleActionsHideList
    @Test("control-only persisted actions leave the Desk action list hidden")
    func controlOnlyActionListIsEmpty() async throws {
        let root = try temporaryRoot("control-only")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await persistedItem(root: root, id: "control-only", actions: [
            action("VIEW", "View"),
            action(" read ", "Read"),
            action(" REPLY ", "Reply"),
        ])

        #expect(InboxVisibleActionsPresentation.actions(for: item).isEmpty)
    }

    // app.desk / desk.inbox.visibleActionsHideList
    @Test("malformed and duplicate persisted actions cannot create a duplicate or mislabeled button")
    func malformedAndDuplicateActionRowsFailClosed() async throws {
        let root = try temporaryRoot("malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await persistedItem(root: root, id: "malformed", actions: [
            action("  ", "Empty ID"),
            action("not_a_native_action", "Looks actionable"),
            action("approve", "   "),
            action("APPROVE", "Approve once"),
            action("approve", "Approve twice"),
        ])

        let visible = InboxVisibleActionsPresentation.actions(for: item)
        #expect(visible.map(\.id) == ["approve"])
        #expect(visible.map(\.label) == ["Approve once"])
    }
}
