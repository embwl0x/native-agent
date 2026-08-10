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

    // F3-H1 (round-3 audit): the HMAC signature self-heal retry must sign with
    // the REFRESHED secret. The retry send is nested inside the refresh Task
    // (`await refreshFromKVS(); send(...)`), so it runs strictly AFTER the KVS
    // refresh completes. This pins that ordering: the retry send does NOT fire
    // synchronously from receiveICloudRejection — the pre-fix bug, where a
    // detached `Task { await refreshFromKVS() }` was followed by an immediate
    // synchronous `send(...)`. That send re-signed with the STALE secret while
    // the refresh Task was still suspended at the KVS synchronize; with the
    // single retry slot already consumed, the second signature_invalid rejection
    // fell through to failPendingReply and the message was permanently dropped
    // on exactly the stale-secret event this path exists to heal.
    func test_signatureSelfHeal_retrySendRunsAfterKVSRefresh() async {
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
        store.streamingHintsByMessageId[placeholder.id] = "Sending"
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

        // SYNCHRONOUS: the retry slot is consumed and the old placeholder torn
        // down immediately, but the actual send is deferred behind the refresh
        // await. Pre-fix, send() ran here synchronously — appending a fresh
        // streaming placeholder and setting isLoading=true while signing with
        // the stale secret. These assertions fail against the pre-fix ordering.
        XCTAssertTrue(store.retriedSignatureCorrelations.contains(correlation),
                      "the single retry slot is consumed")
        XCTAssertNil(store.pendingICloudPlaceholders[correlation],
                     "old placeholder removed during synchronous cleanup")
        XCTAssertFalse(store.isLoading,
                       "cleanup ran; the retry send has NOT fired yet")
        XCTAssertTrue(store.messages.allSatisfy { !$0.isStreaming },
                      "no new streaming placeholder — send is deferred behind refreshFromKVS()")
        XCTAssertTrue(store.streamingHintsByMessageId.isEmpty,
                      "no 'Sending' hint yet — the retry send has not run")

        // Drain the MainActor until the refresh Task resolves and the deferred
        // send fires. Bounded (no blind sleep). Ceiling is comfortably past the
        // refresh's internal KVS-synchronize timeout (2s) — on a simulator with
        // no live iCloud, refreshFromKVS resolves via that timeout, then send
        // runs; the ceiling must exceed it so we observe the send, not a false
        // negative from exiting on the same 2s boundary.
        //
        // The signal is `streamingHintsByMessageId` becoming non-empty: send()
        // sets it ("Sending") synchronously at the head of its body, and the
        // fast-fail path (no iCloud in the simulator → sendMessage throws) tears
        // the placeholder down and flips isLoading back to false WITHOUT
        // clearing this hint. So isLoading / isStreaming are transient and race
        // the failure teardown, but the hint durably records that the retry send
        // ran — which is exactly what we need to prove (send fired post-refresh,
        // the message was not dropped). We assert it was empty synchronously
        // above, so its appearance here is unambiguously the retry send.
        var sendFired = false
        for _ in 0..<600 {   // ~6s ceiling > 2s KVS-synchronize timeout
            await Task.yield()
            if !store.streamingHintsByMessageId.isEmpty
                || store.isLoading
                || store.messages.contains(where: { $0.isStreaming }) {
                sendFired = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sendFired,
                      "the retry send fires AFTER refreshFromKVS completes — the message is not dropped")
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
