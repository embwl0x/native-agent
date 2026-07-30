import Foundation
import Testing
@testable import PersistenceCore

@Suite("GitHubCommandStore")
struct GitHubCommandStoreTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func observation(
        repo: String = "example/widgets",
        number: Int = 42,
        version: String,
        signals: Set<GitHubCommandActionSignal> = [],
        open: Bool = true,
        merged: Bool = false,
        head: String? = "abc123",
        decision: GitHubCommandBlocker? = nil,
        waiting: GitHubCommandWaitingKind = .review,
        stale: Bool = false,
        reviewThreads: [GitHubCommandReviewThreadEvidence]? = nil
    ) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: repo,
            number: number,
            kind: .pullRequest,
            title: "Repair the widget",
            isOpen: open,
            isMerged: merged,
            observedVersion: "observed-\(version)",
            actionableEventVersion: signals.isEmpty ? nil : version,
            signals: signals,
            headSHA: head,
            humanDecision: decision,
            waitingKind: waiting,
            isStale: stale,
            finalReceipt: open ? nil : "\(repo) #\(number) \(merged ? "merged" : "closed").",
            reviewThreads: reviewThreads
        )
    }

    private func dispatch(
        _ store: GitHubCommandStore,
        itemId: String
    ) async throws -> GitHubCommandDispatchReceipt {
        let intent = try #require(try await store.prepareDispatch(itemId: itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: itemId, receipt: receipt)
        return receipt
    }

    @Test("store owns the complete transition path")
    func transitionPath() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let detected = try await store.detect(
            repository: "example/widgets", number: 42, kind: .pullRequest, title: "Repair the widget"
        )
        #expect(detected.state == .detected)

        let waiting = try await store.observe(observation(version: "quiet", waiting: .review))
        #expect(waiting.state == .waitingUpstream(.review))

        let actionable = try await store.observe(observation(
            version: "review-77", signals: [.changesRequested]
        ))
        #expect(actionable.state == .needsCodex)
        let receipt = try await dispatch(store, itemId: actionable.itemId)
        #expect(try await store.liveState().item(actionable.itemId)?.state == .codexWorking)
        #expect(try await store.liveState().item(actionable.itemId)?.dispatchReceipt == receipt)

        let callbacks = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed", summary: "Pushed the requested repair."
        )
        #expect(callbacks.first?.state == .verifying)
        let verified = try await store.observe(observation(
            version: "after-fix", head: "def456", waiting: .review
        ))
        #expect(verified.state == .waitingUpstream(.review))
        #expect(verified.dispatchReceipt == receipt)
        #expect(verified.workLog.map(\.kind).contains("codex_callback"))

        let needsUser = try await store.observe(observation(
            version: "decision-1",
            decision: GitHubCommandBlocker(detail: "Product direction is disputed.", owner: "Repository owner")
        ))
        #expect(needsUser.state == .needsUser)
        let resolved = try await store.observe(observation(
            version: "merged-1", open: false, merged: true, head: "def456"
        ))
        #expect(resolved.state == .resolved)
        #expect(resolved.finalReceipt == "example/widgets #42 merged.")
    }

    @Test("causal transition projection is read-only bounded and payload-free")
    func causalTransitionProjection() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await store.detect(
            repository: "example/widgets",
            number: 42,
            kind: .pullRequest,
            title: "Repair the widget"
        )
        let item = try await store.observe(observation(
            version: "review-private", signals: [.changesRequested]
        ))
        let receipt = try await dispatch(store, itemId: item.itemId)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: "completed",
            summary: "Private callback body that must not enter transition evidence."
        )
        _ = try await store.observe(observation(
            version: "merged-private", open: false, merged: true, head: "def456"
        ))
        let claim = try #require(try await store.claimNotification(itemId: item.itemId))
        _ = try await store.recordNotification(
            itemId: item.itemId,
            dedupKey: claim.dedupKey,
            status: "accepted",
            detail: "Private delivery detail"
        )

        let opsBefore = try Data(contentsOf: store.opsPath)
        let stateBefore = try Data(contentsOf: store.statePath)
        let transitions = try await store.causalTransitionEvidence()
        let opsAfter = try Data(contentsOf: store.opsPath)
        let stateAfter = try Data(contentsOf: store.statePath)

        #expect(opsAfter == opsBefore)
        #expect(stateAfter == stateBefore)
        #expect(Set(transitions.map(\.kind)).isSuperset(of: [
            "detected", "observed", "dispatch_prepared", "dispatch_succeeded",
            "callback_received", "notification_claimed", "notification_recorded",
        ]))
        #expect(transitions.contains {
            $0.kind == "dispatch_prepared" && $0.expectedNextEvidence == "dispatch_result"
        })
        #expect(transitions.allSatisfy { $0.operationId.count == 64 && $0.itemIdentity.count == 64 })
        let lifecycle = transitions.filter { $0.trajectoryID != nil }
        #expect(lifecycle.map(\.sequenceNumber) == Array(0..<lifecycle.count))
        #expect(lifecycle.last?.terminalClass == "verified_success")
        #expect(lifecycle.last?.verificationClass == "verified")
        #expect(lifecycle.allSatisfy { $0.procedureShapeIdentity?.count == 64 })
        let procedureReport = ProcedureTrajectoryExtractor.extract(transitions)
        let oracleTrajectory = try #require(procedureReport.trajectories.first)
        #expect(oracleTrajectory.domain == "github_command")
        let oracleCandidate = try #require(ProcedureCandidateCompiler.evaluate(
            trajectories: [oracleTrajectory]
        ).first)
        #expect(oracleCandidate.productRole == .githubReducerOracle)
        #expect(!oracleCandidate.manualInvocationEligible)
        #expect(oracleCandidate.manualBlockingReasons.contains(.externalSendIneligible))
        #expect(try await store.causalTransitionEvidence(limit: 3).count == 3)

        let encoded = try JSONEncoder().encode(transitions)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("example/widgets"))
        #expect(!text.contains("Repair the widget"))
        #expect(!text.contains("Private callback"))
        #expect(!text.contains("Private delivery"))
        #expect(!text.contains(receipt.messageId))
    }

    @Test("shared motor projection preserves GitHub verification semantics")
    func sharedMotorProjection() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(
            version: "motor-private", signals: [.changesRequested]
        ))

        let ready = try #require(try await store.motorActionReadModel(actionId: item.itemId))
        #expect(ready.phase == .ready)
        #expect(ready.verification == .notStarted)
        #expect(ready.domainState == GitHubCommandStateName.needsCodex.rawValue)
        #expect(ready.expectedNextEvidence == "dispatch_result")
        #expect(ready.actionIdentity == CausalTransitionEvidence.opaqueIdentity(item.itemId))
        #expect(ready.cancellationIdentity == nil)
        #expect(ready.deadline == nil)

        let receipt = try await dispatch(store, itemId: item.itemId)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: "completed",
            summary: "Private callback"
        )
        let verifying = try #require(try await store.motorActionReadModel(actionId: item.itemId))
        #expect(verifying.phase == .verifying)
        #expect(verifying.verification == .pending)
        #expect(verifying.expectedNextEvidence == "github_verification")

        _ = try await store.observe(observation(
            version: "merged-private", open: false, merged: true, head: "motor-head"
        ))
        let resolved = try #require(try await store.motorActionReadModel(actionId: item.itemId))
        #expect(resolved.phase == .succeeded)
        #expect(resolved.verification == .satisfied)
        #expect(resolved.phase.isTerminal)

        _ = try await store.observe(observation(
            repo: "example/closed-without-merge",
            number: 99,
            version: "closed-private",
            open: false,
            merged: false
        ))
        let closedUnmerged = try #require(try await store.motorActionReadModel(
            actionId: "example/closed-without-merge#99"
        ))
        #expect(closedUnmerged.phase == .cancelled)
        #expect(closedUnmerged.verification == .notRequired)
    }

    @Test("causal transition projection maps failure operation families")
    func causalTransitionFailureFamilies() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(
            version: "ci-private", signals: [.ciFailure]
        ))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        _ = try await store.recordDispatchFailure(
            itemId: item.itemId,
            eventKey: intent.eventKey,
            detail: "Private dispatch failure"
        )
        _ = try await store.recordVerificationReadFailure(
            itemId: item.itemId,
            detail: "Private verification failure"
        )

        let transitions = try await store.causalTransitionEvidence()
        #expect(Set(transitions.map(\.kind)).isSuperset(of: [
            "dispatch_failed", "verification_read_failed",
        ]))
        let text = String(decoding: try JSONEncoder().encode(transitions), as: UTF8.self)
        #expect(!text.contains("Private dispatch"))
        #expect(!text.contains("Private verification"))
    }

    @Test("causal projection stays bounded on a 10x synthetic feed")
    func causalTransitionSyntheticScale() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let observations = (1...1_000).map { number in
            observation(
                repo: "example/widgets",
                number: number,
                version: "quiet-\(number)",
                waiting: .review
            )
        }
        _ = try await store.observe(observations)

        var samples: [TimeInterval] = []
        for _ in 0..<10 {
            let start = Date()
            let evidence = try await store.causalTransitionEvidence(limit: 512)
            samples.append(Date().timeIntervalSince(start))
            #expect(evidence.count == 512)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print(String(format: "GITHUB_CAUSAL_10X median_ms=%.3f p95_ms=%.3f ops=1000 output=512", median * 1_000, p95 * 1_000))
        // Structural guarantee (evidence.count == 512) is asserted in the loop
        // above and always runs. The absolute wall-clock bound is a perf-
        // regression tripwire only — gated behind NATIVE_AGENT_PERF_ASSERTS so
        // CI scheduler contention can't flake it, measurable on demand. See
        // nativeagent-hangproof-subprocess-tests (no tight wall-clock asserts).
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_PERF_ASSERTS"] == "1" {
            #expect(p95 < 0.250)
        }
    }

    @Test("one actionable event dispatches at most once across polling and replay")
    func dispatchDedupAcrossRestart() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = GitHubCommandStore(dataRoot: root)
        let item = try await first.observe(observation(
            version: "ci-abc-9", signals: [.ciFailure]
        ))
        let receipt = try await dispatch(first, itemId: item.itemId)
        _ = try await first.observe(observation(version: "ci-abc-9", signals: [.ciFailure]))

        let replayed = GitHubCommandStore(dataRoot: root)
        let state = try await replayed.liveState()
        #expect(state.item(item.itemId)?.state == .codexWorking)
        #expect(state.dispatchedEventKeys == [receipt.eventKey])
        #expect(try await replayed.prepareDispatch(itemId: item.itemId) == nil)

        _ = try await replayed.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed", summary: "CI repair completed."
        )
        let unchanged = try await replayed.observe(observation(
            version: "ci-abc-9", signals: [.ciFailure]
        ))
        #expect(unchanged.state == .attention(.verificationFailed))

        // Bounded "still needs work -> back to codex" loop (User, 2026-07-12):
        // verificationFailed re-dispatches with a FRESH salted key until
        // maxDispatchAttemptsPerEvent total attempts, then parks as a real
        // blocker that claims APNS. No claim while retries remain.
        #expect(try await replayed.claimNotification(itemId: item.itemId) == nil)
        // Idempotent resume (review round 4): preparing the same unrecorded
        // retry twice returns the identical intent — a crash between prepare
        // and record must not burn the cap or change the reserved key.
        let intent2a = try #require(try await replayed.prepareDispatch(itemId: item.itemId))
        let intent2b = try #require(try await replayed.prepareDispatch(itemId: item.itemId))
        #expect(intent2a.dispatchId == intent2b.dispatchId)
        #expect(intent2a.attempt == intent2b.attempt)
        // A prepared-but-unexecuted attempt never claims a notification.
        #expect(try await replayed.claimNotification(itemId: item.itemId) == nil)
        let retry2 = try await dispatch(replayed, itemId: item.itemId)
        #expect(retry2.dispatchId != receipt.dispatchId)
        #expect(retry2.dispatchId == intent2a.dispatchId)
        _ = try await replayed.recordCallback(
            messageIds: [retry2.messageId], codexStatus: "completed", summary: "Second pass."
        )
        let still2 = try await replayed.observe(observation(version: "ci-abc-9", signals: [.ciFailure]))
        #expect(still2.state == .attention(.verificationFailed))
        #expect(try await replayed.claimNotification(itemId: item.itemId) == nil)

        let retry3 = try await dispatch(replayed, itemId: item.itemId)
        #expect(retry3.dispatchId != retry2.dispatchId)
        _ = try await replayed.recordCallback(
            messageIds: [retry3.messageId], codexStatus: "completed", summary: "Third pass."
        )
        let parked = try await replayed.observe(observation(version: "ci-abc-9", signals: [.ciFailure]))
        #expect(parked.state == .attention(.verificationFailed))
        // Attempts exhausted: no further dispatch, and NOW it is User-worthy.
        #expect(try await replayed.prepareDispatch(itemId: item.itemId) == nil)
        let claim = try await replayed.claimNotification(itemId: item.itemId)
        #expect(claim?.kind == .blocker)
    }

    @Test("a successful callback cannot self-certify an unresolved review thread")
    func callbackCannotSelfCertifyUnresolvedReview() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let active = GitHubCommandReviewThreadEvidence(
            threadId: "PRRT_777", isResolved: false, isOutdated: false,
            rootCommentId: 777, reviewId: 700, unresolvedGeneration: 1
        )
        let item = try await store.observe(observation(
            version: "thread:PRRT_777:unresolved:g1",
            signals: [.reviewComment], reviewThreads: [active]
        ))
        let receipt = try await dispatch(store, itemId: item.itemId)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed",
            summary: "Replied to all review threads; no code change needed."
        )
        // The exact same GraphQL thread generation remains actionable. Codex's
        // callback and a pushed head are correlation/action evidence, not
        // external settlement evidence while that owner event remains open.
        let unresolved = try await store.observe(observation(
            version: "thread:PRRT_777:unresolved:g1",
            signals: [.reviewComment], head: "def456", reviewThreads: [active]
        ))
        #expect(unresolved.state == .attention(.verificationFailed))
        #expect(unresolved.blocker?.owner == "Codex")
        #expect(try await store.prepareDispatch(itemId: item.itemId) != nil)
    }

    @Test("authoritative resolved or outdated review evidence settles after callback")
    func authoritativeReviewEvidenceSettles() async throws {
        for (suffix, resolved, outdated) in [
            ("resolved", true, false),
            ("outdated", false, true),
        ] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let store = GitHubCommandStore(dataRoot: root)
            let active = GitHubCommandReviewThreadEvidence(
                threadId: "PRRT_888", isResolved: false, isOutdated: false,
                rootCommentId: 888, reviewId: 800, unresolvedGeneration: 1
            )
            let item = try await store.observe(observation(
                repo: "example/\(suffix)",
                version: "thread:PRRT_888:unresolved:g1",
                signals: [.changesRequested, .reviewComment],
                reviewThreads: [active]
            ))
            let receipt = try await dispatch(store, itemId: item.itemId)
            _ = try await store.recordCallback(
                messageIds: [receipt.messageId], codexStatus: "completed", summary: "Addressed."
            )
            let settled = try await store.observe(observation(
                repo: "example/\(suffix)", version: suffix,
                reviewThreads: [GitHubCommandReviewThreadEvidence(
                    threadId: "PRRT_888", isResolved: resolved, isOutdated: outdated,
                    rootCommentId: 888, reviewId: 800, unresolvedGeneration: 1
                )]
            ))
            #expect(settled.state == .waitingUpstream(.review))
            #expect(settled.blocker == nil)
        }
    }

    // A mixed-cause verification failure remains blocked when a later poll
    // still carries actionable review evidence. Callback success never drains
    // canonical GitHub state.
    @Test("mixed-cause parked verificationFailed does not drain on a review-only poll")
    func mixedCauseParkDoesNotDrain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(
            version: "comment:888", signals: [.reviewComment]
        ))
        let receipt = try await dispatch(store, itemId: item.itemId)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed", summary: "Addressed."
        )
        let parked = try await store.observe(observation(
            version: "comment:888", signals: [.reviewComment, .ciFailure]
        ))
        #expect(parked.state == .attention(.verificationFailed))
        let still = try await store.observe(observation(
            version: "comment:888", signals: [.reviewComment]
        ))
        #expect(still.state == .attention(.verificationFailed))
    }

    // Round 5: a stale unconsumed reservation must NOT resume once the item
    // settles — a closed PR carrying the same event key would otherwise hand
    // codex a dispatch for work that no longer exists.
    @Test("settled items never resume a leftover dispatch intent")
    func staleIntentDoesNotResumeAfterSettle() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(
            version: "ci-stale-1", signals: [.ciFailure]
        ))
        // Reserve but never record (crash window with an unconsumed intent).
        _ = try #require(try await store.prepareDispatch(itemId: item.itemId))
        // The PR closes while the dispatch was never sent.
        let settled = try await store.observe(observation(
            version: "ci-stale-1", signals: [.ciFailure], open: false, merged: true
        ))
        #expect(settled.state == .resolved)
        #expect(try await store.prepareDispatch(itemId: item.itemId) == nil)
    }

    @Test("dispatch intent recovers both crash windows without false working state")
    func atomicDispatchCrashRecovery() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(
            version: "comment-501", signals: [.reviewComment]
        ))
        let firstIntent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        #expect(try await store.liveState().item(item.itemId)?.state == .needsCodex)
        #expect(try await store.liveState().item(item.itemId)?.dispatchReceipt == nil)

        let restarted = GitHubCommandStore(dataRoot: root)
        let recoveredIntent = try #require(try await restarted.prepareDispatch(itemId: item.itemId))
        #expect(recoveredIntent.dispatchId == firstIntent.dispatchId)
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: recoveredIntent.eventKey,
            dispatchId: recoveredIntent.dispatchId,
            messageId: recoveredIntent.dispatchId,
            queuedAt: DeskClock.nowISO(),
            recovered: true
        )
        let working = try await restarted.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        #expect(working.state == .codexWorking)
        #expect(working.dispatchReceipt?.recovered == true)

        let root2 = try self.root(); defer { try? FileManager.default.removeItem(at: root2) }
        let callbackStore = GitHubCommandStore(dataRoot: root2)
        let item2 = try await callbackStore.observe(observation(
            repo: "example/other", number: 7, version: "conflict-a", signals: [.conflict]
        ))
        let intent2 = try #require(try await callbackStore.prepareDispatch(itemId: item2.itemId))
        let correlated = try await callbackStore.recordCallback(
            messageIds: [intent2.dispatchId], codexStatus: "completed", summary: "Recovered callback."
        )
        #expect(correlated.first?.state == .verifying)
        #expect(correlated.first?.dispatchReceipt?.recovered == true)
        #expect(correlated.first?.dispatchReceipt?.messageId == intent2.dispatchId)
    }

    @Test("APNS claims exist only for terminal success or a real blocker and survive restart")
    func notificationBoundaryAndDedup() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let detected = try await store.detect(
            repository: "example/widgets", number: 42, kind: .pullRequest, title: "Repair"
        )
        #expect(try await store.claimNotification(itemId: detected.itemId) == nil)
        _ = try await store.observe(observation(version: "quiet", waiting: .ci))
        #expect(try await store.claimNotification(itemId: detected.itemId) == nil)
        _ = try await store.observe(observation(version: "ci-1", signals: [.ciFailure]))
        #expect(try await store.claimNotification(itemId: detected.itemId) == nil)
        let receipt = try await dispatch(store, itemId: detected.itemId)
        #expect(try await store.claimNotification(itemId: detected.itemId) == nil)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed", summary: "Done."
        )
        #expect(try await store.claimNotification(itemId: detected.itemId) == nil)

        let blocker = try await store.observe(observation(
            version: "decision-2",
            decision: GitHubCommandBlocker(detail: "Permission is required.", owner: "Repository owner")
        ))
        let blockerIntent = try #require(try await store.claimNotification(itemId: blocker.itemId))
        #expect(blockerIntent.kind == .blocker)
        #expect(blockerIntent.body.contains("Owner: Repository owner"))
        #expect(try await GitHubCommandStore(dataRoot: root).claimNotification(itemId: blocker.itemId) == nil)

        let resolved = try await store.observe(observation(
            version: "closed-2", open: false, merged: true
        ))
        let success = try #require(try await store.claimNotification(itemId: resolved.itemId))
        #expect(success.kind == .success)
        #expect(success.body == "example/widgets #42 merged.")
        #expect(try await GitHubCommandStore(dataRoot: root).claimNotification(itemId: resolved.itemId) == nil)
    }

    @Test("a callback after a terminal state is logged stale and never revives the item")
    func staleCallbackAfterResolved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(version: "ci-3", signals: [.ciFailure]))
        let receipt = try await dispatch(store, itemId: item.itemId)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed", summary: "CI repaired."
        )
        let resolved = try await store.observe(observation(version: "merged-3", open: false, merged: true))
        #expect(resolved.state == .resolved)

        // A duplicate/late completion correlating to the same receipt must not
        // flip a terminal item back into verifying.
        let after = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed", summary: "Duplicate completion."
        )
        #expect(after.first?.state == .resolved)
        #expect(after.first?.workLog.map(\.kind).contains("stale_callback") == true)
        let reread = try await GitHubCommandStore(dataRoot: root).liveState().item(item.itemId)
        #expect(reread?.state == .resolved)
    }

    @Test("codex_working ages to callback_overdue without spawning a competing task")
    func codexWorkingAgesToCallbackOverdue() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(version: "review-6", signals: [.changesRequested]))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        // A dispatch whose receipt was queued past the overdue window with no
        // callback ever recorded.
        let staleReceipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO(Date().addingTimeInterval(-7 * 60 * 60))
        )
        let working = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: staleReceipt)
        #expect(working.state == .codexWorking)

        // A fresh observation re-runs routing; the overdue receipt ages it.
        let aged = try await store.observe(observation(version: "review-6", signals: [.changesRequested]))
        #expect(aged.state == .attention(.callbackOverdue))

        // A callback_overdue blocker is a real blocker and may claim APNS.
        let overdueClaim = try #require(try await store.claimNotification(itemId: item.itemId))
        #expect(overdueClaim.kind == .blocker)

        // The reply watcher is durable and owns recovery of the original turn.
        // A timeout does not prove that turn made no changes, so GitHub Command
        // must never mint a competing task automatically.
        #expect(try await store.prepareDispatch(itemId: item.itemId) == nil)
    }

    @Test("a settled review event does not re-open attention on an identical benign re-poll")
    func settledReviewDoesNotReopenAttention() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let active = GitHubCommandReviewThreadEvidence(
            threadId: "PRRT_909", isResolved: false, isOutdated: false,
            rootCommentId: 909, reviewId: 900, unresolvedGeneration: 1
        )
        let resolved = GitHubCommandReviewThreadEvidence(
            threadId: "PRRT_909", isResolved: true, isOutdated: false,
            rootCommentId: 909, reviewId: 900, unresolvedGeneration: 1
        )
        let item = try await store.observe(observation(
            version: "thread:PRRT_909:unresolved:g1",
            signals: [.changesRequested], reviewThreads: [active]
        ))
        let receipt = try await dispatch(store, itemId: item.itemId)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed", summary: "Pushed the fix."
        )
        // The authoritative thread generation settles, so the observation
        // builder removes the actionable event.
        let settled = try await store.observe(observation(
            version: "review-9-resolved", reviewThreads: [resolved]
        ))
        #expect(settled.state == .waitingUpstream(.review))

        // A benign re-poll of the same resolved generation stays settled.
        let repoll = try await store.observe(observation(
            version: "review-9-resolved", reviewThreads: [resolved]
        ))
        #expect(repoll.state == .waitingUpstream(.review))

        // Reopening the same thread increments its generation and is new work.
        let reopenedThread = GitHubCommandReviewThreadEvidence(
            threadId: "PRRT_909", isResolved: false, isOutdated: false,
            rootCommentId: 909, reviewId: 900, unresolvedGeneration: 2
        )
        let reopened = try await store.observe(observation(
            version: "thread:PRRT_909:unresolved:g2",
            signals: [.changesRequested], reviewThreads: [reopenedThread]
        ))
        #expect(reopened.state == .needsCodex)
    }

    @Test("claimNotification refuses transient verification_read_failed")
    func claimNotificationRefusesVerificationReadFailed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(version: "ci-4", signals: [.ciFailure]))
        #expect(item.state == .needsCodex)
        // A single failed read is a blip: log it, keep the state, no alarm.
        let first = try await store.recordVerificationReadFailure(
            itemId: item.itemId, detail: "GitHub was briefly unreadable at launch."
        )
        #expect(first.state == .needsCodex)
        #expect(first.workLog.contains { $0.kind == "verification_read_failed" })
        // A second consecutive failure earns attention — but never a push.
        let second = try await store.recordVerificationReadFailure(
            itemId: item.itemId, detail: "GitHub is still unreadable."
        )
        #expect(second.state == .attention(.verificationReadFailed))
        #expect(try await store.claimNotification(itemId: item.itemId) == nil)
        // While the latest read is failed, dispatch is refused — the evidence
        // behind the dispatchable state is unverified.
        #expect(try await store.prepareDispatch(itemId: item.itemId) == nil)
        // A successful read resets the run: dispatch works again and the next
        // single blip stays quiet.
        let healed = try await store.observe(observation(version: "ci-5", signals: [.ciFailure]))
        #expect(healed.verificationReadFailures == nil)
        #expect(try await store.prepareDispatch(itemId: item.itemId) != nil)
        let blipAfterHeal = try await store.recordVerificationReadFailure(
            itemId: item.itemId, detail: "Another lone 502."
        )
        #expect(blipAfterHeal.state != .attention(.verificationReadFailed))
    }

    @Test("a dispatch result recorded after a superseding observation cleared the intent is filed stale and kept in the ledger")
    func dispatchSuccessSurvivesClearedIntent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(version: "review-1", signals: [.changesRequested]))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))

        // Mid-send, a poll routes a NEW actionable event and the reducer
        // clears the old intent. Before the fix BOTH record paths threw on
        // the cleared intent: the real dispatch was never recorded, the
        // eventKey never entered the at-most-once ledger, and the runtime's
        // whole dispatch cycle aborted (2026-07-21 audit).
        let superseded = try await store.observe(observation(version: "review-2", signals: [.changesRequested]))
        #expect(superseded.state == .needsCodex)
        #expect(superseded.dispatchIntent == nil)

        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: intent.preparedAt
        )
        let recorded = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        // State is NOT stomped back to codexWorking; the receipt is filed stale…
        #expect(recorded.state == .needsCodex)
        #expect(recorded.workLog.map(\.kind).contains("stale_dispatch_receipt") == true)
        // …but the eventKey DID enter the at-most-once ledger.
        #expect(try await store.liveState().dispatchedEventKeys.contains(intent.eventKey))

        // The NEW event dispatches normally, and a flip back to the OLD event
        // routes to the bounded retry path — never a silent re-dispatch.
        let nextIntent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        #expect(nextIntent.eventKey != intent.eventKey)
        let flipBack = try await store.observe(observation(version: "review-1", signals: [.changesRequested]))
        #expect(flipBack.state == .attention(.verificationFailed))
    }

    @Test("a dispatch failure recorded after the intent cleared stays out of the attention bucket")
    func dispatchFailureSurvivesClearedIntent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(version: "review-1", signals: [.changesRequested]))
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        _ = try await store.observe(observation(version: "review-2", signals: [.changesRequested]))

        let recorded = try await store.recordDispatchFailure(
            itemId: item.itemId, eventKey: intent.eventKey, detail: "bridge timeout"
        )
        // The superseded event's failure must not drag the item into
        // attention(dispatchFailed); it is logged stale instead.
        #expect(recorded.state == .needsCodex)
        #expect(recorded.workLog.map(\.kind).contains("stale_dispatch_failure") == true)
    }

    @Test("stale callbacks on a terminal item never grow the work log past the cap")
    func staleCallbacksStayBounded() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation(version: "ci-9", signals: [.ciFailure]))
        let receipt = try await dispatch(store, itemId: item.itemId)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId], codexStatus: "completed", summary: "Done."
        )
        let resolved = try await store.observe(observation(version: "merged-9", open: false, merged: true))
        #expect(resolved.state == .resolved)

        // Every duplicate callback correlates to the retained receipt and
        // appends a stale_callback row — unbounded before the cap.
        for _ in 0..<(GitHubCommandStore.maxWorkLogEntries + 10) {
            _ = try await store.recordCallback(
                messageIds: [receipt.messageId], codexStatus: "completed", summary: "Duplicate."
            )
        }
        let after = try #require(try await store.liveState().item(item.itemId))
        #expect(after.state == .resolved)
        #expect(after.workLog.count <= GitHubCommandStore.maxWorkLogEntries)
        #expect(after.workLog.last?.kind == "stale_callback")
    }

    @Test("aged resolved items retire and the dispatched ledger keeps only live references plus the tail")
    func terminalRetirementBoundsReducedState() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(
            dataRoot: root,
            changeBus: StoreChangeBus(),
            opsCompactionThreshold: 1_000_000,
            terminalItemRetentionSeconds: 0,
            dispatchedEventKeysTailCap: 0
        )
        let item = try await store.observe(observation(version: "review-5", signals: [.changesRequested]))
        let receipt = try await dispatch(store, itemId: item.itemId)
        let resolved = try await store.observe(observation(version: "closed-5", open: false))
        #expect(resolved.state == .resolved)

        // A NEWER op lands: the resolved item's age now exceeds the (zero)
        // retention and it retires out of the reduced state.
        let liveItem = try await store.observe(
            observation(repo: "other/repo", number: 7, version: "review-7", signals: [.changesRequested])
        )
        let liveReceipt = try await dispatch(store, itemId: liveItem.itemId)

        let state = try await store.liveState()
        #expect(state.item(item.itemId) == nil)
        #expect(state.items.count == 1)
        // The retired item's key is referenced by nothing live and outside
        // the (zero) tail — pruned. The live item's receipt key survives.
        #expect(!state.dispatchedEventKeys.contains(receipt.eventKey))
        #expect(state.dispatchedEventKeys.contains(liveReceipt.eventKey))
    }

    @Test("every tracked item remains in exactly one state after replay")
    func noItemVanishes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await store.detect(repository: "one/repo", number: 1, kind: .issue, title: "Detected")
        _ = try await store.observe(observation(repo: "two/repo", number: 2, version: "quiet", waiting: .maintainer))
        _ = try await store.observe(observation(repo: "three/repo", number: 3, version: "ci", signals: [.ciFailure]))
        _ = try await store.observe(observation(
            repo: "four/repo", number: 4, version: "decision",
            decision: GitHubCommandBlocker(detail: "Direction needed.", owner: "Repository owner")
        ))
        _ = try await store.observe(observation(repo: "five/repo", number: 5, version: "closed", open: false))

        let state = try await GitHubCommandStore(dataRoot: root).liveState()
        #expect(state.items.count == 5)
        #expect(state.allItemsAreInExactlyOneState)
        #expect(GitHubCommandStateName.allCases.reduce(0) { $0 + state.count(in: $1) } == 5)
    }
}
