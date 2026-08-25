import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

/// Direct behavioral proof for chat controls whose SwiftUI owners intentionally
/// keep their local interaction state private.  These tests exercise the
/// public model boundaries the controls invoke; they do not scrape source or
/// recreate the view state machine in a fixture.
///
/// Candidate ledger rows:
/// - ui.chat.sidebar.sessionRow
/// - ui.chat.emptyState
/// - ui.chat.queue.queueMenu
@Suite("Chat visible behavior completion")
struct ChatVisibleBehaviorCompletionEvalTests {
    private func session(_ id: String, title: String) throws -> ChatSession {
        let data = Data("""
        {"id":"\(id)","title":\(String(reflecting: title)),"createdAt":"2026-08-24T00:00:00Z"}
        """.utf8)
        return try JSONDecoder().decode(ChatSession.self, from: data)
    }

    @Test("a session row receives a human title, never raw whitespace")
    func chatSessionDisplayTitleNormalizesWhitespaceOnlyValues() throws {
        let blank = try session("blank", title: " \n\t ")
        let named = try session("named", title: "  Planning  ")

        #expect(blank.displayTitle == ChatSession.placeholderTitle)
        #expect(named.displayTitle == "Planning")
        #expect(!blank.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // EVAL FENCE: app.chat / ui.chat.sidebar.sessionRow
    @Test("sidebar rows change identity across a pin flip and never duplicate a render pass")
    func sidebarSessionRowsUseSectionScopedStableIdentities() throws {
        let moved = try session("move-me", title: "Move me")
        let duplicate = try session("duplicate", title: "First receipt")
        let duplicateAfterRefresh = try session("duplicate", title: "Stale duplicate receipt")
        let prefixShaped = try session("pinned-move-me", title: "Prefix-shaped ID")

        let unpinnedIdentity = ChatSidebarSessionRowIdentity(sessionID: moved.id, pinned: false)
        let pinnedIdentity = ChatSidebarSessionRowIdentity(sessionID: moved.id, pinned: true)
        #expect(unpinnedIdentity != pinnedIdentity)

        // Exercise the same section projection consumed by ChatView's
        // LazyVStack.  The duplicate is an adverse index receipt: it must
        // collapse to one row rather than give LazyVStack ambiguous identity.
        let sections = ChatSidebarSections.split(
            visible: [moved, duplicate, duplicateAfterRefresh, prefixShaped],
            orderedPinned: [moved]
        )
        let rowIdentities = sections.pinned.map {
            ChatSidebarSessionRowIdentity(sessionID: $0.id, pinned: true)
        } + sections.unpinned.map {
            ChatSidebarSessionRowIdentity(sessionID: $0.id, pinned: false)
        }

        #expect(sections.pinned.map(\.id) == ["move-me"])
        #expect(sections.unpinned.map(\.id) == ["duplicate", "pinned-move-me"])
        #expect(Set(rowIdentities).count == rowIdentities.count)
        #expect(rowIdentities.contains(unpinnedIdentity) == false)
        #expect(rowIdentities.contains(pinnedIdentity))
    }

    @MainActor
    @Test("an empty-state suggestion remains with the session that accepted it")
    func injectedSuggestionDraftSurvivesAChatSwitchWithoutLeaking() {
        let model = AppModel()
        let first = "suggestion-a-\(UUID().uuidString)"
        let second = "suggestion-b-\(UUID().uuidString)"
        model.activeChatSessionId = first

        // ChatEmptyState's suggestion closure uses this injection boundary.
        // Capture the target before a switch, as a tap can race a sidebar
        // selection on the same run loop.
        let tappedSessionId = model.activeChatSessionId
        model.injectChatDraft("Run the audit", sessionId: tappedSessionId)
        model.activeChatSessionId = second

        #expect(model.chatDraft(for: second).isEmpty)
        #expect(model.chatDraft(for: first) == "Run the audit")

        model.activeChatSessionId = first
        #expect(model.chatDraft(for: model.activeChatSessionId) == "Run the audit")
    }

    @MainActor
    @Test("queue menu promotion and removal retain the exact selected turn")
    func queueActionsOperateOnTheMenuItemIdentityNotItsCurrentOrdinal() {
        let model = AppModel()
        let sessionId = "queue-menu-\(UUID().uuidString)"
        let first = QueuedChatTurn(id: "first", text: "first queued")
        let second = QueuedChatTurn(id: "second", text: "second queued")
        let third = QueuedChatTurn(id: "third", text: "third queued")
        model.queuedChatTurnsBySession[sessionId] = [first, second, third]

        // "Send 3 now" must promote the third item's stable ID, rather than
        // whatever happens to occupy ordinal 3 after the menu is materialized.
        #expect(model.promoteQueuedChatTurn(third.id, sessionId: sessionId))
        #expect(model.queuedChatTurns(for: sessionId).map(\.id) == ["third", "first", "second"])

        // The destructive pair in the same menu must remove that stable ID
        // only; a stale ordinal must not delete its new neighbor.
        model.removeQueuedChatTurn(first.id, sessionId: sessionId)
        #expect(model.queuedChatTurns(for: sessionId).map(\.id) == ["third", "second"])
        #expect(model.queuedChatTurns(for: sessionId).map(\.text) == ["third queued", "second queued"])
    }

    @Test("queued attachment-only turns have an honest preview and hidden turns stay out of the menu")
    func queuePreviewAndVisibilityDistinguishAttachmentsFromUserVisibleTurns() {
        let attachment = MultimodalAttachment(
            id: "attachment", type: "image", base64: "aW1hZ2U=",
            mime: "image/png", name: "proof.png", byteSize: 5
        )
        let oneAttachment = QueuedChatTurn(text: " \n", attachments: [attachment])
        let manyAttachments = QueuedChatTurn(text: "", attachments: [attachment, attachment])
        let hidden = QueuedChatTurn(text: "internal greeting", hideUserBubble: true)

        #expect(oneAttachment.preview == "One attachment")
        #expect(manyAttachments.preview == "2 attachments")
        #expect(oneAttachment.shouldDisplayInSendNextQueue)
        #expect(!hidden.shouldDisplayInSendNextQueue)
    }
}
