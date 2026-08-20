import Foundation
import Testing
@testable import PersistenceCore

/// Desk notify CASCADE (2026-08-18) — the live gap Agent caught on campaign 644.
///
/// Setup that failed in production: item 644 was notify level=direct,
/// on=[state_change, blocked, done]; sub-items 644.1–644.4 were created under
/// it and, like every sub-item, defaulted to level=quiet. Closing 644.1 fired
/// NOTHING — receipts: two ops on that handle (create_item, set_status done)
/// and zero mark_notified. The parent stayed silent too, because a child close
/// does not advance the PARENT's updatedAt. That is the whole delegation use
/// case ("watch a delegated project tick through steps without asking me")
/// dead by construction.
///
/// The contract these tests pin:
///  1. Direct parent + quiet child + child closes ⇒ a push fires (THE repro).
///  2. It fires on the CHILD handle, so the child's own stamp gates it and two
///     siblings closing together are two pings, not one.
///  3. Inherited pings are TRANSITION-ONLY: content churn on a quiet child
///     under a direct parent stays silent (the storm guard).
///  4. A child that states its own level governs itself — that is how a
///     sub-item opts out of a loud parent.
///  5. A parked ancestor silences the subtree; an explicit-only ancestor never
///     becomes a standing subscription; a quiet parent cascades nothing.
///  6. Cycles in a hand-authored parent chain terminate.
@Suite("Desk notify cascade")
struct DeskNotifyCascadeTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(
        handle: String,
        alias: String,
        parent: String? = nil,
        title: String,
        status: DeskStatus,
        level: NotifyLevel = .quiet,
        on: [String] = [],
        updatedAt: Date,
        closedAt: Date? = nil,
        lastNotifiedAt: Date? = nil,
        deferUntil: Date? = nil,
        waitingOn: String? = nil
    ) -> DeskItem {
        var item = DeskItem(
            handle: handle,
            alias: alias,
            parent: parent,
            kind: .plan,
            status: status,
            project: "NativeAgent",
            title: title,
            openedAt: DeskClock.nowISO(updatedAt.addingTimeInterval(-86_400)),
            updatedAt: DeskClock.nowISO(updatedAt)
        )
        item.closedAt = closedAt.map { DeskClock.nowISO($0) }
        item.deferUntil = deferUntil.map { DeskClock.nowISO($0) }
        item.waitingOn = waitingOn
        item.notify = NotifyPolicy(
            level: level, on: on,
            lastNotifiedAt: lastNotifiedAt.map { DeskClock.nowISO($0) }
        )
        return item
    }

    /// The live 644 shape: direct parent with Agent's exact filter set.
    private func parent(
        level: NotifyLevel = .direct,
        on: [String] = ["state_change", "blocked", "done"],
        deferUntil: Date? = nil,
        lastNotifiedAt: Date? = nil
    ) -> DeskItem {
        // Already pinged AFTER its own last change ⇒ the parent is settled and
        // silent, so every ping in this suite is provably the child's.
        row(handle: "desk_parent", alias: "644", title: "Campaign 644",
            status: .now, level: level, on: on,
            updatedAt: now.addingTimeInterval(-3600),
            lastNotifiedAt: lastNotifiedAt ?? now.addingTimeInterval(-1800),
            deferUntil: deferUntil)
    }

    private func state(_ items: [DeskItem]) -> DeskState {
        DeskState(items: items, generatedTs: "")
    }

    // MARK: 1 — THE repro

    @Test func quietChildClosingUnderDirectParentPushes() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        let decisions = DeskNotifyEvaluator.decisions(state([parent(), child]), now: now)
        #expect(decisions.count == 1)
        let ping = try! #require(decisions.first)
        #expect(ping.handle == "desk_child1")          // the CHILD is stamped
        #expect(ping.level == .direct)                 // borrowed from the parent
        #expect(ping.body == "✓ Step one — done (step of Campaign 644)")
    }

    @Test func urgentParentLendsUrgent() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        let decisions = DeskNotifyEvaluator.decisions(
            state([parent(level: .urgent), child]), now: now)
        #expect(decisions.first?.level == .urgent)
    }

    @Test func inheritanceReachesGrandchildThroughQuietMiddle() {
        let mid = row(handle: "desk_mid", alias: "644.1", parent: "desk_parent",
                      title: "Phase", status: .now, updatedAt: now.addingTimeInterval(-600))
        let leaf = row(handle: "desk_leaf", alias: "644.1.1", parent: "desk_mid",
                       title: "Step one", status: .done,
                       updatedAt: now.addingTimeInterval(-120),
                       closedAt: now.addingTimeInterval(-120))
        let decisions = DeskNotifyEvaluator.decisions(state([parent(), mid, leaf]), now: now)
        #expect(decisions.map(\.handle) == ["desk_leaf"])
    }

    // MARK: 2 — per-child stamping

    @Test func twoSiblingsClosingAreTwoPings() {
        let a = row(handle: "desk_a", alias: "644.1", parent: "desk_parent", title: "Step one",
                    status: .done, updatedAt: now.addingTimeInterval(-120),
                    closedAt: now.addingTimeInterval(-120))
        let b = row(handle: "desk_b", alias: "644.2", parent: "desk_parent", title: "Step two",
                    status: .done, updatedAt: now.addingTimeInterval(-60),
                    closedAt: now.addingTimeInterval(-60))
        let decisions = DeskNotifyEvaluator.decisions(state([parent(), a, b]), now: now)
        #expect(Set(decisions.map(\.handle)) == ["desk_a", "desk_b"])
    }

    @Test func alreadyStampedChildIsSilentForever() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-60),      // post-close churn
                        closedAt: now.addingTimeInterval(-300),
                        lastNotifiedAt: now.addingTimeInterval(-240))
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).isEmpty)
    }

    @Test func staleCloseCannotReplayHistory() {
        let old = now.addingTimeInterval(-(DeskNotifyEvaluator.terminalPingWindow + 3600))
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done, updatedAt: old, closedAt: old)
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).isEmpty)
    }

    // MARK: 3 — storm guard: transition-only

    @Test func contentChurnOnAQuietChildStaysSilent() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .now,          // just edited, not moved
                        updatedAt: now.addingTimeInterval(-60))
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).isEmpty)
    }

    @Test func blockedChildPushesWithWhatItWaitsOn() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .blocked,
                        updatedAt: now.addingTimeInterval(-60), waitingOn: "owner")
        let ping = try! #require(
            DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).first)
        #expect(ping.handle == "desk_child1")
        #expect(ping.body.contains("blocked (step of Campaign 644)"))
        #expect(ping.body.contains("waiting on: owner"))
    }

    @Test func blockedChildRespectsCooldown() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .blocked,
                        updatedAt: now.addingTimeInterval(-60),
                        lastNotifiedAt: now.addingTimeInterval(-120))
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).isEmpty)
        let later = now.addingTimeInterval(DeskNotifyEvaluator.defaultCooldown + 120)
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: later).count == 1)
    }

    @Test func parentFilterWithoutDoneOptsOutOfChildCloses() {
        let onlyBlocked = parent(on: ["blocked"])
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        #expect(DeskNotifyEvaluator.decisions(state([onlyBlocked, child]), now: now).isEmpty)
    }

    // MARK: 4/5 — the refusals

    @Test func childWithItsOwnLevelGovernsItself() {
        // digest is a deliberate choice on the child ⇒ no inheritance, no ping.
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done, level: .digest,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).isEmpty)
    }

    @Test func quietParentCascadesNothing() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        #expect(DeskNotifyEvaluator.decisions(
            state([parent(level: .quiet), child]), now: now).isEmpty)
    }

    @Test func parkedAncestorSilencesTheSubtree() {
        let parked = parent(deferUntil: now.addingTimeInterval(7 * 86_400))
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        #expect(DeskNotifyEvaluator.decisions(state([parked, child]), now: now).isEmpty)
    }

    @Test func explicitOnlyAncestorIsNotAStandingSubscription() {
        let announcer = parent(on: ["explicit"], lastNotifiedAt: now.addingTimeInterval(-7200))
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        #expect(DeskNotifyEvaluator.decisions(state([announcer, child]), now: now).isEmpty)
    }

    @Test func orphanChildWithAMissingParentIsSilentNotCrashing() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_ghost",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        #expect(DeskNotifyEvaluator.decisions(state([child]), now: now).isEmpty)
    }

    // MARK: 6 — hostile feed

    @Test func parentChainCycleTerminates() {
        var a = row(handle: "desk_a", alias: "9.1", parent: "desk_b", title: "A",
                    status: .done, updatedAt: now.addingTimeInterval(-120),
                    closedAt: now.addingTimeInterval(-120))
        a.parent = "desk_b"
        let b = row(handle: "desk_b", alias: "9.2", parent: "desk_a", title: "B",
                    status: .now, updatedAt: now.addingTimeInterval(-600))
        #expect(DeskNotifyEvaluator.decisions(state([a, b]), now: now).isEmpty)
    }

    // MARK: 7 — review hardening (gpt-5.5, 2026-08-18)

    /// FINDING 3: "default-quiet" is literal. A child that stated its own `on`
    /// filter is not a default row — borrowing the ancestor's filters would
    /// silently overrule what the child asked for.
    @Test func quietChildWithItsOwnFilterDoesNotBorrowAncestorFilters() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done, on: ["blocked"],
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        // Parent says done; child said blocked-only. The child governs itself.
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).isEmpty)
        #expect(DeskNotifyEvaluator.inheritedNotify(state([parent(), child]), now: now).isEmpty)
    }

    @Test func quietChildWithItsOwnCooldownDoesNotInherit() {
        var child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .done,
                        updatedAt: now.addingTimeInterval(-120),
                        closedAt: now.addingTimeInterval(-120))
        child.notify.cooldown = "1d"
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).isEmpty)
    }

    /// FINDING 2: the rollout storm. Children sitting blocked for weeks with no
    /// stamp must NOT all fire on the first tick after this ships.
    @Test func ancientBlockedChildrenDoNotStormOnRollout() {
        let ancient = now.addingTimeInterval(-(DeskNotifyEvaluator.terminalPingWindow + 7200))
        let kids = (1...25).map { i in
            row(handle: "desk_old\(i)", alias: "644.\(i)", parent: "desk_parent",
                title: "Old step \(i)", status: .blocked, updatedAt: ancient)
        }
        #expect(DeskNotifyEvaluator.decisions(state([parent()] + kids), now: now).isEmpty)
    }

    @Test func recentlyBlockedChildStillPushes() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .blocked,
                        updatedAt: now.addingTimeInterval(-3600))
        #expect(DeskNotifyEvaluator.decisions(state([parent(), child]), now: now).count == 1)
    }

    /// FINDING 4: both deadline branches must agree on WHOSE cooldown applies,
    /// or the loop wakes at a moment the evaluator will refuse.
    @Test func deferredInheritedChildUsesTheInheritedCooldown() {
        // The child carries NO cooldown of its own (it must not, or fix 3
        // refuses inheritance) — so the ONLY way the deferred branch can be
        // right is by reading the ANCESTOR's cooldown. Parent cooldown 2h vs
        // the 30m default is the whole difference this pins.
        var par = parent()
        par.notify.cooldown = "2h"
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .blocked,
                        updatedAt: now.addingTimeInterval(-600),
                        lastNotifiedAt: now.addingTimeInterval(-900),
                        deferUntil: now.addingTimeInterval(1800))
        let due = DeskNotifyEvaluator.nextMeaningfulDeadline(state([par, child]), after: now)
        // park lifts at +1800s; inherited cooldown crossing = -900 + 7200 = +6300s.
        // The later gate wins ⇒ the inherited cooldown, NOT the park and NOT
        // the 30m default (which would have given +900s).
        #expect(due == now.addingTimeInterval(6300))
    }

    // MARK: deadline scheduling

    @Test func blockedChildCooldownSchedulesAWake() {
        let child = row(handle: "desk_child1", alias: "644.1", parent: "desk_parent",
                        title: "Step one", status: .blocked,
                        updatedAt: now.addingTimeInterval(-60),
                        lastNotifiedAt: now.addingTimeInterval(-120))
        let due = DeskNotifyEvaluator.nextMeaningfulDeadline(state([parent(), child]), after: now)
        #expect(due != nil)
    }
}
