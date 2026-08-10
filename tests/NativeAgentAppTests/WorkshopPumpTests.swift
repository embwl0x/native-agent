import Foundation
import Testing
import PersistenceCore
import CognitiveSubstrate
import ChatOrchestration
import NativeAgentCore
@testable import NativeAgentApp

// Wave B — the pump + membrane + session guarantees (H1, H3, H4, H5, M6, M8, L12).
//
// Every invariant here is proven at the code layer the design demands: the
// membrane rejects by NAME, the writer contains by CANONICAL PATH, the session
// authorizes on a REAL reservation, and the pump does ZERO LLM on a quiet /
// capped / posture-off tick.

// MARK: - helpers

private func makeTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A valid, non-friction dossier so openPursuit is accepted by the Wave A store.
private func validDossier() -> PromotionDossier {
    PromotionDossier(citations: [
        .feltSalience(dates: ["2026-07-01", "2026-07-03"]),
    ])
}

private func openTestPursuit(_ store: SwiftNativeDeskStore, title: String = "learn kalman filters") async throws -> DeskItem {
    let pursuit = Pursuit(
        why: "I keep hitting sensor-fusion questions I can't answer.",
        evidence: validDossier(),
        doneLooksLike: "I can explain a Kalman update from memory.",
        abandonCondition: "If it stops being useful after 3 sessions."
    )
    return try await store.openPursuit(project: "curiosity", title: title, pursuit: pursuit)
}

/// An in-memory pursuit DeskItem for pure choiceScore tests (no store).
private func makePursuitItem(
    alias: String, citations: [DossierSource],
    completedToday: Int = 0, maxSessions: Int = 12
) -> DeskItem {
    let today = DeskClock.dayStamp(Date())
    let reservations = (0..<completedToday).map { i in
        WorkReservation(reservationId: "r\(alias)\(i)", day: today, slot: "s\(i)",
                        reservedAt: "2026-07-11T00:00:00.000000+00:00",
                        receipt: "x", completedAt: "2026-07-11T01:00:00.000000+00:00")
    }
    let pursuit = Pursuit(
        why: "w", evidence: PromotionDossier(citations: citations),
        doneLooksLike: "d", maxSessions: maxSessions, abandonCondition: "a",
        reservations: reservations)
    return DeskItem(
        handle: "desk_\(alias)", alias: alias, kind: .project, project: "na",
        title: "p\(alias)", openedAt: "2026-07-11T00:00:00.000000+00:00",
        updatedAt: "2026-07-11T00:00:00.000000+00:00", origin: .agent, pursuit: pursuit)
}

/// A session runner spy — records every call so we can assert ZERO dispatch on
/// quiet/capped ticks.
private actor SessionSpy: WorkshopSessionRunning {
    private(set) var calls: [WorkshopSessionRequest] = []
    let status: WorkshopSessionStatus
    init(status: WorkshopSessionStatus = .completed) { self.status = status }
    func run(_ request: WorkshopSessionRequest) async -> WorkshopSessionReceipt {
        calls.append(request)
        return WorkshopSessionReceipt(
            handle: request.handle, reservationId: request.reservationId,
            status: status, summary: "spy", model: "spy-model",
            artifactPaths: [], generatedAt: Date())
    }
    func callCount() -> Int { calls.count }
}

private func normalPosture() -> OrganismBehaviorPosture {
    OrganismBehaviorPosture(generatedAt: Date(), enabled: true, posture: "steady", loopBudget: .normal)
}
private func conservePosture() -> OrganismBehaviorPosture {
    OrganismBehaviorPosture(generatedAt: Date(), enabled: true, posture: "conserving", loopBudget: .conserve)
}

private func makePump(
    root: URL,
    store: SwiftNativeDeskStore,
    spy: any WorkshopSessionRunning,
    posture: @escaping @Sendable () async -> OrganismBehaviorPosture?,
    enabled: Bool = true,
    now: @escaping @Sendable () -> Date = { Date() },
    flushReservationLog: @escaping @Sendable (URL) -> Bool = WorkshopReservationDurability.flush
) -> WorkshopPump {
    WorkshopPump(
        dataRoot: root,
        store: store,
        lease: BackgroundWorkLease(dataRoot: root),
        receiptLog: WorkshopReceiptLog(dataRoot: root),
        sessionRunner: spy,
        posture: posture,
        isEnabled: { enabled },
        now: now,
        flushReservationLog: flushReservationLog
    )
}

// MARK: - H4: posture gate + lease

@Test func h4_conserveAndSleepPostureDoNotRun() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    _ = try await openTestPursuit(store)
    let spy = SessionSpy()

    let conserve = makePump(root: root, store: store, spy: spy, posture: { conservePosture() })
    #expect(await conserve.tick() == .postureNotNormal)

    let sleepPump = makePump(root: root, store: store, spy: spy, posture: {
        OrganismBehaviorPosture(generatedAt: Date(), enabled: true, posture: "conserving", loopBudget: .sleep)
    })
    #expect(await sleepPump.tick() == .postureNotNormal)

    // Organism disabled (nil posture) — inert by construction.
    let offPump = makePump(root: root, store: store, spy: spy, posture: { nil })
    #expect(await offPump.tick() == .postureNotNormal)

    let explicitlyOffPump = makePump(root: root, store: store, spy: spy, posture: {
        OrganismBehaviorPosture(
            generatedAt: Date(), enabled: false, posture: "off", loopBudget: .normal)
    })
    #expect(await explicitlyOffPump.tick() == .postureNotNormal)

    #expect(await spy.callCount() == 0, "no session may run outside a normal green window")
}

@Test func h4_disabledAutonomyDoesNotRun() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    _ = try await openTestPursuit(store)
    let spy = SessionSpy()
    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() }, enabled: false)
    #expect(await pump.tick() == .disabled)
    #expect(await spy.callCount() == 0)
}

@Test func h4_leasePreventsDoubleSpendInOneWindow() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    _ = try await openTestPursuit(store)
    let spy = SessionSpy()
    // Pin `now` so both ticks land in the SAME green window.
    let fixed = Date(timeIntervalSince1970: 1_760_000_000)
    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() }, now: { fixed })

    #expect(await pump.tick() == .ran(.completed))
    // Second tick, same window: the shared lease is already spent → no session.
    #expect(await pump.tick() == .leaseHeld)
    #expect(await spy.callCount() == 1, "the background-work lease allows one session per green window")
}

@Test func h4_leaseIsSharedAcrossHolders() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let lease = BackgroundWorkLease(dataRoot: root)
    #expect(await lease.tryAcquire(holder: "reflection", window: "2026-07-11-b5") == true)
    // A DIFFERENT holder cannot take the same window — this is what stops
    // reflection + replay + workshop stacking in one green window.
    #expect(await lease.tryAcquire(holder: "workshop", window: "2026-07-11-b5") == false)
    #expect(await lease.tryAcquire(holder: "workshop", window: "2026-07-11-b6") == true)
}

@Test func h4_twoIndependentLeaseInstancesRaceAtomically() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let first = BackgroundWorkLease(dataRoot: root)
    let second = BackgroundWorkLease(dataRoot: root)
    let wins = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        group.addTask { await first.tryAcquire(holder: "first", window: "2026-07-11-race") }
        group.addTask { await second.tryAcquire(holder: "second", window: "2026-07-11-race") }
        var values: [Bool] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(wins.filter { $0 }.count == 1, "cross-instance same-window ticks must have exactly one lease winner")
}

@Test func h4_leaseRetainsPriorWindowClaimsAndFailsClosedOnCorruption() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let lease = BackgroundWorkLease(dataRoot: root)
    #expect(await lease.tryAcquire(holder: "new", window: "2026-07-11-b6"))
    #expect(await lease.tryAcquire(holder: "late-old", window: "2026-07-11-b5"))
    #expect(await lease.tryAcquire(holder: "replay-new", window: "2026-07-11-b6") == false,
            "a late older tick must not erase a newer window's spent claim")

    let corruptRoot = makeTempRoot(); defer { try? FileManager.default.removeItem(at: corruptRoot) }
    let leasePath = corruptRoot.appendingPathComponent("workshop/background_lease.json")
    try FileManager.default.createDirectory(at: leasePath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: leasePath)
    #expect(await BackgroundWorkLease(dataRoot: corruptRoot).tryAcquire(
        holder: "workshop", window: "2026-07-11-b6") == false,
        "an unreadable lease must defer rather than overwrite and run")
}

@Test func pumpOverlappingTicksRemainSingleFlightAtLeaseBoundary() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    _ = try await openTestPursuit(store)
    let spy = SessionSpy()
    let fixed = Date(timeIntervalSince1970: 1_760_000_000)
    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() }, now: { fixed })
    let outcomes = await withTaskGroup(of: WorkshopPump.TickOutcome.self, returning: [WorkshopPump.TickOutcome].self) { group in
        group.addTask { await pump.tick() }
        group.addTask { await pump.tick() }
        var values: [WorkshopPump.TickOutcome] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(outcomes.filter { $0 == .ran(.completed) }.count == 1)
    #expect(outcomes.filter { $0 == .leaseHeld }.count == 1)
    #expect(await spy.callCount() == 1)
}

// MARK: - H3: reserve before any LLM work

@Test func h3_capHitPursuitIsNotSelectedAndRunsNoSession() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let item = try await openTestPursuit(store)
    let spy = SessionSpy()
    // Exhaust the per-pursuit daily cap (2/day) directly against the store for
    // TODAY, in two distinct slots.
    let today = DeskClock.dayStamp(Date())
    _ = try await store.reserveWorkSession(item.handle, day: today, slot: "manual-a")
    _ = try await store.reserveWorkSession(item.handle, day: today, slot: "manual-b")

    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() })
    // The capped pursuit is pre-filtered out of selection (nothing else due) →
    // quiet, ZERO LLM. The cap costs no lease and no session.
    #expect(await pump.tick() == .quiet)
    #expect(await spy.callCount() == 0, "a cap-hit pursuit must not reach the session/LLM (H3)")
}

@Test func h3_reserveRefusalBeforeAnyLLM() async throws {
    // Directly exercises the RESERVE-FIRST gate: a due User cadence item is
    // selected, but Wave A's store won't reserve a non-pursuit → the reservation
    // is refused BEFORE any session/LLM. (Also documents the Wave-C seam: User
    // cadence items need a non-pursuit reservation path in the store to run.)
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let item = try await store.createItem(kind: .watch, project: "ops", title: "daily digest")
    _ = try await store.setCadence(item.handle, cadence: Cadence(mode: .daily))   // due now (no nextRefreshAt)
    let spy = SessionSpy()

    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() })
    #expect(await pump.tick() == .reservationRefused)
    #expect(await spy.callCount() == 0, "reservation is refused BEFORE any LLM work (H3)")
}

@Test func h3_reservationFlushFailureStopsBeforeProviderBoundary() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    _ = try await openTestPursuit(store)
    let spy = SessionSpy()
    let pump = makePump(
        root: root,
        store: store,
        spy: spy,
        posture: { normalPosture() },
        flushReservationLog: { _ in false }
    )
    #expect(await pump.tick() == .reservationRefused)
    #expect(await spy.callCount() == 0,
            "an unflushed reservation must consume no provider tokens")
}

@Test func h3_reservationDurabilityFlushesTheCanonicalParent() throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let realDesk = root.appendingPathComponent("real-desk", isDirectory: true)
    try FileManager.default.createDirectory(at: realDesk, withIntermediateDirectories: true)
    let realOps = realDesk.appendingPathComponent("desk_ops.jsonl")
    try Data("{}\n".utf8).write(to: realOps)
    #expect(WorkshopReservationDurability.flush(realOps))

    // O_NOFOLLOW on the file alone is insufficient: it still follows a
    // symlinked parent. The durability fence must sync (and therefore verify)
    // the canonical parent before any provider work starts.
    let linkedDesk = root.appendingPathComponent("linked-desk", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedDesk, withDestinationURL: realDesk)
    #expect(!WorkshopReservationDurability.flush(
        linkedDesk.appendingPathComponent("desk_ops.jsonl")
    ))
}

// MARK: - quiet day → zero dispatch

@Test func quietDayPerformsNoDispatch() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)   // nothing due — empty board
    let spy = SessionSpy()
    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() })
    #expect(await pump.tick() == .quiet)
    #expect(await spy.callCount() == 0, "a quiet day makes zero provider calls (pump does no LLM itself)")
}

// MARK: - M8: compact per-session receipt

@Test func m8_writesCompactPerSessionReceipt() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    _ = try await openTestPursuit(store)
    let spy = SessionSpy()
    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() })
    #expect(await pump.tick() == .ran(.completed))

    let receiptsPath = root.appendingPathComponent("workshop").appendingPathComponent("receipts.jsonl")
    let contents = try String(contentsOf: receiptsPath, encoding: .utf8)
    let lines = contents.split(separator: "\n").filter { !$0.isEmpty }
    #expect(lines.count == 1, "exactly one compact receipt row per session")
    #expect(contents.contains("\"reservationId\""))
    #expect(contents.contains("completed"))
    #expect(contents.contains("\"handle\""))
}

// MARK: - selection ordering (Wave C seam)



@Test func selection_recentAttentionSpreadsToAFreshSibling() async throws {
    // Wave C: momentum rewards completed work, but a pursuit worked in the last
    // day yields THIS tick so attention spreads — a fresh sibling of equal
    // evidence takes the slot rather than the same pursuit every tick.
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let a = try await openTestPursuit(store, title: "pursuit A")
    let b = try await openTestPursuit(store, title: "pursuit B")
    let today = DeskClock.dayStamp(Date())
    let res = try await store.reserveWorkSession(a.handle, day: today, slot: "s1")
    _ = try await store.completeWorkSession(a.handle, reservationId: res, receipt: "did a thing")

    let state = try await store.liveState()
    let pick = WorkshopPump.selectDueItem(from: state, now: Date())
    #expect(pick?.handle == b.handle, "A was just worked → recent-attention penalty cedes the slot to fresh B")
    #expect(pick?.isPursuit == true)
    #expect(pick?.choiceRationale.contains("recent") == true, "the choice records its rationale")
}

@Test func selection_strongerEvidenceCanWinDespiteRecentWork() async throws {
    // The blend is not pure recency: a much stronger dossier outweighs the
    // recent-attention penalty. (5 citations / 3 non-friction kinds vs 1.)
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let rich = PromotionDossier(citations: [
        .standingView(id: "sv1"), .dreamDigest(id: "dd1"), .openQuestionSeed(id: "oq1"),
        .feltSalience(dates: ["2026-07-08", "2026-07-10"]), .traceFriction(count: 4, window: "7d"),
    ])
    let thin = PromotionDossier(citations: [.standingView(id: "sv2"), .traceFriction(count: 2, window: "7d")])
    let strong = try await store.openPursuit(project: "na", title: "strong",
        pursuit: Pursuit(why: "w", evidence: rich, doneLooksLike: "d", abandonCondition: "a"))
    _ = try await store.openPursuit(project: "na", title: "weak",
        pursuit: Pursuit(why: "w", evidence: thin, doneLooksLike: "d", abandonCondition: "a"))
    // Work the STRONG one so it carries the recent-attention penalty.
    let today = DeskClock.dayStamp(Date())
    let r = try await store.reserveWorkSession(strong.handle, day: today, slot: "s1")
    _ = try await store.completeWorkSession(strong.handle, reservationId: r, receipt: "step")

    let state = try await store.liveState()
    let pick = WorkshopPump.selectDueItem(from: state, now: Date())
    #expect(pick?.handle == strong.handle, "richer evidence + momentum beats the thin one despite recent work")
}

@Test func choiceScoreIsFrictionResistantAndBounded() {
    // MULTIPLE friction citations can't inflate evidence strength (gpt-5.5 MED):
    // standing_view + 4 trace_friction must NOT out-score a diverse non-friction
    // dossier — friction lifts neither breadth nor diversity.
    let frictionHeavy = makePursuitItem(alias: "1", citations: [
        .standingView(id: "s"),
        .traceFriction(count: 9, window: "7d"), .traceFriction(count: 8, window: "24h"),
        .traceFriction(count: 7, window: "7d"), .traceFriction(count: 6, window: "30m"),
    ])
    let diverse = makePursuitItem(alias: "2", citations: [
        .standingView(id: "s"), .dreamDigest(id: "d"),
    ])
    let sf = WorkshopPump.choiceScore(for: frictionHeavy)!
    let sd = WorkshopPump.choiceScore(for: diverse)!
    #expect(sd.evidenceStrength > sf.evidenceStrength, "friction volume can't beat non-friction diversity")
    #expect(sf.total <= 3.0 && sd.total <= 3.0, "components stay bounded")
}

@Test func globalDailyCapPreFiltersAllPursuits() async throws {
    // gpt-5.5 MED: once the global 6/day workshop cap is hit, selectDueItem must
    // return nothing — else the pump spends the green-window lease on a pursuit
    // whose reservation the store then refuses, every tick.
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let today = DeskClock.dayStamp(Date())
    // The open-pursuit cap is 2 and per-pursuit is 2/day, so reaching the GLOBAL
    // 6/day needs terminal pursuits' reservations to still count (they do). Two
    // pursuits reserved twice then CLOSED = 4 global; a third open pursuit
    // reserved twice = 6. Their reservations persist in state after close.
    for i in 0..<2 {
        let p = try await openTestPursuit(store, title: "closed\(i)")
        _ = try await store.reserveWorkSession(p.handle, day: today, slot: "am")
        _ = try await store.reserveWorkSession(p.handle, day: today, slot: "pm")
        _ = try await store.setStatus(p.handle, status: .done)
    }
    let third = try await openTestPursuit(store, title: "third")
    _ = try await store.reserveWorkSession(third.handle, day: today, slot: "am")
    _ = try await store.reserveWorkSession(third.handle, day: today, slot: "pm")
    // A fresh pursuit is within its own budget…
    _ = try await openTestPursuit(store, title: "fresh")
    let state = try await store.liveState()
    #expect(WorkshopPump.selectDueItem(from: state, now: Date()) == nil,
            "…but the global 6/day cap pre-filters every pursuit — no lease spent on a doomed reserve")
}

@Test func workshopNextDeadlineUsesExactUTCWindowBoundary() throws {
    let formatter = ISO8601DateFormatter()
    let now = try #require(formatter.date(from: "2026-07-13T10:35:00Z"))
    let pursuit = makePursuitItem(alias: "1", citations: [.standingView(id: "s")])
    let state = DeskState(items: [pursuit], generatedTs: "")
    let due = try #require(WorkshopPump.nextMeaningfulDeadline(from: state, after: now))
    #expect(formatter.string(from: due) == "2026-07-13T12:00:00Z")
}

// MARK: - Budget-exhaustion closure (2026-08-08)

/// A pursuit whose session budget is spent could never be picked again but
/// stayed OPEN forever, squatting one of the two open-pursuit cap slots —
/// with both slots exhausted, the volition lane starves permanently (live
/// case: 10/12 and 6/12 heading to zombie-hood). The pump now honors the
/// pursuit's own abandonCondition mechanically: receipt, then cancel.
@Test func exhaustedPursuitIsClosedByTheNextTick() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)

    let pursuit = Pursuit(
        why: "test exhaustion",
        evidence: validDossier(),
        doneLooksLike: "n/a",
        maxSessions: 1,
        abandonCondition: "If sessions run out, close with a note."
    )
    let item = try await store.openPursuit(project: "curiosity", title: "exhaust me", pursuit: pursuit)
    _ = try await store.reserveWorkSession(item.handle, day: "2026-08-07", slot: "w1")

    let spy = SessionSpy()
    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() })
    let outcome = await pump.tick()

    // Nothing else is due, and the exhausted pursuit must not be worked.
    #expect(outcome == .quiet)
    #expect(await spy.callCount() == 0)

    let state = try await store.liveState()
    let closed = state.items.first { $0.handle == item.handle }
    #expect(closed?.status == .canceled,
            "an exhausted pursuit is closed per its own abandon condition")
}

/// An in-budget pursuit must be untouched by the closure sweep.
@Test func inBudgetPursuitIsNotClosed() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let item = try await openTestPursuit(store)

    let spy = SessionSpy()
    let pump = makePump(root: root, store: store, spy: spy, posture: { normalPosture() })
    _ = await pump.tick()

    let state = try await store.liveState()
    let row = state.items.first { $0.handle == item.handle }
    #expect(row?.status.isTerminal == false,
            "a pursuit with budget remaining must never be swept closed")
}
