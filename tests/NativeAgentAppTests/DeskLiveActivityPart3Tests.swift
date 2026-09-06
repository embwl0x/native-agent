import Foundation
import Testing
@testable import NativeAgentApp
@testable import PersistenceCore
import WorkshopExecution

@Suite("Desk Live Activity Part 3")
struct DeskLiveActivityPart3Tests {
    private let now = Date(timeIntervalSince1970: 1_777_000_000)

    @Test("relative timestamps share sane deterministic boundaries and never echo raw ISO")
    func relativeTimestampBoundaries() {
        let cases: [(TimeInterval, String)] = [
            (-60, "just now"),
            (0, "just now"),
            (89.999, "just now"),
            (90, "1m ago"),
            (3_599.999, "59m ago"),
            (3_600, "1h ago"),
            (86_399.999, "23h ago"),
            (86_400, "1d ago"),
        ]
        for (secondsAgo, expected) in cases {
            #expect(DeskRelativeTimePresentation.text(
                for: now.addingTimeInterval(-secondsAgo), now: now) == expected)
        }

        let raw = "2026-08-27T12:34:56.123456+00:00"
        let rendered = DeskRelativeTimePresentation.text(forISO: raw, now: now)
        #expect(rendered != raw)
        #expect(!rendered.contains("T12:34:56"))
        #expect(DeskRelativeTimePresentation.text(forISO: "not-a-date", now: now) == "unknown")
    }

    @Test("every scoped Desk row routes timestamp fields through relative presentation")
    func noRawISORendersOnScopedRows() throws {
        let source = try AppSourceScraping.appSource("DeskView.swift")
        #expect(rawTimestampTextLeaks(in: source).isEmpty)

        // Negative control: the guard must detect the exact regression it
        // claims to prevent rather than passing because the pattern is inert.
        let deliberatelyLeaking = source + "\nText(item.updatedAt)\nText(exec.createdAt)"
        #expect(rawTimestampTextLeaks(in: deliberatelyLeaking) == [
            "Text(item.updatedAt)", "Text(exec.createdAt)",
        ])

        #expect(source.contains("Text(relativeTime(item.motorUpdatedAt ?? item.updatedAt))"))
        #expect(source.contains("Text(relativeTime(exec.updatedAt))"))
        #expect(source.contains("Text(\"worked \\(relativeTime(last))\")"))
        #expect(source.contains("DeskItemPresentation.freshness(for: item, now: deskPresentationNow)"))
    }

    @Test("one semantic status vocabulary is reused across every Desk row family")
    func canonicalStatusTonesAreReused() throws {
        #expect(DeskStatusTonePresentation.tone(for: .now) == .info)
        #expect(DeskExecutionPresentation.pill(for: "running").tone == .info)
        #expect(DeskGitHubStatePillPresentation.pill(for: githubItem(
            id: "working", state: .codexWorking)).tone == .info)

        #expect(DeskStatusTonePresentation.tone(for: .blocked) == .danger)
        #expect(DeskExecutionPresentation.pill(for: "failed").tone == .danger)
        #expect(DeskGitHubStatePillPresentation.pill(for: githubItem(
            id: "attention", state: .attention(.dispatchFailed))).tone == .danger)

        #expect(DeskStatusTonePresentation.tone(for: .done) == .success)
        #expect(DeskExecutionPresentation.pill(for: "completed").tone == .success)
        #expect(DeskGitHubStatePillPresentation.pill(for: githubItem(
            id: "resolved", state: .resolved)).tone == .success)

        let view = try AppSourceScraping.appSource("DeskView.swift")
        #expect(AppSourceScraping.occurrences(
            of: "private func statusColor(_ tone: DeskPresentationTone)", in: view) == 1)
        #expect(!view.contains("ghStatePillColor"))
        #expect(view.contains(".fill(statusColor(DeskStatusTonePresentation.tone(for: lane.status)))"))
        #expect(AppSourceScraping.occurrences(
            of: ".capsuleTag(statusColor(pill.tone))", in: view) == 2)
    }

    @Test("header counts follow eligible rows and quiet sections keep calm titles")
    func eligibleCountsAndQuietHeaders() throws {
        #expect(DeskSectionHeaderPresentation.label("In progress", count: 3) == "In progress · 3")
        #expect(DeskSectionHeaderPresentation.label("In progress", count: 0) == "In progress")
        #expect(DeskSectionHeaderPresentation.label("Agent pursuits", count: nil) == "Agent pursuits")

        let active = (1...6).map { index in
            deskItem(id: "active-\(index)", secondsAgo: TimeInterval(index))
        }
        guard case .rows(let live) = DeskLiveActivityPresentation.make(
            deskItems: .rows(active),
            generatedTs: DeskClock.nowISO(now),
            now: now)
        else {
            Issue.record("expected live rows")
            return
        }
        #expect(live.rows.count == DeskLiveActivityPresentation.visibleRowCap)
        #expect(live.overflowCount == 2)
        #expect(live.eligibleRowCount == 6)
        #expect(DeskSectionHeaderPresentation.label(
            "Live Activity", count: live.eligibleRowCount) == "Live Activity · 6")

        let resolved = (1...7).map { index in
            githubItem(id: "resolved-\(index)", state: .resolved, number: index)
        }
        let eligible = resolved + [githubItem(id: "needs-user", state: .needsUser, number: 99)]
        #expect(DeskGitHubPortfolioStrip.headerCount(items: eligible) == 6,
                "seven historical resolutions contribute the five rendered rows, not a hidden total")
        #expect(DeskGitHubPortfolioStrip.headerCount(items: []) == nil,
                "an empty watcher remains calm instead of advertising zero")

        let view = try AppSourceScraping.appSource("DeskView.swift")
        #expect(view.contains("\"Live Activity\", count: content.eligibleRowCount"))
        #expect(view.contains("count: DeskGitHubPortfolioStrip.headerCount(items: githubItems)"))
        #expect(view.contains("Text(DeskSectionHeaderPresentation.label(title, count: count))"))
    }

    @Test("Part 3 header and row presentation adds no write affordance")
    func presentationStaysReadOnly() throws {
        let view = try AppSourceScraping.appSource("DeskView.swift")
        let presentation = try AppSourceScraping.appSource("DeskPresentation.swift")
        let scoped = [
            sourceSlice(view, from: "private var liveActivitySection", to: "private func liveActivityRow"),
            sourceSlice(view, from: "private func sectionHeader", to: "private func laneUnavailableNotice"),
            sourceSlice(view, from: "private func programLaneRow", to: "private func executionRow"),
        ].joined(separator: "\n")

        #expect(scoped.count > 300, "the source guard must cover the intended render seams")
        #expect(writeAffordanceLeaks(in: scoped).isEmpty)
        // 2026-09-06: scrape the EXECUTABLE source, not the comments.
        // 7df7a4cd ("Fable 5.1 sweep wave 2 ... desk veto controls") moved the
        // owner's Veto off the Diagnostics observatory and onto the Desk row,
        // and the DeskPursuitVetoControl doc comment names where the mutation
        // still lives ("WorkshopObservatoryVetoHandler → SwiftNativeDeskStore
        // .vetoPursuit", DeskPresentation.swift:627). That is a POINTER to the
        // store, not a dependency on it; a raw substring check read the prose
        // as a leak. The pin is unchanged and still the real one: the
        // presentation layer holds no store reference in code.
        #expect(!executableSource(presentation).contains("SwiftNativeDeskStore"))

        // Negative control for the scoped detector.
        #expect(writeAffordanceLeaks(in: scoped + "\nButton(\"Set status\") {}") == ["Button("])
    }

    private func deskItem(id: String, secondsAgo: TimeInterval) -> DeskItem {
        DeskItem(
            handle: id,
            alias: id,
            kind: .plan,
            status: .now,
            project: "Desk 790",
            title: id,
            openedAt: DeskClock.nowISO(now.addingTimeInterval(-3_600)),
            updatedAt: DeskClock.nowISO(now.addingTimeInterval(-secondsAgo)))
    }

    private func githubItem(
        id: String,
        state: GitHubCommandItemState,
        number: Int = 1
    ) -> GitHubCommandItem {
        GitHubCommandItem(
            itemId: id,
            repository: "nativeagent/desktop",
            number: number,
            kind: .pullRequest,
            title: id,
            state: state,
            observation: nil,
            dispatchIntent: nil,
            dispatchReceipt: nil,
            workLog: [],
            blocker: nil,
            finalReceipt: nil,
            lastCallbackStatus: nil,
            lastSettledEventKey: nil,
            notificationClaims: [],
            notificationReceipts: [],
            verificationReadFailures: nil,
            createdAt: "2026-08-27T12:00:00Z",
            updatedAt: "2026-08-27T12:00:00Z")
    }

    private func rawTimestampTextLeaks(in source: String) -> [String] {
        let timestampFields = [
            "item.updatedAt", "item.createdAt", "item.openedAt", "item.motorUpdatedAt",
            "exec.updatedAt", "exec.createdAt", "pursuit.lastWorkedAt", "deskGeneratedTs",
        ]
        return source.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("Text("),
                  timestampFields.contains(where: line.contains),
                  !line.contains("relativeTime(")
            else { return nil }
            return line
        }
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) -> String {
        guard let lower = source.range(of: start),
              let upper = source.range(of: end, range: lower.upperBound..<source.endIndex)
        else { return "" }
        return String(source[lower.lowerBound..<upper.lowerBound])
    }

    /// 2026-09-06: the source with whole-line `//` and `///` comments removed,
    /// so a scrape can tell a symbol a file USES from one it merely names in
    /// prose.
    private func executableSource(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
    }

    private func writeAffordanceLeaks(in source: String) -> [String] {
        ["Button(", ".onTapGesture", "perform(", "SwiftNativeDeskStore"]
            .filter { source.contains($0) }
    }
}
