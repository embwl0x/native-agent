import Foundation
import XCTest
import NativeAgentShared
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`.
///
/// Direct state-machine proof for iPhone chat receipts.  The live iCloud
/// listener is deliberately outside this test: these tests construct the
/// exact signed-message projection after transport validation, then assert the
/// visible store transition.  That keeps a duplicate/late event from looking
/// like a second answer just because its transport delivery succeeded.
///
/// Ledger row directly covered here:
///   * `ios.chatStore.textDeltaSeqGate`
///   * `ios.chatStore.replyTimeoutAndPoll`
///
/// The final/new-session cases are deliberately adjacent state-owner proof;
/// they should not be used as a substitute for a real session-tab UI action.
@MainActor
final class ChatReceiptStateMachineEvalTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "NativeAgentMobileTests.chatReceiptState.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "NativeAgent.unifiedSession.v1")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeStore(timeout: UInt64 = 180) -> ChatStore {
        ChatStore(
            defaults: defaults,
            restoreQueuedSends: false,
            iCloudReplyTimeoutSeconds: timeout
        )
    }

    private func pendingStore(
        sessionID: String = "phone-session",
        correlationID: String = "turn-1",
        timeout: UInt64 = 180
    ) -> (store: ChatStore, placeholder: ChatMessage) {
        let store = makeStore(timeout: timeout)
        store.setSelectedSessionID(sessionID)
        let user = ChatMessage(role: .user, text: "Please check that")
        let placeholder = ChatMessage(role: .assistant, text: "", isStreaming: true)
        store.messages = [user, placeholder]
        store.isLoading = true
        store.pendingICloudPlaceholders[correlationID] = placeholder.id
        store.pendingSendArgs[correlationID] = ChatStore.PendingSendArgs(
            text: user.text,
            sessionID: sessionID,
            controls: .defaults,
            attachments: [],
            appendedUserId: user.id
        )
        store.streamingHintsByMessageId[placeholder.id] = "Checking"
        return (store, placeholder)
    }

    private func installReplyWaits(on store: ChatStore, correlationID: String) {
        store.pendingTimeouts[correlationID] = Task { }
        store.pendingPolls[correlationID] = Task { }
    }

    private func assertNoReplyWaits(
        _ store: ChatStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(store.pendingTimeouts.isEmpty, file: file, line: line)
        XCTAssertTrue(store.pendingPolls.isEmpty, file: file, line: line)
    }

    func test_finalReceiptResolvesOneOptimisticBubbleExactlyOnce() throws {
        let correlationID = "turn-final"
        let (store, placeholder) = pendingStore(correlationID: correlationID)
        installReplyWaits(on: store, correlationID: correlationID)
        store.maxDeltaSeqByCorrelation[correlationID] = 4

        let final = BridgeMessage.make(
            sender: "mac",
            text: "Everything is ready.",
            sessionID: "phone-session",
            correlationID: correlationID,
            metadata: ["kind": "final"]
        )
        store.receiveICloudReply(final)
        store.receiveICloudReply(final) // iCloud may redeliver after an observer rebind.

        XCTAssertEqual(store.messages.count, 2, "a duplicate final receipt appended a second visible answer")
        XCTAssertEqual(store.messages.last?.id, placeholder.id)
        XCTAssertEqual(store.messages.last?.text, "Everything is ready.")
        XCTAssertFalse(store.messages.last?.isStreaming ?? true)
        XCTAssertTrue(store.pendingICloudPlaceholders.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.resolvedICloudReplyIds.contains(correlationID))
        XCTAssertNil(store.maxDeltaSeqByCorrelation[correlationID], "a completed turn left stream sequence state behind")
        XCTAssertNil(store.streamingHintsByMessageId[placeholder.id])
        assertNoReplyWaits(store)
    }

    func test_everyReplyTerminalRetiresItsTimeoutAndPollTogether() async {
        let errorID = "turn-error"
        let (errorStore, _) = pendingStore(correlationID: errorID)
        installReplyWaits(on: errorStore, correlationID: errorID)
        errorStore.receiveICloudReply(.make(
            sender: "mac", text: "provider unavailable", sessionID: "phone-session",
            correlationID: errorID, metadata: ["kind": "error"]
        ))
        assertNoReplyWaits(errorStore)

        let rejectionID = "turn-rejection"
        let (rejectionStore, _) = pendingStore(correlationID: rejectionID)
        installReplyWaits(on: rejectionStore, correlationID: rejectionID)
        rejectionStore.receiveICloudRejection(ICloudBridgeRejectedMessage(
            messageID: "rejected-message",
            correlationID: rejectionID,
            reason: "signature mismatch"
        ))
        assertNoReplyWaits(rejectionStore)

        let cancelledID = "turn-cancelled"
        let (cancelledStore, _) = pendingStore(correlationID: cancelledID)
        installReplyWaits(on: cancelledStore, correlationID: cancelledID)
        cancelledStore.receiveICloudReply(.make(
            sender: "mac", text: "", sessionID: "phone-session",
            correlationID: cancelledID, metadata: ["kind": "cancelled"]
        ))
        assertNoReplyWaits(cancelledStore)

        let timedOutID = "turn-timeout"
        let (timedOutStore, timedOutPlaceholder) = pendingStore(
            correlationID: timedOutID,
            timeout: 0
        )
        installReplyWaits(on: timedOutStore, correlationID: timedOutID)
        timedOutStore.armTimeout(for: timedOutID, placeholderId: timedOutPlaceholder.id)
        for _ in 0..<50 where timedOutStore.pendingICloudPlaceholders[timedOutID] != nil {
            await Task.yield()
        }
        XCTAssertNil(timedOutStore.pendingICloudPlaceholders[timedOutID])
        assertNoReplyWaits(timedOutStore)

        let sessionID = "turn-session-switch"
        let (sessionStore, _) = pendingStore(correlationID: sessionID)
        installReplyWaits(on: sessionStore, correlationID: sessionID)
        sessionStore.startNewSession()
        assertNoReplyWaits(sessionStore)
    }

    func test_lateDeltaCannotRewriteTheCompletedReceipt() throws {
        let correlationID = "turn-late-delta"
        let (store, placeholder) = pendingStore(correlationID: correlationID)
        store.receiveICloudReply(.make(
            sender: "mac",
            text: "The complete answer.",
            sessionID: "phone-session",
            correlationID: correlationID,
            metadata: ["kind": "final"]
        ))

        store.receiveICloudReply(.make(
            sender: "mac",
            text: "Old partial answer",
            sessionID: "phone-session",
            correlationID: correlationID,
            metadata: ["kind": "text_delta", "seq": "99"]
        ))

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.last?.id, placeholder.id)
        XCTAssertEqual(store.messages.last?.text, "The complete answer.")
        XCTAssertFalse(store.messages.last?.isStreaming ?? true)
        XCTAssertNil(store.maxDeltaSeqByCorrelation[correlationID])
    }

    func test_deltaSequenceIsStrictAndMalformedUpdatesAreDropped() {
        let correlationID = "turn-sequence"
        let (store, placeholder) = pendingStore(correlationID: correlationID)

        store.receiveICloudReply(.make(
            sender: "mac",
            text: "newer accumulated text",
            sessionID: "phone-session",
            correlationID: correlationID,
            metadata: ["kind": "text_delta", "seq": "2"]
        ))
        store.cancelTypewriter(placeholder.id)
        XCTAssertEqual(store.maxDeltaSeqByCorrelation[correlationID], 2)

        store.receiveICloudReply(.make(
            sender: "mac",
            text: "older accumulated text",
            sessionID: "phone-session",
            correlationID: correlationID,
            metadata: ["kind": "text_delta", "seq": "1"]
        ))
        store.receiveICloudReply(.make(
            sender: "mac",
            text: "malformed accumulated text",
            sessionID: "phone-session",
            correlationID: correlationID,
            metadata: ["kind": "text_delta", "seq": "not-an-integer"]
        ))

        XCTAssertEqual(store.maxDeltaSeqByCorrelation[correlationID], 2)
        XCTAssertEqual(store.messages.last?.id, placeholder.id)
        XCTAssertTrue(store.messages.last?.isStreaming ?? false)
    }

    func test_newSessionRetiresEveryOldReceiptBeforeItCanTouchTheFreshTranscript() throws {
        let oldCorrelation = "old-turn"
        let (store, _) = pendingStore(sessionID: "old-session", correlationID: oldCorrelation)
        store.maxDeltaSeqByCorrelation[oldCorrelation] = 2

        store.startNewSession()
        let freshSession = try XCTUnwrap(store.selectedSessionID)
        XCTAssertNotEqual(freshSession, "old-session")
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.resolvedICloudReplyIds.contains(oldCorrelation))
        XCTAssertNil(store.maxDeltaSeqByCorrelation[oldCorrelation])

        store.receiveICloudReply(.make(
            sender: "mac",
            text: "Old answer that must not appear in a new chat",
            sessionID: "old-session",
            correlationID: oldCorrelation,
            metadata: ["kind": "final"]
        ))

        XCTAssertEqual(store.selectedSessionID, freshSession)
        XCTAssertTrue(store.messages.isEmpty, "a retired session wrote into the brand-new transcript")
    }

    func test_unknownCorrelationDoesNotResolveOrReplaceTheActiveOptimisticTurn() {
        let (store, placeholder) = pendingStore(correlationID: "active-turn")

        store.receiveICloudReply(.make(
            sender: "mac",
            text: "An unrelated Mac announcement",
            sessionID: "phone-session",
            correlationID: "unknown-turn",
            metadata: ["kind": "final"]
        ))

        XCTAssertEqual(store.pendingICloudPlaceholders["active-turn"], placeholder.id)
        XCTAssertTrue(store.messages.contains(where: { $0.id == placeholder.id && $0.isStreaming }))
        XCTAssertTrue(store.isLoading, "an unknown receipt completed the user's actual pending turn")
        XCTAssertEqual(
            store.messages.filter { $0.role == .assistant && $0.text == "An unrelated Mac announcement" }.count,
            1,
            "an unrelated but valid Mac message should remain visible once, not be mistaken for the active answer"
        )
    }
}
