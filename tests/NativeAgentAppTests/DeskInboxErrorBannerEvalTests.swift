import Foundation
import Testing
@testable import NativeAgentApp

// Eval coverage — fence `app.desk`, ledger row `desk.inbox.errorBanner`.
// This drives InboxView's mounted load-state boundary with a fail-then-success
// reader, proving retained cards are labeled stale and a healthy retry removes
// the error rather than leaving a ghost banner behind.

private func inboxRecord(_ id: String) throws -> InboxItemRecord {
    let data = Data("""
    {
      "id": "\(id)",
      "created_at": "2026-08-24T00:00:00Z",
      "source": "idle_checkin",
      "severity": "info",
      "title": "Inbox item \(id)",
      "summary": "summary",
      "actions": [],
      "status": "unread"
    }
    """.utf8)
    return try JSONDecoder().decode(InboxItemRecord.self, from: data)
}

@MainActor
@Test("inbox failures label retained rows and a successful retry clears the error banner")
func inboxErrorBannerTracksTheActualLoadOutcome() async throws {
    let stale = try inboxRecord("stale")
    let fresh = try inboxRecord("fresh")
    let state = InboxLoadState(items: [stale])

    let failed = await state.reload {
        throw NSError(
            domain: "InboxEval",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Inbox file is unreadable"])
    }
    #expect(!failed)
    #expect(state.items.map(\.id) == ["stale"])
    #expect(state.errorText == "Inbox couldn't refresh — showing 1 previously loaded item. Inbox file is unreadable")

    let succeeded = await state.reload { [fresh] }
    #expect(succeeded)
    #expect(state.items.map(\.id) == ["fresh"])
    #expect(state.errorText == nil)
}
