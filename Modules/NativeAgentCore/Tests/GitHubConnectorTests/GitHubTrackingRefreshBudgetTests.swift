// W6 / L4-03 — the github_tracking tick-timeout defect.
//
// PREMISE AS RECORDED vs PREMISE AS FOUND (STEP 0):
// L4-03 cites 621 `timeout after 120s` receipts. Those are HISTORICAL — every
// one falls in 2026-07-12..2026-07-16, and commit 127a2827 already raised
// `tickTimeoutOverride` from 120s to 600s. The defect is NOT fixed, it is
// displaced: `background_loop_failures.jsonl` carries `timeout after 600s`
// receipts on 2026-07-30 and again 2026-08-11. Raising the wall bought four
// weeks; it did not bound the pass.
//
// ROOT CAUSE (read, not guessed): the refresh is ONE sequential sweep over
// every tracked repository, and per-request timeouts are already tight (30s,
// `GitHubConnectorActions.call:281`). So no single request eats the tick — the
// SUM does, and it has no ceiling. Worse, `try await` inside `for repo in
// config.repositories` propagated straight out of `refresh()`: one repository
// throwing (the live 404/502/504 receipts) discarded every other repository's
// work for that tick, and a tick killed by the timeout wrote nothing at all.
//
// These tests pin the two properties that make that impossible, with an
// injected clock — no network, no wall-clock sleep, no elapsed-time assertion.

import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import GitHubConnector

/// Deterministic fake clock. `@unchecked Sendable` is honest here: the pass is
/// strictly sequential, so there is no concurrent access to serialize.
private final class FakeClock: @unchecked Sendable {
    private var current: Date
    init(_ start: Date) { self.current = start }
    var now: Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

@Test
func trackingDeadlineUsesCanonicalLearnedDeskCadence() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitHubTrackingDeadline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("connectors/github", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let refreshed = Date(timeIntervalSince1970: 1_800_000_000)
    let refreshedISO = ISO8601DateFormatter().string(from: refreshed)
    let refKey = "owner/repo#pr#7"
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "version": .int(2),
            "project": .string("NativeAgent"),
            "mode": .string("repository"),
            "repositories": .array([.object([
                "fullName": .string("owner/repo"),
                "name": .string("repo"),
                "htmlURL": .string("https://github.com/owner/repo"),
            ])]),
            "refreshIntervalMinutes": .int(15),
            "staleAfterHours": .int(72),
            "updatedAt": .string(refreshedISO),
        ]),
        to: root.appendingPathComponent("connectors/github/tracking.json")
    )
    try await persistence.writeJSON(
        .object([
            "version": .int(2),
            "project": .string("NativeAgent"),
            "refreshedAt": .string(refreshedISO),
            "entities": .array([.object([
                "key": .string(refKey),
                "repository": .string("owner/repo"),
                "number": .int(7),
                "kind": .string("pull_request"),
                "title": .string("Tighten cadence"),
                "state": .string("open"),
                "updatedAt": .string(refreshedISO),
                "url": .string("https://github.com/owner/repo/pull/7"),
            ])]),
        ]),
        to: root.appendingPathComponent("connectors/github/tracking_snapshot.json")
    )

    // Three changes make a 4h EWMA trustworthy. The cadence owner's 0.5 poll
    // factor therefore stretches the configured 15m floor to an exact 2h.
    let stat = DeskRefObservationStat(
        refKey: refKey,
        firstObservedAt: refreshedISO,
        lastObservedAt: refreshedISO,
        lastChangeAt: refreshedISO,
        observations: 4,
        changes: 3,
        ewmaChangeIntervalSec: 4 * 60 * 60,
        lastFingerprint: "head-4"
    )
    _ = try await DeskCadenceStore(dataRoot: root).updating { _ in
        (DeskCadenceStats(refs: [refKey: stat]), ())
    }

    let now = refreshed.addingTimeInterval(60)
    let deadline = await GitHubConnectorActions.nextTrackingRefreshDeadline(
        after: now,
        dataRoot: root
    )
    #expect(deadline == refreshed.addingTimeInterval(2 * 60 * 60))
}

@Test
func trackingDeadlineIsAbsentWithoutCanonicalConfigOrSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitHubTrackingDeadlineMissing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(
        await GitHubConnectorActions.nextTrackingRefreshDeadline(after: Date(), dataRoot: root)
            == nil
    )
}

@Test
func slowRepositoryCannotConsumeTheWholeTick() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = FakeClock(start)
    var visited: [String] = []

    // "slow-repo" burns the entire 300s budget by itself — the live shape of a
    // repo whose detail fan-out walks into the tick timeout.
    let outcome = await GitHubConnectorActions.testRepositoryPass(
        ["fast-repo", "slow-repo", "after-a", "after-b"],
        budgetSeconds: 300,
        startedAt: start,
        clock: { clock.now }
    ) { repo in
        visited.append(repo)
        clock.advance(repo == "slow-repo" ? 400 : 5)
    }

    // The pass RETURNED. Before this change the sweep had no exit condition
    // short of the 600s tick timeout, which cancels mid-flight and writes
    // nothing.
    #expect(outcome.completed == ["fast-repo", "slow-repo"])
    // The repos behind the slow one are named as budget-skipped — legible
    // degradation, not silent truncation.
    #expect(outcome.skippedForBudget == ["after-a", "after-b"])
    #expect(outcome.failed.isEmpty)
    // And crucially: no work was ATTEMPTED for them, so they cost nothing.
    #expect(visited == ["fast-repo", "slow-repo"])
}

@Test
func oneFailingRepositoryDoesNotAbortTheSweep() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = FakeClock(start)
    var visited: [String] = []

    struct RepoUnreachable: Error, LocalizedError {
        var errorDescription: String? { "Not Found (HTTP 404)" }
    }

    let outcome = await GitHubConnectorActions.testRepositoryPass(
        ["ok-one", "gone", "ok-two"],
        budgetSeconds: 300,
        startedAt: start,
        clock: { clock.now }
    ) { repo in
        visited.append(repo)
        clock.advance(1)
        if repo == "gone" { throw RepoUnreachable() }
    }

    // The live 404 receipts (2026-08-11, six in one hour) used to take the
    // whole pass with them. Now they take only themselves.
    #expect(visited == ["ok-one", "gone", "ok-two"])
    #expect(outcome.completed == ["ok-one", "ok-two"])
    #expect(outcome.failed == ["gone"])
    #expect(outcome.skippedForBudget.isEmpty)
}

@Test
func budgetExhaustionIsCheckedAtRepositoryBoundariesOnly() async throws {
    // A budget already spent before the sweep starts must skip EVERY repo
    // rather than half-running one — a repository is the unit that carries
    // forward cleanly.
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = FakeClock(start.addingTimeInterval(1_000))
    var visited: [String] = []

    let outcome = await GitHubConnectorActions.testRepositoryPass(
        ["a", "b"],
        budgetSeconds: 300,
        startedAt: start,
        clock: { clock.now }
    ) { repo in
        visited.append(repo)
    }

    #expect(visited.isEmpty)
    #expect(outcome.skippedForBudget == ["a", "b"])
    #expect(outcome.completed.isEmpty)
}

@Test
func degradedRepositoriesCarryTheirPriorEntitiesForward() async throws {
    // The data-loss guard. Skipping a repo without carrying its prior rows
    // would make the snapshot report those PRs as vanished — and `upsertDesk`
    // archives vanished work. This is the difference between "could not
    // refresh" and "deleted".
    func entity(_ repo: String, _ number: Int) -> JSONValue {
        .object([
            "key": .string("\(repo.lowercased())#pr#\(number)"),
            "repository": .string(repo),
            "number": .int(Int64(number)),
            "kind": .string("pr"),
            "title": .string("PR \(number)"),
            "state": .string("open"),
            "updatedAt": .string("2026-08-11T00:00:00Z"),
            "url": .string("https://github.com/\(repo)/pull/\(number)"),
            "needsUser": .bool(false),
            "blocked": .bool(false),
            "stale": .bool(false),
        ])
    }

    let previous = [
        entity("owner/skipped", 1),
        entity("owner/skipped", 2),
        entity("owner/refreshed", 9),
    ]

    let carried = GitHubConnectorActions.testCarryForwardRepositories(
        ["owner/skipped"],
        previous: previous
    )

    #expect(carried.sorted() == ["owner/skipped#pr#1", "owner/skipped#pr#2"])
    // The repo that DID refresh is not carried — its fresh rows are authoritative.
    #expect(!carried.contains("owner/refreshed#pr#9"))
}

@Test
func carryForwardIsCaseInsensitiveOnRepositoryName() async throws {
    // GitHub repo names round-trip with inconsistent casing between the search
    // API and config. A case-sensitive match here would silently carry nothing
    // and reintroduce the archive-live-work bug.
    let previous: [JSONValue] = [
        .object([
            "key": .string("owner/repo#pr#3"),
            "repository": .string("Owner/Repo"),
            "number": .int(3),
            "kind": .string("pr"),
            "title": .string("PR 3"),
            "state": .string("open"),
            "updatedAt": .string("2026-08-11T00:00:00Z"),
            "url": .string("https://github.com/Owner/Repo/pull/3"),
            "needsUser": .bool(false),
            "blocked": .bool(false),
            "stale": .bool(false),
        ])
    ]

    let carried = GitHubConnectorActions.testCarryForwardRepositories(
        ["owner/repo"],
        previous: previous
    )
    #expect(carried == ["owner/repo#pr#3"])
}
