import Foundation
import Testing
@testable import PersistenceCore

/// LIVE DEFECT (found on User's own board, 2026-08-17): GitHub answered a blip
/// with 503/404 during verification, two consecutive failures parked the item
/// in attention(verification_read_failed) — and it stayed parked for a day.
/// The dispatched-event early return in `route` treated EVERY attention reason
/// as sticky, but a read failure is a claim about OUR EYES, not about the
/// work: reaching that code again proves reads recovered. Five items sat in
/// User's needs-attention bucket behind this, and nothing but a human could
/// clear them.
@Suite("GitHubCommand read-failure recovery")
struct GitHubCommandStoreReadFailureRecoveryTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-command-readfail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func actionable(_ version: String) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets", number: 11, kind: .pullRequest,
            title: "Repair the widget", isOpen: true,
            observedVersion: "observed-\(version)",
            actionableEventVersion: version, signals: [.ciFailure],
            headSHA: "abc123", waitingKind: .review
        )
    }

    private func quiet() -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets", number: 11, kind: .pullRequest,
            title: "Repair the widget", isOpen: true,
            observedVersion: "observed-quiet",
            actionableEventVersion: nil, signals: [],
            headSHA: "abc123", waitingKind: .review
        )
    }

    /// Drive an item to a dispatched state, then park it on read failures.
    private func parkedOnReadFailure(_ store: GitHubCommandStore) async throws -> String {
        let item = try await store.observe(actionable("ci-1"))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        _ = try await store.recordDispatchSuccess(
            itemId: item.itemId,
            receipt: GitHubCommandDispatchReceipt(
                eventKey: intent.eventKey, dispatchId: intent.dispatchId,
                messageId: intent.dispatchId, queuedAt: DeskClock.nowISO()))
        _ = try await store.recordVerificationReadFailure(itemId: item.itemId, detail: "HTTP 503")
        let parked = try await store.recordVerificationReadFailure(itemId: item.itemId, detail: "HTTP 503")
        #expect(parked.state == .attention(.verificationReadFailed))
        return item.itemId
    }

    @Test("a successful observation unsticks a read-failure parking")
    func successfulObservationUnsticksReadFailure() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await parkedOnReadFailure(store)

        // Reads recover and the event is genuinely still actionable.
        let recovered = try await store.observe(actionable("ci-1"))
        #expect(recovered.state != .attention(.verificationReadFailed),
                "a successful read must never leave the can't-see parking in place")
        #expect(recovered.state == .attention(.verificationFailed),
                "live truth: the dispatched event is still actionable")
    }

    @Test("recovery lands on the quiet state when the event actually cleared")
    func recoveryLandsOnWaitingWhenEventCleared() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await parkedOnReadFailure(store)

        let recovered = try await store.observe(quiet())
        #expect(recovered.state == .waitingUpstream(.review))
        #expect(recovered.blocker == nil)
    }

    @Test("a real work-failure claim stays sticky")
    func genuineVerificationFailureStaysSticky() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(actionable("ci-1"))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey, dispatchId: intent.dispatchId,
            messageId: intent.dispatchId, queuedAt: DeskClock.nowISO())
        _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed",
            summary: "Codex says it fixed CI.")
        let failed = try await store.observe(actionable("ci-1"))
        #expect(failed.state == .attention(.verificationFailed))
        // Re-observing must not re-derive a work-failure claim away.
        let again = try await store.observe(actionable("ci-1"))
        #expect(again.state == .attention(.verificationFailed), "a work-failure claim is sticky")
    }
}

/// THE EMPTY-SET TRAP (live, 2026-08-18). Stale-neutralization skips routing
/// when an observation's actionability claims are thread-derived and the fresh
/// evidence shows no actionable thread. But `Set().isSubset(of:)` is ALWAYS
/// true, so a QUIET observation satisfied it too and skipped routing entirely —
/// items froze on whatever state they last held. Two of User's PRs sat in
/// attention(verification_read_failed) receiving clean zero-signal observations
/// every five minutes; one had already closed upstream and still never resolved.
@Suite("GitHubCommand quiet-observation routing")
struct GitHubCommandQuietObservationRoutingTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-quiet-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `generation` is what preservation uses to rank freshness: a HIGHER
    /// unresolved generation is genuinely new work, so a stale re-claim must
    /// reuse the same generation the settled evidence carried.
    private func thread(
        _ id: String, resolved: Bool, generation: Int = 1
    ) -> GitHubCommandReviewThreadEvidence {
        GitHubCommandReviewThreadEvidence(
            threadId: id, isResolved: resolved, isOutdated: false,
            unresolvedGeneration: generation)
    }

    private func withThreads(
        _ version: String,
        signals: Set<GitHubCommandActionSignal>,
        threads: [GitHubCommandReviewThreadEvidence],
        isOpen: Bool = true
    ) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets", number: 21, kind: .pullRequest,
            title: "Repair the widget", isOpen: isOpen,
            observedVersion: "observed-\(version)",
            actionableEventVersion: signals.isEmpty ? nil : version,
            signals: signals, headSHA: "abc123",
            waitingKind: .review, reviewThreads: threads
        )
    }

    /// A quiet observation must settle the item even when thread preservation
    /// rewrote the incoming evidence.
    @Test func aQuietObservationStillRoutes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        // Prior: an actionable review thread routes it to codex.
        _ = try await store.observe(
            withThreads("review-1", signals: [.reviewComment], threads: [thread("T1", resolved: false)]))
        // Now: quiet reading, and preservation keeps the richer prior threads.
        let quiet = try await store.observe(
            withThreads("quiet", signals: [], threads: []))
        #expect(quiet.state == .waitingUpstream(.review),
                "a zero-signal reading is real news — it must not be neutralized")
    }

    /// The closed case: a PR that ended upstream must reach .resolved.
    @Test func aClosedPullRequestResolvesFromAQuietObservation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await store.observe(
            withThreads("review-1", signals: [.reviewComment], threads: [thread("T1", resolved: false)]))
        let closed = try await store.observe(
            withThreads("closed", signals: [], threads: [], isOpen: false))
        #expect(closed.state == .resolved)
    }

    /// The genuine neutralization case still holds: a thread-derived CLAIM
    /// contradicted by fresher evidence must not re-route the item.
    @Test func staleThreadDerivedClaimIsStillNeutralized() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await store.observe(
            withThreads("review-1", signals: [.reviewComment], threads: [thread("T1", resolved: false)]))
        // Settle it with fresher evidence showing the thread resolved.
        let settled = try await store.observe(
            withThreads("quiet", signals: [], threads: [thread("T1", resolved: true)]))
        #expect(settled.state == .waitingUpstream(.review))
        // A STALE poll now re-claims the review comment at the SAME
        // generation the settled evidence already answered.
        let stale = try await store.observe(
            withThreads("review-1", signals: [.reviewComment],
                        threads: [thread("T1", resolved: false, generation: 1)]))
        let expected: GitHubCommandItemState = .waitingUpstream(.review)
        #expect(stale.state == expected,
                "a stale thread-derived claim must not drag the item back")
    }
}

/// REGRESSION TEETH for the empty-set trap (2026-08-18). The suite above pins
/// the behaviour but does NOT reproduce the defect: its fixtures leave an
/// ACTIONABLE thread in the preserved evidence, so the neutralization branch is
/// never entered and removing the guard leaves them green. Entering the branch
/// needs all three of its conditions live at once:
///
///   1. preservation actually REWROTE the incoming observation
///      (`preserved != observation`) — the prior read carried a thread this
///      one dropped, which is ordinary GraphQL paging;
///   2. the merged evidence contains NO actionable thread; and
///   3. the observation is QUIET — zero signals, which is the whole trap,
///      because `Set().isSubset(of:)` is always true.
///
/// With those three aligned a clean, quiet, fully-settled reading was silently
/// swallowed and the item froze on whatever state it last held. These tests go
/// RED the moment the `!observation.signals.isEmpty` guard is removed.
@Suite("GitHubCommand empty-set neutralization trap")
struct GitHubCommandEmptySetNeutralizationTrapTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-emptyset-trap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func thread(
        _ id: String, resolved: Bool, generation: Int = 1
    ) -> GitHubCommandReviewThreadEvidence {
        GitHubCommandReviewThreadEvidence(
            threadId: id, isResolved: resolved, isOutdated: false,
            unresolvedGeneration: generation)
    }

    private func observation(
        _ version: String,
        signals: Set<GitHubCommandActionSignal>,
        threads: [GitHubCommandReviewThreadEvidence]?,
        isOpen: Bool = true
    ) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets", number: 31, kind: .pullRequest,
            title: "Repair the widget", isOpen: isOpen,
            observedVersion: "observed-\(version)",
            actionableEventVersion: signals.isEmpty ? nil : version,
            signals: signals, headSHA: "abc123",
            waitingKind: .review, reviewThreads: threads
        )
    }

    /// The prior read carries T1 unresolved (the actionable event that routed
    /// the item) alongside T2 already resolved. Codex works it, then two GitHub
    /// read failures park it in attention(verification_read_failed) — the exact
    /// live shape of #60852.
    private func parkedWithRicherThreadEvidence(
        _ store: GitHubCommandStore
    ) async throws -> String {
        let first = try await store.observe(observation(
            "review-1", signals: [.reviewComment],
            threads: [thread("T1", resolved: false), thread("T2", resolved: true)]))
        let intent = try #require(try await store.prepareDispatch(itemId: first.itemId))
        _ = try await store.recordDispatchSuccess(
            itemId: first.itemId,
            receipt: GitHubCommandDispatchReceipt(
                eventKey: intent.eventKey, dispatchId: intent.dispatchId,
                messageId: intent.dispatchId, queuedAt: DeskClock.nowISO()))
        _ = try await store.recordVerificationReadFailure(itemId: first.itemId, detail: "HTTP 503")
        let parked = try await store.recordVerificationReadFailure(itemId: first.itemId, detail: "HTTP 503")
        // #require, not #expect: every assertion in the callers is read against
        // this starting state, so a fixture that never parked must stop the
        // test rather than let it "pass" from the wrong place.
        try #require(parked.state == .attention(.verificationReadFailed))
        return first.itemId
    }

    /// THE REPRODUCER. Reads recover and the sweep returns a perfectly clean
    /// reading: no signals, T1 now resolved, T2 simply absent from this page.
    /// Preservation re-adds T2, so `preserved != observation` and the merged
    /// evidence holds no actionable thread — both surviving neutralization
    /// conditions. Only the emptiness check stops the item being frozen.
    @Test("a quiet reading unsticks a parking even when preservation rewrites threads")
    func quietReadingRoutesInsideTheNeutralizationBranch() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await parkedWithRicherThreadEvidence(store)

        let quiet = try await store.observe(observation(
            "quiet", signals: [], threads: [thread("T1", resolved: true)]))

        // Pin that the fixture really is inside the branch: preservation put
        // T2 back, which is condition 1, and nothing merged is actionable,
        // which is condition 2. If either stops holding, this test has stopped
        // reproducing and the assertions below prove nothing.
        let preserved = try #require(quiet.observation?.reviewThreads)
        #expect(preserved.map(\.threadId).sorted() == ["T1", "T2"],
                "fixture must enter the branch: preservation has to rewrite the incoming threads")
        #expect(preserved.contains(where: \.isActionable) == false,
                "fixture must enter the branch: no merged thread may be actionable")

        #expect(quiet.state != .attention(.verificationReadFailed),
                "a zero-signal reading is real news: it must route, not be neutralized as a stale claim")
        #expect(quiet.state == .waitingUpstream(.review))
    }

    /// The live cost, stated as an outcome: #60852 had CLOSED upstream and
    /// still sat parked, because every clean sweep was swallowed. A closed
    /// reading inside the same branch must reach .resolved.
    @Test("a closed pull request resolves from inside the neutralization branch")
    func closedPullRequestResolvesInsideTheNeutralizationBranch() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await parkedWithRicherThreadEvidence(store)

        let closed = try await store.observe(observation(
            "closed", signals: [], threads: [thread("T1", resolved: true)], isOpen: false))
        let preserved = try #require(closed.observation?.reviewThreads)
        #expect(preserved.map(\.threadId).sorted() == ["T1", "T2"])
        #expect(preserved.contains(where: \.isActionable) == false)

        #expect(closed.state == .resolved,
                "a PR that ended upstream must settle, however quiet the reading is")
    }

    /// The other side of the tooth: the guard must NARROW the branch, not
    /// delete it. Deliberately wedge-independent — it never relies on a quiet
    /// observation routing, so it holds its verdict whether or not the
    /// emptiness guard is present, and a wedge experiment can read it as a
    /// true control rather than as collateral damage.
    @Test("a stale thread-derived claim is still neutralized")
    func staleClaimIsStillNeutralized() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        // Settled truth, established WITHOUT passing through the branch:
        // there is no prior evidence, so preservation rewrites nothing.
        let settled = try await store.observe(observation(
            "quiet", signals: [],
            threads: [thread("T1", resolved: true), thread("T2", resolved: true)]))
        try #require(settled.state == .waitingUpstream(.review))

        // A stale poll re-claims the review comment from thread evidence the
        // settled read already answered: T1 unresolved at the SAME generation,
        // with T2 missing from its page. Preservation keeps the resolved T1
        // (resolved g1 outranks active g1) and re-adds T2, so the claim is
        // thread-derived and contradicted — exactly what neutralization is for.
        let stale = try await store.observe(observation(
            "review-1", signals: [.reviewComment],
            threads: [thread("T1", resolved: false, generation: 1)]))
        let preserved = try #require(stale.observation?.reviewThreads)
        #expect(preserved.map(\.threadId).sorted() == ["T1", "T2"])
        #expect(preserved.contains(where: \.isActionable) == false)
        #expect(stale.state == .waitingUpstream(.review),
                "a stale thread-derived claim must not drag the item back")
    }
}
