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

    func succeed(_ sessionId: String, messages: [ChatMessage], receipt: ContextReceipt? = nil) {
        let continuation = pending.removeValue(forKey: sessionId)
        continuation?.resume(returning: Snapshot(messages: messages, receipt: receipt))
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
@Test(arguments: ["user", "assistant"], [false, true])
func preWriteFailureRecoveryKeepsCurrentRequestInsteadOfOlderCanonicalUser(
    predecessorRole: String, sameText: Bool
) throws {
    let session = "pre-write-failure"
    let originalText = "The current exact request"
    let predecessor = ChatMessage(
        id: "prior-canonical", sessionId: session, role: predecessorRole,
        content: sameText ? originalText : "An older request or reply"
    )
    var original = ChatMessage(id: "current-local-user", sessionId: session, role: "user", content: originalText)
    var originalMetadata = ChatMessageMetadata()
    originalMetadata.attachments = [PersistedAttachment(
        id: "original-file", type: "file", mime: "text/plain", name: "request.txt", byteSize: 12
    )]
    original.metadata = originalMetadata
    let notice = ChatMessage(
        id: AppModel.syntheticErrorIDPrefix + "current-failure", sessionId: session, role: "assistant",
        content: "Draft failed.", metadata: .syntheticError("fixture failure", inputHadAttachments: true)
    )
    let canonical = [predecessor]
    let restored = try #require(AppModel.restoredUnpersistedChatRequest(
        originalUser: original, predecessor: predecessor, notice: notice, canonicalMessages: canonical
    ))
    #expect(restored.map(\.id) == [predecessor.id, original.id, notice.id])
    #expect(restored[1] == original)
    #expect(restored.last?.metadata?.syntheticUserRowPersisted == false)
    let target = try #require(restored.last)
    let retry = try #require(MacChatRetrySnapshot.capture(
        target: target, messages: restored, sessionId: session, isSyntheticNotice: true
    ))
    #expect(retry.priorUserMessageId == original.id)
    #expect(retry.priorUserMessageId != predecessor.id)
    #expect(retry.priorUserText == originalText)
    #expect(!retry.userRowPersisted)
    #expect(retry.inputHadAttachments)
    #expect(retry.matchesCanonical(canonical))
    // Recovery changes only the new notice, not the caller's evidence.
    #expect(notice.metadata?.syntheticUserRowPersisted == true)
}

@MainActor
@Test(arguments: ["user", "assistant"])
func preWriteFailureRecoveryRefusesAdvancedCanonicalTail(newRole: String) {
    let session = "pre-write-failure"
    let predecessor = ChatMessage(id: "prior", sessionId: session, role: "user", content: "Same text")
    let original = ChatMessage(id: "current-local", sessionId: session, role: "user", content: "Same text")
    let notice = ChatMessage(
        id: AppModel.syntheticErrorIDPrefix + "failure", sessionId: session, role: "assistant",
        content: "Draft failed.", metadata: .syntheticError("fixture failure")
    )
    let canonical = [predecessor, ChatMessage(
        id: "new-canonical", sessionId: session, role: newRole, content: "Same text"
    )]
    #expect(AppModel.restoredUnpersistedChatRequest(
        originalUser: original, predecessor: predecessor, notice: notice, canonicalMessages: canonical
    ) == nil)
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

// The injected throwing-loader test above proves transaction ordering, but it
// cannot prove the real disk adapter throws. SessionHistoryReader deliberately
// exposes read failure/malformed counts separately for tolerant prompt history;
// the app must not silently turn those adverse reads into a new empty chat.
@MainActor
@Test(arguments: ["unreadable", "malformed", "invalid-shape"])
func persistedTranscriptFailureRetainsPreviousConversation(kind: String) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("transactional-disk-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("chat/messages/requested.jsonl")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data((kind == "invalid-shape" ? "17\n{\"role\":\"assistant\"}\n" : "{broken-json}\n").utf8)
    if kind == "unreadable" {
        // A directory at the transcript path deterministically fails Data's
        // file read even when the test host has elevated filesystem access.
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    } else {
        try bytes.write(to: path)
    }
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
    let previous = try transactionalSession("previous")
    let requested = try transactionalSession("requested")
    let messages = [transactionalMessage("kept", sessionId: previous.id, content: "Keep the visible conversation")]
    model.chatSessions = [previous, requested]
    model.activeChatSessionId = previous.id
    model.chatMessagesBySession[previous.id] = messages

    await #expect(throws: (any Error).self) {
        _ = try await NativeClient.getChatMessages(sessionId: requested.id, dataRoot: root)
    }
    await model.selectChatSession(requested, persistSelection: false) { id in
        let loaded = try await NativeClient.getChatMessages(sessionId: id, dataRoot: root)
        return AppModel.ChatSessionLoadSnapshot(messages: loaded, receipt: nil)
    }

    #expect(model.activeChatSessionId == previous.id)
    #expect(model.chatMessages == messages)
    #expect(model.chatMessagesBySession[requested.id] == nil)
    #expect(model.statusText.hasPrefix("Chat session load failed:"))
    if kind != "unreadable" {
        #expect(try Data(contentsOf: path) == bytes, "failed display reads must preserve damaged history bytes")
    }
}

@MainActor
@Test(arguments: ["missing", "empty", "whitespace"])
func missingEmptyAndWhitespacePersistedTranscriptsRemainSelectable(kind: String) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("transactional-empty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("chat/messages/new-session.jsonl")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    if kind != "missing" {
        try Data((kind == "whitespace" ? " \n\t\n" : "").utf8).write(to: path)
    }
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
    let requested = try transactionalSession("new-session")
    model.chatSessions = [requested]
    await model.selectChatSession(requested, persistSelection: false) { id in
        let loaded = try await NativeClient.getChatMessages(sessionId: id, dataRoot: root)
        return AppModel.ChatSessionLoadSnapshot(messages: loaded, receipt: nil)
    }
    #expect(model.activeChatSessionId == requested.id)
    #expect(model.chatMessages.isEmpty)
    #expect(!model.statusText.hasPrefix("Chat session load failed:"))
}

@Test
func partiallyMalformedPersistedTranscriptKeepsReadableHistoryWithoutRewriting() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("transactional-partial-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("chat/messages/partial.jsonl")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("{broken-json}\n{\"role\":\"assistant\",\"content\":\"valid retained message\"}\n17\n".utf8)
    try bytes.write(to: path)
    let messages = try await NativeClient.getChatMessages(sessionId: "partial", dataRoot: root)
    #expect(messages.map(\.content) == ["valid retained message"])
    #expect(try Data(contentsOf: path) == bytes)
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
@Test(arguments: [false, true])
func selectionLoadCannotReplaceRowsFromTurnThatSettledWhileLoading(turnAlreadyRunning: Bool) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("transactional-turn-race-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
    let selected = try transactionalSession("selected")
    let prior = [transactionalMessage("prior", sessionId: selected.id, content: "Earlier reply")]
    model.activeChatSessionId = "previous"
    model.chatSessions = [selected]
    model.setChatMessages(prior, for: selected.id)
    let start = Date(timeIntervalSince1970: 1_788_110_000)
    let turnID = "intervening-turn"
    if turnAlreadyRunning {
        _ = model.beginChatTurnLifecycle(sessionId: selected.id, turnId: turnID, at: start)
        model.streamingSessions.insert(selected.id)
    }
    let harness = ChatSessionLoadHarness()
    let load = Task { @MainActor in
        await model.selectChatSession(selected, persistSelection: false) { sessionId in
            try await harness.load(sessionId)
        }
    }
    await harness.waitUntilRequested(selected.id)
    #expect(model.activeChatSessionId == selected.id)
    if !turnAlreadyRunning {
        _ = model.beginChatTurnLifecycle(sessionId: selected.id, turnId: turnID, at: start)
        model.streamingSessions.insert(selected.id)
    }
    let fresh = prior + [
        ChatMessage(id: "tool-receipt", sessionId: selected.id, role: "tool", content: "Recorded result"),
        transactionalMessage("new-final", sessionId: selected.id, content: "New final reply"),
    ]
    let freshReceipt = try JSONDecoder().decode(ContextReceipt.self,
        from: Data(#"{"runId":"new-run","sessionId":"selected"}"#.utf8))
    let staleReceipt = try JSONDecoder().decode(ContextReceipt.self,
        from: Data(#"{"runId":"old-run","sessionId":"selected"}"#.utf8))
    model.setChatMessages(fresh, for: selected.id)
    model.setLatestContextReceipt(freshReceipt, for: selected.id)
    let identity = MacChatTurnIdentity(sessionId: selected.id, turnId: turnID)
    _ = model.applyChatTurnLifecycleInput(.init(
        identity: identity, kind: .completed, occurredAt: start.addingTimeInterval(1)))
    _ = model.closeChatTurnLifecycleIntake(
        sessionId: selected.id, turnId: turnID, at: start.addingTimeInterval(1))
    model.streamingSessions.remove(selected.id)
    #expect(model.activeChatTurnLifecycleIDsBySession[selected.id] == nil,
            "the active-turn flag alone cannot detect a completed intervening turn")

    harness.succeed(selected.id, messages: prior, receipt: staleReceipt)
    await load.value
    #expect(model.activeChatSessionId == selected.id)
    #expect(model.chatMessages(for: selected.id) == fresh)
    #expect(model.latestContextReceipt(for: selected.id) == freshReceipt)
}

@MainActor
@Test(arguments: ["messages", "receipt"])
func detachedLoadCannotReplaceTurnThatSettledDuringEitherAwait(endpoint: String) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("detached-turn-race-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
    let session = "detached"
    model.activeChatSessionId = "main-window"
    let oldRows = [transactionalMessage("old", sessionId: session, content: "Earlier reply")]
    model.setChatMessages(oldRows, for: session)
    let oldReceipt = try JSONDecoder().decode(ContextReceipt.self, from: Data(#"{"runId":"old"}"#.utf8))
    let newReceipt = try JSONDecoder().decode(ContextReceipt.self, from: Data(#"{"runId":"new"}"#.utf8))
    let harness = ChatSessionLoadHarness()
    let load = Task { @MainActor in
        await model.loadDetachedSessionMessages(session, loadMessages: { _ in
            if endpoint == "messages" {
                return try await harness.load("messages").messages
            }
            return oldRows
        }, loadReceipt: { _ in
            guard endpoint == "receipt" else {
                Issue.record("superseded message load must not continue to a receipt read")
                return oldReceipt
            }
            let snapshot = try await harness.load("receipt")
            return try #require(snapshot.receipt)
        })
    }
    await harness.waitUntilRequested(endpoint)

    let instant = Date(timeIntervalSince1970: 1_788_110_000)
    let identity = try #require(model.beginChatTurnLifecycle(sessionId: session, turnId: "new-turn", at: instant))
    model.streamingSessions.insert(session)
    let freshRows = oldRows + [
        ChatMessage(id: "new-tool", sessionId: session, role: "tool", content: "Recorded result"),
        transactionalMessage("new-final", sessionId: session, content: "New final reply"),
    ]
    model.setChatMessages(freshRows, for: session)
    model.setLatestContextReceipt(newReceipt, for: session)
    let freshStatus = AppModel.nextRefreshStatus(previous: nil, failedEndpoints: [], at: instant)
    model.detachedChatRefreshStatus[session] = freshStatus
    model.detachedChatContextReceiptRefreshStatus[session] = freshStatus
    _ = model.applyChatTurnLifecycleInput(.init(
        identity: identity, kind: .completed, occurredAt: instant.addingTimeInterval(1)))
    _ = model.closeChatTurnLifecycleIntake(sessionId: session, turnId: identity.turnId, at: instant.addingTimeInterval(1))
    model.streamingSessions.remove(session)

    harness.succeed(endpoint, messages: oldRows, receipt: oldReceipt)
    await load.value
    #expect(model.activeChatSessionId == "main-window")
    #expect(model.chatMessages(for: session) == freshRows)
    #expect(model.latestContextReceipt(for: session) == newReceipt)
    #expect(model.detachedChatRefreshStatus[session]?.lastSuccessAt == instant)
    #expect(model.detachedChatContextReceiptRefreshStatus[session]?.lastSuccessAt == instant)
}

@MainActor
@Test
func detachedLoadWithoutInterveningTurnAppliesAuthoritativeSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detached-load-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
    model.activeChatSessionId = "main-window"
    let session = "detached"
    model.setChatMessages([transactionalMessage("cached", sessionId: session, content: "Incomplete cache")], for: session)
    let rows = [transactionalMessage("loaded", sessionId: session, content: "Authoritative reply")]
    let receipt = try JSONDecoder().decode(ContextReceipt.self, from: Data(#"{"runId":"loaded"}"#.utf8))
    await model.loadDetachedSessionMessages(session, loadMessages: { _ in rows }, loadReceipt: { _ in receipt })
    #expect(model.chatMessages(for: session) == rows)
    #expect(model.latestContextReceipt(for: session) == receipt)
    #expect(model.detachedChatRefreshStatus[session]?.isStale == false)
    #expect(model.detachedChatContextReceiptRefreshStatus[session]?.isStale == false)
    #expect(model.activeChatSessionId == "main-window")
}

@MainActor
@Test(arguments: [false, true])
func detachedLoadFailuresRemainVisibleAndDoNotInventEmptyHistory(hasCachedRows: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detached-error-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
    let session = "detached"
    let cached = [transactionalMessage("cached", sessionId: session, content: "Last known reply")]
    let receipt = try JSONDecoder().decode(ContextReceipt.self, from: Data(#"{"runId":"cached"}"#.utf8))
    if hasCachedRows {
        model.setChatMessages(cached, for: session)
        model.setLatestContextReceipt(receipt, for: session)
    }
    await model.loadDetachedSessionMessages(
        session, loadMessages: { _ in throw TransactionalSelectionFailure() },
        loadReceipt: { _ in throw TransactionalSelectionFailure() })
    #expect(model.chatMessagesBySession[session] == (hasCachedRows ? cached : nil))
    #expect(model.latestContextReceipt(for: session) == (hasCachedRows ? receipt : nil))
    #expect(model.detachedChatRefreshStatus[session]?.isStale == true)
    #expect(model.detachedChatContextReceiptRefreshStatus[session]?.isStale == true)
}

@MainActor
@Test(arguments: [false, true], [false, true])
func sessionLoadPathsPreserveUnpersistedRequestOnlyAtItsOriginalCanonicalTail(
    detached: Bool, canonicalAdvanced: Bool
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-request-load-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
    let session = try transactionalSession("local-request")
    model.activeChatSessionId = "main-window"
    model.chatSessions = [session]
    let baseline = [transactionalMessage("old-answer", sessionId: session.id, content: "Prior answer")]
    let user = ChatMessage(id: "unsent-user", sessionId: session.id, role: "user", content: "Original unsent request")
    let notice = ChatMessage(
        id: AppModel.syntheticErrorIDPrefix + "unsent", sessionId: session.id, role: "assistant",
        content: "Connect a provider.", metadata: .syntheticError("no_provider_connected", userRowPersisted: false)
    )
    model.setChatMessages(baseline + [user, notice], for: session.id)
    let originalRetry = try #require(MacChatRetrySnapshot.capture(
        target: notice, messages: baseline + [user, notice], sessionId: session.id, isSyntheticNotice: true
    ))
    let disk = canonicalAdvanced
        ? baseline + [transactionalMessage("new-answer", sessionId: session.id, content: "New canonical reply")]
        : baseline
    let receipt = try JSONDecoder().decode(ContextReceipt.self, from: Data(#"{"runId":"loaded-context"}"#.utf8))

    if detached {
        await model.loadDetachedSessionMessages(session.id, loadMessages: { _ in disk }, loadReceipt: { _ in receipt })
    } else {
        await model.selectChatSession(session, persistSelection: false) { _ in
            AppModel.ChatSessionLoadSnapshot(messages: disk, receipt: receipt)
        }
    }

    let rows = model.chatMessages(for: session.id)
    #expect(rows == (canonicalAdvanced ? disk : baseline + [user, notice]))
    #expect(model.activeChatSessionId == (detached ? "main-window" : session.id))
    #expect(model.latestContextReceipt(for: session.id) == receipt)
    if !canonicalAdvanced {
        #expect(MacChatRetrySnapshot.capture(
            target: notice, messages: rows, sessionId: session.id, isSyntheticNotice: true
        ) == originalRetry)
        #expect(originalRetry.matchesCanonical(disk))
    }
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

@MainActor
@Test
func liveSessionIndexRefreshAddsExternalSessionWithoutDisturbingActiveChat() async throws {
    let model = AppModel()
    let active = try transactionalSession("active")
    let bridge = try transactionalSession("bridge-created")
    let activeMessages = [
        transactionalMessage("active-message", sessionId: active.id, content: "keep me visible")
    ]
    model.chatSessions = [active]
    model.activeChatSessionId = active.id
    model.chatMessagesBySession[active.id] = activeMessages
    model.chatDrafts[active.id] = "unfinished draft"

    await model.refreshChatSessionIndex {
        [bridge, active]
    }

    #expect(model.chatSessions.map(\.id) == [bridge.id, active.id])
    #expect(model.activeChatSessionId == active.id)
    #expect(model.chatMessages == activeMessages)
    #expect(model.chatDrafts[active.id] == "unfinished draft")
}

@MainActor
@Test
func failedLiveSessionIndexRefreshKeepsLastProvenRowsAndRecoversCleanly() async throws {
    struct FixtureFailure: Error {}
    let model = AppModel()
    let active = try transactionalSession("active")
    model.chatSessions = [active]

    await model.refreshChatSessionIndex {
        throw FixtureFailure()
    }

    #expect(model.chatSessions == [active])
    #expect(model.chatSessionIndexRefreshFailed)

    await model.refreshChatSessionIndex {
        [active]
    }

    #expect(model.chatSessions == [active])
    #expect(!model.chatSessionIndexRefreshFailed)
}
