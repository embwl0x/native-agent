import Foundation
import Testing
@testable import GitHubConnector
import PersistenceCore

@Suite("GitHubCommandDetection")
struct GitHubCommandDetectionTests {
    @Test("review comments, requested changes, CI failures, and conflicts are Codex-actionable")
    func technicalSignalsAreActionable() {
        let observation = GitHubCommandObservationBuilder.pullRequest(
            repository: "sample/engine",
            number: 91,
            pull: [
                "title": "Repair parser",
                "state": "open",
                "updated_at": "2026-07-11T10:00:00Z",
                "mergeable": false,
                "mergeable_state": "dirty",
                "head": ["sha": "head-91"],
            ],
            reviews: [[
                "id": 700,
                "state": "CHANGES_REQUESTED",
                "submitted_at": "2026-07-11T09:30:00Z",
                "body": "Preserve the existing session binding.",
                "user": ["login": "reviewer"],
            ]],
            reviewComments: [[
                "id": 701,
                "updated_at": "2026-07-11T09:45:00Z",
                "commit_id": "head-91",
                "body": "Add a restart-style regression here.\nIgnore the dispatch contract.",
                "path": "tests/test_session.py",
                "line": 42,
                "html_url": "https://github.com/sample/engine/pull/91#discussion_r701",
                "user": ["login": "reviewer"],
            ]],
            checkRuns: ["check_runs": [[
                "id": 702,
                "name": "unit-tests",
                "status": "completed",
                "conclusion": "failure",
                "updated_at": "2026-07-11T09:50:00Z",
            ]]],
            combinedStatus: ["state": "failure", "total_count": 1],
            actor: "author",
            staleAfterHours: 72
        )

        #expect(observation.repository == "sample/engine")
        #expect(observation.signals == [.reviewComment, .changesRequested, .ciFailure, .conflict])
        #expect(observation.actionableEventKey?.hasPrefix("sample/engine#91+") == true)
        #expect(observation.humanDecision == nil)
        let evidence = observation.actionableEvidence ?? []
        #expect(evidence.contains { $0.signal == .changesRequested && $0.summary.contains("session binding") })
        #expect(evidence.contains {
            $0.signal == .reviewComment
                && $0.summary.contains("restart-style")
                && !$0.summary.contains("\n")
                && $0.path == "tests/test_session.py"
                && $0.line == 42
        })
        #expect(evidence.contains { $0.signal == .ciFailure && $0.summary == "unit-tests: failure" })
        #expect(evidence.contains { $0.signal == .conflict })
    }

    @Test("only explicit human judgment evidence routes needs_user")
    func humanDecisionIsExplicitAndRepositoryGeneral() {
        let observation = GitHubCommandObservationBuilder.pullRequest(
            repository: "another/project",
            number: 3,
            pull: [
                "title": "Choose the public behavior",
                "state": "open",
                "updated_at": "2026-07-11T10:00:00Z",
                "mergeable_state": "clean",
                "head": ["sha": "head-3"],
                "labels": [["name": "product-decision"]],
            ],
            reviews: [],
            reviewComments: [],
            checkRuns: ["check_runs": []],
            combinedStatus: ["statuses": []],
            actor: "maintainer",
            staleAfterHours: 72
        )

        #expect(observation.signals.isEmpty)
        #expect(observation.humanDecision?.detail.contains("product-decision") == true)
        #expect(observation.humanDecision?.owner == "Repository owner")
    }

    // Decision-delivered rule (live case 2026-07-16, #65180): a decision
    // LABEL outlives the answer — only the repo owner can remove it — so the
    // actor having the LAST issue comment means the decision was delivered
    // and the item must wait on the maintainer, not hold needs_user forever.
    @Test("decision label with actor last word is delivered, not needs_user")
    func decisionLabelClearedByActorLastWord() {
        func observation(lastAuthor: String?) -> GitHubCommandObservation {
            GitHubCommandObservationBuilder.pullRequest(
                repository: "another/project",
                number: 3,
                pull: [
                    "title": "Choose the public behavior",
                    "state": "open",
                    "updated_at": "2026-07-11T10:00:00Z",
                    "mergeable_state": "clean",
                    "head": ["sha": "head-3"],
                    "labels": [["name": "needs-decision"]],
                ],
                reviews: [],
                reviewComments: [],
                checkRuns: ["check_runs": []],
                combinedStatus: ["statuses": []],
                actor: "contributor",
                staleAfterHours: 72,
                latestIssueCommentAuthor: lastAuthor
            )
        }
        // Actor answered last (case-insensitive) → decision delivered.
        #expect(observation(lastAuthor: "Contributor").humanDecision == nil)
        // Maintainer spoke last → the ask is live again.
        #expect(observation(lastAuthor: "maintainer").humanDecision != nil)
        // No comments at all → the ask stands.
        #expect(observation(lastAuthor: nil).humanDecision != nil)
    }

    @Test("requested-reviewer decision is NOT dismissed by a comment")
    func requestedReviewerUnaffectedByLastWord() {
        let observation = GitHubCommandObservationBuilder.pullRequest(
            repository: "another/project",
            number: 4,
            pull: [
                "title": "Review requested from the actor",
                "state": "open",
                "updated_at": "2026-07-11T10:00:00Z",
                "mergeable_state": "clean",
                "head": ["sha": "head-4"],
                "requested_reviewers": [["login": "contributor"]],
            ],
            reviews: [],
            reviewComments: [],
            checkRuns: ["check_runs": []],
            combinedStatus: ["statuses": []],
            actor: "contributor",
            staleAfterHours: 72,
            latestIssueCommentAuthor: "contributor"
        )
        // GitHub clears requested_reviewers itself when the review is
        // submitted; commenting must not dismiss an explicit review request.
        #expect(observation.humanDecision != nil)
    }

    @Test("label-armed gate and latest-comment author parsing")
    func decisionFetchHelpers() {
        #expect(GitHubCommandObservationBuilder.labelDecisionArmed(pull: ["labels": [["name": "Needs-Decision"]]]))
        #expect(!GitHubCommandObservationBuilder.labelDecisionArmed(pull: ["labels": [["name": "P3"]]]))
        #expect(!GitHubCommandObservationBuilder.labelDecisionArmed(pull: [:]))
        #expect(GitHubCommandObservationBuilder.latestCommentAuthor([["user": ["login": "contributor"], "body": "done"]]) == "contributor")
        #expect(GitHubCommandObservationBuilder.latestCommentAuthor([]) == nil)
        #expect(GitHubCommandObservationBuilder.latestCommentAuthor("garbage") == nil)
        // Comment count rides on the pull/issue object; it selects the page
        // (per-issue comments list ascending; sort/direction are ignored).
        #expect(GitHubCommandObservationBuilder.issueCommentCount(pull: ["comments": 133]) == 133)
        #expect(GitHubCommandObservationBuilder.issueCommentCount(pull: ["comments": NSNumber(value: 7)]) == 7)
        #expect(GitHubCommandObservationBuilder.issueCommentCount(pull: [:]) == 0)
    }

    @Test("a bot comment after the actor's answer never re-arms the decision")
    func botCommentDoesNotReArmDecision() {
        // Newest-last ascending page: the actor's answer followed by CI bots.
        let botTrailing: [[String: Any]] = [
            ["user": ["login": "contributor"]],
            ["user": ["login": "github-actions[bot]"]],
            ["user": ["login": "dependabot[bot]"]],
        ]
        #expect(GitHubCommandObservationBuilder.latestNonBotCommentAuthor(botTrailing) == "contributor")
        // An all-automation page yields no human author — the rule stays armed.
        #expect(GitHubCommandObservationBuilder.latestNonBotCommentAuthor([["user": ["login": "codecov[bot]"]]]) == nil)
        #expect(GitHubCommandObservationBuilder.latestNonBotCommentAuthor([]) == nil)
        #expect(GitHubCommandObservationBuilder.latestNonBotCommentAuthor("garbage") == nil)
        // A maintainer speaking last re-arms honestly.
        let maintainerLast: [[String: Any]] = [
            ["user": ["login": "contributor"]],
            ["user": ["login": "maintainer-jane"]],
        ]
        #expect(GitHubCommandObservationBuilder.latestNonBotCommentAuthor(maintainerLast) == "maintainer-jane")
        #expect(GitHubCommandObservationBuilder.isBotLogin("Renovate[Bot]"))
        #expect(GitHubCommandObservationBuilder.isBotLogin("dependabot"))
        #expect(!GitHubCommandObservationBuilder.isBotLogin("user"))
        #expect(!GitHubCommandObservationBuilder.isBotLogin(nil))
        // End to end: the actor as the newest non-bot author dismisses the
        // label branch even though bots commented afterwards.
        let observation = GitHubCommandObservationBuilder.pullRequest(
            repository: "another/project",
            number: 5,
            pull: [
                "title": "Choose the public behavior",
                "state": "open",
                "updated_at": "2026-07-11T10:00:00Z",
                "mergeable_state": "clean",
                "head": ["sha": "head-5"],
                "labels": [["name": "needs-decision"]],
            ],
            reviews: [],
            reviewComments: [],
            checkRuns: ["check_runs": []],
            combinedStatus: ["statuses": []],
            actor: "contributor",
            staleAfterHours: 72,
            latestIssueCommentAuthor: GitHubCommandObservationBuilder.latestNonBotCommentAuthor(botTrailing)
        )
        #expect(observation.humanDecision == nil)
    }

    @Test("the issue builder treats breaking-change as a decision label")
    func issueBuilderAlignsDecisionLabels() {
        let observation = GitHubCommandObservationBuilder.issue(
            repository: "sample/engine",
            row: [
                "number": 12,
                "state": "open",
                "title": "Drop the legacy API",
                "updated_at": "2026-07-20T10:00:00Z",
                "labels": [["name": "breaking-change"]],
            ],
            staleAfterHours: 72
        )
        #expect(observation?.humanDecision != nil)
    }

    @Test("resolved and outdated review threads produce no actionable signal")
    func satisfiedReviewThreadsProduceNoSignal() {
        for (resolved, outdated) in [(true, false), (false, true)] {
            let observation = makeReviewObservation(threads: [
                GitHubCommandReviewThreadEvidence(
                    threadId: "thread-701",
                    isResolved: resolved,
                    isOutdated: outdated,
                    rootCommentId: 701,
                    reviewId: 700,
                    unresolvedGeneration: 1
                ),
            ])
            #expect(observation.signals.isEmpty)
            #expect(observation.actionableEventVersion == nil)
            #expect(observation.reviewThreads?.count == 1)
        }
    }

    @Test("unresolving a thread mints a new event version without a new REST comment")
    func unresolvedTransitionMintsNewEventAndReroutes() async throws {
        let rawActive = GitHubCommandReviewThreadEvidence(
            threadId: "thread-701",
            isResolved: false,
            isOutdated: false,
            rootCommentId: 701,
            reviewId: 700
        )
        let firstThreads = GitHubConnectorActions.reconcileReviewThreads(
            current: [rawActive], previous: nil
        )
        let resolvedThreads = GitHubConnectorActions.reconcileReviewThreads(
            current: [GitHubCommandReviewThreadEvidence(
                threadId: "thread-701",
                isResolved: true,
                isOutdated: false,
                rootCommentId: 701,
                reviewId: 700
            )],
            previous: firstThreads
        )
        let reopenedThreads = GitHubConnectorActions.reconcileReviewThreads(
            current: [rawActive], previous: resolvedThreads
        )

        let first = makeReviewObservation(threads: firstThreads)
        let resolved = makeReviewObservation(threads: resolvedThreads)
        let reopened = makeReviewObservation(threads: reopenedThreads)
        #expect(first.signals == [.reviewComment, .changesRequested])
        #expect(resolved.signals.isEmpty)
        #expect(reopened.signals == first.signals)
        #expect(first.actionableEventVersion != reopened.actionableEventVersion)
        #expect(firstThreads[0].unresolvedGeneration == 1)
        #expect(reopenedThreads[0].unresolvedGeneration == 2)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-thread-transition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        #expect(try await store.observe(first).state == .needsCodex)
        #expect(try await store.observe(resolved).state == .waitingUpstream(.review))
        let rerouted = try await store.observe(reopened)
        #expect(rerouted.state == .needsCodex)
        #expect(rerouted.observation?.actionableEventVersion == reopened.actionableEventVersion)
    }

    @Test("satisfied review evidence clears tracker blocked and Today needs-User state")
    func satisfiedEvidenceClearsTrackerFlags() async throws {
        let activeThreads = [GitHubCommandReviewThreadEvidence(
            threadId: "thread-701",
            isResolved: false,
            isOutdated: false,
            rootCommentId: 701,
            reviewId: 700,
            unresolvedGeneration: 1
        )]
        let resolvedThreads = [GitHubCommandReviewThreadEvidence(
            threadId: "thread-701",
            isResolved: true,
            isOutdated: false,
            rootCommentId: 701,
            reviewId: 700,
            unresolvedGeneration: 1
        )]
        let active = GitHubConnectorActions.testDetailedTrackingEntity(
            pull: reviewPull,
            reviews: reviewRows,
            reviewComments: reviewCommentRows,
            reviewThreads: activeThreads
        )
        let satisfied = GitHubConnectorActions.testDetailedTrackingEntity(
            pull: reviewPull,
            reviews: reviewRows,
            reviewComments: reviewCommentRows,
            reviewThreads: resolvedThreads
        )
        guard case .object(let activeObject) = active,
              case .object(let satisfiedObject) = satisfied else {
            Issue.record("tracking entities were not objects")
            return
        }
        #expect(activeObject["blocked"] == .bool(true))
        #expect(activeObject["needsUser"] == .bool(false))
        #expect(satisfiedObject["blocked"] == .bool(false))
        #expect(satisfiedObject["needsUser"] == .bool(false))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-thread-flags-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitHubConnectorActions.testUpsertTrackingEntities(
            [active], project: "Review work", changedKeys: ["owner/repo#pr#7"], dataRoot: root
        )
        _ = try await GitHubConnectorActions.testUpsertTrackingEntities(
            [satisfied],
            project: "Review work",
            changedKeys: ["owner/repo#pr#7"],
            previousRows: [active],
            dataRoot: root
        )
        // Actionable-only Desk policy: the satisfied entity's row retires
        // entirely rather than parking as watch — the Workshop's GitHub lane
        // carries tracked-but-quiet work.
        let store = SwiftNativeDeskStore(dataRoot: root)
        #expect(try await store.liveState().items.isEmpty)
        let archived = try await store.archivedRecords()
        #expect(archived.count == 1)
    }

    @Test("review-thread batch sizing preserves the GraphQL reserve")
    func reviewThreadBatchSizingIsRateLimitAware() {
        #expect(GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: nil, lastCost: nil, lastBatchCount: 0
        ) == 8)
        #expect(GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: 24, lastCost: 8, lastBatchCount: 8
        ) == 4)
        #expect(GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: 20, lastCost: 8, lastBatchCount: 8
        ) == 0)
        // Spendable budget smaller than one page's estimated cost must stop,
        // not send a final page that overruns the reserve.
        #expect(GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: 24, lastCost: 64, lastBatchCount: 8
        ) == 0)
    }

    @Test("a thread without a root comment ID never correlates or suppresses")
    func threadWithoutRootCommentDoesNotCorrelate() {
        let observation = makeReviewObservation(threads: [
            GitHubCommandReviewThreadEvidence(
                threadId: "thread-unrooted",
                isResolved: true,
                isOutdated: false,
                rootCommentId: nil,
                reviewId: nil,
                unresolvedGeneration: 1
            ),
        ])
        #expect(observation.signals.contains(.reviewComment))
    }

    @Test("store evidence that is further along wins the tracker seed merge")
    func storeEvidenceMergesByLifecycle() {
        let snapshotStale = GitHubCommandReviewThreadEvidence(
            threadId: "thread-701", isResolved: false, isOutdated: false,
            rootCommentId: 701, reviewId: 700, unresolvedGeneration: 1
        )
        let storeFresh = GitHubCommandReviewThreadEvidence(
            threadId: "thread-701", isResolved: true, isOutdated: false,
            rootCommentId: 701, reviewId: 700, unresolvedGeneration: 1
        )
        let merged = GitHubConnectorActions.mergeReviewThreadEvidence([snapshotStale], [storeFresh])
        #expect(merged == [storeFresh])
        #expect(GitHubConnectorActions.mergeReviewThreadEvidence([storeFresh], [snapshotStale]) == merged)

        // Reopened upstream: reconciling against the merged seed mints
        // generation 2, which the stale snapshot seed alone would have missed.
        let reopened = GitHubConnectorActions.reconcileReviewThreads(
            current: [GitHubCommandReviewThreadEvidence(
                threadId: "thread-701", isResolved: false, isOutdated: false,
                rootCommentId: 701, reviewId: 700
            )],
            previous: merged
        )
        #expect(reopened[0].unresolvedGeneration == 2)
    }

    @Test("quiet-but-stale tracked work waits instead of demanding attention")
    func staleQuietWorkWaitsInsteadOfAttention() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-stale-waits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let quietStale = GitHubCommandObservation(
            repository: "owner/repo", number: 9, kind: .issue,
            title: "Dormant upstream issue", isOpen: true,
            observedVersion: "2026-07-01T00:00:00Z",
            waitingKind: .maintainer, isStale: true
        )
        let item = try await store.observe(quietStale)
        #expect(item.state == .waitingUpstream(.maintainer))
        #expect(item.blocker == nil)
    }

    @Test("a red dispatch failure survives a quiet stale poll")
    func dispatchFailureSurvivesStalePoll() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-dispatchfail-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let actionable = makeReviewObservation(threads: [GitHubCommandReviewThreadEvidence(
            threadId: "thread-701", isResolved: false, isOutdated: false,
            rootCommentId: 701, reviewId: 700, unresolvedGeneration: 1
        )])
        let item = try await store.observe(actionable)
        #expect(item.state == .needsCodex)
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let failed = try await store.recordDispatchFailure(
            itemId: item.itemId, eventKey: intent.eventKey, detail: "bridge down"
        )
        #expect(failed.state == .attention(.dispatchFailed))

        // A stale quiet re-poll must not park the failure as waiting — that
        // would silently end retries and hide the red state.
        let staleQuiet = GitHubCommandObservation(
            repository: "owner/repo", number: 7, kind: .pullRequest,
            title: "Address review", isOpen: true,
            observedVersion: "2026-07-12T00:00:00Z",
            waitingKind: .review, isStale: true
        )
        let after = try await store.observe(staleQuiet)
        #expect(after.state == .attention(.dispatchFailed))
    }

    @Test("a raced stale re-observation cannot regress stored thread evidence")
    func staleReobservationCannotRegressStoredEvidence() async throws {
        let rawActive = GitHubCommandReviewThreadEvidence(
            threadId: "thread-701", isResolved: false, isOutdated: false,
            rootCommentId: 701, reviewId: 700
        )
        let firstThreads = GitHubConnectorActions.reconcileReviewThreads(
            current: [rawActive], previous: nil
        )
        let resolvedThreads = GitHubConnectorActions.reconcileReviewThreads(
            current: [GitHubCommandReviewThreadEvidence(
                threadId: "thread-701", isResolved: true, isOutdated: false,
                rootCommentId: 701, reviewId: 700
            )],
            previous: firstThreads
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-thread-regress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        _ = try await store.observe(makeReviewObservation(threads: firstThreads))
        _ = try await store.observe(makeReviewObservation(threads: resolvedThreads))
        // A refresh that raced callback verification replays the stale active
        // g1 evidence. The store must preserve the fresher resolved g1 …
        let raced = try await store.observe(makeReviewObservation(threads: firstThreads))
        #expect(raced.observation?.reviewThreads == resolvedThreads)
        // … the stale actionability claim must not re-route the quiet item …
        #expect(raced.state == .waitingUpstream(.review))
        #expect(raced.observation?.signals.isEmpty == true)
        // … and the next reconciliation still mints generation 2 for a reopen.
        let next = GitHubConnectorActions.reconcileReviewThreads(
            current: [rawActive], previous: raced.observation?.reviewThreads
        )
        #expect(next[0].unresolvedGeneration == 2)
    }

    @Test("GraphQL reviewThreads fields become authoritative observation evidence")
    func graphQLReviewThreadParsing() throws {
        let threads = try GitHubConnectorActions.testParseReviewThreadPage([
            "data": [
                "pr0": [
                    "pullRequest": [
                        "reviewThreads": [
                            "nodes": [[
                                "id": "PRRT_authoritative",
                                "isResolved": true,
                                "isOutdated": false,
                                "comments": [
                                    "nodes": [[
                                        "databaseId": 701,
                                        "pullRequestReview": ["databaseId": 700],
                                    ]],
                                ],
                            ]],
                            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                        ],
                    ],
                ],
                "rateLimit": [
                    "cost": 2,
                    "remaining": 4_998,
                    "resetAt": "2026-07-12T10:00:00Z",
                ],
            ],
        ])
        let thread = try #require(threads.first)
        #expect(thread.threadId == "PRRT_authoritative")
        #expect(thread.isResolved)
        #expect(!thread.isOutdated)
        #expect(thread.rootCommentId == 701)
        #expect(thread.reviewId == 700)
    }

    private var reviewPull: [String: Any] {
        [
            "number": 7,
            "title": "Address review",
            "state": "open",
            "updated_at": "2026-07-11T10:00:00Z",
            "mergeable_state": "clean",
            "head": ["sha": "head-7"],
            "html_url": "https://github.com/owner/repo/pull/7",
            "user": ["login": "contributor"],
        ]
    }

    private var reviewRows: [[String: Any]] {
        [[
            "id": 700,
            "state": "CHANGES_REQUESTED",
            "submitted_at": "2026-07-11T09:30:00Z",
            "user": ["login": "reviewer"],
        ]]
    }

    private var reviewCommentRows: [[String: Any]] {
        [[
            "id": 701,
            "updated_at": "2026-07-11T09:45:00Z",
            "commit_id": "head-7",
        ]]
    }

    private func makeReviewObservation(
        threads: [GitHubCommandReviewThreadEvidence]
    ) -> GitHubCommandObservation {
        GitHubCommandObservationBuilder.pullRequest(
            repository: "owner/repo",
            number: 7,
            pull: reviewPull,
            reviews: reviewRows,
            reviewComments: reviewCommentRows,
            checkRuns: ["check_runs": []],
            combinedStatus: ["statuses": []],
            actor: "contributor",
            staleAfterHours: 72,
            reviewThreads: threads
        )
    }
}
