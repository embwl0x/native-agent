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

    @Test("review label gates wait on maintainers while real CI failures still route")
    func reviewLabelGateIsMaintainerOwned() {
        func observation(extraFailure: Bool) -> GitHubCommandObservation {
            var runs: [[String: Any]] = [
                ["id": 1, "name": "Review label gate", "status": "completed", "conclusion": "failure"],
                ["id": 2, "name": "All required checks pass", "status": "completed", "conclusion": "failure"],
            ]
            if extraFailure {
                runs.append(["id": 3, "name": "Python tests", "status": "completed", "conclusion": "failure"])
            }
            return GitHubCommandObservationBuilder.pullRequest(
                repository: "sample/engine",
                number: 92,
                pull: [
                    "title": "Wait for review",
                    "state": "open",
                    "updated_at": "2026-08-19T10:00:00Z",
                    "mergeable_state": "clean",
                    "head": ["sha": "head-92"],
                ],
                reviews: [],
                reviewComments: [],
                checkRuns: ["check_runs": runs],
                combinedStatus: ["state": "pending", "total_count": 0, "statuses": []],
                actor: "author",
                staleAfterHours: 72
            )
        }

        let maintainerOnly = observation(extraFailure: false)
        #expect(maintainerOnly.signals.isEmpty)
        #expect(maintainerOnly.actionableEventVersion == nil)
        #expect(maintainerOnly.waitingKind == .maintainer)

        let technical = observation(extraFailure: true)
        #expect(technical.signals == [.ciFailure])
        #expect(technical.actionableEvidence?.count == 1)
        #expect(technical.actionableEvidence?.first?.summary == "Python tests: failure")
    }

    @Test("decision labels require assignment before routing needs_user")
    func decisionLabelsRequireAssignment() {
        func observation(assignees: [[String: Any]] = []) -> GitHubCommandObservation {
            GitHubCommandObservationBuilder.pullRequest(
                repository: "another/project",
                number: 3,
                pull: [
                    "title": "Choose the public behavior",
                    "state": "open",
                    "updated_at": "2026-07-11T10:00:00Z",
                    "mergeable_state": "clean",
                    "head": ["sha": "head-3"],
                    "labels": [["name": "product-decision"]],
                    "assignees": assignees,
                ],
                reviews: [],
                reviewComments: [],
                checkRuns: ["check_runs": []],
                combinedStatus: ["statuses": []],
                actor: "maintainer",
                staleAfterHours: 72
            )
        }

        #expect(observation().signals.isEmpty)
        #expect(observation().humanDecision == nil)
        let assigned = observation(assignees: [["login": "maintainer"]])
        #expect(assigned.humanDecision?.detail.contains("product-decision") == true)
        #expect(assigned.humanDecision?.owner == "maintainer")
    }

    @Test("an unassigned upstream decision never creates owner-attention Desk work")
    func unassignedDecisionDoesNotCreateDeskWork() async throws {
        let entity = GitHubConnectorActions.testDetailedTrackingEntity(
            pull: [
                "number": 7,
                "title": "Choose the upstream behavior",
                "state": "open",
                "updated_at": "2026-07-11T10:00:00Z",
                "html_url": "https://github.com/owner/repo/pull/7",
                "mergeable_state": "clean",
                "head": ["sha": "head-7"],
                "labels": [["name": "needs-decision"]],
                "user": ["login": "contributor"],
            ],
            reviews: [],
            reviewComments: [],
            reviewThreads: []
        )
        guard case .object(let object) = entity else {
            Issue.record("tracking entity was not an object")
            return
        }
        #expect(object["needsUser"] == .bool(false))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-unassigned-decision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await GitHubConnectorActions.testUpsertTrackingEntities(
            [entity], project: "Upstream work", changedKeys: ["owner/repo#pr#7"], dataRoot: root
        )
        #expect(result == .object(["archived": .int(0), "created": .int(0), "updated": .int(0)]))
        #expect(try await SwiftNativeDeskStore(dataRoot: root).liveState().items.isEmpty)
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
                    "assignees": [["login": "contributor"]],
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
        #expect(GitHubCommandObservationBuilder.labelDecisionArmed(
            pull: ["labels": [["name": "Needs-Decision"]], "assignees": [["login": "contributor"]]],
            repository: "another/project", actor: "contributor"
        ))
        #expect(!GitHubCommandObservationBuilder.labelDecisionArmed(
            pull: ["labels": [["name": "Needs-Decision"]]],
            repository: "another/project", actor: "contributor"
        ))
        #expect(!GitHubCommandObservationBuilder.labelDecisionArmed(
            pull: ["labels": [["name": "P3"]]], repository: "another/project", actor: "contributor"
        ))
        #expect(!GitHubCommandObservationBuilder.labelDecisionArmed(
            pull: [:], repository: "another/project", actor: "contributor"
        ))
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
                "assignees": [["login": "contributor"]],
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

    @Test("new external PR conversation feedback is actionable without replaying history")
    func externalIssueCommentDetectionUsesDetailCutoff() throws {
        let comments: [[String: Any]] = [[
            "id": 900,
            "created_at": "2026-07-11T10:05:00Z",
            "updated_at": "2026-07-11T10:05:00Z",
            "body": "Please add cleanup-warning coverage.\nKeep the existing fallback.",
            "html_url": "https://github.com/sample/engine/pull/91#issuecomment-900",
            "user": ["login": "reviewer"],
        ]]
        func observation(cutoff: String) -> GitHubCommandObservation {
            GitHubCommandObservationBuilder.pullRequest(
                repository: "sample/engine",
                number: 91,
                pull: [
                    "title": "Repair cleanup",
                    "state": "open",
                    "updated_at": "2026-07-11T10:05:00Z",
                    "mergeable_state": "clean",
                    "head": ["sha": "head-91"],
                ],
                reviews: [],
                reviewComments: [],
                checkRuns: ["check_runs": []],
                combinedStatus: ["statuses": []],
                actor: "author",
                staleAfterHours: 72,
                issueComments: comments,
                issueCommentNotBefore: DeskClock.parseISO(cutoff)
            )
        }

        let fresh = observation(cutoff: "2026-07-11T10:00:00Z")
        #expect(fresh.signals == [.issueComment])
        #expect(fresh.actionableEventVersion?.contains("issue_comment:900") == true)
        let evidence = try #require(fresh.actionableEvidence?.first)
        #expect(evidence.signal == .issueComment)
        #expect(evidence.author == "reviewer")
        #expect(evidence.summary.contains("cleanup-warning coverage"))
        #expect(!evidence.summary.contains("\n"))

        let historical = observation(cutoff: "2026-07-11T10:06:00Z")
        #expect(historical.signals.isEmpty)
    }

    @Test("exact issue-comment verification settles after a new head or contributor reply")
    func exactIssueCommentVerificationUsesHeadAndLastWord() {
        let external: [String: Any] = [
            "id": 900,
            "created_at": "2026-07-11T10:05:00Z",
            "user": ["login": "reviewer"],
        ]
        let response: [String: Any] = [
            "id": 901,
            "created_at": "2026-07-11T10:06:00Z",
            "user": ["login": "author"],
        ]
        func observation(head: String, comments: [[String: Any]]) -> GitHubCommandObservation {
            GitHubCommandObservationBuilder.pullRequest(
                repository: "sample/engine",
                number: 91,
                pull: [
                    "title": "Repair cleanup", "state": "open",
                    "updated_at": "2026-07-11T10:06:00Z",
                    "mergeable_state": "clean", "head": ["sha": head],
                ],
                reviews: [], reviewComments: [],
                checkRuns: ["check_runs": []], combinedStatus: ["statuses": []],
                actor: "author", staleAfterHours: 72,
                issueComments: comments,
                expectedIssueCommentIdentifier: "900",
                expectedIssueCommentHeadSHA: "head-91"
            )
        }

        #expect(observation(head: "head-91", comments: [external]).signals == [.issueComment])
        #expect(observation(head: "head-92", comments: [external]).signals.isEmpty)
        #expect(observation(head: "head-91", comments: [external, response]).signals.isEmpty)
    }

    @Test("issue decision labels also require contributor assignment")
    func issueBuilderRequiresAssignment() {
        func observation(assignees: [[String: Any]] = []) -> GitHubCommandObservation? {
            GitHubCommandObservationBuilder.issue(
                repository: "sample/engine",
                row: [
                    "number": 12,
                    "state": "open",
                    "title": "Drop the legacy API",
                    "updated_at": "2026-07-20T10:00:00Z",
                    "labels": [["name": "breaking-change"]],
                    "assignees": assignees,
                ],
                actor: "contributor",
                staleAfterHours: 72
            )
        }
        #expect(observation()?.humanDecision == nil)
        #expect(observation(assignees: [["login": "contributor"]])?.humanDecision?.owner == "contributor")
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

    @Test("GraphQL mergeability defeats REST unknown after base movement")
    func graphQLMergeabilityParsing() throws {
        let evidence = try GitHubConnectorActions.testParseMergeabilityPage([
            "data": [
                "pr0": [
                    "pullRequest": [
                        "headRefOid": "head-7",
                        "updatedAt": "2026-07-11T10:00:00Z",
                        "mergeable": "CONFLICTING",
                        "mergeStateStatus": "DIRTY",
                    ],
                ],
                "rateLimit": [
                    "cost": 1,
                    "remaining": 4_999,
                    "resetAt": "2026-07-12T10:00:00Z",
                ],
            ],
        ])
        #expect(evidence.headSHA == "head-7")
        #expect(evidence.mergeableState == "dirty")
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

/// Cross-review HIGH (2026-08-17): the SELF-CLEAR. Sweep 1 detects a
/// conversation comment against the prior detailFetchedAt watermark and writes
/// a fresh stamp; sweep 2 then compares that same comment against the NEW
/// stamp, finds nothing actionable, and route() falls through to the no-event
/// tail — knocking an item codex is actively working from codex_working to
/// waiting_upstream and stamping its event settled. The tracking sweep must
/// carry the expected comment identity forward, exactly like the verification
/// path, so the signal survives until the comment is genuinely answered.
@Suite("GitHub issue-comment persistence across sweeps")
struct GitHubIssueCommentSweepPersistenceTests {
    private let comment: [String: Any] = [
        "id": 900,
        "created_at": "2026-07-11T10:05:00Z",
        "body": "Please add cleanup-warning coverage.",
        "user": ["login": "reviewer"],
    ]

    private func observation(
        notBefore: String,
        expectedIdentifier: String?,
        expectedHead: String?
    ) -> GitHubCommandObservation {
        GitHubCommandObservationBuilder.pullRequest(
            repository: "sample/engine",
            number: 91,
            pull: [
                "title": "Repair cleanup", "state": "open",
                "updated_at": "2026-07-11T10:05:00Z",
                "mergeable_state": "clean", "head": ["sha": "head-91"],
            ],
            reviews: [], reviewComments: [],
            checkRuns: ["check_runs": []], combinedStatus: ["statuses": []],
            actor: "author", staleAfterHours: 72,
            issueComments: [comment],
            issueCommentNotBefore: DeskClock.parseISO(notBefore),
            expectedIssueCommentIdentifier: expectedIdentifier,
            expectedIssueCommentHeadSHA: expectedHead
        )
    }

    /// Sweep 1: the watermark predates the comment — detected.
    @Test func firstSweepDetectsTheComment() {
        let first = observation(
            notBefore: "2026-07-11T10:00:00Z", expectedIdentifier: nil, expectedHead: nil)
        #expect(first.signals == [.issueComment])
    }

    /// Sweep 2 WITHOUT the carried identity — the regression, kept as the
    /// explicit statement of what the watermark alone does.
    @Test func watermarkAloneLosesTheEventOnTheNextSweep() {
        let second = observation(
            notBefore: "2026-07-11T10:30:00Z", expectedIdentifier: nil, expectedHead: nil)
        #expect(second.signals.isEmpty,
                "documented failure mode: the stamp moved past the comment")
    }

    /// Sweep 2 WITH the carried identity — the fix. The unanswered comment is
    /// still actionable no matter how far the stamp has advanced.
    @Test func carriedIdentityKeepsTheEventAliveUntilAnswered() {
        let second = observation(
            notBefore: "2026-07-11T10:30:00Z", expectedIdentifier: "900", expectedHead: "head-91")
        #expect(second.signals == [.issueComment])
        #expect(second.actionableEventVersion?.contains("issue_comment:900") == true)
    }

    /// …and it still SETTLES honestly once the contributor answers.
    @Test func carriedIdentityStillSettlesOnAContributorReply() {
        let reply: [String: Any] = [
            "id": 901, "created_at": "2026-07-11T10:40:00Z", "user": ["login": "author"],
        ]
        let settled = GitHubCommandObservationBuilder.pullRequest(
            repository: "sample/engine", number: 91,
            pull: [
                "title": "Repair cleanup", "state": "open",
                "updated_at": "2026-07-11T10:40:00Z",
                "mergeable_state": "clean", "head": ["sha": "head-91"],
            ],
            reviews: [], reviewComments: [],
            checkRuns: ["check_runs": []], combinedStatus: ["statuses": []],
            actor: "author", staleAfterHours: 72,
            issueComments: [comment, reply],
            issueCommentNotBefore: DeskClock.parseISO("2026-07-11T10:30:00Z"),
            expectedIssueCommentIdentifier: "900",
            expectedIssueCommentHeadSHA: "head-91"
        )
        #expect(settled.signals.isEmpty, "the author had the last word — the event is answered")
    }
}
