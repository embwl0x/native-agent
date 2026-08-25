import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import GitHubConnector

// Eval coverage (ledger fence core.connectors) for the GitHub connector's
// three unwatched surfaces: the envelope redactor, the GraphQL review-thread
// evidence path (silent zero / silent empty), and the WRITE fan-out's
// pre-flight guards. Everything here is pure or fails before `call(...)`,
// so no test can reach api.github.com.

private func githubEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("github-eval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Every github.* envelope is built through this redactor, so a leak test has
/// to walk nesting, not just a top-level string.
@Suite("GitHub envelope redaction")
struct GitHubSecretRedactorTests {
    // GitHubConnectorActions.swift:480. A pattern that stops matching ships
    // PATs into chat, memory and the activity feed with a normal-looking UI.
    @Test
    func recognizableTokenShapesAreRedactedAtEveryNestingDepth() throws {
        // Split literals so secret scanners never see a whole token shape.
        let classic = "ghp_" + String(repeating: "A", count: 36)
        let oauth = "gho_" + String(repeating: "B", count: 36)
        let server = "ghs_" + String(repeating: "C", count: 36)
        let fineGrained = "github_pat_" + String(repeating: "D", count: 30)

        let envelope: JSONValue = .object([
            "actionId": .string("github.status"),
            "top": .string("token \(classic) trailing"),
            "rows": .array([
                .string(oauth),
                .object(["header": .string("Authorization: Bearer \(fineGrained)")]),
            ]),
            "nested": .object([
                "deeper": .object(["value": .string(server)]),
            ]),
        ])

        let redacted = GitHubConnectorSecretRedactor.redactValue(envelope)
        let serialized = String(decoding: try redacted.serializedData(pretty: false), as: UTF8.self)

        for secret in [classic, oauth, server, fineGrained] {
            #expect(!serialized.contains(secret), "an unredacted token survived: \(secret.prefix(4))…")
        }
        #expect(serialized.contains("[REDACTED_GITHUB_TOKEN]"))
        // Non-secret content around the match must survive — a redactor that
        // blanks whole strings would hide the error the envelope is carrying.
        #expect(serialized.contains("trailing"))
        #expect(serialized.contains("github.status"))
    }
}

@Suite("GitHub review-thread evidence")
struct GitHubReviewThreadEvidenceTests {
    // GitHubReviewThreads.swift:341. Silent zero at the moment it matters: a
    // 0 batch means NO pull request gets review-thread evidence that sweep,
    // and a PR with an unresolved blocking thread then presents as clean.
    // The caller turns a 0 into a thrown 429 (:79-86) rather than an empty
    // (therefore "clean") thread list — asserted here only at the boundary
    // function, since reaching the caller's guard requires a live GraphQL
    // round trip first.
    @Test
    func batchLimitSpendsNothingOnceTheRateLimitReserveIsReached() throws {
        // Unknown budget (first batch of a sweep) → the full batch.
        #expect(GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: nil, lastCost: nil, lastBatchCount: 0) == 8)
        // Plenty of budget → still capped by the maximum batch size.
        #expect(GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: 5_000, lastCost: 8, lastBatchCount: 8) == 8)
        // AT and BELOW the reserve → refuse to spend.
        #expect(GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: 20, lastCost: 8, lastBatchCount: 8) == 0)
        #expect(GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: 19, lastCost: 8, lastBatchCount: 8) == 0)
        // Just above the reserve → a bounded, non-zero batch that cannot
        // exceed what is spendable above the reserve.
        let narrow = GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: 21, lastCost: 1, lastBatchCount: 1)
        #expect(narrow >= 1 && narrow <= 8)
        let costly = GitHubConnectorActions.testReviewThreadBatchLimit(
            remaining: 24, lastCost: 40, lastBatchCount: 8)
        #expect(costly * 5 <= 4, "a 5-point-per-PR estimate must not overrun a 4-point budget")
    }

    // A GraphQL schema change or an errors body must NOT degrade into an
    // empty page: an empty thread list reads as "nothing blocking".
    @Test
    func parseRefusesErrorBodiesAndSchemaDriftInsteadOfReturningAnEmptyPage() throws {
        let errorBody: [String: Any] = [
            "errors": [["message": "Field 'reviewThreads' doesn't exist"]],
            "data": ["rateLimit": ["remaining": 4_900, "cost": 1]],
        ]
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.testParseReviewThreadPage(errorBody)
        }

        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.testParseReviewThreadPage(["message": "Bad credentials"])
        }

        // `data` present, but the aliased PR selection drifted away.
        let drifted: [String: Any] = ["data": ["rateLimit": ["remaining": 4_900, "cost": 1]]]
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.testParseReviewThreadPage(drifted)
        }

        // Pagination that claims a next page without a cursor would silently
        // drop every later thread.
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.testParseReviewThreadPage(
                reviewThreadRoot(nodes: [], hasNextPage: true, endCursor: nil)
            )
        }
    }

    @Test
    func parseCarriesResolvedAndOutdatedFlagsForAWellFormedPage() throws {
        let threads = try GitHubConnectorActions.testParseReviewThreadPage(
            reviewThreadRoot(
                nodes: [
                    [
                        "id": "THREAD_1", "isResolved": false, "isOutdated": false,
                        "comments": ["nodes": [[
                            "databaseId": 4_242,
                            "pullRequestReview": ["databaseId": 99],
                        ]]],
                    ],
                    ["id": "THREAD_2", "isResolved": true, "isOutdated": true, "comments": ["nodes": []]],
                ],
                hasNextPage: false,
                endCursor: nil
            )
        )
        #expect(threads.count == 2)
        let unresolved = try #require(threads.first { $0.threadId == "THREAD_1" })
        #expect(unresolved.isResolved == false)
        #expect(unresolved.rootCommentId == 4_242)
        let resolved = try #require(threads.first { $0.threadId == "THREAD_2" })
        #expect(resolved.isResolved == true)
        #expect(resolved.isOutdated == true)
    }

    // A malformed node must fail the page, not be skipped — a skipped
    // unresolved thread is indistinguishable from a resolved one.
    @Test
    func parseRefusesAThreadNodeMissingItsResolutionFlags() throws {
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.testParseReviewThreadPage(
                reviewThreadRoot(
                    nodes: [["id": "THREAD_1", "isOutdated": false]],
                    hasNextPage: false,
                    endCursor: nil
                )
            )
        }
    }

    private func reviewThreadRoot(
        nodes: [[String: Any]],
        hasNextPage: Bool,
        endCursor: String?
    ) -> [String: Any] {
        var pageInfo: [String: Any] = ["hasNextPage": hasNextPage]
        if let endCursor { pageInfo["endCursor"] = endCursor }
        return [
            "data": [
                "pr0": [
                    "pullRequest": [
                        "reviewThreads": ["nodes": nodes, "pageInfo": pageInfo],
                    ],
                ],
                "rateLimit": ["remaining": 4_900, "cost": 1],
            ],
        ]
    }
}

@Suite("GitHub write pre-flight")
struct GitHubWritePreflightTests {
    // GitHubProjectTracking.swift:127 — the connector's entire write fan-out
    // (issue/PR create, comment, close/merge). Every refusal below happens
    // before `call(...)`, which is the only thing standing between a body
    // builder regression and a comment on the wrong issue.
    @Test
    func mutateRefusesMalformedWritesBeforeIssuingARequest() async throws {
        let root = try githubEvalRoot()

        func expectInvalidInput(
            _ what: Comment,
            _ input: [String: JSONValue]
        ) async {
            do {
                _ = try await GitHubConnectorActions.mutate(input: input, dataRoot: root)
                Issue.record("expected a refusal: \(what)")
            } catch let error as GitHubConnectorError {
                guard case .invalidInput = error else {
                    Issue.record("expected invalidInput for \(what), got \(error)")
                    return
                }
            } catch {
                Issue.record("expected GitHubConnectorError for \(what), got \(error)")
            }
        }

        await expectInvalidInput("create_issue without a title", [
            "operation": .string("create_issue"),
            "repo": .string("owner/repo"),
            "body": .string("no title"),
        ])
        await expectInvalidInput("a repository without an owner", [
            "operation": .string("create_issue"),
            "repo": .string("repo"),
            "title": .string("t"),
        ])
        await expectInvalidInput("a non-positive number", [
            "operation": .string("comment_issue"),
            "repo": .string("owner/repo"),
            "number": .int(0),
            "body": .string("hi"),
        ])
        await expectInvalidInput("a negative number", [
            "operation": .string("close_issue"),
            "repo": .string("owner/repo"),
            "number": .int(-3),
        ])
        await expectInvalidInput("comment without a body", [
            "operation": .string("comment_issue"),
            "repo": .string("owner/repo"),
            "number": .int(7),
        ])
        await expectInvalidInput("create_pull_request without head/base", [
            "operation": .string("create_pull_request"),
            "repo": .string("owner/repo"),
            "title": .string("t"),
        ])
        await expectInvalidInput("request_reviewers with nobody to request", [
            "operation": .string("request_reviewers"),
            "repo": .string("owner/repo"),
            "number": .int(7),
        ])
        // An update whose builder produced NO fields would PATCH an empty
        // body and report success having changed nothing.
        await expectInvalidInput("update_issue with no fields to update", [
            "operation": .string("update_issue"),
            "repo": .string("owner/repo"),
            "number": .int(7),
        ])
        await expectInvalidInput("an unsupported operation", [
            "operation": .string("delete_repository"),
            "repo": .string("owner/repo"),
        ])
    }

    // GitHubConnectorActions.swift:92 — this action flips a repository
    // public/private on github.com. An ambiguous target or an unrecognized
    // visibility token must throw, never default.
    @Test
    func setRepoVisibilityRefusesAnAmbiguousTargetOrVisibility() async throws {
        let root = try githubEvalRoot()

        func expectRefusal(_ what: Comment, _ input: [String: JSONValue]) async {
            do {
                _ = try await GitHubConnectorActions.setRepoVisibility(input: input, dataRoot: root)
                Issue.record("expected a refusal: \(what)")
            } catch let error as GitHubConnectorError {
                guard case .invalidInput = error else {
                    Issue.record("expected invalidInput for \(what), got \(error)")
                    return
                }
            } catch {
                Issue.record("expected GitHubConnectorError for \(what), got \(error)")
            }
        }

        await expectRefusal("no repository at all", ["private": .bool(true)])
        await expectRefusal("a bare repo name with no owner", [
            "repo": .string("repo"), "private": .bool(true),
        ])
        await expectRefusal("no visibility token", ["repo": .string("owner/repo")])
        await expectRefusal("an unrecognized visibility token", [
            "repo": .string("owner/repo"), "visibility": .string("internal"),
        ])
        await expectRefusal("a numeric visibility that is not a boolean", [
            "repo": .string("owner/repo"), "visibility": .int(1),
        ])
    }
}

@Suite("GitHub repository reading")
struct GitHubRepositoryReadingEvalTests {
    // GitHubRepositoryReading.swift:300 (repositoryRef) decides whether
    // `sha` reaches the commits query at all. A ref that silently becomes nil
    // answers a feature-branch question with default-branch commits.
    @Test
    func commitRefDerivationPassesRealRefsThroughAndRefusesInjectionShapes() throws {
        #expect(try GitHubConnectorActions.repositoryRef(.string("feature/my-branch"))
            == "feature/my-branch")
        #expect(try GitHubConnectorActions.repositoryRef(.string("  main  ")) == "main")
        // Absent/blank refs are the documented default-branch fall-through —
        // nil is what omits `sha` from the query.
        #expect(try GitHubConnectorActions.repositoryRef(nil) == nil)
        #expect(try GitHubConnectorActions.repositoryRef(.string("   ")) == nil)

        for bad in ["a..b", "back\\slash", "tilde~1", "caret^2", String(repeating: "x", count: 251)] {
            #expect(throws: GitHubConnectorError.self) {
                _ = try GitHubConnectorActions.repositoryRef(.string(bad))
            }
        }
    }

    @Test
    func repositoryIdentityResolvesTheSameTargetFromEveryAcceptedInputShape() throws {
        #expect(try GitHubConnectorActions.repositoryIdentity(["repo": .string("owner/repo")])
            .fullName == "owner/repo")
        #expect(try GitHubConnectorActions.repositoryIdentity([
            "owner": .string("owner"), "repo": .string("repo"),
        ]).fullName == "owner/repo")
        #expect(try GitHubConnectorActions.repositoryIdentity([
            "url": .string("https://github.com/owner/repo.git"),
        ]).fullName == "owner/repo")
        // A non-github host must never be reached with the user's PAT.
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.repositoryIdentity([
                "url": .string("https://evil.example/owner/repo"),
            ])
        }
        #expect(throws: GitHubConnectorError.self) {
            _ = try GitHubConnectorActions.repositoryIdentity(["repo": .string("repo")])
        }
    }

    // The projection is what the model actually reads. It must stay bounded by
    // the caller's limit and keep the identifying fields of each commit.
    @Test
    func commitProjectionStaysBoundedAndKeepsIdentifyingFields() throws {
        let source: [[String: Any]] = (0..<30).map { index in
            [
                "sha": "sha-\(index)",
                "html_url": "https://github.com/owner/repo/commit/sha-\(index)",
                "commit": [
                    "message": "commit message \(index)",
                    "author": ["name": "Author \(index)", "email": "a@example.com", "date": "2026-08-01T00:00:00Z"],
                ],
                "author": ["login": "octocat"],
            ]
        }
        let projection = GitHubToolProjection.commits(source, limit: 5)
        #expect(projection.rows.count == 5)
        #expect(projection.sourceCount == 30)
        #expect(projection.truncated)
        let first = try #require(projection.rows.first)
        #expect(first["sha"] as? String == "sha-0")
        let detail = try #require(first["commit"] as? [String: Any])
        #expect(detail["message"] as? String == "commit message 0")

        // A short page is not truncated — the flag has to distinguish the two.
        let short = GitHubToolProjection.commits(Array(source.prefix(2)), limit: 5)
        #expect(short.rows.count == 2)
        #expect(!short.truncated)
    }
}
