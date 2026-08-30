import Foundation
import Testing
@testable import NativeAgentApp
@testable import PersistenceCore
import WorkshopExecution

@Suite("Desk Live Activity Part 2")
struct DeskLiveActivityPart2Tests {
    private let now = Date(timeIntervalSince1970: 1_777_000_000)

    private func item(
        _ handle: String,
        secondsAgo: TimeInterval,
        status: DeskStatus = .now,
        title: String? = nil,
        summary: String? = nil,
        assignee: String? = nil,
        laneOf: String? = nil,
        parent: String? = nil,
        progress: DeskProgress? = nil
    ) -> DeskItem {
        DeskItem(
            handle: handle,
            alias: handle.replacingOccurrences(of: "desk_", with: ""),
            parent: parent,
            kind: .plan,
            status: status,
            project: "Desk 790",
            title: title ?? "Title \(handle)",
            summary: summary,
            assignee: assignee,
            laneOf: laneOf,
            progress: progress,
            openedAt: DeskClock.nowISO(now.addingTimeInterval(-3_600)),
            updatedAt: DeskClock.nowISO(now.addingTimeInterval(-secondsAgo)))
    }

    private func generated(_ secondsAgo: TimeInterval) -> String {
        DeskClock.nowISO(now.addingTimeInterval(-secondsAgo))
    }

    @Test("only now-status rows inside the 30-minute window are live")
    func thirtyMinuteCutoffAndMissingProgress() {
        let realProgress = DeskProgress(done: 2, total: 5, note: "projection wired")
        let rows = [
            item("desk_recent", secondsAgo: 60, summary: "Building the live header",
                 assignee: "codex", progress: realProgress),
            item("desk_exact", secondsAgo: 30 * 60, progress: nil),
            item("desk_old", secondsAgo: 30 * 60 + 0.01),
            item("desk_next", secondsAgo: 1, status: .next),
            item("desk_done", secondsAgo: 1, status: .done),
        ]

        let state = DeskLiveActivityPresentation.make(
            deskItems: .rows(rows), generatedTs: generated(0), now: now)
        guard case .rows(let content) = state else {
            Issue.record("expected live rows, got \(state)")
            return
        }
        #expect(content.rows.map(\.id) == ["desk_recent", "desk_exact"])
        #expect(content.rows[0].summary == "Building the live header")
        #expect(content.rows[0].assignee == "codex")
        #expect(content.rows[0].assigneeSymbol == "chevron.left.forwardslash.chevron.right")
        #expect(content.rows[0].progress == .init(done: 2, total: 5, note: "projection wired"))
        #expect(content.rows[1].progress == nil,
                "absent progress must not become a synthetic zero-percent bar")
        #expect(content.rows[1].assignee == "Unassigned")

        let quiet = DeskLiveActivityPresentation.make(
            deskItems: .rows([rows[2], rows[3], rows[4]]),
            generatedTs: generated(0),
            now: now)
        #expect(quiet == .quiet)
        #expect(DeskLiveActivityPresentation.make(
            deskItems: .rows([]), generatedTs: "", now: now) == .quiet,
                "a blank-slate Desk must render no Live Activity chrome")
    }

    @Test("live rows are newest-first, capped at four, with honest overflow")
    func orderingCapAndOverflow() {
        let rows = [
            item("desk_5", secondsAgo: 300),
            item("desk_1", secondsAgo: 60),
            item("desk_6", secondsAgo: 360),
            item("desk_3", secondsAgo: 180),
            item("desk_2", secondsAgo: 120),
            item("desk_4", secondsAgo: 240),
        ]
        guard case .rows(let content) = DeskLiveActivityPresentation.make(
            deskItems: .rows(rows), generatedTs: generated(0), now: now)
        else {
            Issue.record("expected live content")
            return
        }
        #expect(content.rows.map(\.id) == ["desk_1", "desk_2", "desk_3", "desk_4"])
        #expect(content.overflowCount == 2)
        #expect(content.rows[0].lastUpdateText == "last update just now")

        let equal = [
            item("desk_b", secondsAgo: 10),
            item("desk_a", secondsAgo: 10),
        ]
        guard case .rows(let tie) = DeskLiveActivityPresentation.make(
            deskItems: .rows(equal), generatedTs: generated(0), now: now)
        else {
            Issue.record("expected tied live content")
            return
        }
        #expect(tie.rows.map(\.id) == ["desk_a", "desk_b"],
                "equal timestamps need a stable handle tie-breaker")
    }

    @Test("unreadable, invalid-freshness, fresh, and stale states stay distinct")
    func unreadableAndStaleHonesty() {
        let unavailable = DeskLiveActivityPresentation.make(
            deskItems: .unavailable("desk bytes unreadable"),
            generatedTs: nil,
            now: now)
        #expect(unavailable == .unavailable(.init(
            title: "Live Activity unavailable", detail: "desk bytes unreadable")))

        let active = item("desk_active", secondsAgo: 60)
        let invalidTimestamp = DeskLiveActivityPresentation.make(
            deskItems: .rows([active]), generatedTs: "not-a-date", now: now)
        guard case .unavailable(let invalidNotice) = invalidTimestamp else {
            Issue.record("invalid generatedTs was presented as fresh")
            return
        }
        #expect(invalidNotice.detail.contains("generated timestamp"))

        guard case .rows(let fresh) = DeskLiveActivityPresentation.make(
            deskItems: .rows([active]), generatedTs: generated(5 * 60), now: now)
        else {
            Issue.record("expected exact-boundary content")
            return
        }
        #expect(!fresh.isStale, "staleness begins after, not at, five minutes")

        guard case .rows(let stale) = DeskLiveActivityPresentation.make(
            deskItems: .rows([active]), generatedTs: generated(5 * 60 + 1), now: now)
        else {
            Issue.record("expected stale content")
            return
        }
        #expect(stale.isStale)
        #expect(stale.asOfText == "as of 5m ago")
    }

    @Test("the next reload is one exact semantic boundary, never a cadence")
    func nextTransitionBoundary() {
        let active = item("desk_active", secondsAgo: 60)
        guard case .rows(let content) = DeskLiveActivityPresentation.make(
            deskItems: .rows([active]), generatedTs: generated(60), now: now)
        else {
            Issue.record("expected live content")
            return
        }
        let expectedStale = now.addingTimeInterval(4 * 60 + 0.001)
        #expect(abs((content.nextRefreshAt ?? .distantPast).timeIntervalSince(expectedStale)) < 0.000_1)

        guard case .rows(let alreadyStale) = DeskLiveActivityPresentation.make(
            deskItems: .rows([active]), generatedTs: generated(10 * 60), now: now)
        else {
            Issue.record("expected stale live content")
            return
        }
        let expectedExpiry = now.addingTimeInterval(29 * 60 + 0.001)
        #expect(abs((alreadyStale.nextRefreshAt ?? .distantPast).timeIntervalSince(expectedExpiry)) < 0.000_1)
    }

    @Test("laneOf builds an in-progress family without changing Desk hierarchy")
    func familyGroupingIsProjectionOnly() {
        let program = item(
            "desk_program", secondsAgo: 300, status: .watch,
            title: "Wave 2", summary: "Make the Desk visibly alive")
        let laneNow = item(
            "desk_lane_1", secondsAgo: 30, status: .now,
            title: "Live header", assignee: "codex", laneOf: program.handle,
            progress: DeskProgress(done: 2, total: 4))
        let laneDone = item(
            "desk_lane_2", secondsAgo: 120, status: .done,
            title: "Metadata", assignee: "claude", laneOf: program.handle)
        let canonicalChild = item(
            "desk_child", secondsAgo: 20, status: .next,
            title: "Real child", parent: program.handle)
        let missingParent = item(
            "desk_orphan_lane", secondsAgo: 10, laneOf: "desk_missing")
        let items = [program, canonicalChild, laneNow, laneDone, missingParent]
        let state = DeskState(items: items, generatedTs: generated(0))
        let canonicalBefore = state.children(of: program.handle)
        let boardBefore = DeskBoardLayout.groups(items, allItems: items)

        let families = DeskProgramFamilyPresentation.families(from: .rows(items))
        #expect(families.count == 1)
        guard let family = families.first else {
            Issue.record("expected one program family")
            return
        }
        #expect(family.id == program.handle)
        #expect(family.parentSummary == "Make the Desk visibly alive")
        #expect(family.lanes.map(\.id) == [laneNow.handle, laneDone.handle])
        #expect(family.lanes[0].progress == .init(done: 2, total: 4, note: nil))
        #expect(family.lanes[1].progress == nil)

        // laneOf is not a second hierarchy: the canonical child API and board
        // grouping remain byte-for-byte the same before and after projection.
        #expect(state.children(of: program.handle) == canonicalBefore)
        #expect(state.children(of: program.handle).map(\.handle) == [canonicalChild.handle])
        #expect(laneNow.parent == nil)
        #expect(DeskBoardLayout.groups(items, allItems: items) == boardBefore)
    }

    @Test("laneOf cycles and dangling references stay bounded presentation-only families")
    func laneOfCyclesAndDanglingReferencesStayBounded() {
        let selfCycle = item("desk_self_cycle", secondsAgo: 1, laneOf: "desk_self_cycle")
        let dangling = item("desk_dangling_lane", secondsAgo: 1, laneOf: "desk_missing")
        #expect(DeskProgramFamilyPresentation.families(from: .rows([selfCycle, dangling])).isEmpty)

        let twoA = item("desk_two_a", secondsAgo: 10, laneOf: "desk_two_b")
        let twoB = item("desk_two_b", secondsAgo: 10, laneOf: "desk_two_a")
        let twoFamilies = DeskProgramFamilyPresentation.families(from: .rows([twoB, twoA]))
        #expect(twoFamilies.count == 2, "a two-cycle deliberately renders two bounded families")
        #expect(twoFamilies.map(\.id) == ["desk_two_a", "desk_two_b"])
        #expect(twoFamilies[0].lanes.map(\.id) == ["desk_two_b"])
        #expect(twoFamilies[1].lanes.map(\.id) == ["desk_two_a"])

        let threeA = item("desk_three_a", secondsAgo: 20, laneOf: "desk_three_c")
        let threeB = item("desk_three_b", secondsAgo: 20, laneOf: "desk_three_a")
        let threeC = item("desk_three_c", secondsAgo: 20, laneOf: "desk_three_b")
        let threeFamilies = DeskProgramFamilyPresentation.families(
            from: .rows([threeC, threeA, threeB]))
        #expect(threeFamilies.map(\.id) == ["desk_three_a", "desk_three_b", "desk_three_c"])
        #expect(threeFamilies[0].lanes.map(\.id) == ["desk_three_b"])
        #expect(threeFamilies[1].lanes.map(\.id) == ["desk_three_c"])
        #expect(threeFamilies[2].lanes.map(\.id) == ["desk_three_a"])

        #expect(twoA.parent == nil && twoB.parent == nil)
        #expect(threeA.parent == nil && threeB.parent == nil && threeC.parent == nil)
        #expect(twoA.laneOf == "desk_two_b" && threeA.laneOf == "desk_three_c")
    }

    @Test("combined In progress honesty includes Desk program availability")
    func combinedInProgressHonesty() {
        let emptyExecutions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
        let unavailableDesk: DeskLaneState<DeskItem> = .unavailable("desk feed failed")
        #expect(DeskHonestyPresentation.inProgressLane(
            executions: emptyExecutions,
            deskItems: unavailableDesk,
            hasRenderedRows: false
        ) == .unavailable(.init(
            title: "Desk program state unavailable", detail: "desk feed failed")))

        let count = DeskExecutionInProgressCount(
            executionsLane: emptyExecutions,
            deskItemsLane: .rows([]),
            renderedBenchCount: 2,
            renderedProgramFamilyCount: 3)
        #expect(count.value == 5)
    }

    @Test("Live Activity is above Waiting on you and uses only DeskLiveReloader")
    func viewWiringUsesExistingReloaderWithoutPolling() throws {
        let view = try AppSourceScraping.appSource("DeskView.swift")
        let reloader = try AppSourceScraping.appSource("DeskLiveReloader.swift")
        let live = try #require(view.range(of: "liveActivitySection"))
        let attention = try #require(view.range(of: "attentionSection", range: live.upperBound..<view.endIndex))
        #expect(live.lowerBound < attention.lowerBound)
        #expect(view.contains("DeskLiveReloader.shared.scheduleRefresh(at:"))
        #expect(!view.contains("TimelineView"))
        #expect(!view.contains("Timer.publish"))
        #expect(reloader.contains("func scheduleRefresh(at deadline: Date?)"))
        #expect(!reloader.contains("Timer.publish"))
        #expect(!reloader.contains("scheduledTimer"))
    }
}
