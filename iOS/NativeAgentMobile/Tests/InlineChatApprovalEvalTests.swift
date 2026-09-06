import Foundation
import NativeAgentShared
import XCTest
@testable import NativeAgentMobile

/// Sweep 2026-09-01 item 36 — `ios.chat.inlineApproval`.
///
/// Silent-failure class: INVISIBLE BLOCK. The Mac renders the approval a turn
/// is waiting on straight onto that turn (MacChatTurnApproval); iOS chat had
/// zero approval references, so a blocked turn looked exactly like a slow one
/// and the only recovery was to guess and switch to the Activity tab.
///
/// The risk of fixing it is the mirror image: a bubble that shows SOMEONE
/// ELSE'S approval, or a settled one, or one this phone is not allowed to
/// resolve. These fence the projection that decides what appears.
final class InlineChatApprovalEvalTests: XCTestCase {

    private func approval(
        id: String,
        session: String?,
        status: String = "pending",
        decision: String? = nil,
        localOnly: Bool? = false,
        remoteResolvable: Bool? = true
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            title: "Run \(id)",
            action: "shell",
            risk: "high",
            reason: "needs a person",
            status: status,
            createdAt: "2026-09-01T00:00:00Z",
            decision: decision,
            localOnly: localOnly,
            remoteResolvable: remoteResolvable,
            chatOriginSessionId: session
        )
    }

    func test_onlyThisConversationsUndecidedApprovalsReachTheBubble() {
        let rows = [
            approval(id: "mine", session: "session-A"),
            approval(id: "other-chat", session: "session-B"),
            approval(id: "not-a-chat-approval", session: nil),
            approval(id: "already-approved", session: "session-A", status: "resolved", decision: "approved"),
            approval(id: "settled-unreadably", session: "session-A", status: "pending", decision: "???"),
        ]

        let visible = MobileChatApprovalProjection.pendingApprovals(
            sessionId: "session-A", approvals: rows
        )
        XCTAssertEqual(
            visible.map(\.id), ["mine"],
            "a chat bubble must only ever show this conversation's own live question"
        )
    }

    func test_anUnidentifiedSessionShowsNothingRatherThanEverything() {
        let rows = [approval(id: "mine", session: "session-A")]
        XCTAssertTrue(MobileChatApprovalProjection.pendingApprovals(sessionId: nil, approvals: rows).isEmpty)
        XCTAssertTrue(MobileChatApprovalProjection.pendingApprovals(sessionId: "", approvals: rows).isEmpty)
        XCTAssertTrue(MobileChatApprovalProjection.pendingApprovals(sessionId: "   ", approvals: rows).isEmpty)
    }

    /// The iOS transcript has no per-message timestamps, so the only turn the
    /// phone can PROVE is the newest assistant turn. The anchor must be that
    /// turn and never an arbitrary older bubble.
    func test_theCardAnchorsToTheNewestAssistantTurn() {
        let older = ChatMessage(role: .assistant, text: "first answer")
        let user = ChatMessage(role: .user, text: "and now this")
        let newest = ChatMessage(role: .assistant, text: "", isStreaming: true)

        XCTAssertEqual(
            MobileChatApprovalProjection.anchorMessageID(in: [older, user, newest]),
            newest.id
        )
        // No assistant turn yet (she asked before saying anything): fall back
        // to the last bubble on screen rather than dropping the card.
        XCTAssertEqual(MobileChatApprovalProjection.anchorMessageID(in: [user]), user.id)
        XCTAssertNil(MobileChatApprovalProjection.anchorMessageID(in: []))
    }

    /// One predicate, one meaning. The bubble may not unlock a decision the
    /// Activity tab would refuse.
    func test_thePhoneDecidesOnlyWhatTheActivityTabWouldAlsoLetItDecide() {
        XCTAssertTrue(MobileChatApprovalProjection.canDecideOnPhone(
            approval(id: "ok", session: "s", localOnly: false, remoteResolvable: true)
        ))
        for (localOnly, remoteResolvable) in [
            (true, true), (false, false), (nil, true), (false, nil), (nil, nil),
        ] as [(Bool?, Bool?)] {
            XCTAssertFalse(
                MobileChatApprovalProjection.canDecideOnPhone(
                    approval(id: "partial", session: "s", localOnly: localOnly, remoteResolvable: remoteResolvable)
                ),
                "localOnly=\(String(describing: localOnly)) remoteResolvable=\(String(describing: remoteResolvable)) must stay Mac-only"
            )
        }
    }

    /// The bubble is a second SURFACE, never a second AUTHORITY: it dispatches
    /// the identical signed action the Activity tab does, and the canonical
    /// list stays where it was.
    func test_inlineDecisionsUseTheSameSignedActionPathAsTheActivityTab() throws {
        let bubbles = try MobileEvalSources.mobileSource("ChatBubbleViews.swift")
        for call in [
            "iCloudSyncEngine.shared.approveApproval(id: id)",
            "iCloudSyncEngine.shared.rejectApproval(id: id)",
        ] {
            XCTAssertTrue(bubbles.contains(call), "the inline card lost \(call)")
        }
        XCTAssertFalse(
            bubbles.contains("sendAction("),
            "the inline card must not hand-roll an action envelope of its own"
        )

        let activity = try MobileEvalSources.mobileSource("ActivityView.swift")
        for call in [
            "iCloudSyncEngine.shared.approveApproval(id: id)",
            "iCloudSyncEngine.shared.rejectApproval(id: id)",
        ] {
            XCTAssertTrue(activity.contains(call), "the Activity tab must stay the canonical decision surface")
        }

        let chat = try MobileEvalSources.mobileSource("ChatView.swift")
        XCTAssertTrue(
            chat.contains("InlineChatApprovalCard(approval: approval)"),
            "the chat transcript must actually render the inline approval card"
        )
    }
}
