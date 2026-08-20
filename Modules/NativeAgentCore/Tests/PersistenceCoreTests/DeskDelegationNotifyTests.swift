import Foundation
import Testing
@testable import PersistenceCore

/// Desk delegation pushes (2026-08-17, docs/build_plans/desk-delegation-pushes.md):
/// User delegates a project to Agent, she orchestrates Claude/codex, and "I'll
/// let you know when it's done" was a promise in her head with no background
/// turn to keep it. These tests pin the MECHANICAL contract that replaced it:
///  1. A direct/urgent item CLOSING fires one completion ping — the old
///     blanket "a finished item doesn't interrupt User" silenced exactly the
///     ping User most wanted.
///  2. The completion ping cannot replay history: closes older than the 48h
///     window (the live board carried 49 historical dones at introduction)
///     never fire.
///  3. It fires ONCE: after the stamp, a closed item is silent forever.
///  4. The `on` filter is enforced for change pings — "blocked" pings only
///     while blocked, unknown filters alone go silent, empty/"state_change"
///     keep any-change semantics, explicit-only is untouched.
@Suite("Desk delegation notify")
struct DeskDelegationNotifyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        status: DeskStatus,
        level: NotifyLevel = .direct,
        on: [String] = [],
        updatedAt: Date,
        closedAt: Date? = nil,
        lastNotifiedAt: Date? = nil,
        waitingOn: String? = nil
    ) -> DeskItem {
        var row = DeskItem(
            handle: "desk_delegated",
            alias: "700",
            kind: .plan,
            status: status,
            project: "NativeAgent",
            title: "Ship the widget",
            openedAt: DeskClock.nowISO(updatedAt.addingTimeInterval(-86_400)),
            updatedAt: DeskClock.nowISO(updatedAt)
        )
        row.closedAt = closedAt.map { DeskClock.nowISO($0) }
        row.waitingOn = waitingOn
        row.notify = NotifyPolicy(
            level: level,
            on: on,
            lastNotifiedAt: lastNotifiedAt.map { DeskClock.nowISO($0) },
            notifyReason: nil
        )
        return row
    }

    private func state(_ items: [DeskItem]) -> DeskState {
        DeskState(items: items, generatedTs: "")
    }

    // MARK: completion ping (W1)

    @Test func freshCloseFiresOneCompletionPing() {
        let closed = item(status: .done, updatedAt: now.addingTimeInterval(-60),
                          closedAt: now.addingTimeInterval(-60))
        let decisions = DeskNotifyEvaluator.decisions(state([closed]), now: now)
        #expect(decisions.count == 1)
        #expect(decisions.first?.body == "✓ Ship the widget — done")
    }

    @Test func cancelFiresWithHonestVerb() {
        let canceled = item(status: .canceled, updatedAt: now.addingTimeInterval(-60),
                            closedAt: now.addingTimeInterval(-60))
        let decisions = DeskNotifyEvaluator.decisions(state([canceled]), now: now)
        #expect(decisions.first?.body == "✕ Ship the widget — canceled")
    }

    /// THE STORM GUARD. Shipping this feature onto a board with 49 historical
    /// dones must fire zero pings.
    @Test func historicalCloseNeverFires() {
        let old = item(status: .done,
                       updatedAt: now.addingTimeInterval(-30 * 86_400),
                       closedAt: now.addingTimeInterval(-30 * 86_400))
        #expect(DeskNotifyEvaluator.decisions(state([old]), now: now).isEmpty)
    }

    @Test func completionPingFiresExactlyOnce() {
        // Stamped AFTER the close (the loop's markNotified) ⇒ silent forever.
        let stamped = item(status: .done, updatedAt: now.addingTimeInterval(-120),
                           closedAt: now.addingTimeInterval(-120),
                           lastNotifiedAt: now.addingTimeInterval(-60))
        #expect(DeskNotifyEvaluator.decisions(state([stamped]), now: now).isEmpty,
                "a completion ping that already fired must never re-fire")
    }

    /// gpt-5.5 HIGH (2026-08-17): a note/ref appended AFTER the completion
    /// ping bumps updatedAt past lastNotifiedAt while closedAt stays within
    /// the window — keying the once-only gate off updatedAt re-sent the same
    /// completion. The gate keys off closedAt vs lastNotifiedAt.
    @Test func postCloseChurnNeverResendsCompletion() {
        let churned = item(status: .done,
                           updatedAt: now.addingTimeInterval(-10),      // note added after stamp
                           closedAt: now.addingTimeInterval(-3_600),    // closed 1h ago, in window
                           lastNotifiedAt: now.addingTimeInterval(-3_540)) // pinged just after close
        #expect(DeskNotifyEvaluator.decisions(state([churned]), now: now).isEmpty,
                "post-close churn must not replay the completion ping")
    }

    @Test func reopenAndRecloseEarnsFreshCompletionPing() {
        // closedAt advanced PAST the old stamp ⇒ a genuinely new close.
        let reclosed = item(status: .done,
                            updatedAt: now.addingTimeInterval(-30),
                            closedAt: now.addingTimeInterval(-30),
                            lastNotifiedAt: now.addingTimeInterval(-7_200))
        #expect(DeskNotifyEvaluator.decisions(state([reclosed]), now: now).count == 1)
    }

    @Test func completionBypassesCooldownAfterStepPing() {
        // A step ping fired 5 minutes ago (inside the 30m cooldown); the close
        // op bumped updatedAt past it. Completion must not wait out a cooldown.
        let closed = item(status: .done, updatedAt: now.addingTimeInterval(-30),
                          closedAt: now.addingTimeInterval(-30),
                          lastNotifiedAt: now.addingTimeInterval(-300))
        #expect(DeskNotifyEvaluator.decisions(state([closed]), now: now).count == 1)
    }

    @Test func quietItemsAndExplicitOnlyStaySilentAtClose() {
        let quiet = item(status: .done, level: .quiet,
                         updatedAt: now.addingTimeInterval(-60),
                         closedAt: now.addingTimeInterval(-60))
        let explicitOnly = item(status: .done, on: ["explicit"],
                                updatedAt: now.addingTimeInterval(-60),
                                closedAt: now.addingTimeInterval(-60))
        #expect(DeskNotifyEvaluator.decisions(state([quiet, explicitOnly]), now: now).isEmpty)
    }

    @Test func closeWithoutClosedAtStampStaysSilent() {
        // A terminal status with no parseable closedAt has no recency proof —
        // fail silent, not loud (the storm guard's authority is the stamp).
        let unstamped = item(status: .done, updatedAt: now.addingTimeInterval(-60))
        #expect(DeskNotifyEvaluator.decisions(state([unstamped]), now: now).isEmpty)
    }

    // MARK: on-filter enforcement (W2)

    @Test func blockedFilterPingsOnlyWhileBlocked() {
        let blocked = item(status: .blocked, on: ["blocked", "done"],
                           updatedAt: now.addingTimeInterval(-60),
                           waitingOn: "User's Apple ID password")
        let working = item(status: .now, on: ["blocked", "done"],
                           updatedAt: now.addingTimeInterval(-60))
        let decisions = DeskNotifyEvaluator.decisions(state([blocked]), now: now)
        #expect(decisions.count == 1)
        #expect(decisions.first?.body.contains("waiting on: User's Apple ID password") == true,
                "a blocker ping answers 'on WHAT?' in the push itself")
        #expect(DeskNotifyEvaluator.decisions(state([working]), now: now).isEmpty,
                "on:[blocked,done] must not ping ordinary progress churn")
    }

    @Test func doneFilterAllowsCloseAndSilencesChurn() {
        let closed = item(status: .done, on: ["done"],
                          updatedAt: now.addingTimeInterval(-60),
                          closedAt: now.addingTimeInterval(-60))
        let churning = item(status: .now, on: ["done"],
                            updatedAt: now.addingTimeInterval(-60))
        #expect(DeskNotifyEvaluator.decisions(state([closed]), now: now).count == 1)
        #expect(DeskNotifyEvaluator.decisions(state([churning]), now: now).isEmpty)
    }

    @Test func stateChangeAndEmptyFiltersKeepAnyChangeSemantics() {
        // The live board's urgent item rides on:["state_change","explicit"] —
        // enforcement must not silence it (pinned against the 2026-08-17 board).
        let liveShape = item(status: .now, level: .urgent, on: ["state_change", "explicit"],
                             updatedAt: now.addingTimeInterval(-60))
        let bare = item(status: .now, updatedAt: now.addingTimeInterval(-60))
        #expect(DeskNotifyEvaluator.decisions(state([liveShape]), now: now).count == 1)
        #expect(DeskNotifyEvaluator.decisions(state([bare]), now: now).count == 1)
    }

    @Test func undetectableFiltersAloneStaySilent() {
        // Stateless enforcement cannot see transitions; unblocked/user_next/due
        // alone must not degrade into any-change pings.
        let row = item(status: .now, on: ["unblocked", "user_next"],
                       updatedAt: now.addingTimeInterval(-60))
        #expect(DeskNotifyEvaluator.decisions(state([row]), now: now).isEmpty)
    }
}
