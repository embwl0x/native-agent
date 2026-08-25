import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Desk Inbox AppModel mirror behavior")
struct DeskInboxAppModelMirrorBehaviorTests {
    private func item(_ id: String) throws -> InboxItemRecord {
        try JSONDecoder().decode(
            InboxItemRecord.self,
            from: Data(#"{"id":"\#(id)","created_at":"2026-08-24T00:00:00Z","source":"test","severity":"actionable","title":"\#(id)","summary":"test","actions":[],"status":"unread"}"#.utf8)
        )
    }

    // app.desk / desk.inbox.appModelMirror
    @MainActor
    @Test("an honest empty model snapshot clears the mounted copy once")
    func honestEmptyModelSnapshotHasOneVisibleTransition() async throws {
        let pending = try item("pending")
        let state = InboxLoadState(items: [pending])

        let failedReload = await state.reload {
            throw NSError(domain: "InboxMirrorEval", code: 1)
        }
        #expect(!failedReload)
        #expect(state.items == [pending])
        #expect(state.errorText?.contains("couldn't refresh") == true)

        #expect(state.replaceItems([]))
        #expect(state.items.isEmpty)
        #expect(!state.replaceItems([]))
        #expect(state.items.isEmpty)
    }

    // app.desk / desk.inbox.appModelMirror
    @MainActor
    @Test("a confirmed resolution cannot be undone by a stale AppModel mirror copy")
    func staleMirrorCannotResurrectResolvedCards() async throws {
        let resolved = try item("resolved")
        let newCard = try item("new-card")
        let state = InboxLoadState(items: [resolved])

        #expect(await state.reload { [] })
        #expect(state.items.isEmpty)
        #expect(state.locallyResolvedIDs == [resolved.id])

        #expect(!state.replaceItems([resolved]))
        #expect(state.items.isEmpty)
        #expect(state.locallyResolvedIDs == [resolved.id])

        #expect(state.replaceItems([resolved, newCard]))
        #expect(state.items.map(\.id) == [newCard.id])
    }
}
