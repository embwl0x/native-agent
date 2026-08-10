import Foundation
import Testing
@testable import PersistenceCore

/// The "opened a self-pursuit" push storm (2026-08-08): the reflection opener
/// sets `on: ["explicit"]` intending ONE announcement, but the v1 evaluator
/// ignored the filter and re-fired the frozen open-time `notifyReason` every
/// time the Workshop pump's own work-session ops advanced `updatedAt` —
/// 28 pushes for 2 pursuits in 4 days, all reading "opened a self-pursuit".
///
/// Contract pinned here:
///  1. `on == ["explicit"]` pings once, then never again from content churn,
///     and generates no wake deadlines once fired.
///  2. Legitimate re-pings (other filters) describe the CURRENT state instead
///     of replaying the open-time announcement.
@Suite("Desk explicit-only notify")
struct DeskExplicitOnlyNotifyTests {

    private func pursuitItem(
        on: [String],
        updatedAt: Date,
        lastNotifiedAt: String? = nil
    ) -> DeskItem {
        var row = DeskItem(
            handle: "desk_pursuit",
            alias: "523",
            kind: .plan,
            status: .now,
            project: "workshop",
            title: "Pursue: absence is a system at rest",
            openedAt: DeskClock.nowISO(updatedAt.addingTimeInterval(-86_400)),
            updatedAt: DeskClock.nowISO(updatedAt)
        )
        row.notify = NotifyPolicy(
            level: .direct,
            on: on,
            lastNotifiedAt: lastNotifiedAt,
            notifyReason: "Agent opened a self-pursuit: absence is a system at rest"
        )
        return row
    }

    private func state(_ items: [DeskItem]) -> DeskState {
        DeskState(items: items, generatedTs: "")
    }

    @Test func explicitOnlyFiresItsOneAnnouncement() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = pursuitItem(on: ["explicit"], updatedAt: now)
        let decisions = DeskNotifyEvaluator.decisions(state([fresh]), now: now)
        #expect(decisions.count == 1)
        #expect(decisions.first?.body.contains("opened a self-pursuit") == true,
                "the one announcement carries the opener's reason")
    }

    /// THE BUG. Machine churn after the announcement used to replay it forever.
    @Test func explicitOnlyNeverRePingsOnContentChurn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Announced 2h ago (cooldown long elapsed), churned 5 minutes ago.
        let pinged = pursuitItem(
            on: ["explicit"],
            updatedAt: now.addingTimeInterval(-300),
            lastNotifiedAt: DeskClock.nowISO(now.addingTimeInterval(-7_200))
        )
        #expect(DeskNotifyEvaluator.decisions(state([pinged]), now: now).isEmpty,
                "on == [explicit] is a one-time announcement; work-session churn must not replay it")
        #expect(DeskNotifyEvaluator.nextMeaningfulDeadline(state([pinged]), after: now) == nil,
                "an announcement that can never re-fire must not schedule wake deadlines")
    }

    @Test func nonExplicitRePingDescribesCurrentStateNotTheAnnouncement() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pinged = pursuitItem(
            on: ["state_change"],
            updatedAt: now.addingTimeInterval(-300),
            lastNotifiedAt: DeskClock.nowISO(now.addingTimeInterval(-7_200))
        )
        let decisions = DeskNotifyEvaluator.decisions(state([pinged]), now: now)
        #expect(decisions.count == 1)
        #expect(decisions.first?.body.contains("opened a self-pursuit") == false,
                "a re-ping must not replay the frozen open-time reason")
        #expect(decisions.first?.body.contains("now") == true,
                "a re-ping names the current status")
    }

    @Test func firstPingStillUsesTheReasonForNonExplicitFilters() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = pursuitItem(on: ["state_change"], updatedAt: now)
        let decisions = DeskNotifyEvaluator.decisions(state([fresh]), now: now)
        #expect(decisions.first?.body.contains("opened a self-pursuit") == true)
    }
}
