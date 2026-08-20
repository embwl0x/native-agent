import Foundation
import Testing
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
@testable import NativeAgentApp

/// Desk 658.12 — the canonical approval, projected into the turn card.
///
/// These pin four things: the projection reads the inbox and invents nothing;
/// an unprovable outcome never renders as approved; a stale turn's approval
/// cannot enter the current card; and the wiring that makes any of it reachable
/// in the running app actually exists.
@Suite("Mac Chat turn card approvals", .serialized)
struct MacChatTurnCardApprovalTests {

    // MARK: - Projection from the canonical row

    @Test func aPendingApprovalBecomesAFirstClassCardStateWithDecisionAffordances() throws {
        let state = liveState(session: "s", turn: "t", startedAt: 0)
        let card = try #require(project(
            state,
            at: 5,
            approvals: [row(id: "a1", session: "s", createdAt: 1, status: "pending")]
        ))

        let approval = try #require(card.approval)
        #expect(approval.approvalId == "a1")
        #expect(approval.outcome == .pending)
        #expect(approval.isActionable)
        #expect(card.title == "Approve mac_inject_text?")
        #expect(card.tone == .attention)
        #expect(card.symbolName == "lock.shield")
        // Waiting on a person is not motion.
        #expect(card.showsLiveIndicator == false)
        // A live card is clickable; so is a settled one that still holds a
        // pending decision.
        #expect(card.hasControls)
    }

    @Test func aTurnWaitingOnAnApprovalKeepsItsCardAfterTheTurnItselfCompletes() throws {
        // The non-blocking filer means the turn can finish while the person has
        // not decided. The question outlives the turn, so the card must too.
        let settled = completedState(session: "s", turn: "t", startedAt: 0)
        let pending = row(id: "a1", session: "s", createdAt: 1, status: "pending")

        #expect(MacChatTurnCardProjection.isVisible(settled, sessionId: "s") == false)
        #expect(MacChatTurnCardProjection.isVisible(settled, sessionId: "s", approvals: [pending]))
        let card = try #require(project(settled, at: 5, approvals: [pending]))
        #expect(card.approval?.outcome == .pending)
        #expect(card.hasControls)
    }

    @Test func aProvenDecisionAddsNoChromeToAFinishedTurn() throws {
        let settled = completedState(session: "s", turn: "t", startedAt: 0)
        for decision in ["approved", "denied"] {
            let resolved = row(
                id: "a1", session: "s", createdAt: 1,
                status: "resolved", decision: decision
            )
            #expect(
                MacChatTurnCardProjection.isVisible(settled, sessionId: "s", approvals: [resolved]) == false,
                "a proven \(decision) decision must not float permanent chrome over the transcript"
            )
            #expect(project(settled, at: 5, approvals: [resolved]) == nil)
        }
    }

    // MARK: - Honest terminals

    @Test func everyOutcomeIsReadFromTheRowAndUnprovableOnesAreNeverApproved() throws {
        let cases: [(status: String, decision: String?, expected: MacChatTurnCardApproval.Outcome)] = [
            ("pending", nil, .pending),
            ("resolved", "approved", .approved),
            ("resolved", "denied", .denied),
            ("resolved", "rejected", .denied),
            ("canceled", "canceled", .expired),
            ("expired", nil, .expired),
            // Settled with nothing readable: the whole point of this unit.
            ("resolved", nil, .unresolved),
            ("orphaned", nil, .unresolved),
            ("", nil, .unresolved),
            ("weird_future_status", nil, .unresolved),
            ("pending", "something_unreadable", .unresolved),
        ]
        for testCase in cases {
            let outcome = MacChatTurnApprovalProjection.outcome(for: row(
                id: "a", session: "s", createdAt: 1,
                status: testCase.status, decision: testCase.decision
            ))
            #expect(
                outcome == testCase.expected,
                "status=\(testCase.status) decision=\(testCase.decision ?? "nil") projected \(outcome)"
            )
            if testCase.expected != .approved {
                #expect(outcome != .approved, "an unproven outcome rendered as approved")
            }
        }
    }

    @Test func anUnprovenOutcomeKeepsTheCardAndReadsNeitherGreenNorRed() throws {
        let settled = completedState(session: "s", turn: "t", startedAt: 0)
        for status in ["resolved", "orphaned", "expired"] {
            let unproven = row(id: "a1", session: "s", createdAt: 1, status: status)
            let card = try #require(
                project(settled, at: 5, approvals: [unproven]),
                "\(status) must keep its card"
            )
            #expect(card.tone == .unresolved)
            #expect(card.approval?.isActionable == false)
            // Nothing to click on an unresolved settled card.
            #expect(card.hasControls == false)
            #expect(!card.title.lowercased().contains("approved "))
        }
    }

    @Test func everyOutcomeHasItsOwnWordsAndSymbol() throws {
        var titles: [String: MacChatTurnCardApproval.Outcome] = [:]
        var symbols: [String: MacChatTurnCardApproval.Outcome] = [:]
        let outcomes: [MacChatTurnCardApproval.Outcome] =
            [.pending, .approved, .denied, .expired, .unresolved]
        for outcome in outcomes {
            let approval = MacChatTurnCardApproval(
                approvalId: "a", toolName: "mac_inject_text", reason: nil, outcome: outcome
            )
            let title = MacChatTurnCardProjection.approvalTitle(for: approval)
            let symbol = MacChatTurnCardProjection.symbolName(forApproval: approval)
            #expect(titles[title] == nil, "\(outcome) reuses \(titles[title]!)'s words: \(title)")
            #expect(symbols[symbol] == nil, "\(outcome) reuses \(symbols[symbol]!)'s symbol: \(symbol)")
            titles[title] = outcome
            symbols[symbol] = outcome
            #expect(!MacChatTurnCardProjection.approvalDetail(for: approval).isEmpty)
            #expect(!approval.badge.isEmpty)
        }
        #expect(titles.count == outcomes.count)
    }

    // MARK: - Fences

    @Test func aStaleTurnsApprovalCannotEnterTheReplacementTurnsCard() throws {
        // The approval was filed by the turn that has since been replaced. It
        // stays in Activity → Approvals; it does not follow the user forward.
        let stale = row(id: "old", session: "s", createdAt: 1, status: "pending")
        let replacement = liveState(session: "s", turn: "turn-new", startedAt: 10)

        #expect(MacChatTurnApprovalProjection.approval(
            sessionId: "s", turnStartedAt: time(10), approvals: [stale]
        ) == nil)
        let card = try #require(project(replacement, at: 12, approvals: [stale]))
        #expect(card.approval == nil)
        #expect(card.title.contains("Agent"))

        // NEGATIVE CONTROL: the same row, filed after the replacement turn
        // opened, is exactly what this card SHOULD adopt — so the fence above
        // is proving provenance, not just returning nil for everything.
        let fresh = row(id: "new", session: "s", createdAt: 11, status: "pending")
        let adopted = try #require(project(replacement, at: 12, approvals: [fresh]))
        #expect(adopted.approval?.approvalId == "new")
    }

    @Test func anotherSessionsApprovalNeverCrossesIntoThisCard() throws {
        let state = liveState(session: "session-a", turn: "t", startedAt: 0)
        let foreign = row(id: "other", session: "session-b", createdAt: 1, status: "pending")
        // A non-chat approval (workshop step, memory proposal) carries no chat
        // origin at all and is equally out of bounds.
        let nonChat = ApprovalRequest(
            id: "workshop", title: "Approve step", action: "workshop_step",
            risk: "confirm", status: "pending",
            createdAt: MacChatTurnApprovalTestSupport.iso(time(1)),
            chatOriginSessionId: nil
        )

        let card = try #require(project(state, at: 2, approvals: [foreign, nonChat]))
        #expect(card.approval == nil)
    }

    @Test func aRowWithNoReadableCreationTimeFailsClosed() throws {
        let state = liveState(session: "s", turn: "t", startedAt: 0)
        for stamp in [nil, "", "not-a-date"] as [String?] {
            var broken = row(id: "a1", session: "s", createdAt: 1, status: "pending")
            broken.createdAt = stamp
            #expect(
                project(state, at: 2, approvals: [broken])?.approval == nil,
                "unprovable provenance (\(stamp ?? "nil")) must not enter the card"
            )
        }
    }

    @Test func thePendingRequestOutranksSettledOnesFromTheSameTurn() throws {
        let state = liveState(session: "s", turn: "t", startedAt: 0)
        let approvals = [
            row(id: "settled", session: "s", createdAt: 5, status: "resolved", decision: "approved"),
            row(id: "waiting", session: "s", createdAt: 2, status: "pending"),
        ]
        let card = try #require(project(state, at: 6, approvals: approvals))
        #expect(card.approval?.approvalId == "waiting")
        #expect(card.approval?.outcome == .pending)
    }

    @Test func theProjectionIsPureAndCarriesNoClockOfItsOwn() throws {
        // Same inputs, two different observation instants inside one displayed
        // second: identical approval projection. Visibility itself never reads
        // the clock at all.
        let state = liveState(session: "s", turn: "t", startedAt: 0)
        let pending = [row(id: "a1", session: "s", createdAt: 1, status: "pending")]
        let a = try #require(project(state, at: 5.1, approvals: pending))
        let b = try #require(project(state, at: 5.9, approvals: pending))
        #expect(a == b)
    }

    // MARK: - Wiring (a projection nothing renders is a dead feature)

    @Test func theCardIsTheOnlyPlaceThisProjectionIsRenderedAndItIsActuallyWired() throws {
        let card = try AppSourceScraping.appSource("MacChatTurnCard.swift")
        // The host must feed the canonical rows in — a default-empty argument
        // silently projects "no approval, ever".
        #expect(card.contains("approvals: appModel.approvals"))
        // And it must dispatch decisions through the canonical resolve path.
        #expect(card.contains("appModel.resolveApproval(id: approvalId, decision: decision)"))
        // The card decides nothing itself.
        #expect(!card.contains("SwiftNativeApprovalInbox"))
        #expect(!card.contains("TrustCenter"))
        #expect(!card.contains("SecurityCenter"))
        // Hit testing must follow "has controls", not "is terminal" — a settled
        // turn holding a pending approval has to stay clickable.
        #expect(card.contains(".allowsHitTesting(model.hasControls)"))

        // Both surfaces gate visibility on the same approval-aware truth.
        let actions = try AppSourceScraping.appSource("ChatView+SessionActions.swift")
        #expect(actions.contains("approvals: appModel.approvals"))
        let detached = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        #expect(detached.contains("approvals: appModel.approvals"))
    }

    @Test func theCanonicalChatOriginSurvivesTheClientMapping() throws {
        // Without this the whole projection is unreachable in the running app:
        // every row would arrive with a nil chat origin and match nothing.
        let payload = JSONValue.object([
            "kind": .string("chat_tool_approval"),
            "origin": .object(["sessionId": .string("session-7")]),
        ])
        #expect(NativeClient.chatApprovalOriginSessionId(payload) == "session-7")

        // Only chat tool approvals carry a chat origin.
        #expect(NativeClient.chatApprovalOriginSessionId(.object([
            "kind": .string("workshop_step"),
            "origin": .object(["sessionId": .string("session-7")]),
        ])) == nil)
        // The filer writes .null when there was no verified session.
        #expect(NativeClient.chatApprovalOriginSessionId(.object([
            "kind": .string("chat_tool_approval"),
            "origin": .object(["sessionId": .null]),
        ])) == nil)
        #expect(NativeClient.chatApprovalOriginSessionId(.object([
            "kind": .string("chat_tool_approval"),
            "origin": .object(["sessionId": .string("   ")]),
        ])) == nil)
        #expect(NativeClient.chatApprovalOriginSessionId(.object([:])) == nil)
    }

    @Test func noSecondApprovalSurfaceGrewInsideTheChatCardFiles() throws {
        // One approval store, one decision path. The card files must not open
        // an inbox, keep a resolved flag, or duplicate the inline card.
        for name in ["MacChatTurnCard.swift", "MacChatTurnApproval.swift"] {
            let source = try AppSourceScraping.appSource(name)
            #expect(!source.contains("struct InlineApprovalCard"))
            #expect(!source.contains("@State private var resolved"))
            #expect(!source.contains("ApprovalInbox("))
        }
    }

    // MARK: - Helpers

    private func row(
        id: String,
        session: String,
        createdAt: TimeInterval,
        status: String,
        decision: String? = nil
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            title: "Approve mac_inject_text",
            action: "mac_inject_text",
            risk: "confirm",
            reason: "autonomy=confirm",
            status: status,
            createdAt: MacChatTurnApprovalTestSupport.iso(time(createdAt)),
            decision: decision,
            chatOriginSessionId: session
        )
    }

    private func liveState(
        session: String,
        turn: String,
        startedAt: TimeInterval
    ) -> MacChatTurnLifecycleState {
        let identity = MacChatTurnIdentity(sessionId: session, turnId: turn)
        let state = MacChatTurnLifecycleState(identity: identity, startedAt: time(startedAt))
        return MacChatTurnLifecycleReducer.reduce(state, input: MacChatTurnLifecycleInput(
            identity: identity,
            kind: .working(action: nil),
            occurredAt: time(startedAt + 1)
        ))
    }

    private func completedState(
        session: String,
        turn: String,
        startedAt: TimeInterval
    ) -> MacChatTurnLifecycleState {
        let identity = MacChatTurnIdentity(sessionId: session, turnId: turn)
        return MacChatTurnLifecycleReducer.reduce(
            liveState(session: session, turn: turn, startedAt: startedAt),
            input: MacChatTurnLifecycleInput(
                identity: identity,
                kind: .completed,
                occurredAt: time(startedAt + 2)
            )
        )
    }

    private func project(
        _ state: MacChatTurnLifecycleState,
        at offset: TimeInterval,
        approvals: [ApprovalRequest]
    ) -> MacChatTurnCardModel? {
        MacChatTurnCardProjection.card(
            for: state,
            sessionId: state.identity.sessionId,
            personaName: "Agent",
            at: time(offset),
            approvals: approvals
        )
    }

    private func time(_ offset: TimeInterval) -> Date {
        MacChatTurnApprovalTestSupport.origin.addingTimeInterval(offset)
    }
}

enum MacChatTurnApprovalTestSupport {
    /// Fixed instant: these tests must never depend on the wall clock.
    static let origin = Date(timeIntervalSince1970: 1_780_000_000)

    /// The exact stamp shape the canonical inbox writes.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = formatter.string(from: date)
        return zulu.hasSuffix("Z") ? String(zulu.dropLast()) + "+00:00" : zulu
    }
}
