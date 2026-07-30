import Foundation
import Testing
@testable import NativeAgentApp

private struct TransactionalSelectionFailure: LocalizedError {
    var errorDescription: String? { "fixture transcript unavailable" }
}

@MainActor
private final class ChatSessionLoadHarness {
    private typealias Snapshot = AppModel.ChatSessionLoadSnapshot
    private var pending: [String: CheckedContinuation<Snapshot, any Error>] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func load(_ sessionId: String) async throws -> AppModel.ChatSessionLoadSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            pending[sessionId] = continuation
            let waiters = requestWaiters.removeValue(forKey: sessionId) ?? []
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilRequested(_ sessionId: String) async {
        if pending[sessionId] != nil { return }
        await withCheckedContinuation { continuation in
            requestWaiters[sessionId, default: []].append(continuation)
        }
    }

    func succeed(_ sessionId: String, messages: [ChatMessage]) {
        let continuation = pending.removeValue(forKey: sessionId)
        continuation?.resume(returning: Snapshot(messages: messages, receipt: nil))
    }
}

private func transactionalSession(_ id: String) throws -> ChatSession {
    let data = Data("""
    {
      "id": "\(id)",
      "title": "Session \(id)",
      "createdAt": "2026-07-09T12:00:00Z"
    }
    """.utf8)
    return try JSONDecoder().decode(ChatSession.self, from: data)
}

private func transactionalMessage(_ id: String, sessionId: String, content: String) -> ChatMessage {
    ChatMessage(id: id, sessionId: sessionId, role: "assistant", content: content)
}

@Test
func iCloudReplacementIntentFailsClosedWithoutBothSignedFields() {
    let id = UUID()
    #expect(ICloudChatReplacementIntent.decode([
        "suppressUserAppend": "true",
        "replacementAssistantMessageId": id.uuidString,
    ]) == ICloudChatReplacementIntent(assistantMessageID: id.uuidString))
    #expect(ICloudChatReplacementIntent.decode([
        "replacementAssistantMessageId": id.uuidString,
    ]) == nil)
    #expect(ICloudChatReplacementIntent.decode([
        "suppressUserAppend": "true",
        "replacementAssistantMessageId": "not-a-uuid",
    ]) == nil)
}

@MainActor
@Test
func startupSendRejectionPreservesDraftAndAttachments() async {
    let model = AppModel()
    model.activeChatSessionId = ""
    model.chatSessions = []
    model.chatDrafts["startup"] = "keep this draft"
    let attachment = MultimodalAttachment(
        id: "attachment-1",
        type: "image",
        base64: "aW1hZ2U=",
        mime: "image/png",
        name: "startup.png",
        byteSize: 5
    )
    model.chatPendingAttachments[""] = [attachment]

    let acceptance = await model.startActiveChatTurn(
        "keep this draft",
        attachments: [attachment],
        expectedSessionId: ""
    )

    #expect(acceptance == .rejected(message: "Chat is still starting. Your message was not sent."))
    #expect(model.chatDrafts["startup"] == "keep this draft")
    #expect(model.chatPendingAttachments[""] == [attachment])
    #expect(model.chatTasks.isEmpty)
    #expect(model.streamingSessions.isEmpty)
    #expect(model.statusText == "Chat is still starting. Your message was not sent.")
}

@MainActor
@Test
func failedSessionSelectionRetainsPreviousConversationAndIdentity() async throws {
    let model = AppModel()
    let previous = try transactionalSession("previous")
    let requested = try transactionalSession("requested")
    let previousMessages = [
        transactionalMessage("previous-message", sessionId: previous.id, content: "still visible")
    ]
    model.chatSessions = [previous, requested]
    model.activeChatSessionId = previous.id
    model.chatMessagesBySession[previous.id] = previousMessages

    await model.selectChatSession(requested, persistSelection: false) { _ in
        throw TransactionalSelectionFailure()
    }

    #expect(model.activeChatSessionId == previous.id)
    #expect(model.chatMessages == previousMessages)
    #expect(model.chatMessagesBySession[requested.id] == nil)
    #expect(model.statusText == "Chat session load failed: fixture transcript unavailable")
}

@MainActor
@Test
func rapidSessionSelectionsCommitOnlyTheLatestRequest() async throws {
    let model = AppModel()
    let previous = try transactionalSession("previous")
    let sessionA = try transactionalSession("A")
    let sessionB = try transactionalSession("B")
    let previousMessages = [
        transactionalMessage("previous-message", sessionId: previous.id, content: "previous")
    ]
    let messagesA = [transactionalMessage("message-A", sessionId: sessionA.id, content: "A")]
    let messagesB = [transactionalMessage("message-B", sessionId: sessionB.id, content: "B")]
    model.chatSessions = [previous, sessionA, sessionB]
    model.activeChatSessionId = previous.id
    model.chatMessagesBySession[previous.id] = previousMessages
    let harness = ChatSessionLoadHarness()

    let loadA = Task { @MainActor in
        await model.selectChatSession(sessionA, persistSelection: false) { sessionId in
            try await harness.load(sessionId)
        }
    }
    await harness.waitUntilRequested(sessionA.id)

    let loadB = Task { @MainActor in
        await model.selectChatSession(sessionB, persistSelection: false) { sessionId in
            try await harness.load(sessionId)
        }
    }
    await harness.waitUntilRequested(sessionB.id)

    #expect(model.activeChatSessionId == previous.id)
    #expect(model.chatMessages == previousMessages)

    harness.succeed(sessionA.id, messages: messagesA)
    await loadA.value
    #expect(model.activeChatSessionId == previous.id)
    #expect(model.chatMessagesBySession[sessionA.id] == nil)

    harness.succeed(sessionB.id, messages: messagesB)
    await loadB.value
    #expect(model.activeChatSessionId == sessionB.id)
    #expect(model.chatMessages == messagesB)
}

@MainActor
@Test
func cachedSessionSelectionCommitsBeforeRefreshCompletes() async throws {
    let model = AppModel()
    let previous = try transactionalSession("previous")
    let cached = try transactionalSession("cached")
    let cachedMessages = [
        transactionalMessage("cached-message", sessionId: cached.id, content: "cached")
    ]
    let refreshedMessages = [
        transactionalMessage("refreshed-message", sessionId: cached.id, content: "refreshed")
    ]
    model.chatSessions = [previous, cached]
    model.activeChatSessionId = previous.id
    model.chatMessagesBySession[previous.id] = [
        transactionalMessage("previous-message", sessionId: previous.id, content: "previous")
    ]
    model.chatMessagesBySession[cached.id] = cachedMessages
    let harness = ChatSessionLoadHarness()

    let refresh = Task { @MainActor in
        await model.selectChatSession(cached, persistSelection: false) { sessionId in
            try await harness.load(sessionId)
        }
    }
    await harness.waitUntilRequested(cached.id)

    #expect(model.activeChatSessionId == cached.id)
    #expect(model.chatMessages == cachedMessages)

    harness.succeed(cached.id, messages: refreshedMessages)
    await refresh.value
    #expect(model.chatMessages == refreshedMessages)
}
