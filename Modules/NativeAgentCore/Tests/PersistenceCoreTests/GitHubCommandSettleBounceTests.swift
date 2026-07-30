import Foundation
import Testing
@testable import PersistenceCore

/// Audit round 2, G3: `lastSettledEventKey` was write-never, so the route()
/// anti-bounce guard could never fire — an already-settled eventKey that
/// re-surfaced (marker resurrection while still in the monotonic dispatched
/// set) bounced the item back into attention(verificationFailed) and burned
/// dispatch attempts on work codex already finished.
@Suite("GitHubCommand settle anti-bounce")
struct GitHubCommandSettleBounceTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-command-settle-bounce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func actionable(_ version: String) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets",
            number: 9,
            kind: .pullRequest,
            title: "Repair the widget",
            isOpen: true,
            observedVersion: "observed-\(version)",
            actionableEventVersion: version,
            signals: [.reviewComment],
            headSHA: "abc123",
            waitingKind: .review
        )
    }

    private func quiet() -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets",
            number: 9,
            kind: .pullRequest,
            title: "Repair the widget",
            isOpen: true,
            observedVersion: "observed-quiet",
            actionableEventVersion: nil,
            signals: [],
            headSHA: "abc123",
            waitingKind: .review
        )
    }

    @Test("a settled eventKey re-surfacing does not bounce back to attention")
    func settledEventKeyDoesNotBounce() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)

        // Full lifecycle: actionable → dispatch → completed callback →
        // quiet observation settles verifying into waiting_upstream.
        let item = try await store.observe(actionable("review-1"))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: "completed",
            summary: "Codex resolved the review thread."
        )
        let settled = try await store.observe(quiet())
        #expect(settled.state == .waitingUpstream(.review))
        #expect(settled.lastSettledEventKey == intent.eventKey)

        // The identical actionable event re-surfaces (marker resurrection:
        // same eventKey, still in the dispatched at-most-once set). The item
        // must STAY settled — no attention park, no burned attempt.
        let resurrected = try await store.observe(actionable("review-1"))
        #expect(resurrected.state == .waitingUpstream(.review))
        #expect(resurrected.blocker == nil)
        #expect(try await store.claimPendingNotifications().isEmpty)

        // A genuinely NEW actionable event still routes back to codex.
        let fresh = try await store.observe(actionable("review-2"))
        #expect(fresh.state == .needsCodex)
    }

    @Test("a reopened item re-observing its settled eventKey does not stay resolved")
    func reopenedItemDoesNotStayResolved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)

        // Full lifecycle: actionable → dispatch → completed callback → quiet
        // settle stamps lastSettledEventKey → the PR closes into .resolved.
        let item = try await store.observe(actionable("review-1"))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: "completed",
            summary: "Codex resolved the review thread."
        )
        let settled = try await store.observe(quiet())
        #expect(settled.state == .waitingUpstream(.review))
        #expect(settled.lastSettledEventKey == intent.eventKey)

        let closed = try await store.observe(GitHubCommandObservation(
            repository: "example/widgets",
            number: 9,
            kind: .pullRequest,
            title: "Repair the widget",
            isOpen: false,
            observedVersion: "observed-closed",
            actionableEventVersion: nil,
            signals: [],
            headSHA: "abc123",
            waitingKind: .review
        ))
        #expect(closed.state == .resolved)

        // The PR REOPENS with the same actionable event visible (same
        // eventKey: still in the dispatched at-most-once set AND equal to
        // lastSettledEventKey). Before the fix the anti-bounce early return
        // fired on terminal items too, leaving reopened work in .resolved
        // forever. It must route to attention instead.
        let reopened = try await store.observe(actionable("review-1"))
        #expect(reopened.state == .attention(.verificationFailed))
    }


    @Test("a quiet observation with a human decision also records settlement")
    func needsUserSettleAlsoStamps() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(actionable("review-1"))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: "completed",
            summary: "Codex resolved the review thread."
        )

        // GitHub clears the actionable event AND surfaces a decision label in
        // the same observation: verifying → needsUser used to skip the settle
        // stamp entirely (review round 2, finding 1).
        let decided = GitHubCommandObservation(
            repository: "example/widgets",
            number: 9,
            kind: .pullRequest,
            title: "Repair the widget",
            isOpen: true,
            observedVersion: "observed-decided",
            actionableEventVersion: nil,
            signals: [],
            headSHA: "abc123",
            humanDecision: GitHubCommandBlocker(detail: "Maintainer asked which direction to take.", owner: "User"),
            waitingKind: .review
        )
        let parked = try await store.observe(decided)
        #expect(parked.state == .needsUser)
        #expect(parked.lastSettledEventKey == intent.eventKey)

        // Decision answered, then the OLD eventKey resurrects: no bounce.
        _ = try await store.observe(quiet())
        let resurrected = try await store.observe(actionable("review-1"))
        #expect(resurrected.state != .attention(.verificationFailed))
    }

    @Test("settling records the key when the event clears before the callback")
    func codexWorkingSettleAlsoStamps() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(actionable("review-1"))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)

        // Codex fixed it fast: GitHub goes quiet while the item is still
        // codex_working (callback not yet landed).
        let settled = try await store.observe(quiet())
        #expect(settled.lastSettledEventKey == intent.eventKey)

        let resurrected = try await store.observe(actionable("review-1"))
        #expect(resurrected.state != .attention(.verificationFailed))
    }
}
