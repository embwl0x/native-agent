import Testing
import Foundation
@testable import PersistenceCore

// MARK: - Desk → Workshop (Wave A) store tests
//
// Proves the store-owned pursuit invariants that prompt rules can't hold:
//   • M10 op-replay byte-identity for a PRE-ORIGIN feed (origin=.owner omitted).
//   • H2 open-pursuit cap incl. close/reopen tricks + third-pursuit refusal.
//   • M7 dossier source-mix refusals (friction-only, single-day chat obs).
//   • origin immutability across the whole op surface.
//   • work-session reservation idempotency + daily caps (per-pursuit 2, global
//     6), counted from the ops feed rather than a mutable counter.
//   • the generic desk_add_item / append path can never mint origin=agent.

@Suite("DeskWorkshop")
struct DeskWorkshopTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskws-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A structurally-valid dossier: one non-friction source + friction, so the
    /// source-mix rule passes. `n` disambiguates ids across pursuits.
    private func validDossier(_ n: Int = 0) -> PromotionDossier {
        PromotionDossier(citations: [
            .standingView(id: "sv_\(n)"),
            .feltSalience(dates: ["2026-07-08", "2026-07-10"]),
            .traceFriction(count: 3, window: "7d"),
        ])
    }

    private func validPursuit(_ n: Int = 0, privateName: String? = nil) -> Pursuit {
        Pursuit(
            why: "I keep circling this — it's worth a real answer.",
            evidence: validDossier(n),
            doneLooksLike: "Can I answer X in ≤10 sessions?",
            abandonCondition: "If two sessions produce no new evidence.",
            privateName: privateName
        )
    }

    // MARK: M10 — pre-origin feed replays byte-identical

    @Test func preOriginFeedReplaysByteIdentical() throws {
        // Old-format op lines: NO `origin`/`pursuit` keys, exactly what the
        // pre-Workshop encoder produced.
        let lines: [JSONValue] = [
            .object([
                "opId": .string("deskop_a"), "ts": .string("2026-01-01T00:00:00.000000+00:00"),
                "op": .string("create_item"), "handle": .string("desk_a"),
                "alias": .string("1"), "kind": .string("plan"),
                "project": .string("na"), "title": .string("t"), "summary": .string("s"),
            ]),
            .object([
                "opId": .string("deskop_b"), "ts": .string("2026-01-01T00:00:01.000000+00:00"),
                "op": .string("set_status"), "handle": .string("desk_a"), "status": .string("now"),
            ]),
            .object([
                "opId": .string("deskop_c"), "ts": .string("2026-01-01T00:00:02.000000+00:00"),
                "op": .string("close_item"), "handle": .string("desk_a"),
                "outcomeSummary": .string("done"), "status": .string("done"),
            ]),
        ]
        for line in lines {
            let op = try #require(DeskOp.fromJSON(line))
            let original = try line.serializedData(pretty: false)
            let roundtrip = try op.toJSON().serializedData(pretty: false)
            #expect(original == roundtrip, "byte drift on \(op.op): \(String(data: roundtrip, encoding: .utf8) ?? "")")
        }
        // And the decoded create defaults origin=.owner with no pursuit.
        let created = try #require(DeskOp.fromJSON(lines[0]))
        guard case let .createItem(_, _, _, _, _, _, origin, pursuit) = created.body else {
            Issue.record("not a create"); return
        }
        #expect(origin == .owner)
        #expect(pursuit == nil)
    }

    @Test func preOriginFeedLoadsIntoStoreAsOwner() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let old: JSONValue = .object([
            "opId": .string("deskop_a"), "ts": .string("2026-01-01T00:00:00.000000+00:00"),
            "op": .string("create_item"), "handle": .string("desk_a"),
            "alias": .string("1"), "kind": .string("plan"),
            "project": .string("na"), "title": .string("t"),
        ])
        try await SwiftNativePersistenceCore().appendJSONL(old, to: store.opsPath)
        let state = try await store.liveState()
        let row = try #require(state.items.first { $0.handle == "desk_a" })
        #expect(row.origin == .owner)
        #expect(row.pursuit == nil)
    }

    // DeskOrigin.user → .owner rename (2026-07-11): the default origin was
    // never serialized (M10 omit rule), but a freak feed carrying an explicit
    // legacy "user" must still load — unknown raw values decode nil and land on
    // the same `?? .owner` default rather than dropping the item.
    @Test func explicitLegacyUserOriginDecodesToOwner() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let legacy: JSONValue = .object([
            "opId": .string("deskop_a"), "ts": .string("2026-01-01T00:00:00.000000+00:00"),
            "op": .string("create_item"), "handle": .string("desk_a"),
            "alias": .string("1"), "kind": .string("plan"),
            "project": .string("na"), "title": .string("t"),
            "origin": .string("user"),
        ])
        try await SwiftNativePersistenceCore().appendJSONL(legacy, to: store.opsPath)
        let state = try await store.liveState()
        let row = try #require(state.items.first { $0.handle == "desk_a" })
        #expect(row.origin == .owner)
        #expect(DeskOrigin(rawValue: "user") == nil)
    }

    @Test func legacySelfAuthoredOriginMigratesToNeutralAgentRole() throws {
        let retiredValue = ["ay", "ala"].joined()
        let legacy: JSONValue = .object([
            "opId": .string("deskop_legacy_agent"),
            "ts": .string("2026-01-01T00:00:00.000000+00:00"),
            "op": .string("create_item"),
            "handle": .string("desk_legacy_agent"),
            "alias": .string("1"),
            "kind": .string("project"),
            "project": .string("na"),
            "title": .string("legacy pursuit"),
            "origin": .string(retiredValue),
        ])

        let decoded = try #require(DeskOp.fromJSON(legacy))
        guard case let .createItem(_, _, _, _, _, _, origin, _) = decoded.body else {
            Issue.record("not a create")
            return
        }
        #expect(origin == .agent)
        #expect(DeskOrigin.agent.rawValue == "agent")
        guard case .object(let reencoded) = decoded.toJSON() else {
            Issue.record("re-encoded op was not an object")
            return
        }
        #expect(reencoded["origin"] == .string("agent"))
    }

    // MARK: H2 — open-pursuit cap (incl. close/reopen tricks)

    @Test func thirdOpenPursuitRefused() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        _ = try await store.openPursuit(project: "na", title: "P1", pursuit: validPursuit(1))
        _ = try await store.openPursuit(project: "na", title: "P2", pursuit: validPursuit(2))
        await #expect(throws: DeskError.self) {
            _ = try await store.openPursuit(project: "na", title: "P3", pursuit: validPursuit(3))
        }
    }

    @Test func closingAPursuitFreesACapSlot() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p1 = try await store.openPursuit(project: "na", title: "P1", pursuit: validPursuit(1))
        _ = try await store.openPursuit(project: "na", title: "P2", pursuit: validPursuit(2))
        _ = try await store.closeItem(p1.handle, outcomeSummary: "let it go")   // 1 open now
        // A slot freed → a new pursuit opens.
        _ = try await store.openPursuit(project: "na", title: "P3", pursuit: validPursuit(3))
        let openCount = SwiftNativeDeskStore.openAgentPursuitCount(in: try await store.liveState())
        #expect(openCount == 2)
    }

    @Test func reopeningATerminalPursuitCountsAgainstCap() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p1 = try await store.openPursuit(project: "na", title: "P1", pursuit: validPursuit(1))
        _ = try await store.openPursuit(project: "na", title: "P2", pursuit: validPursuit(2))
        _ = try await store.closeItem(p1.handle, outcomeSummary: "closed")       // open: P2 only
        _ = try await store.openPursuit(project: "na", title: "P3", pursuit: validPursuit(3)) // open: P2,P3
        // Reopening P1 would make 3 open — the close/reopen trick must be refused.
        await #expect(throws: DeskError.self) {
            _ = try await store.setStatus(p1.handle, status: .now)
        }
        // P1 stays terminal.
        let p1row = try #require(try await store.liveState().items.first { $0.handle == p1.handle })
        #expect(p1row.status.isTerminal)
    }

    // MARK: M7 — dossier source-mix refusals

    @Test func frictionOnlyDossierRefused() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let frictionOnly = Pursuit(
            why: "w", evidence: PromotionDossier(citations: [.traceFriction(count: 5, window: "3d")]),
            doneLooksLike: "d", abandonCondition: "a"
        )
        await #expect(throws: DeskError.self) {
            _ = try await store.openPursuit(project: "na", title: "friction", pursuit: frictionOnly)
        }
        // The dossier's own gate names the reason.
        #expect(frictionOnly.evidence.validationError()?.contains("friction") == true)
    }

    @Test func singleDayChatObservationRefused() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let oneDay = PromotionDossier(citations: [.chatObservation(noteIds: ["n1", "n2"], distinctDays: 1)])
        #expect(oneDay.validationError() != nil)
        let pursuit = Pursuit(why: "w", evidence: oneDay, doneLooksLike: "d", abandonCondition: "a")
        await #expect(throws: DeskError.self) {
            _ = try await store.openPursuit(project: "na", title: "oneday", pursuit: pursuit)
        }
        // Two distinct days passes ONLY with ≥2 cited notes — one note can't
        // forge "recurred across days" (2026-07-11 review MED).
        #expect(PromotionDossier(citations: [.chatObservation(noteIds: ["n1"], distinctDays: 2)]).validationError() != nil)
        #expect(PromotionDossier(citations: [.chatObservation(noteIds: ["n1", "n2"], distinctDays: 2)]).validationError() == nil)
    }

    @Test func singleDateFeltSalienceRefused() {
        #expect(PromotionDossier(citations: [.feltSalience(dates: ["2026-07-08"])]).validationError() != nil)
        #expect(PromotionDossier(citations: [.feltSalience(dates: ["2026-07-08", "2026-07-08"])]).validationError() != nil) // not distinct
        #expect(PromotionDossier(citations: [.feltSalience(dates: ["2026-07-08", "2026-07-09"])]).validationError() == nil)
        #expect(PromotionDossier(citations: [.feltSalience(dates: ["not-a-date", "also-bad"])]).validationError() != nil)
    }

    @Test func missingRequiredFieldRefused() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let noWhy = Pursuit(why: "   ", evidence: validDossier(), doneLooksLike: "d", abandonCondition: "a")
        await #expect(throws: DeskError.self) {
            _ = try await store.openPursuit(project: "na", title: "nowhy", pursuit: noWhy)
        }
    }

    // MARK: origin immutability

    @Test func originIsImmutableAcrossTheOpSurface() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p = try await store.openPursuit(project: "na", title: "P", pursuit: validPursuit(1, privateName: "north star"))
        #expect(p.origin == .agent)
        // Every mutation op — none carries origin, so none can change it.
        _ = try await store.setStatus(p.handle, status: .now)
        _ = try await store.updateTitle(p.handle, title: "P renamed")
        _ = try await store.appendNote(p.handle, text: "progress")
        _ = try await store.addRef(p.handle, ref: DeskRef(kind: .note(text: "n")))
        _ = try await store.closeItem(p.handle, outcomeSummary: "closed")
        let row = try #require(try await store.liveState().items.first { $0.handle == p.handle })
        #expect(row.origin == .agent)
        #expect(row.pursuit?.privateName == "north star")   // pursuit payload survives too
        // A user item stays user.
        let j = try await store.createItem(kind: .plan, project: "na", title: "user item")
        #expect(j.origin == .owner)
    }

    // MARK: generic path cannot mint origin=agent

    @Test func genericAppendCannotCreateAgent() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let agentCreate = DeskOp(handle: DeskClock.newHandle(), body: .createItem(
            alias: "1", kind: .project, project: "na", title: "sneaky",
            parent: nil, summary: nil, origin: .agent, pursuit: validPursuit(9)
        ))
        // Even with a VALID pursuit, the generic append path refuses origin=agent.
        await #expect(throws: DeskError.self) {
            _ = try await store.append(agentCreate)
        }
        #expect(try await store.liveState().items.isEmpty)
    }

    @Test func createItemMethodIsAlwaysUser() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let i = try await store.createItem(kind: .project, project: "na", title: "t")
        #expect(i.origin == .owner)
        #expect(i.pursuit == nil)
    }

    // MARK: work-session reservations — idempotency + daily caps

    @Test func reservationIsIdempotentPerHandleDaySlot() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p = try await store.openPursuit(project: "na", title: "P", pursuit: validPursuit(1))
        let r1 = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "am")
        let r2 = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "am")
        #expect(r1 == r2)   // same triple → same id
        // Exactly ONE reservation folded from ops (dedup at compact) — the count
        // is DISTINCT-from-ops, not a bumped counter.
        let row = try #require(try await store.liveState().items.first { $0.handle == p.handle })
        #expect(row.pursuit?.reservations.count == 1)
        #expect(row.pursuit?.workSessionsToday == 1)
    }

    @Test func replayedDuplicateReserveOpFoldsToOne() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p = try await store.openPursuit(project: "na", title: "P", pursuit: validPursuit(1))
        let rid = DeskClock.reservationId(handle: p.handle, day: "2026-07-11", slot: "am")
        // Two raw reserve ops with the SAME id (simulating a replayed/crashed
        // append) must fold to a single reservation.
        for i in 0..<2 {
            let op = DeskOp(ts: "2026-07-11T0\(i):00:00.000000+00:00", handle: p.handle,
                            body: .reserveWorkSession(reservationId: rid, day: "2026-07-11", slot: "am"))
            try await SwiftNativePersistenceCore().appendJSONL(op.toJSON(), to: store.opsPath)
        }
        let row = try #require(try await store.liveState().items.first { $0.handle == p.handle })
        #expect(row.pursuit?.reservations.count == 1)
    }

    @Test func perPursuitDailyCapIsTwo() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p = try await store.openPursuit(project: "na", title: "P", pursuit: validPursuit(1))
        _ = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "am")
        _ = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "pm")
        // Third distinct slot same day → per-pursuit cap.
        await #expect(throws: DeskError.self) {
            _ = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "eve")
        }
        // A different day is fine.
        _ = try await store.reserveWorkSession(p.handle, day: "2026-07-12", slot: "am")
        let row = try #require(try await store.liveState().items.first { $0.handle == p.handle })
        #expect(row.pursuit?.reservations.filter { $0.day == "2026-07-11" }.count == 2)
    }

    @Test func globalDailyCapIsSixCountedFromOps() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let day = "2026-07-11"
        // Accumulate 6 reservations across three pursuits (2 each), closing each
        // to stay under the 2-open cap — terminal pursuits' reservations STILL
        // count globally (they're on the ops feed).
        for n in 0..<3 {
            let p = try await store.openPursuit(project: "na", title: "P\(n)", pursuit: validPursuit(n))
            _ = try await store.reserveWorkSession(p.handle, day: day, slot: "am")
            _ = try await store.reserveWorkSession(p.handle, day: day, slot: "pm")
            _ = try await store.closeItem(p.handle, outcomeSummary: "closed")
        }
        // A fresh store instance (stateless — all state on disk) proves the count
        // comes from the ops feed, not an in-memory counter.
        let store2 = SwiftNativeDeskStore(dataRoot: root)
        let p4 = try await store2.openPursuit(project: "na", title: "P4", pursuit: validPursuit(9))
        await #expect(throws: DeskError.self) {
            _ = try await store2.reserveWorkSession(p4.handle, day: day, slot: "am")
        }
        // The next day is unaffected — the cap is per-day.
        _ = try await store2.reserveWorkSession(p4.handle, day: "2026-07-12", slot: "am")
    }

    @Test func completeWorkSessionRequiresARealReservation() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p = try await store.openPursuit(project: "na", title: "P", pursuit: validPursuit(1))
        // No reservation yet → complete refused.
        await #expect(throws: DeskError.self) {
            _ = try await store.completeWorkSession(p.handle, reservationId: "wres_bogus", receipt: "did stuff")
        }
        let rid = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "am")
        _ = try await store.completeWorkSession(p.handle, reservationId: rid, receipt: "wired the seam")
        let row = try #require(try await store.liveState().items.first { $0.handle == p.handle })
        // Receipt lands as a note; the reservation is marked complete.
        #expect(row.notes.contains { $0.text == "wired the seam" })
        #expect(row.pursuit?.reservations.first { $0.reservationId == rid }?.isCompleted == true)
        #expect(row.pursuit?.lastWorkedAt != nil)
    }

    @Test func reserveRefusedOnNonPursuit() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let userItem = try await store.createItem(kind: .project, project: "na", title: "user project")
        await #expect(throws: DeskError.self) {
            _ = try await store.reserveWorkSession(userItem.handle, day: "2026-07-11", slot: "am")
        }
    }

    // MARK: projection renders the pursuit marker

    @Test func projectionShowsPursuitMarkerAndPrivateName() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        _ = try await store.openPursuit(project: "na", title: "Chase the thread",
                                        pursuit: validPursuit(1, privateName: "the quiet one"))
        let text = DeskProjection.render(try await store.liveState())
        #expect(text.contains("pursuit"))
        #expect(text.contains("the quiet one"))
    }

    // MARK: 2026-07-11 review fixes

    /// H2: a pursuit is written under the dedicated `open_pursuit` op token, so
    /// a pre-Workshop binary (which knows no such token) SKIPS it on rebuild —
    /// it can never see a pursuit as a user project and mutate it past the cap.
    @Test func pursuitOpUsesDedicatedTokenOldBinarySkips() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        _ = try await store.openPursuit(project: "na", title: "P1", pursuit: validPursuit(1))
        // The persisted op line carries the dedicated token, NOT create_item.
        let ops = try await store.readOpsUnlocked()
        #expect(ops.contains { $0.op == "open_pursuit" })
        #expect(!ops.contains { $0.op == "create_item" })
        // Simulate an OLD binary: drop tokens it wouldn't know. The pursuit
        // vanishes rather than materializing as an uncited user project.
        let oldView = SwiftNativeDeskStore.compact(ops.filter { $0.op != "open_pursuit" })
        #expect(oldView.items.isEmpty)
    }

    /// H1: the generic append path enforces the reservation caps identically —
    /// a raw 3rd-slot reserve op is refused, not silently applied.
    @Test func genericAppendReserveHonorsPerPursuitCap() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p = try await store.openPursuit(project: "na", title: "P1", pursuit: validPursuit(1))
        _ = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "am")
        _ = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "pm")
        // A raw generic-append reserve for a 3rd distinct slot must be refused.
        let rogue = DeskOp(handle: p.handle, body: .reserveWorkSession(
            reservationId: DeskClock.reservationId(handle: p.handle, day: "2026-07-11", slot: "eve"),
            day: "2026-07-11", slot: "eve"))
        await #expect(throws: DeskError.self) { _ = try await store.append(rogue) }
    }

    /// MED: a reserved slot completes exactly once; a re-complete is refused so
    /// a retry can't record a duplicate work receipt.
    @Test func completeWorkSessionRefusesDoubleComplete() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let p = try await store.openPursuit(project: "na", title: "P1", pursuit: validPursuit(1))
        let rid = try await store.reserveWorkSession(p.handle, day: "2026-07-11", slot: "am")
        _ = try await store.completeWorkSession(p.handle, reservationId: rid, receipt: "found it")
        await #expect(throws: DeskError.self) {
            _ = try await store.completeWorkSession(p.handle, reservationId: rid, receipt: "again")
        }
    }

    /// MED: felt-salience distinctness is by CALENDAR DAY — two timestamps on
    /// one day (or a bare day vs its midnight ISO form) is not two days.
    @Test func feltSalienceCountsCalendarDaysNotRawStrings() {
        #expect(PromotionDossier(citations: [.feltSalience(dates: [
            "2026-07-08T09:00:00+00:00", "2026-07-08T21:00:00+00:00"])]).validationError() != nil)
        #expect(PromotionDossier(citations: [.feltSalience(dates: [
            "2026-07-08", "2026-07-08T00:00:00+00:00"])]).validationError() != nil)
        #expect(PromotionDossier(citations: [.feltSalience(dates: [
            "2026-07-08T09:00:00+00:00", "2026-07-09"])]).validationError() == nil)
    }

    /// LOW: trace-friction window must be a positive duration, not "-7d"/"garbage".
    @Test func traceFrictionWindowRejectsNonDurations() {
        let mix: (String) -> PromotionDossier = { w in
            PromotionDossier(citations: [.standingView(id: "sv"), .traceFriction(count: 3, window: w)])
        }
        #expect(mix("7d").validationError() == nil)
        #expect(mix("24h").validationError() == nil)
        #expect(mix("30m").validationError() == nil)
        #expect(mix("-7d").validationError() != nil)
        #expect(mix("garbage").validationError() != nil)
    }
}
