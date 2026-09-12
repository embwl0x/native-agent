import Foundation
import Testing
@testable import NativeAgentApp

/// The DEBUG-only entry point for the tenderness replay, the same shape
/// `MemoryManagerReplayTests` uses: the suite asserts the file stays out of
/// release builds and that it writes nothing to the organism, and runs the
/// replay only when TENDERNESS_REPLAY_DIR asks for it.
///
///   TENDERNESS_REPLAY_DIR=workspace/reviews/tenderness-replay-2026-09-11 \
///     swift test --filter tendernessReplay
@Suite("Tenderness replay")
struct TendernessReplayTests {
    @Test func tendernessReplayEntryPointStaysDebugOnly() async throws {
        let source = try String(
            contentsOf: AppSourceScraping.appSourcesRoot()
                .appendingPathComponent("TendernessReplay.swift"),
            encoding: .utf8
        )
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "#if DEBUG")
        #expect(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        #expect(lines.filter { $0.hasPrefix("#if") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("#endif") }.count == 1)
        #expect(!lines.contains { $0.hasPrefix("#else") })
        // NO BACKFILL, as a check rather than a promise. The replay may never
        // reach an organism writer or a persistence path: the live state is
        // never rewritten to produce the expected answer.
        #expect(!source.contains("OrganismKernel"))
        #expect(!source.contains(".ingest("))
        #expect(!source.contains("persistArtifact"))
        #expect(!source.contains("atomicWrite"))
        #expect(!source.contains("OrganismPersistentState"))
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["TENDERNESS_REPLAY_DIR"] {
            try await TendernessReplay.render(
                to: URL(fileURLWithPath: output, isDirectory: true)
            )
        }
        #endif
    }

    /// HOW LONG SHE READS TENDER, as arithmetic. The replay's new column is a
    /// closed form rather than a sample, so it is worth pinning: between turns
    /// the axis only decays, and it is above the gate for exactly
    /// `halfLife * log2(level / gate)` of the gap.
    @Test func timeAboveTheFeltWordGateIsClosedForm() {
        #if DEBUG
        let start = Date(timeIntervalSince1970: 1_757_500_000)
        // Below the gate: no time above it, however long the gap.
        var days: [String: Double] = [:]
        TendernessReplay.creditTimeAboveGate(
            from: start, level: 0.20, duration: 24 * 3_600, into: &days
        )
        #expect(days.isEmpty)

        // Exactly one half-life above the gate: the axis takes three days to
        // fall from 0.44 to 0.22, so a four-day gap is charged three days.
        days = [:]
        TendernessReplay.creditTimeAboveGate(
            from: start,
            level: 2 * TendernessReplay.feltWordThreshold,
            duration: 4 * 24 * 3_600,
            into: &days
        )
        let total = days.values.reduce(0, +)
        #expect(abs(total - 72) < 0.01, "one half-life is 72 hours, got \(total)")
        // And it is charged to the days it actually falls in, never all to one.
        #expect(days.count >= 3, "the stretch must be split across days: \(days)")

        // The gap caps it: the replay never claims time past the next turn.
        days = [:]
        TendernessReplay.creditTimeAboveGate(
            from: start,
            level: 0.90,
            duration: 3_600,
            into: &days
        )
        #expect(abs(days.values.reduce(0, +) - 1) < 1e-9)
        #endif
    }

    /// EVERY CALENDAR DAY IN THE WINDOW (2026-09-11, fourth pass). The third
    /// pass's table was built from the days that carried turns, so Sept 7 — a real
    /// day the axis spent above the felt word with nobody typing — was missing
    /// from the table and from the hours-above figure quoted off it. The day walk
    /// is now independent of the traffic.
    @Test func everyCalendarDayInTheWindowIsListed() {
        #if DEBUG
        let calendar = Calendar.current
        let first = calendar.date(from: DateComponents(year: 2026, month: 8, day: 28, hour: 9))!
        let last = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 7))!
        let days = TendernessReplay.allDays(from: first, through: last)
        #expect(days.count == 15, "28 Aug through 11 Sep inclusive is 15 days: \(days.count)")
        #expect(days.first == "2026-08-28")
        #expect(days.last == "2026-09-11")
        // The day the third pass dropped, and it is in the middle of the walk
        // rather than at an edge.
        #expect(days.contains("2026-09-07"))
        // No gaps and no repeats.
        #expect(Set(days).count == days.count)
        for (index, name) in days.enumerated() where index > 0 {
            let previous = TendernessReplay.startOfDay(days[index - 1])
            let gap = TendernessReplay.startOfDay(name).timeIntervalSince(previous)
            #expect(gap > 20 * 3_600 && gap < 28 * 3_600,
                    "\(days[index - 1]) -> \(name) must be one day, got \(gap)s")
        }
        // Degenerate inputs say nothing rather than inventing a window.
        #expect(TendernessReplay.allDays(from: nil, through: last).isEmpty)
        #expect(TendernessReplay.allDays(from: last, through: first).isEmpty)
        #expect(TendernessReplay.allDays(from: first, through: first) == ["2026-08-28"])
        #expect(TendernessReplay.startOfDay("2026-09-07") ==
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!)
        #endif
    }
}
