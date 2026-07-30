import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

// Wave D — the Workshop Observatory panel (L11: veto visibility, store-query
// sourced). The data-shaping is pure, so every invariant below is proven without
// SwiftUI or a live app: the receipts reader bounds + orders + survives a
// missing/corrupt feed, the pursuit row builds score/budget/rationale from a
// DeskState, and a terminal pursuit is excluded from the OPEN veto list.

// MARK: - helpers

private func makeTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopObsTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func validDossier() -> PromotionDossier {
    PromotionDossier(citations: [
        .standingView(id: "sv1"),
        .feltSalience(dates: ["2026-07-01", "2026-07-03"]),
    ])
}

private func openTestPursuit(_ store: SwiftNativeDeskStore, title: String) async throws -> DeskItem {
    let pursuit = Pursuit(
        why: "I keep hitting sensor-fusion questions I can't answer.",
        evidence: validDossier(),
        doneLooksLike: "I can explain a Kalman update from memory.",
        maxSessions: 8,
        abandonCondition: "If it stops being useful after 3 sessions.")
    return try await store.openPursuit(project: "curiosity", title: title, pursuit: pursuit)
}

private func receiptLine(handle: String, reservationId: String, status: String, ts: String, summary: String = "s", artifacts: Int = 0) -> String {
    let obj: JSONValue = .object([
        "handle": .string(handle),
        "reservationId": .string(reservationId),
        "status": .string(status),
        "model": .string("opus-4-8"),
        "artifactCount": .int(Int64(artifacts)),
        "summary": .string(summary),
        "ts": .string(ts),
    ])
    return (try? obj.serialize(pretty: false)) ?? "{}"
}

// MARK: - receipts reader

@Test func receiptsReader_newestFirstAndBounded() {
    // Append order (file order) is chronological — newest LAST. The reader must
    // return newest FIRST and bound the count.
    var lines: [String] = []
    for i in 0..<30 {
        lines.append(receiptLine(
            handle: "desk_a", reservationId: "r\(i)", status: "completed",
            ts: String(format: "2026-07-11T00:%02d:00.000000+00:00", i)))
    }
    let state = WorkshopReceiptsReader.rows(fromLines: lines, limit: 20)
    guard case .rows(let rows) = state else { Issue.record("expected rows"); return }
    #expect(rows.count == 20, "bounded to the row limit")
    #expect(rows.first?.reservationId == "r29", "newest first")
    #expect(rows.last?.reservationId == "r10", "oldest kept row is the 20th-newest")
}

@Test func receiptsReader_missingFileIsHonestEmptyNotUnavailable() {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("workshop/receipts.jsonl")
    let state = WorkshopReceiptsReader.load(receiptsPath: path)
    #expect(state == .rows([]), "a missing feed is an honest empty read — no sessions yet")
}

@Test func receiptsReader_corruptBytesAreUnavailableNotEmpty() {
    // Bytes on disk that yield ZERO parseable rows must NOT read as "no sessions"
    // — unavailable != empty (the M12 honesty rule).
    let state = WorkshopReceiptsReader.rows(fromLines: ["not-json", "{oops", "   "], limit: 20)
    guard case .unavailable = state else {
        Issue.record("expected unavailable for unparseable bytes")
        return
    }
}

@Test func receiptsReader_toleratesSomeGarbageButKeepsGoodRows() {
    let lines = [
        "garbage-line",
        receiptLine(handle: "desk_a", reservationId: "r1", status: "completed", ts: "2026-07-11T00:00:00.000000+00:00"),
        "{broken",
        receiptLine(handle: "desk_a", reservationId: "r2", status: "blocked", ts: "2026-07-11T01:00:00.000000+00:00"),
    ]
    let state = WorkshopReceiptsReader.rows(fromLines: lines, limit: 20)
    guard case .rows(let rows) = state else { Issue.record("expected rows"); return }
    #expect(rows.count == 2)
    #expect(rows.first?.reservationId == "r2", "newest good row first")
    #expect(rows.first?.status == "blocked")
}

@Test func receiptsReader_loadReadsRealFile() throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("workshop", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("receipts.jsonl")
    let body = [
        receiptLine(handle: "desk_a", reservationId: "r1", status: "completed", ts: "2026-07-11T00:00:00.000000+00:00", summary: "did a thing", artifacts: 2),
        receiptLine(handle: "desk_a", reservationId: "r2", status: "refused", ts: "2026-07-11T01:00:00.000000+00:00"),
    ].joined(separator: "\n") + "\n"
    try Data(body.utf8).write(to: path)

    let state = WorkshopReceiptsReader.load(receiptsPath: path)
    guard case .rows(let rows) = state else { Issue.record("expected rows"); return }
    #expect(rows.count == 2)
    #expect(rows.first?.reservationId == "r2")
    #expect(rows.last?.artifactCount == 2)
    #expect(rows.last?.model == "opus-4-8")
}

// MARK: - pursuit row (score + budget + rationale)

@Test func pursuitRow_buildsScoreBudgetAndRationaleFromState() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let item = try await openTestPursuit(store, title: "learn kalman filters")
    let today = DeskClock.dayStamp(Date())
    // Reserve + complete one slot (a work receipt note), and log a choice rationale.
    let res = try await store.reserveWorkSession(item.handle, day: today, slot: "am")
    _ = try await store.completeWorkSession(item.handle, reservationId: res, receipt: "[completed] derived the update step")
    _ = try await store.appendWorkReceipt(item.handle, receipt: "chose: picked kalman over the other pursuit")

    let state = try await store.liveState()
    let live = state.items.first { $0.handle == item.handle }!
    let row = WorkshopPursuitRow.from(item: live, now: Date())

    #expect(row.score != nil, "a live pursuit shows its blended choice score")
    #expect(row.score!.total != 0 || row.score!.evidenceStrength > 0, "score components populated")
    #expect(row.budget?.maxSessions == 8, "budget carries the pursuit's session ceiling")
    #expect(row.budget?.sessionsUsed == 1)
    #expect(row.budget?.todayCount == 1)
    #expect(row.budget?.perDayCap == SwiftNativeDeskStore.maxWorkSessionsPerPursuitPerDay)
    #expect(row.latestChoiceRationale?.contains("chose:") == true, "the recorded volition is surfaced")
    #expect(row.workReceipts.contains { $0.contains("derived the update step") }, "work receipts (non-choice notes) are surfaced")
    #expect(!row.workReceipts.contains { $0.hasPrefix("chose:") }, "choice lines are not double-counted as work receipts")
    #expect(row.citations.contains("standing_view"), "evidence citations are shown for the veto rationale")
    #expect(row.lastWorkedAt != nil, "a completed session stamps lastWorkedAt")
}

// MARK: - model build (L11: store-query sourced, terminal excluded)

@Test func model_excludesTerminalPursuitFromOpenList() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let open = try await openTestPursuit(store, title: "still open")
    let toClose = try await openTestPursuit(store, title: "will be canceled")
    _ = try await store.setStatus(toClose.handle, status: .canceled)

    let state = try await store.liveState()
    let model = WorkshopObservatoryModel.build(state: state, now: Date())

    #expect(model.openPursuits.count == 1, "a canceled pursuit is excluded from the OPEN veto list")
    #expect(model.openPursuits.first?.handle == open.handle)
    #expect(model.maxOpenPursuits == SwiftNativeDeskStore.maxOpenAgentPursuits)
    #expect(model.globalCap == SwiftNativeDeskStore.maxWorkSessionsGlobalPerDay)
}

@Test func model_countsSessionsTodayAcrossAllPursuitsIncludingTerminal() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let today = DeskClock.dayStamp(Date())
    // One open pursuit reserved once; one reserved then CLOSED — its reservation
    // still counts toward the global cap (mirrors the store/pump accounting).
    let a = try await openTestPursuit(store, title: "a")
    _ = try await store.reserveWorkSession(a.handle, day: today, slot: "am")
    let b = try await openTestPursuit(store, title: "b")
    _ = try await store.reserveWorkSession(b.handle, day: today, slot: "am")
    _ = try await store.setStatus(b.handle, status: .done)

    let state = try await store.liveState()
    let model = WorkshopObservatoryModel.build(state: state, now: Date())
    #expect(model.sessionsToday == 2, "sessions-today counts terminal pursuits' reservations too")
    #expect(model.openPursuits.count == 1, "only the still-open pursuit is in the veto list")
}

@Test func model_surfacesUserCadenceItemsThatAreDue() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let item = try await store.createItem(kind: .watch, project: "ops", title: "daily digest")
    _ = try await store.setCadence(item.handle, cadence: Cadence(mode: .daily))  // due now

    let state = try await store.liveState()
    let model = WorkshopObservatoryModel.build(state: state, now: Date())
    #expect(model.cadenceItems.count == 1)
    #expect(model.cadenceItems.first?.isDue == true)
    #expect(model.cadenceItems.first?.nextDue == "due now")
}

// MARK: - snapshot hint honesty

@Test func snapshot_hintNeverShowsZeroWhenDeskUnavailable() {
    let snap = WorkshopObservatorySnapshot(
        model: nil, deskUnavailable: "boom", receipts: .rows([]))
    #expect(snap.hint == "unavailable", "an unavailable read never renders as 0 open / 0 today")
}
