import Foundation
import Testing
@testable import PersistenceCore

/// Parking an item silences the DIRECT/URGENT lane too (audit 2026-08-02,
/// finding 4).
///
/// DeskSequencing drops a deferred item out of `nextUp`; DeskNagEvaluator
/// refuses to call it stale. DeskNotifyEvaluator — the only lane that can
/// actually buzz User's phone — never consulted `isDeferred` at all, so an item
/// parked until September that picked up a reference today fired a direct push.
/// "Not now" has to mean the same thing on every lane.
@Suite("Desk deferred notify")
struct DeskDeferredNotifyTests {

    private func directItem(
        handle: String = "desk_a",
        updatedAt: Date,
        deferUntil: String? = nil,
        lastNotifiedAt: String? = nil,
        status: DeskStatus = .todo
    ) -> DeskItem {
        var row = DeskItem(
            handle: handle,
            alias: "1",
            kind: .plan,
            status: status,
            project: "NativeAgent",
            title: "notarize the build",
            openedAt: DeskClock.nowISO(updatedAt),
            updatedAt: DeskClock.nowISO(updatedAt)
        )
        row.deferUntil = deferUntil
        row.notify = NotifyPolicy(level: .direct, lastNotifiedAt: lastNotifiedAt)
        return row
    }

    private func state(_ items: [DeskItem]) -> DeskState {
        DeskState(items: items, generatedTs: "")
    }

    /// A park stamp strictly after `now`, expressed the way User types one
    /// (`yyyy-MM-dd`). Derived from `now` so the fixtures can't silently expire.
    private func parkDay(after now: Date, days: Int = 30) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now.addingTimeInterval(TimeInterval(days) * 86_400))
    }

    /// THE BUG. A never-notified direct item that is parked into the future
    /// used to fire on the first tick. PRE-FIX: `decisions` returned 1.
    @Test func aParkedItemDoesNotFireTheDirectLane() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let park = parkDay(after: now)
        let parked = directItem(updatedAt: now, deferUntil: park)
        #expect(now < DeskSequencing.parseDeferStamp(park)!, "fixture sanity: the park is in the future")
        #expect(DeskNotifyEvaluator.decisions(state([parked]), now: now).isEmpty,
                "parking must silence the shoulder-tap, not just the sequencing lane")
    }

    /// The same for the re-ping path: content advanced past the last ping and
    /// the cooldown elapsed, but the item is parked.
    @Test func aParkedItemDoesNotRePingWhenItsContentAdvances() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastPing = now.addingTimeInterval(-4 * 3_600)
        let parked = directItem(
            updatedAt: now.addingTimeInterval(-60),
            deferUntil: parkDay(after: now),
            lastNotifiedAt: DeskClock.nowISO(lastPing)
        )
        #expect(DeskNotifyEvaluator.decisions(state([parked]), now: now).isEmpty)
    }

    /// SUPPRESSED, NOT LOST. `markNotified` never ran, so `updatedAt` still
    /// sits past `lastNotifiedAt` — the ping lands on the first tick after the
    /// park ends.
    @Test func theSuppressedPingFiresOnceTheParkElapses() {
        let parkEnd = DeskSequencing.parseDeferStamp("2026-09-01")!
        let duringPark = parkEnd.addingTimeInterval(-86_400)
        let afterPark = parkEnd.addingTimeInterval(60)
        let item = directItem(
            updatedAt: duringPark,
            deferUntil: "2026-09-01",
            lastNotifiedAt: DeskClock.nowISO(duringPark.addingTimeInterval(-7_200))
        )
        #expect(DeskNotifyEvaluator.decisions(state([item]), now: duringPark).isEmpty)
        let after = DeskNotifyEvaluator.decisions(state([item]), now: afterPark)
        #expect(after.count == 1, "the change was deferred, not discarded")
        #expect(after[0].handle == "desk_a")
    }

    /// An UNPARSEABLE defer stamp is NOT a park — same rule as
    /// `DeskSequencing.isDeferred`. A typo must never silence a direct item
    /// forever.
    @Test func anUnparseableDeferStampDoesNotSilenceTheLane() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = directItem(updatedAt: now, deferUntil: "sometime after the heat death")
        #expect(DeskNotifyEvaluator.decisions(state([item]), now: now).count == 1)
    }

    /// An ELAPSED park is not a park.
    @Test func anElapsedParkLetsTheLaneFire() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = directItem(updatedAt: now, deferUntil: "2020-01-01")
        #expect(DeskNotifyEvaluator.decisions(state([item]), now: now).count == 1)
    }

    // MARK: - The deadline function must agree with the new gate

    /// THE CONSISTENCY REQUIREMENT. If the lane is silent until the park ends,
    /// the exact-deadline owner has to be woken AT the park end — otherwise a
    /// suppressed ping waits for the next unrelated ops event or the 24h
    /// backstop, and "parked until Friday" pings sometime Saturday.
    /// PRE-FIX this returned nil (the item had no outstanding cooldown at all).
    @Test func theDeadlineIsTheParkEndForASilencedItem() {
        let parkEnd = DeskSequencing.parseDeferStamp("2026-09-01")!
        let now = parkEnd.addingTimeInterval(-3 * 86_400)
        let item = directItem(
            updatedAt: now,
            deferUntil: "2026-09-01",
            lastNotifiedAt: DeskClock.nowISO(now.addingTimeInterval(-7_200))
        )
        #expect(DeskNotifyEvaluator.nextMeaningfulDeadline(state([item]), after: now) == parkEnd)
    }

    /// A parked item with NO prior ping also schedules its park end — it is
    /// eligible the moment the park lifts.
    @Test func theDeadlineIsTheParkEndEvenWithoutAPriorPing() {
        let parkEnd = DeskSequencing.parseDeferStamp("2026-09-01")!
        let now = parkEnd.addingTimeInterval(-86_400)
        let item = directItem(updatedAt: now, deferUntil: "2026-09-01")
        #expect(DeskNotifyEvaluator.nextMeaningfulDeadline(state([item]), after: now) == parkEnd)
    }

    /// Unparked items keep the original cooldown-crossing contract.
    @Test func anUnparkedItemStillReportsItsCooldownCrossing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastPing = now.addingTimeInterval(-600)
        var item = directItem(updatedAt: now, lastNotifiedAt: DeskClock.nowISO(lastPing))
        item.notify = NotifyPolicy(level: .direct, cooldown: "30m", lastNotifiedAt: DeskClock.nowISO(lastPing))
        let due = DeskNotifyEvaluator.nextMeaningfulDeadline(state([item]), after: now)
        #expect(due != nil)
        #expect(abs(due!.timeIntervalSince(lastPing.addingTimeInterval(1_800))) < 1)
    }

    /// A terminal parked item is nobody's deadline.
    @Test func aTerminalParkedItemIsNotADeadline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = directItem(updatedAt: now, deferUntil: parkDay(after: now), status: .done)
        #expect(DeskNotifyEvaluator.nextMeaningfulDeadline(state([item]), after: now) == nil)
        #expect(DeskNotifyEvaluator.decisions(state([item]), now: now).isEmpty)
    }
}
