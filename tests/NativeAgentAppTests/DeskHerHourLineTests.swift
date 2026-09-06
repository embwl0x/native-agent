import Testing
import Foundation
@testable import NativeAgentApp
import BackgroundLoops
import PersistenceCore

// HER HOUR ON THE DESK — personality-depth item 9, the visible half.
//
// The Desk's claim about her hour is one line and two promises: it says what she
// actually did (her own words, newest entry), and it is ABSENT when the lane is
// not installed. Nothing here renders a count, a badge, or an action, because
// the lane writes no desk ops and her aesthetic life is not board work.

private let deskNow = Date(timeIntervalSince1970: 1_756_000_000)

private func traceEntry(
    outcome: StudioWanderLane.Outcome,
    line: String,
    minutesAgo: Double
) -> StudioWanderLane.TraceEntry {
    StudioWanderLane.TraceEntry(
        at: StudioClock.nowISO(deskNow.addingTimeInterval(-minutesAgo * 60)),
        outcome: outcome,
        line: line
    )
}

// MARK: - Absent when the lane is not installed

/// The kill switch reaches the Desk. Off means the line does not exist — not
/// "Her hour: disabled", not an empty row, not a zero.
@Test func deskHerHour_isAbsentWhenTheLaneIsNotInstalled() {
    #expect(
        DeskHerHourPresentation.state(
            installed: false,
            entry: traceEntry(outcome: .chose, line: "Sat with the Meuser house.", minutesAgo: 30),
            now: deskNow
        ) == .absent
    )
}

@Test func deskHerHour_isAbsentBeforeSheHasEverHadOne() {
    #expect(
        DeskHerHourPresentation.state(installed: true, entry: nil, now: deskNow) == .absent
    )
}

/// A trace row whose line is blank is not a fact worth a row of chrome either.
@Test func deskHerHour_isAbsentWhenSheSaidNothing() {
    #expect(
        DeskHerHourPresentation.state(
            installed: true,
            entry: traceEntry(outcome: .declined, line: "   ", minutesAgo: 5),
            now: deskNow
        ) == .absent
    )
}

// MARK: - Renders the last line, in her words

@Test func deskHerHour_rendersHerOwnClosingLineWithHowLongAgo() {
    let state = DeskHerHourPresentation.state(
        installed: true,
        entry: traceEntry(
            outcome: .chose,
            line: "Spent it on the Meuser house photographs. The stair still bothers me.",
            minutesAgo: 45
        ),
        now: deskNow
    )
    guard case .line(let text, let symbol) = state else {
        Issue.record("an installed lane with a trace entry must render a line")
        return
    }
    // Her words, verbatim — the Desk never paraphrases her.
    #expect(text.hasPrefix("Spent it on the Meuser house photographs."))
    #expect(text.hasSuffix("45m ago"))
    #expect(symbol == "eye")
    // No verdict, no score, no progress, no task vocabulary.
    for banned in ["%", "todo", "due", "overdue", "streak", "chose", "declined"] {
        #expect(!text.lowercased().contains(banned))
    }
}

/// A DECLINE IS NOT A LESSER OUTCOME. It renders exactly like a choice — same
/// weight, same shape, no "nothing happened" phrasing supplied by us.
@Test func deskHerHour_rendersADeclineWithEqualStanding() {
    let state = DeskHerHourPresentation.state(
        installed: true,
        entry: traceEntry(outcome: .declined, line: "Didn't feel like looking at anything.", minutesAgo: 200),
        now: deskNow
    )
    guard case .line(let text, let symbol) = state else {
        Issue.record("a decline is still an hour she spent")
        return
    }
    #expect(text == "Didn't feel like looking at anything. · 3h ago")
    #expect(symbol == "moon.zzz")
}

@Test func deskHerHour_marksAnUnobtainableArtifactDistinctly() {
    #expect(DeskHerHourPresentation.symbol(.noArtifact) == "eye.slash")
    #expect(DeskHerHourPresentation.symbol(.chose) == "eye")
    #expect(DeskHerHourPresentation.symbol(.declined) == "moon.zzz")
}

@Test func deskHerHour_boundsALongLineRatherThanLettingItTakeTheBoard() {
    let long = String(repeating: "the stair still bothers me ", count: 20)
    let state = DeskHerHourPresentation.state(
        installed: true,
        entry: traceEntry(outcome: .chose, line: long, minutesAgo: 1),
        now: deskNow
    )
    guard case .line(let text, _) = state else {
        Issue.record("expected a line")
        return
    }
    #expect(text.contains("…"))
    // Bounded body plus the relative-time suffix; never the raw 540 characters.
    #expect(text.count < DeskHerHourPresentation.maximumCharacters + 20)
}

// MARK: - It is the NEWEST entry, read from the lane's own file

/// The Desk shows the last hour, not the first. `recordEndedHour` appends, so
/// `trace.last` is what the line must be built from.
@Test func deskHerHour_showsTheNewestEntryFromTheLanesOwnState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("desk-her-hour-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await StudioWanderLane.recordEndedHour(
        dataRoot: root,
        entry: traceEntry(outcome: .chose, line: "An older hour.", minutesAgo: 3000),
        at: deskNow.addingTimeInterval(-3000 * 60)
    )
    try await StudioWanderLane.recordEndedHour(
        dataRoot: root,
        entry: traceEntry(outcome: .noArtifact, line: "Went for it; couldn't get the work.", minutesAgo: 10),
        at: deskNow.addingTimeInterval(-600)
    )

    let loaded = try await StudioWanderLane.loadState(dataRoot: root)
    let state = DeskHerHourPresentation.state(
        installed: true,
        entry: loaded.trace.last,
        now: deskNow
    )
    guard case .line(let text, let symbol) = state else {
        Issue.record("expected the newest hour to render")
        return
    }
    #expect(text.hasPrefix("Went for it; couldn't get the work."))
    #expect(symbol == "eye.slash")
}
