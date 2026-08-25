import XCTest
import NativeAgentShared
@testable import NativeAgentMobile

// Stale-snapshot guard regression net (2026-06-11, ledger ff7b6657).
// the user's repro: while actively chatting on iPhone, new messages vanished from
// the list, then ALL reappeared later. Cause: an iCloud snapshot built BEFORE
// the newest turns synced back replaced the local list wholesale. These tests
// pin the merge semantics that fix it: resolved local turns are never dropped,
// and they dedup by id / content-equivalence once a fresh snapshot catches up.
@MainActor
final class ChatStoreMergeTests: XCTestCase {

    private func isolatedDefaults(_ label: String = #function) -> UserDefaults {
        let suite = "NativeAgentMobileTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "NativeAgent.unifiedSession.v1")
        return defaults
    }

    private func msg(_ role: ChatMessage.Role, _ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text)
    }

    private func makeStore(_ messages: [ChatMessage]) -> ChatStore {
        let store = ChatStore(restoreQueuedSends: false)
        store.messages = messages
        return store
    }

    func test_corruptExactTranscriptNeverFallsThroughToUnownedGlobalCache() throws {
        let defaults = isolatedDefaults()
        let sessionID = "pinned-session"
        defaults.set(sessionID, forKey: "NativeAgentMobile.chatSessionID")
        defaults.set(Data("not-json".utf8), forKey: "NativeAgentMobile.chatMessages.session.\(sessionID)")
        defaults.set(
            try JSONEncoder().encode([msg(.assistant, "wrong conversation")]),
            forKey: "NativeAgentMobile.chatMessages"
        )

        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNotNil(store.errorBanner)
    }

    func test_sessionOwnedGlobalEnvelopeMigratesToExactCacheOnce() throws {
        let defaults = isolatedDefaults()
        let sessionID = "owned-main"
        defaults.set(sessionID, forKey: "NativeAgentMobile.chatSessionID")
        let expected = msg(.assistant, "owned transcript")
        let envelope = ChatStore.CachedTranscript(
            schemaVersion: 2,
            sessionID: sessionID,
            messages: [expected]
        )
        defaults.set(try JSONEncoder().encode(envelope), forKey: "NativeAgentMobile.chatMessages")

        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)

        XCTAssertEqual(store.messages.map(\.id), [expected.id])
        XCTAssertNotNil(defaults.data(forKey: store.transcriptStorageKey(for: sessionID)))
    }

    func test_queueRestoresFromOneAppOwnedStoreWithoutProcessLatch() {
        let defaults = isolatedDefaults()
        let owner = ChatStore(defaults: defaults, restoreQueuedSends: false)
        owner.setSelectedSessionID("queue-owner")
        owner.isLoading = true
        _ = owner.send(text: "survive relaunch", client: MacBridgeClient())

        let restored = ChatStore(defaults: defaults)

        XCTAssertEqual(restored.queuedSends.map(\.text), ["survive relaunch"])
    }

    private func session(
        id: String,
        title: String,
        source: String? = nil,
        archived: Bool = false
    ) throws -> NativeAgentShared.ChatSession {
        var object: [String: Any] = [
            "id": id,
            "title": title,
            "createdAt": "2026-07-15T00:00:00Z",
            "archived": archived,
        ]
        if let source { object["source"] = source }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(NativeAgentShared.ChatSession.self, from: data)
    }

    func test_tabProjectionContainsOnlyPhoneMainAndOrderedMacPins() throws {
        let pinned = try session(id: "pin-1", title: " First ")
        let duplicateMain = try session(id: "phone-main", title: "Duplicate")
        let archived = try session(id: "pin-old", title: "Old", archived: true)

        let tabs = ChatSessionTabProjection.make(
            mainSessionID: "phone-main",
            mainTitle: "iPhone",
            pinnedSessions: [pinned, duplicateMain, pinned, archived]
        )

        XCTAssertEqual(tabs.map(\.id), ["ios-main", "pin-1"])
        XCTAssertEqual(tabs.map(\.sessionID), ["phone-main", "pin-1"])
        XCTAssertEqual(tabs.last?.title, "First")
        XCTAssertEqual(tabs.last?.kind, .pinned("pin-1"))
    }

    func test_externalUnpinRequiresSelectedPinnedSessionToReturnToMain() {
        XCTAssertTrue(ChatStore.shouldReturnToMainSession(
            selectedSessionID: "removed-pin",
            mainSessionID: "phone-main",
            availablePinnedSessionIDs: ["other-pin"]
        ))
        XCTAssertFalse(ChatStore.shouldReturnToMainSession(
            selectedSessionID: "kept-pin",
            mainSessionID: "phone-main",
            availablePinnedSessionIDs: ["kept-pin"]
        ))
        XCTAssertFalse(ChatStore.shouldReturnToMainSession(
            selectedSessionID: "phone-main",
            mainSessionID: "phone-main",
            availablePinnedSessionIDs: []
        ))
        XCTAssertFalse(ChatStore.shouldReturnToMainSession(
            selectedSessionID: "ios-main-awaiting-adoption",
            mainSessionID: nil,
            availablePinnedSessionIDs: []
        ))
    }

    func test_timedOutRetryResumesOriginalSignedEventWithoutNewCorrelation() throws {
        let store = ChatStore(restoreQueuedSends: false)
        let eventID = "signed-device-event"
        var placeholder = msg(.assistant, "(reply timed out)")
        placeholder.isStreaming = false
        placeholder.toolEvents = [ToolEvent(name: "Checked repository", seq: 1)]
        store.messages = [placeholder]
        store.timedOutPendingIds[eventID] = placeholder.id
        store.pendingSendArgs[eventID] = ChatStore.PendingSendArgs(
            text: "Keep advancing NativeAgent",
            sessionID: "session",
            controls: .defaults,
            attachments: [],
            appendedUserId: UUID()
        )

        let resumedID = try XCTUnwrap(store.resumeTimedOutReply(messageId: placeholder.id))

        XCTAssertEqual(resumedID, eventID)
        XCTAssertEqual(store.pendingICloudPlaceholders, [eventID: placeholder.id])
        XCTAssertTrue(store.timedOutPendingIds.isEmpty)
        XCTAssertNotNil(store.pendingSendArgs[eventID], "same event retains its original send evidence")
        XCTAssertFalse(store.resolvedICloudReplyIds.contains(eventID))
        XCTAssertTrue(store.isLoading)
        let resumed = try XCTUnwrap(store.messages.first(where: { $0.id == placeholder.id }))
        XCTAssertTrue(resumed.isStreaming)
        XCTAssertEqual(resumed.text, "")
        XCTAssertEqual(resumed.toolEvents, placeholder.toolEvents, "same work keeps its observed progress")
    }

    func test_sendWhileLoadingQueuesFIFOWithoutAppendingTranscriptRows() {
        let store = ChatStore(restoreQueuedSends: false)
        let client = MacBridgeClient()
        let originalSessionID = store.selectedSessionID
        defer { store.setSelectedSessionID(originalSessionID) }
        store.setSelectedSessionID("queue-session")
        let originalMessageIDs = store.messages.map(\.id)
        store.isLoading = true

        let first = store.send(text: "first follow-up", client: client)
        let second = store.send(text: "second follow-up", client: client)

        guard case .queued = first, case .queued = second else {
            return XCTFail("busy sends must be accepted into send-next")
        }
        XCTAssertEqual(store.queuedSendsForSelectedSession.map(\.text), [
            "first follow-up", "second follow-up",
        ])
        XCTAssertEqual(store.messages.map(\.id), originalMessageIDs,
                       "queued turns are not transcript rows until started")
    }

    func test_queuePromotionAndMigrationPreserveSessionOwnership() throws {
        let store = ChatStore(restoreQueuedSends: false)
        let client = MacBridgeClient()
        let originalSessionID = store.selectedSessionID
        defer { store.setSelectedSessionID(originalSessionID) }
        store.setSelectedSessionID(nil)
        store.isLoading = true
        _ = store.send(text: "nil-session first", client: client)
        let second = store.send(text: "nil-session steer", client: client)
        guard case .queued(let secondID) = second else {
            return XCTFail("second turn was not queued")
        }

        XCTAssertTrue(store.promoteQueuedSend(secondID))
        XCTAssertEqual(store.queuedSendsForSelectedSession.map(\.text), [
            "nil-session steer", "nil-session first",
        ])
        store.migrateQueuedSends(from: nil, to: "mac-assigned-session")
        store.setSelectedSessionID("mac-assigned-session")
        XCTAssertEqual(store.queuedSendsForSelectedSession.map(\.text), [
            "nil-session steer", "nil-session first",
        ])

        store.setSelectedSessionID("different-session")
        XCTAssertTrue(store.queuedSendsForSelectedSession.isEmpty)
    }

    func test_iOSFallbackModelNeverDowngradesBelowGPT56Sol() {
        XCTAssertEqual(ChatRuntimeControls.defaults.model, "gpt-5.6-sol")
    }

    func test_regenerateMetadataRequiresExactReplacementIdentityBeforeSuppressingUserAppend() {
        let replacementID = UUID()
        let valid = MacBridgeClient.chatSendMetadata(
            controls: .defaults,
            suppressRemoteUserAppend: true,
            replacementAssistantMessageID: replacementID
        )
        XCTAssertEqual(valid["suppressUserAppend"], "true")
        XCTAssertEqual(valid["replacementAssistantMessageId"], replacementID.uuidString)

        let missingIdentity = MacBridgeClient.chatSendMetadata(
            controls: .defaults,
            suppressRemoteUserAppend: true,
            replacementAssistantMessageID: nil
        )
        XCTAssertNil(missingIdentity["suppressUserAppend"])
        XCTAssertNil(missingIdentity["replacementAssistantMessageId"])
    }

    func test_regenerateDuringSessionSwitchLeavesCanonicalLocalTurnUntouched() {
        let user = msg(.user, "question")
        let assistant = msg(.assistant, "keep this answer")
        let store = makeStore([user, assistant])
        store.isSwitchingSession = true

        store.regenerateLast(client: MacBridgeClient())

        XCTAssertEqual(store.messages.map(\.id), [user.id, assistant.id])
        XCTAssertEqual(store.messages.last?.text, "keep this answer")
    }

    // Coverage ledger: ios.screens / ios.chat.composer.textField
    func test_sessionSwitchAlwaysReleasesTheComposerAfterSuccessFailureOrCancellation() async {
        enum LoadFailure: Error { case unavailable }

        func waitForSwitchToFinish(_ store: ChatStore) async {
            for _ in 0..<100 where store.isSwitchingSession {
                await Task.yield()
            }
            XCTAssertFalse(store.isSwitchingSession)
        }

        let store = ChatStore(defaults: isolatedDefaults(), restoreQueuedSends: false)
        store.setSelectedSessionID("current")

        store.switchSessionForEvaluation(
            to: "success",
            loadHistory: { _ in [] },
            fallbackMessages: nil
        )
        await waitForSwitchToFinish(store)

        store.switchSessionForEvaluation(
            to: "failure",
            loadHistory: { _ in throw LoadFailure.unavailable },
            fallbackMessages: nil
        )
        await waitForSwitchToFinish(store)
        XCTAssertTrue(store.errorBanner?.contains("Could not load this chat") == true)

        store.switchSessionForEvaluation(
            to: "cancelled",
            loadHistory: { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return nil
            },
            fallbackMessages: nil
        )
        XCTAssertTrue(store.isSwitchingSession)
        store.cancelSessionSwitch()
        XCTAssertFalse(store.isSwitchingSession)
    }

    func test_unmatchedLateCancellationCannotStopANewerTurn() {
        let store = ChatStore(restoreQueuedSends: false)
        store.isLoading = true
        store.receiveICloudReply(.make(
            sender: "mac",
            text: "old cancellation",
            correlationID: "already-retired-turn",
            metadata: ["kind": "cancelled"]
        ))
        XCTAssertTrue(store.isLoading,
                      "a late cancellation without an active placeholder must not stop the new turn")
    }

    func test_publishedTranscriptUpdatesVisibleNonemptySession() {
        let defaults = isolatedDefaults()
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.replaceMainSessionID("phone-main")
        store.setSelectedSessionID("phone-main")
        let user = msg(.user, "already visible")
        let firstReply = msg(.assistant, "first reply")
        store.messages = [user, firstReply]
        let externalUser = msg(.user, "message from the Mac")
        let externalReply = msg(.assistant, "Mac-side reply")

        store.applyMacTranscriptSnapshot(
            [user, firstReply, externalUser, externalReply],
            sessionID: "phone-main"
        )

        XCTAssertEqual(store.messages.map(\.id), [user, firstReply, externalUser, externalReply].map(\.id))
    }

    func test_publishedTranscriptUpdatesContentWhenIdentityIsStable() {
        let defaults = isolatedDefaults()
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.replaceMainSessionID("phone-main")
        store.setSelectedSessionID("phone-main")
        let replyID = UUID()
        store.messages = [msg(.assistant, "old content", id: replyID)]

        store.applyMacTranscriptSnapshot(
            [msg(.assistant, "corrected content", id: replyID)],
            sessionID: "phone-main"
        )

        XCTAssertEqual(store.messages.first?.text, "corrected content")
    }

    func test_publishedTranscriptPreservesPendingLocalStream() {
        let defaults = isolatedDefaults()
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.replaceMainSessionID("phone-main")
        store.setSelectedSessionID("phone-main")
        let existingUser = msg(.user, "earlier")
        let existingReply = msg(.assistant, "earlier reply")
        let pendingUser = msg(.user, "still sending")
        var placeholder = msg(.assistant, "partial")
        placeholder.isStreaming = true
        placeholder.toolEvents = [ToolEvent(name: "read_file", seq: 1)]
        store.messages = [existingUser, existingReply, pendingUser, placeholder]
        store.pendingSendArgs["pending"] = ChatStore.PendingSendArgs(
            text: pendingUser.text,
            sessionID: "phone-main",
            controls: .defaults,
            attachments: [],
            appendedUserId: pendingUser.id
        )
        store.pendingICloudPlaceholders["pending"] = placeholder.id
        store.isLoading = true

        store.applyMacTranscriptSnapshot(
            [existingUser, existingReply],
            sessionID: "phone-main"
        )

        XCTAssertTrue(store.messages.contains(where: { $0.id == pendingUser.id }))
        let retained = store.messages.first(where: { $0.id == placeholder.id })
        XCTAssertEqual(retained?.text, "partial")
        XCTAssertEqual(retained?.toolEvents, placeholder.toolEvents)
        XCTAssertTrue(retained?.isStreaming == true)
        XCTAssertTrue(store.isLoading)
    }

    func test_publishedTranscriptForAnotherSessionCannotClobberVisibleChat() {
        let defaults = isolatedDefaults()
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.replaceMainSessionID("phone-main")
        store.setSelectedSessionID("phone-main")
        let visible = msg(.assistant, "keep visible")
        store.messages = [visible]

        store.applyMacTranscriptSnapshot(
            [msg(.assistant, "other session")],
            sessionID: "different-session"
        )

        XCTAssertEqual(store.messages, [visible])
    }

    func test_snapshotSignalGroupsDistinguishesTargetedChatPublication() {
        XCTAssertEqual(
            iCloudSyncEngine.snapshotSignalGroups("2026-08-16T01:02:03Z|groups=chat,core"),
            Set([.chat, .core])
        )
        XCTAssertEqual(
            iCloudSyncEngine.snapshotSignalGroups("2026-08-16T01:02:03Z|groups=activity"),
            Set([.activity])
        )
        XCTAssertNil(iCloudSyncEngine.snapshotSignalGroups("2026-08-16T01:02:03Z"))
    }

    // The vanish repro: snapshot is a strict prefix of local resolved state.
    func test_stale_snapshot_does_not_drop_resolved_turns() {
        let u1 = msg(.user, "first question")
        let a1 = msg(.assistant, "first answer")
        let u2 = msg(.user, "second question")
        let a2 = msg(.assistant, "second answer")
        let store = makeStore([u1, a1, u2, a2])

        let merged = store.mergedMacMessagesPreservingPending([u1, a1], replyArrived: false)

        XCTAssertEqual(merged.map(\.id), [u1, a1, u2, a2].map(\.id),
                       "stale snapshot must not vanish resolved local turns")
    }

    // Fresh snapshot containing everything by id: no duplication, snapshot order wins.
    func test_fresh_snapshot_with_same_ids_applies_cleanly() {
        let u1 = msg(.user, "q1")
        let a1 = msg(.assistant, "a1")
        let u2 = msg(.user, "q2")
        let a2 = msg(.assistant, "a2")
        let store = makeStore([u1, a1, u2, a2])

        let merged = store.mergedMacMessagesPreservingPending([u1, a1, u2, a2], replyArrived: false)

        XCTAssertEqual(merged.map(\.id), [u1, a1, u2, a2].map(\.id))
    }

    // Bridge-resolved replies keep their LOCAL placeholder UUID forever; the
    // snapshot carries the same reply under the Mac record id. Text-equivalence
    // must dedup — exactly one copy survives.
    func test_bridge_resolved_reply_dedups_by_text_when_ids_differ() {
        let u1 = msg(.user, "what's the plan")
        let localReply = msg(.assistant, "the plan is simple")           // local UUID
        let snapU1 = msg(.user, "what's the plan", id: u1.id)
        let snapReply = msg(.assistant, "the plan is simple")            // different (Mac) id
        let store = makeStore([u1, localReply])

        let merged = store.mergedMacMessagesPreservingPending([snapU1, snapReply], replyArrived: false)

        let copies = merged.filter { $0.role == .assistant && $0.text == "the plan is simple" }
        XCTAssertEqual(copies.count, 1, "equivalent assistant reply must not duplicate")
        XCTAssertEqual(copies.first?.id, snapReply.id, "snapshot copy is authoritative")
    }

    // Same for user messages whose optimistic local id never matched the Mac record id.
    func test_equivalent_user_message_dedups_when_ids_differ() {
        let localUser = msg(.user, "hello there")
        let snapUser = msg(.user, "hello there")  // different id, same text
        let snapReply = msg(.assistant, "hi the user")
        let store = makeStore([localUser])

        let merged = store.mergedMacMessagesPreservingPending([snapUser, snapReply], replyArrived: false)

        XCTAssertEqual(merged.filter { $0.role == .user && $0.text == "hello there" }.count, 1)
    }

    // Streaming placeholders are NOT "resolved" — the stale-snapshot guard must
    // not preserve them (the pending machinery owns their lifecycle).
    func test_streaming_placeholder_not_preserved_by_resolved_guard() {
        let u1 = msg(.user, "q")
        var placeholder = msg(.assistant, "")
        placeholder.isStreaming = true
        let store = makeStore([u1, placeholder])

        let merged = store.mergedMacMessagesPreservingPending([u1], replyArrived: false)

        XCTAssertFalse(merged.contains { $0.isStreaming },
                       "resolved-guard must not adopt streaming placeholders")
    }

    // Mixed case: stale snapshot during an active conversation — older resolved
    // turns preserved in original local order behind the snapshot content.
    func test_preserved_turns_keep_local_order() {
        let u1 = msg(.user, "q1")
        let a1 = msg(.assistant, "a1")
        let u2 = msg(.user, "q2")
        let a2 = msg(.assistant, "a2")
        let u3 = msg(.user, "q3")
        let a3 = msg(.assistant, "a3")
        let store = makeStore([u1, a1, u2, a2, u3, a3])

        let merged = store.mergedMacMessagesPreservingPending([u1, a1], replyArrived: false)

        XCTAssertEqual(merged.map(\.text), ["q1", "a1", "q2", "a2", "q3", "a3"])
    }

    // Mac snapshots are a suffix(80) window: local history longer than the
    // snapshot must stay chronological — recent local-only turns ride at their
    // local positions, NOT appended after the snapshot tail.
    func test_local_longer_than_snapshot_window_keeps_chronological_order() {
        let u1 = msg(.user, "old q")
        let a1 = msg(.assistant, "old a")
        let u2 = msg(.user, "new q")
        let a2 = msg(.assistant, "new a")
        let store = makeStore([u1, a1, u2, a2])
        // Snapshot window only contains the newest turn.
        let merged = store.mergedMacMessagesPreservingPending([u2, a2], replyArrived: false)

        XCTAssertEqual(merged.map(\.text), ["old q", "old a", "new q", "new a"])
    }

    // No tombstones: a local message older than the preserve window that the
    // snapshot doesn't contain defers to the snapshot (aged out or removed on
    // the Mac) — matches the pre-fix replace semantics.
    func test_old_unmatched_local_messages_defer_to_snapshot() {
        let uOld = msg(.user, "ancient q")
        let aOld = msg(.assistant, "ancient a")
        let u1 = msg(.user, "q1")
        let a1 = msg(.assistant, "a1")
        let store = makeStore([uOld, aOld, u1, a1])
        store.localArrivalDates[uOld.id] = .distantPast
        store.localArrivalDates[aOld.id] = .distantPast

        let merged = store.mergedMacMessagesPreservingPending([u1, a1], replyArrived: false)

        XCTAssertEqual(merged.map(\.id), [u1, a1].map(\.id),
                       "stale-beyond-window locals must not resurrect against the snapshot")
    }

    // Mac truncates snapshot content at 6,000 chars + marker. The truncated
    // snapshot copy must (a) match the fuller local copy (no duplicate) and
    // (b) never overwrite the fuller text the user already saw.
    func test_truncated_snapshot_copy_dedups_and_keeps_full_local_text() {
        let fullText = String(repeating: "x", count: 7_000)
        let truncated = String(fullText.prefix(6_000)) + "\n[truncated for iPhone snapshot]"
        let u1 = msg(.user, "long question")
        let localReply = msg(.assistant, fullText)             // local UUID (bridge-resolved)
        let snapU1 = msg(.user, "long question", id: u1.id)
        let snapReply = msg(.assistant, truncated)             // Mac id, truncated copy
        let store = makeStore([u1, localReply])

        let merged = store.mergedMacMessagesPreservingPending([snapU1, snapReply], replyArrived: false)

        let assistants = merged.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1, "truncated copy must dedup against the full local reply")
        XCTAssertEqual(assistants.first?.id, snapReply.id, "snapshot id is authoritative")
        XCTAssertEqual(assistants.first?.text, fullText, "fuller local text must win over the truncated copy")
    }

    // Repeated short replies ("ok") must bind positionally, not globally — a
    // second local "ok" matches the second snapshot "ok", neither vanishes.
    func test_repeated_identical_texts_bind_positionally() {
        let u1 = msg(.user, "ping")
        let a1 = msg(.assistant, "ok")
        let u2 = msg(.user, "ping again")
        let a2 = msg(.assistant, "ok")
        let store = makeStore([u1, a1, u2, a2])
        // Snapshot has both turns under Mac ids.
        let snap = [
            msg(.user, "ping", id: u1.id), msg(.assistant, "ok"),
            msg(.user, "ping again", id: u2.id), msg(.assistant, "ok"),
        ]

        let merged = store.mergedMacMessagesPreservingPending(snap, replyArrived: false)

        XCTAssertEqual(merged.map(\.text), ["ping", "ok", "ping again", "ok"])
        XCTAssertEqual(merged.filter { $0.role == .assistant }.count, 2)
    }

    // Round-3 regression (R3-B2): a SECOND recent local "ok" the snapshot
    // doesn't have yet must be preserved — the snapshot's single "ok" was
    // already consumed by the first local "ok", so the dup-guard must not
    // swallow the new one.
    func test_second_identical_recent_reply_not_dropped_by_dup_guard() {
        let u1 = msg(.user, "ping")
        let a1 = msg(.assistant, "ok")
        let u2 = msg(.user, "ping again")
        let a2 = msg(.assistant, "ok")              // just resolved, not in snapshot yet
        let store = makeStore([u1, a1, u2, a2])
        // Stale snapshot: only the first turn.
        let snap = [msg(.user, "ping", id: u1.id), msg(.assistant, "ok")]

        let merged = store.mergedMacMessagesPreservingPending(snap, replyArrived: false)

        XCTAssertEqual(merged.map(\.text), ["ping", "ok", "ping again", "ok"],
                       "second identical reply must survive a stale snapshot")
    }

    // Round-2 SF1 regression: a local twin of a snapshot row that was flushed
    // behind the cursor (order inversion) consumes that row instead of
    // duplicating.
    func test_local_twin_of_flushed_snapshot_row_does_not_duplicate() {
        let u1 = msg(.user, "alpha")
        let a1 = msg(.assistant, "alpha answer")
        let u2 = msg(.user, "beta")
        let a2 = msg(.assistant, "beta answer")     // local UUID (bridge-resolved)
        // Local order inverted vs snapshot: a2's turn before a1's.
        let store = makeStore([u2, a2, u1, a1])
        let snap = [
            msg(.user, "alpha", id: u1.id), msg(.assistant, "alpha answer", id: a1.id),
            msg(.user, "beta", id: u2.id), msg(.assistant, "beta answer"),  // Mac id
        ]

        let merged = store.mergedMacMessagesPreservingPending(snap, replyArrived: false)

        XCTAssertEqual(merged.filter { $0.text == "beta answer" }.count, 1,
                       "flushed snapshot twin must be consumed, not duplicated")
        XCTAssertEqual(merged.filter { $0.text == "alpha answer" }.count, 1)
    }

    // Round-4 regression (R4-B1): repeated identical user texts. The SECOND
    // local "ping" must NOT anchor to a stale snapshot that only contains the
    // FIRST "ping" — that anchor is how the previous reply mis-resolved the
    // new pending send.
    func test_user_occurrence_anchor_is_occurrence_aware() {
        let u1 = msg(.user, "ping")
        let a1 = msg(.assistant, "ok")
        let u2 = msg(.user, "ping")          // second identical send
        let store = makeStore([u1, a1, u2])

        let staleSnap = [msg(.user, "ping"), msg(.assistant, "ok")]   // Mac ids, first turn only
        XCTAssertNil(store.indexOfUserOccurrence(u2, in: staleSnap),
                     "second occurrence must not anchor to a snapshot holding only the first")

        let freshSnap = [
            msg(.user, "ping"), msg(.assistant, "ok"), msg(.user, "ping"),
        ]
        XCTAssertEqual(store.indexOfUserOccurrence(u2, in: freshSnap), 2,
                       "second occurrence anchors to the snapshot's second equivalent")
        XCTAssertEqual(store.indexOfUserOccurrence(u1, in: freshSnap), 0)
    }

    // Phase 2: typewriter chunking — words never split, backlog scales bites,
    // small remainders flush whole.
    func test_typewriter_chunk_pacing() {
        // Small remainder: everything at once.
        XCTAssertEqual(ChatStore.typewriterChunk(of: Substring("ok then")), "ok then")
        // Word boundary: chunk extends to include the space, never mid-word.
        let text = "alpha beta gamma delta epsilon zeta eta theta"
        let chunk = ChatStore.typewriterChunk(of: Substring(text))
        XCTAssertTrue(chunk.hasSuffix(" "), "chunk must end on a word boundary")
        XCTAssertTrue(text.hasPrefix(chunk))
        // Backlog scaling: a big remainder takes proportionally bigger bites.
        let big = String(repeating: "word ", count: 1_000)
        let bigChunk = ChatStore.typewriterChunk(of: Substring(big))
        XCTAssertGreaterThanOrEqual(bigChunk.count, big.count / 20)
        // No-whitespace tail: returns the rest rather than stalling forever.
        let solid = String(repeating: "x", count: 50)
        XCTAssertEqual(ChatStore.typewriterChunk(of: Substring(solid)), solid)
    }

    // Round-5 regression (R5-B1): a >6,000-char user send appears TRUNCATED in
    // the snapshot. The occurrence anchor must still find it, or pending
    // resolution stalls forever on long sends.
    func test_long_user_send_anchors_against_truncated_snapshot_copy() {
        let fullText = String(repeating: "q", count: 7_000)
        let truncated = String(fullText.prefix(6_000)) + "\n[truncated for iPhone snapshot]"
        let uLong = msg(.user, fullText)
        let store = makeStore([uLong])

        let snap = [msg(.user, truncated), msg(.assistant, "long answer")]

        XCTAssertEqual(store.indexOfUserOccurrence(uLong, in: snap), 0,
                       "truncated snapshot copy must anchor the long user send")
    }

    // Round-6 regression (R6-B1): two long sends sharing the same 6,000-char
    // prefix but differing afterwards form ONE symmetric equivalence class —
    // the second send must NOT anchor to a stale snapshot holding only the
    // first's truncated copy.
    func test_same_prefix_long_sends_rank_symmetrically() {
        let sharedPrefix = String(repeating: "p", count: 6_000)
        let sendA = msg(.user, sharedPrefix + "AAAA")
        let replyA = msg(.assistant, "answer A")
        let sendB = msg(.user, sharedPrefix + "BBBB")   // pending second send
        let store = makeStore([sendA, replyA, sendB])

        let truncated = sharedPrefix + "\n[truncated for iPhone snapshot]"
        let staleSnap = [msg(.user, truncated), msg(.assistant, "answer A")]

        XCTAssertNil(store.indexOfUserOccurrence(sendB, in: staleSnap),
                     "second same-prefix send must not anchor to the first's truncated row")

        let freshSnap = [
            msg(.user, truncated), msg(.assistant, "answer A"), msg(.user, truncated),
        ]
        XCTAssertEqual(store.indexOfUserOccurrence(sendB, in: freshSnap), 2)
    }

    func test_newChatRejectsLateDeltaFinalAndCancelFromPreviousSession() throws {
        let store = ChatStore(restoreQueuedSends: false)
        let originalSessionID = store.selectedSessionID
        let originalMainSessionID = store.mainSessionID
        let oldSessionID = "old-ios-session"
        var freshSessionID: String?
        defer {
            if let freshSessionID {
                UserDefaults.standard.removeObject(
                    forKey: store.transcriptStorageKey(for: freshSessionID)
                )
            }
            store.setSelectedSessionID(originalSessionID)
            store.replaceMainSessionID(originalMainSessionID)
        }

        store.setSelectedSessionID(oldSessionID)
        store.pendingICloudPlaceholders = [
            "old-delta": UUID(),
            "old-cancel": UUID(),
            "old-final-sessionless": UUID(),
        ]
        store.maxDeltaSeqByCorrelation["old-delta"] = 1
        store.isLoading = true

        store.startNewSession()

        freshSessionID = try XCTUnwrap(store.selectedSessionID)
        XCTAssertNotEqual(freshSessionID, oldSessionID)
        XCTAssertEqual(store.mainSessionID, freshSessionID)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.resolvedICloudReplyIds.contains("old-delta"))
        XCTAssertTrue(store.resolvedICloudReplyIds.contains("old-cancel"))
        XCTAssertTrue(store.resolvedICloudReplyIds.contains("old-final-sessionless"))

        let freshUser = msg(.user, "fresh question")
        var freshPlaceholder = msg(.assistant, "")
        freshPlaceholder.isStreaming = true
        store.messages = [freshUser, freshPlaceholder]
        store.pendingICloudPlaceholders["fresh-correlation"] = freshPlaceholder.id
        store.isLoading = true

        store.receiveICloudReply(.make(
            sender: "mac",
            text: "old partial",
            correlationID: "old-delta",
            metadata: ["kind": "text_delta", "seq": "2"]
        ))
        store.receiveICloudReply(.make(
            sender: "mac",
            text: "cancelled",
            sessionID: oldSessionID,
            correlationID: "old-cancel",
            metadata: ["kind": "cancelled"]
        ))
        store.receiveICloudReply(.make(
            sender: "mac",
            text: "old final without a session",
            correlationID: "old-final-sessionless",
            metadata: ["kind": "final"]
        ))
        store.receiveICloudReply(.make(
            sender: "mac",
            text: "old final",
            sessionID: oldSessionID,
            correlationID: "unknown-old-final",
            metadata: ["kind": "final"]
        ))

        XCTAssertEqual(store.selectedSessionID, freshSessionID)
        XCTAssertEqual(store.messages.map(\.id), [freshUser.id, freshPlaceholder.id])
        XCTAssertEqual(store.messages.last?.text, "")
        XCTAssertTrue(store.messages.last?.isStreaming == true)
        XCTAssertEqual(store.pendingICloudPlaceholders["fresh-correlation"], freshPlaceholder.id)
        XCTAssertTrue(store.isLoading, "old cancellation must not stop the fresh turn")

        store.receiveICloudReply(.make(
            sender: "mac",
            text: "fresh answer",
            sessionID: freshSessionID,
            correlationID: "fresh-correlation",
            metadata: ["kind": "final"]
        ))
        XCTAssertEqual(store.selectedSessionID, freshSessionID)
        XCTAssertEqual(store.messages.last?.text, "fresh answer")
        XCTAssertFalse(store.isLoading, "the current session's final reply must still resolve normally")
    }

    // An invalid/unsigned envelope may wake a KVS refresh, but it cannot replay
    // a locally pending message unless that refresh durably installs a different
    // key. A simulator without KVS change therefore surfaces re-pair guidance
    // and leaves no fresh send behind.
    func test_signatureSelfHeal_doesNotReplayWithoutDurableKeyChange() async {
        let store = ChatStore(restoreQueuedSends: false)
        let client = MacBridgeClient()   // held strong — pendingRetryClient is weak
        let pairing = PairingStore()     // held strong — pairingStoreRef is weak
        store.pendingRetryClient = client
        store.pairingStoreRef = pairing

        let correlation = "sig-fail-correlation"
        var placeholder = msg(.assistant, "")
        placeholder.isStreaming = true
        store.messages = [msg(.user, "signed question"), placeholder]
        store.isLoading = true
        store.pendingICloudPlaceholders[correlation] = placeholder.id
        store.pendingSendArgs[correlation] = ChatStore.PendingSendArgs(
            text: "signed question",
            sessionID: "session",
            controls: .defaults,
            attachments: [],
            appendedUserId: nil
        )

        store.receiveICloudRejection(ICloudBridgeRejectedMessage(
            messageID: "m1",
            correlationID: correlation,
            reason: "signature_invalid"
        ))

        // SYNCHRONOUS: reserve the one refresh attempt, but preserve local UI
        // state until the KVS result is known.
        XCTAssertTrue(store.retriedSignatureCorrelations.contains(correlation),
                      "the single refresh slot is reserved")
        XCTAssertNotNil(store.pendingICloudPlaceholders[correlation])
        XCTAssertTrue(store.isLoading)
        XCTAssertTrue(store.streamingHintsByMessageId.isEmpty,
                      "no retry send may fire before a durable key change")

        // Wait past the bounded KVS refresh. With no new KVS material, the
        // original placeholder becomes explicit re-pair guidance and no new
        // transport send is created.
        var refreshResolved = false
        for _ in 0..<600 {   // ~6s ceiling > 2s KVS-synchronize timeout
            await Task.yield()
            if store.pendingICloudPlaceholders[correlation] == nil {
                refreshResolved = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(refreshResolved)
        XCTAssertTrue(store.streamingHintsByMessageId.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.errorBanner, "Pairing out of sync — re-pair?")
    }

    func test_sharedIdentityUsesProfileNameAndNeutralFallback() {
        XCTAssertEqual(NativeAgentIdentity.displayName(nil), "NativeAgent")

        let profile = PersonalityProfile(
            name: "  River  ",
            personaKind: "custom",
            essence: "",
            voice: "",
            traits: PersonalityTraits(
                warmth: 0.5,
                directness: 0.5,
                humor: 0.5,
                proactivity: 0.5,
                rigor: 0.5,
                autonomy: 0.5,
                creativity: 0.5,
                brevity: 0.5
            )
        )
        XCTAssertEqual(NativeAgentIdentity.displayName(profile.name), "River")

        var genericProfile = profile
        genericProfile.name = "AI"
        XCTAssertEqual(NativeAgentIdentity.displayName(genericProfile.name), "NativeAgent")
    }
}

// MARK: - ios.sync fence evals (2026-08-23, coverage ledger wave A)
//
// Pure/injectable surfaces on the iOS↔Mac sync path whose failure mode is
// SILENT: a projection that mints a fresh id every refresh (duplicate
// transcript), a metadata dictionary that stops carrying the routing key
// (every Mac reply dropped), a formatter that prints "60s" instead of "1m",
// a timeout race that never fires (a wedged cloudd freezes the caller), an
// error enum with an empty sentence, and the one guard that keeps provider
// API keys off the iCloud wire entirely.
//
// Ledger rows: ios.macBridgeClient.projectChatRecords,
// shared.icloudConstants.mobileSourceKey (call site), ios.userDisplayFormatters,
// ios.ckLandmine.withCKTimeout / ios.diagnostics.withCKTimeout,
// ios.sync.syncError.userStrings, ios.sync.configureProvider.apiKeyRefusal.
@MainActor
final class ICloudSyncFenceLogicTests: XCTestCase {
    private func isolatedDefaults(_ label: String = #function) -> UserDefaults {
        let suite = "NativeAgentMobileTests.ICloudSyncFence.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "NativeAgent.unifiedSession.v1")
        return defaults
    }


    // MARK: ios.macBridgeClient.projectChatRecords

    private func record(
        id: String,
        role: String,
        content: String,
        attachments: [PersistedAttachmentRecord]? = nil
    ) -> ChatMessageRecord {
        ChatMessageRecord(
            id: id,
            sessionId: "sid-1",
            role: role,
            content: content,
            createdAt: "2026-08-23T09:00:00Z",
            metadata: attachments.map { ChatMessageRecordMetadata(attachments: $0) }
        )
    }

    /// A Mac-side id that IS a UUID must project to the same ChatMessage.id on
    /// every refresh — that stability is the only thing keeping a re-read of
    /// the transcript from appending a second copy of every message.
    func testUUIDBackedRecordsProjectToAStableIdentityAcrossRefreshes() {
        let stableID = UUID()
        let records = [record(id: stableID.uuidString, role: "assistant", content: "hi")]

        let first = MacBridgeClient.projectChatRecords(records)
        let second = MacBridgeClient.projectChatRecords(records)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].id, stableID)
        XCTAssertEqual(first.map(\.id), second.map(\.id),
                       "re-projecting the same records must not mint new identities")
        XCTAssertEqual(first[0].role, .assistant)
        XCTAssertEqual(first[0].text, "hi")
    }

    /// The `UUID(uuidString:) ?? UUID()` fallback is a live dedup landmine: a
    /// Mac id that is not a UUID gets a FRESH identity on every projection, so
    /// the same message can be appended twice. This test documents the hazard
    /// with teeth — if the fallback is ever made deterministic (a hash of the
    /// source id), this test fails and the fix gets an eval instead of a
    /// silent behaviour change.
    func testNonUUIDRecordIdsCurrentlyMintAFreshIdentityEveryProjection() {
        let records = [record(id: "msg_20260823_0001", role: "user", content: "hey")]

        let first = MacBridgeClient.projectChatRecords(records)
        let second = MacBridgeClient.projectChatRecords(records)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(
            first[0].id, second[0].id,
            "non-UUID Mac ids are not stable across projections — if this now passes, "
            + "the fallback became deterministic and the dedup story changed"
        )
    }

    /// Only user/assistant turns are renderable. A `system`/`tool` row must be
    /// dropped, not coerced into an assistant bubble that puts Mac-internal
    /// text in front of the user.
    func testNonRenderableRolesAreDroppedRatherThanCoerced() {
        let records = [
            record(id: UUID().uuidString, role: "system", content: "you are…"),
            record(id: UUID().uuidString, role: "tool", content: "{\"ok\":true}"),
            record(id: UUID().uuidString, role: "user", content: "hey"),
            record(id: UUID().uuidString, role: "Assistant", content: "wrong case"),
        ]
        let projected = MacBridgeClient.projectChatRecords(records)
        XCTAssertEqual(projected.count, 1, "only the exact-case user/assistant rows render")
        XCTAssertEqual(projected[0].role, .user)
    }

    /// Attachments must survive the refresh round trip; dropping them makes a
    /// photo the user sent vanish from history with no error.
    func testAttachmentSummariesSurviveTheRefreshProjection() {
        let records = [
            record(
                id: UUID().uuidString,
                role: "user",
                content: "look at this",
                attachments: [
                    PersistedAttachmentRecord(
                        id: "att-1",
                        type: "image",
                        mime: "image/jpeg",
                        name: "shot.jpg",
                        byteSize: 204_800,
                        path: nil
                    ),
                    // name omitted → must fall back, not collapse to empty.
                    PersistedAttachmentRecord(
                        id: "att-2",
                        type: "image",
                        mime: nil,
                        name: nil,
                        byteSize: nil,
                        path: nil
                    ),
                ]
            )
        ]
        let projected = MacBridgeClient.projectChatRecords(records)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].attachments.count, 2)
        XCTAssertEqual(projected[0].attachments[0].id, "att-1")
        XCTAssertEqual(projected[0].attachments[0].name, "shot.jpg")
        XCTAssertEqual(projected[0].attachments[0].byteSize, 204_800)
        XCTAssertEqual(projected[0].attachments[1].name, "attachment")
        XCTAssertNil(projected[0].attachments[1].byteSize)
    }

    // MARK: shared.icloudConstants.mobileSourceKey — the emitting call site

    /// Every outbound chat message carries the two keys the Mac addresses its
    /// reply with. If either stops being emitted the Mac's reply is addressed
    /// to nobody and the iOS receive filter drops it — chat looks like the Mac
    /// never answered.
    func testChatMetadataAlwaysCarriesTheRoutingKeysTheMacRepliesTo() {
        let metadata = ChatRuntimeControls.defaults.metadata(transport: "icloud")
        XCTAssertEqual(metadata["sourceKey"], NativeAgentICloudBridgeConstants.mobileSourceKey)
        XCTAssertEqual(metadata["routeKey"], ChatRuntimeControls.deviceSourceKey)
        XCTAssertEqual(metadata["transport"], "icloud")
        XCTAssertEqual(metadata["source"], "ios")
        XCTAssertEqual(metadata["clientSurface"], "iphone")
        XCTAssertFalse(metadata["routeKey"]?.isEmpty ?? true)
        XCTAssertTrue(
            NativeAgentICloudBridgeConstants.isMobileSourceKey(metadata["sourceKey"]),
            "the key we emit must be the key our own receive filter accepts"
        )
    }

    /// Blank control fields must be OMITTED, not sent as "". An empty `model`
    /// on the wire overrides the Mac's configured default with nothing and the
    /// turn silently runs on whatever the Mac falls back to.
    func testBlankRuntimeControlsAreOmittedRatherThanSentEmpty() {
        let blank = ChatRuntimeControls(
            model: "   ",
            reasoningEffort: "",
            serviceTier: "",
            fileAccess: "",
            providerId: ""
        )
        let metadata = blank.metadata(transport: "icloud")
        for key in ["model", "reasoningEffort", "serviceTier", "fileAccess", "providerId"] {
            XCTAssertNil(metadata[key], "\(key) must be omitted when blank, not sent empty")
        }
        // The routing keys are never optional.
        XCTAssertNotNil(metadata["sourceKey"])
        XCTAssertNotNil(metadata["routeKey"])

        let filled = ChatRuntimeControls(
            model: "  gpt-5.6-sol ",
            reasoningEffort: "high",
            serviceTier: "default",
            fileAccess: "auto",
            providerId: "openai"
        ).metadata(transport: "icloud")
        XCTAssertEqual(filled["model"], "gpt-5.6-sol", "values must be trimmed before the wire")
    }

    /// The per-device route key is what makes a reply land on THIS phone. An
    /// unnamed device must still get a usable key, never an empty string.
    func testDeviceRouteKeyIsNeverEmptyEvenForAnUnnamedDevice() {
        XCTAssertEqual(ChatRuntimeControls.makeDeviceSourceKey(deviceName: ""), "iphone")
        XCTAssertEqual(ChatRuntimeControls.makeDeviceSourceKey(deviceName: "   "), "iphone")
        XCTAssertEqual(ChatRuntimeControls.makeDeviceSourceKey(deviceName: " User's iPhone "), "iphone:User's iPhone")
        XCTAssertFalse(ChatRuntimeControls.deviceSourceKey.isEmpty)
    }

    // MARK: ios.userDisplayFormatters

    /// Duration boundaries. The rounding order is load-bearing: rounding after
    /// the branch prints "60s", which reads as a broken clock.
    func testDurationFormattingRoundsBeforeItBranches() {
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(0.44), "0.4s")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(4.62), "4.6s")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(9.99), "10.0s")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(10), "10s")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(59.5), "1m")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(134), "2m 14s")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(3600), "1h")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(3780), "1h 3m")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(7200), "2h")
        // Never render a raw seconds count above a minute.
        XCTAssertFalse(UserDisplayFormatters.humanizeDuration(59.5).hasSuffix("60s"))
    }

    /// Non-finite / negative durations must render as nothing rather than
    /// "nans" or "-1.0s" under a live progress row.
    func testDurationFormattingRefusesNonFiniteAndNegativeInput() {
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(.nan), "")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(.infinity), "")
        XCTAssertEqual(UserDisplayFormatters.humanizeDuration(-1), "")
    }

    /// Both Mac timestamp spellings must parse. A parser that only accepts one
    /// makes every relative timestamp on the phone silently fall back to the
    /// raw ISO string — legible, but wrong-looking, and it never raises.
    func testBothMacISOTimestampSpellingsParse() {
        XCTAssertNotNil(UserDisplayFormatters.parseISOTimestamp("2026-08-23T09:00:00Z"))
        XCTAssertNotNil(UserDisplayFormatters.parseISOTimestamp("2026-08-23T09:00:00.123Z"))
        XCTAssertNotNil(UserDisplayFormatters.parseISOTimestamp("  2026-08-23T09:00:00.123Z  "))
        XCTAssertNil(UserDisplayFormatters.parseISOTimestamp(""))
        XCTAssertNil(UserDisplayFormatters.parseISOTimestamp("not-a-date"))

        // Unparseable input returns the raw value — dropping the field is worse.
        XCTAssertEqual(UserDisplayFormatters.humanizeISOTimestamp("not-a-date"), "not-a-date")
        XCTAssertEqual(UserDisplayFormatters.humanizeISOTimestamp("   "), "")
        let relative = UserDisplayFormatters.humanizeISOTimestamp("2026-08-23T09:00:00.123Z")
        XCTAssertFalse(relative.isEmpty)
        XCTAssertFalse(relative.contains("2026-08-23T"), "a parsed timestamp must not render as raw ISO")
    }

    // MARK: ios.ckLandmine.withCKTimeout / ios.diagnostics.withCKTimeout

    /// The guard returns Optional-nil for THREE different reasons and every
    /// caller sees the same nil. All three are pinned here so a regression in
    /// any one of them cannot hide behind the other two.
    func testCKTimeoutReturnsTheValueOnSuccess() async {
        let value = await withCKTimeout("eval.success", seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testCKTimeoutReturnsNilWhenTheWorkThrows() async {
        struct Boom: Error {}
        let value: Int? = await withCKTimeout("eval.throws", seconds: 5) { throw Boom() }
        XCTAssertNil(value)
    }

    /// The one that actually matters: a wedged cloudd must NOT hold the caller.
    /// The work here sleeps far longer than the budget; the race must win.
    /// The bound is deliberately loose (structural proof, not a perf assertion)
    /// — the point is "it returned at all", not "it returned in exactly 200ms".
    func testCKTimeoutAbandonsWedgedWorkInsteadOfBlockingTheCaller() async {
        let started = Date()
        let value: Int? = await withCKTimeout("eval.wedged", seconds: 0.2) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return 7
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(value, "a wedged call must surface as nil, not the late value")
        XCTAssertLessThan(elapsed, 10, "the timeout race never fired — the caller was held by the work")
    }

    // MARK: ios.sync.syncError.userStrings

    /// Every SyncError case must produce a sentence, and the two the user is
    /// most likely to hit must tell them what to DO. A swallowed case renders
    /// as an empty toast, which is indistinguishable from success.
    func testEverySyncErrorCaseRendersAnActionableSentence() {
        let cases: [SyncError] = [
            .notSetup,
            .notSigned,
            .timeout("Mac did not return a response."),
            .persistence("could not write responses/1.json"),
            .busy("another action is still in flight"),
            .unsupported("API keys cannot be sent through iCloud."),
        ]
        var seen = Set<String>()
        for error in cases {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error) has no user-facing description")
            XCTAssertTrue(seen.insert(text).inserted, "duplicate user string: \(text)")
        }
        // The two fixed sentences name the recovery action.
        XCTAssertTrue(SyncError.notSetup.errorDescription?.contains("iCloud Drive") == true)
        XCTAssertTrue(SyncError.notSigned.errorDescription?.contains("QR code") == true)
        // The message-carrying cases pass the message through verbatim.
        XCTAssertEqual(SyncError.timeout("boom").errorDescription, "boom")
        XCTAssertEqual(SyncError.busy("wait").errorDescription, "wait")
        XCTAssertEqual(SyncError.persistence("disk").errorDescription, "disk")
        XCTAssertEqual(SyncError.unsupported("nope").errorDescription, "nope")
    }

    // MARK: ios.sync.configureProvider.apiKeyRefusal

    /// The single `if` that keeps provider API keys off the iCloud wire. It
    /// must refuse BEFORE any envelope is built, so the key never reaches a
    /// signed message, a Drive file, or a CloudKit record. If the guard is
    /// removed the call falls through to the transport and fails with a
    /// DIFFERENT error (`.notSetup`), which is exactly what this asserts
    /// against.
    func testConfigureProviderRefusesAnAPIKeyBeforeAnythingIsSent() async {
        do {
            _ = try await iCloudSyncEngine.shared.configureProvider(
                providerId: "openai",
                apiKey: "sk-live-DO-NOT-SHIP",
                authMode: "api_key"
            )
            XCTFail("configureProvider must refuse to carry an API key over iCloud")
        } catch let error as SyncError {
            guard case .unsupported(let message) = error else {
                return XCTFail("expected .unsupported, got \(error) — the refusal guard did not fire first")
            }
            XCTAssertTrue(message.contains("API keys cannot be sent through iCloud"))
            XCTAssertTrue(message.contains("Mac"), "the refusal must tell the user where keys DO get saved")
            XCTAssertFalse(message.contains("sk-live-DO-NOT-SHIP"), "the refusal must not echo the key")
        } catch {
            XCTFail("expected SyncError.unsupported, got \(error)")
        }
    }

    // Coverage ledger: ios.screens / ios.chat.deepLinkSendHook
    func testLaunchInjectedSendHookAddsTheExactUserMessageAndConsumesItOnce() {
        let store = ChatStore(defaults: isolatedDefaults(), restoreQueuedSends: false)
        let client = MacBridgeClient()
        let notificationCenter = NotificationCenter()
        let text = "launch-hook message"

        NativeAgentDeepLinkSendHook.stageLaunchArguments(
            ["NativeAgentMobile", "-sendTestMessage", text],
            notificationCenter: notificationCenter
        )
        let disposition = NativeAgentDeepLinkSendHook.deliverPending(
            to: store,
            client: client,
            controls: .defaults,
            emitHaptic: false
        )
        XCTAssertNotNil(disposition)
        XCTAssertEqual(store.messages.first(where: { $0.role == .user })?.text, text)
        XCTAssertNil(
            NativeAgentDeepLinkSendHook.deliverPending(
                to: store,
                client: client,
                controls: .defaults,
                emitHaptic: false
            ),
            "the process launch hook must not replay the same injected turn"
        )
        store.sendTask?.cancel()
    }
}
