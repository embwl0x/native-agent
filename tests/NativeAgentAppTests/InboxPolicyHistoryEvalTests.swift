import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.inboxPolicy.viewInboxHistory

private enum InboxHistoryFixtureError: LocalizedError {
    case unavailable

    var errorDescription: String? { "history reader unavailable" }
}

private func inboxHistoryFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InboxPolicyHistory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("notifications", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private func writeInboxHistoryFixture(_ lines: [String], root: URL) throws {
    let inbox = root
        .appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: inbox)
}

@Suite("Inbox Policy history route")
struct InboxPolicyHistoryEvalTests {
    @Test("opening Inbox History reads the live inbox into the one shared mirror, preserves history rows, and keeps failure visible")
    @MainActor
    func historyRouteSharesTheMountedAppInboxAndRecoversFromReaderFailure() async throws {
        let root = try inboxHistoryFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeInboxHistoryFixture([
            #"{"id":"new-unread","created_at":"2026-08-24T10:00:00Z","source":"trigger:morning_brief","severity":"important","title":"Fresh brief","summary":"Visible now","actions":[],"status":"unread"}"#,
            #"{"id":"older-archived","created_at":"2026-08-23T10:00:00Z","source":"doctor","severity":"info","title":"Old diagnostic","summary":"Still part of history","actions":[],"status":"archived"}"#,
        ], root: root)

        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let route = InboxHistoryRoute()

        await route.open(
            read: { try await model.getInboxItems(unreadOnly: false) },
            retainedItemCount: { model.inboxItems.count },
            adopt: { model.inboxItems = $0 }
        )

        #expect(route.isPresented)
        #expect(!route.isLoading)
        #expect(route.errorText == nil)
        #expect(model.inboxItems.map(\.id) == ["new-unread", "older-archived"])
        #expect(InboxHistoryPresentation.content(items: model.inboxItems)
            == .rows(model.inboxItems))
        #expect(InboxHistoryPresentation.statusLabel(for: model.inboxItems[0]) == "Unread")
        #expect(InboxHistoryPresentation.statusLabel(for: model.inboxItems[1]) == "Archived")

        model.inboxReaderOverride = { _ in throw InboxHistoryFixtureError.unavailable }
        let failed = await route.refresh(
            read: { try await model.getInboxItems(unreadOnly: false) },
            retainedItemCount: { model.inboxItems.count },
            adopt: { model.inboxItems = $0 }
        )

        #expect(failed == .failed)
        #expect(route.isPresented, "a failed refresh must not silently dismiss the visible history")
        #expect(route.errorText?.contains("showing 2 previously loaded items") == true)
        #expect(model.inboxItems.map(\.id) == ["new-unread", "older-archived"],
                "a failed policy refresh must retain the shared history rows")

        model.inboxReaderOverride = nil
        let recovered = await route.refresh(
            read: { try await model.getInboxItems(unreadOnly: false) },
            retainedItemCount: { model.inboxItems.count },
            adopt: { model.inboxItems = $0 }
        )
        #expect(recovered == .loaded)
        #expect(route.errorText == nil)

        route.close()
        #expect(!route.isPresented, "Close returns from history to Inbox Policy without replacing its inbox state")
        #expect(InboxHistoryPresentation.content(items: model.inboxItems)
            == .rows(model.inboxItems))
    }
}
