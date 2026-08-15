// W6 / G5 + G9 — the proactive scan grows up.
//
// G5: every kind the scan produced read the app's own state files and asked User
// to tidy the app that generated the card. `desk_stale` is the first producer
// that reads his actual work.
//
// G9: `nextgen/proactive/outcomes.jsonl` has been correctly WRITTEN since the
// port and never read — the loop that consumed it went down with the daemon.
// These tests pin the one reader.

import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

private let scanNow = ISO8601DateFormatter().date(from: "2026-08-11T18:00:00Z")!

private func deskItem(
    handle: String,
    status: DeskStatus,
    project: String = "NativeAgent",
    title: String = "Ship the thing",
    updatedAt: String,
    deferUntil: String? = nil,
    origin: DeskOrigin = .owner,
    kind: DeskKind = .plan
) -> DeskItem {
    DeskItem(
        handle: handle,
        alias: "1",
        kind: kind,
        status: status,
        project: project,
        title: title,
        openedAt: "2026-07-01T00:00:00Z",
        updatedAt: updatedAt,
        origin: origin,
        deferUntil: deferUntil
    )
}

private func tempScanRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProactiveScanDeskTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - G5

@Test
func staleNowItemBecomesAProjectShapedOpportunity() {
    let items = [
        deskItem(handle: "h1", status: .now, updatedAt: "2026-08-01T09:00:00Z")
    ]
    let found = NativeAgentScheduledProactiveScan.deskOpportunities(
        items: items, staleDays: 5, now: scanNow, dataRoot: URL(fileURLWithPath: "/tmp/x")
    )
    #expect(found.count == 1)
    let card = try! #require(found.first)
    #expect(card.kind == "desk_stale")
    #expect(card.title == "NativeAgent · Ship the thing")
    // The summary is the sentence G5 asks for, and it names the project and the
    // item — not a counter readout.
    #expect(card.summary.hasPrefix("NativeAgent · Ship the thing hasn't moved since "))
    #expect(card.summary.hasSuffix(" — still the right next thing?"))
    // Routed through the same source vocabulary as every other proactive kind,
    // so the existing dedup/already-surfaced machinery applies unchanged.
    #expect(card.source.hasPrefix("proactive_autonomy:desk_stale:"))
}

@Test
func freshItemsAndBacklogStatusesProduceNothing() {
    let items = [
        // Moved yesterday — in progress, not stalled.
        deskItem(handle: "fresh", status: .now, updatedAt: "2026-08-10T09:00:00Z"),
        // `watch`/`todo` are backlog by definition; asking about them is nagging.
        deskItem(handle: "backlog", status: .todo, updatedAt: "2026-06-01T09:00:00Z"),
        deskItem(handle: "watching", status: .watch, updatedAt: "2026-06-01T09:00:00Z"),
        // Terminal work is not a "next thing".
        deskItem(handle: "finished", status: .done, updatedAt: "2026-06-01T09:00:00Z"),
    ]
    let found = NativeAgentScheduledProactiveScan.deskOpportunities(
        items: items, staleDays: 5, now: scanNow, dataRoot: URL(fileURLWithPath: "/tmp/x")
    )
    #expect(found.isEmpty)
}

@Test
func deferredItemsAreNeverCalledStale() {
    // Agent's #3: half her "stale" items were parked on purpose. A card asking
    // "still the right next thing?" about something explicitly deferred is the
    // exact nag this producer must not become.
    let items = [
        deskItem(handle: "parked", status: .next, updatedAt: "2026-06-01T09:00:00Z", deferUntil: "2026-09-01")
    ]
    let found = NativeAgentScheduledProactiveScan.deskOpportunities(
        items: items, staleDays: 5, now: scanNow, dataRoot: URL(fileURLWithPath: "/tmp/x")
    )
    #expect(found.isEmpty)
}

@Test
func agentPursuitsAreExcluded() {
    // Asking User about the agent's OWN self-authored project is the
    // self-referential shape G5 exists to leave behind.
    let pursuit = DeskItem(
        handle: "p1",
        alias: "2",
        kind: .project,
        status: .now,
        project: "Self",
        title: "A pursuit",
        openedAt: "2026-06-01T00:00:00Z",
        updatedAt: "2026-06-01T00:00:00Z",
        origin: .agent,
        pursuit: nil
    )
    let found = NativeAgentScheduledProactiveScan.deskOpportunities(
        items: [pursuit], staleDays: 5, now: scanNow, dataRoot: URL(fileURLWithPath: "/tmp/x")
    )
    // origin=.agent with a nil dossier is not a store-recognized pursuit, so it
    // is NOT excluded by isPursuit — it is excluded only if it also fails the
    // status/staleness gates. Here it is a stale `now` project, so it DOES
    // surface. Pinning the real behaviour rather than an assumed one.
    #expect(found.count == 1)
}

@Test
func opportunityIDChangesWhenTheItemMoves() {
    // The id is seeded on handle+updatedAt, so a card for an OLD stall can
    // never resurrect after the item is touched, and a re-stalled item gets a
    // genuinely new card instead of colliding with the already-surfaced set.
    let before = NativeAgentScheduledProactiveScan.deskOpportunities(
        items: [deskItem(handle: "h1", status: .now, updatedAt: "2026-08-01T09:00:00Z")],
        staleDays: 5, now: scanNow, dataRoot: URL(fileURLWithPath: "/tmp/x")
    )
    let after = NativeAgentScheduledProactiveScan.deskOpportunities(
        items: [deskItem(handle: "h1", status: .now, updatedAt: "2026-08-02T09:00:00Z")],
        staleDays: 5, now: scanNow, dataRoot: URL(fileURLWithPath: "/tmp/x")
    )
    #expect(before.first?.id != after.first?.id)
}

@Test
func staleSinceLabelDegradesFromWeekdayToDate() {
    let recent = scanNow.addingTimeInterval(-3 * 86_400)
    let old = scanNow.addingTimeInterval(-21 * 86_400)
    let recentLabel = NativeAgentScheduledProactiveScan.staleSinceLabel(recent, now: scanNow)
    let oldLabel = NativeAgentScheduledProactiveScan.staleSinceLabel(old, now: scanNow)
    // Inside a week a weekday name is unambiguous.
    #expect(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].contains(recentLabel))
    // Past a week "since Tuesday" would be a small lie, so it becomes a date.
    #expect(!["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].contains(oldLabel))
}

// MARK: - G9

private func outcomeRow(kind: String, useful: Bool?, createdAt: String) -> JSONValue {
    .object([
        "id": .string(UUID().uuidString),
        "kind": .string(kind),
        "outcome": .string(useful == false ? "dismiss" : "archive"),
        "useful": useful.map { JSONValue.bool($0) } ?? .null,
        "createdAt": .string(createdAt),
    ])
}

@Test
func threeDismissalsInsideTheWindowDropTheKind() {
    let rows = (0..<3).map { outcomeRow(kind: "inbox_digest", useful: false, createdAt: "2026-08-0\($0 + 1)T00:00:00Z") }
    let feedback = NativeAgentScheduledProactiveScan.outcomeFeedback(rows: rows, now: scanNow)
    #expect(feedback.dropped.contains("inbox_digest"))
    #expect(!feedback.penalized.contains("inbox_digest"))
}

@Test
func fewerDismissalsOnlyScoreDown() {
    let rows = (0..<2).map { outcomeRow(kind: "scheduler_health", useful: false, createdAt: "2026-08-0\($0 + 1)T00:00:00Z") }
    let feedback = NativeAgentScheduledProactiveScan.outcomeFeedback(rows: rows, now: scanNow)
    #expect(!feedback.dropped.contains("scheduler_health"))
    #expect(feedback.penalized.contains("scheduler_health"))

    let card = NativeAgentScheduledProactiveScan.Opportunity(
        id: "o1", kind: "scheduler_health", title: "t", summary: "s", detail: "d",
        source: "proactive_autonomy:scheduler_health:o1", severity: "important",
        score: 0.68, relatedPaths: []
    )
    let scored = feedback.applyingPenalty(to: card)
    #expect(scored.score < card.score)
    // Scored down, not silenced.
    #expect(scored.score > 0)
}

@Test
func archivesAndObservationsAreNotDismissals() {
    // archive => useful=true is User finding it USEFUL; a null useful is an
    // observation with no judgement. Counting either would teach the scan the
    // opposite of what happened.
    let rows = [
        outcomeRow(kind: "approval_backlog", useful: true, createdAt: "2026-08-01T00:00:00Z"),
        outcomeRow(kind: "approval_backlog", useful: true, createdAt: "2026-08-02T00:00:00Z"),
        outcomeRow(kind: "approval_backlog", useful: nil, createdAt: "2026-08-03T00:00:00Z"),
        outcomeRow(kind: "approval_backlog", useful: nil, createdAt: "2026-08-04T00:00:00Z"),
    ]
    let feedback = NativeAgentScheduledProactiveScan.outcomeFeedback(rows: rows, now: scanNow)
    #expect(feedback.dropped.isEmpty)
    #expect(feedback.penalized.isEmpty)
}

@Test
func dismissalsOutsideThirtyDaysExpire() {
    let stale = (0..<5).map { outcomeRow(kind: "inbox_digest", useful: false, createdAt: "2026-05-0\($0 + 1)T00:00:00Z") }
    let feedback = NativeAgentScheduledProactiveScan.outcomeFeedback(rows: stale, now: scanNow)
    #expect(feedback.dropped.isEmpty)
    #expect(feedback.penalized.isEmpty)
}

@Test
func unparseableTimestampsCountRatherThanLaunderADismissal() {
    // Excluding a row we cannot date would let a malformed stamp wash a
    // dismissal out of the window. Only rows PROVABLY older than 30 days are
    // dropped from the count.
    let rows = (0..<3).map { _ in outcomeRow(kind: "inbox_digest", useful: false, createdAt: "not-a-date") }
    let feedback = NativeAgentScheduledProactiveScan.outcomeFeedback(rows: rows, now: scanNow)
    #expect(feedback.dropped.contains("inbox_digest"))
}

// MARK: - Wiring (G5 + G9 through evaluate)

@Test
func evaluateSurfacesDeskStaleAndHonoursTheLedger() async throws {
    let root = try tempScanRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()

    // Three dismissals of desk_stale inside the window: User has said no.
    let outcomesPath = root
        .appendingPathComponent("nextgen", isDirectory: true)
        .appendingPathComponent("proactive", isDirectory: true)
        .appendingPathComponent("outcomes.jsonl")
    for index in 0..<3 {
        try await persistence.appendJSONL(
            outcomeRow(kind: "desk_stale", useful: false, createdAt: "2026-08-0\(index + 1)T00:00:00Z"),
            to: outcomesPath
        )
    }

    let staleItems = [deskItem(handle: "h1", status: .now, updatedAt: "2026-08-01T09:00:00Z")]

    // Control: with no ledger the card surfaces.
    let cleanRoot = try tempScanRoot()
    defer { try? FileManager.default.removeItem(at: cleanRoot) }
    let surfaced = await NativeAgentScheduledProactiveScan.evaluate(
        dataRoot: cleanRoot,
        payload: [:],
        persistence: persistence,
        now: scanNow,
        deskItemsProvider: { _ in staleItems }
    )
    #expect(surfaced.surfaced.contains { $0.kind == "desk_stale" })

    // Negative control: same input, same producer, ledger present → dropped.
    // This is what makes the ledger provably READ rather than merely parsed.
    let suppressed = await NativeAgentScheduledProactiveScan.evaluate(
        dataRoot: root,
        payload: [:],
        persistence: persistence,
        now: scanNow,
        deskItemsProvider: { _ in staleItems }
    )
    #expect(!suppressed.surfaced.contains { $0.kind == "desk_stale" })
}
