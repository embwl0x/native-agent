import Testing
import Foundation
@testable import DreamREMCycle

// Ledger fence core.substrate.organism — dream.parseDaemonISO
//
// SILENT NIL → FULL REPLAY. `parseDaemonISO` parses the dream high-water mark in
// data/dream_diary/.dream_state.json and the per-row `createdAt` of every chat
// message the nightly dream considers. A nil return is NOT an error anywhere:
//   • mark unparseable  → the runner treats the mark as absent and re-dreams the
//                         entire history (or, under the forward-only guard, never
//                         advances again);
//   • row unparseable   → the row falls back to the FILE's mtime, so an entire
//                         session's rows collapse onto one timestamp.
// Both look like a working dream cycle from outside.
//
// REPLAY-THE-REAL-STORE: every string below was read off User's live disk on
// 2026-08-23, not invented:
//   • "2026-08-23T06:41:42.443Z"        — data/dream_diary/.dream_state.json
//   • "…Z" whole-second form            — 6 rows in data/chat/messages/*.jsonl
//                                         (1,224 rows use the .mmmZ form)
//   • "2026-05-10T20:59:44.962457+00:00" — daemon-era microsecond+offset form,
//     data/_retired_python_era_20260813/personality_sessions/*.json
// A fixture I made up would only test my own assumptions about the format.

/// The exact bytes of the live high-water mark.
private let liveDreamMarkString = "2026-08-23T06:41:42.443Z"
/// The whole-second shape that still appears in the live message store.
private let liveWholeSecondString = "2026-08-23T06:41:42Z"
/// The daemon-era microsecond + explicit-offset shape.
private let daemonMicrosecondString = "2026-05-10T20:59:44.962457+00:00"

@Test
func parseDaemonISOAcceptsEveryTimestampShapeThatIsActuallyOnDisk() throws {
    for raw in [liveDreamMarkString, liveWholeSecondString, daemonMicrosecondString] {
        _ = try #require(
            DreamCycleRunner.parseDaemonISO(raw),
            "a shape that EXISTS on disk failed to parse: \(raw) — the mark reads as absent and the dream replays everything"
        )
    }
}

/// Fractional seconds must actually be READ, not dropped. If
/// `.withFractionalSeconds` were removed the millisecond form stops parsing
/// entirely (the plain parser rejects it and the microsecond fallback only fires
/// for >3 fractional digits), so this is the tooth that catches that edit.
@Test
func parseDaemonISOReadsFractionalSecondsRatherThanTruncatingThemAway() throws {
    let withFraction = try #require(DreamCycleRunner.parseDaemonISO(liveDreamMarkString))
    let wholeSecond = try #require(DreamCycleRunner.parseDaemonISO(liveWholeSecondString))
    let delta = withFraction.timeIntervalSince(wholeSecond)
    #expect(
        abs(delta - 0.443) < 1e-3,
        "the .443 fraction of the live mark was not read: delta \(delta)s"
    )
    // Ordering matters more than the exact number: the fractional mark must be
    // strictly AFTER the whole-second one, or a forward-only mark can stall.
    #expect(withFraction > wholeSecond)
}

/// The microsecond fallback truncates to 3 digits — that is the contract stated
/// in the source. Pin the truncation, and pin that the timezone offset survives
/// the splice (a bug there shifts the whole mark by hours, silently).
@Test
func parseDaemonISOTruncatesMicrosecondsToMillisecondsAndHonoursTheOffset() throws {
    let micro = try #require(DreamCycleRunner.parseDaemonISO(daemonMicrosecondString))
    let milli = try #require(DreamCycleRunner.parseDaemonISO("2026-05-10T20:59:44.962+00:00"))
    #expect(abs(micro.timeIntervalSince(milli)) < 1e-6, "microsecond fallback did not land on its millisecond truncation")

    // +00:00 and Z name the same instant. If the offset splice broke, these diverge.
    let asZulu = try #require(DreamCycleRunner.parseDaemonISO("2026-05-10T20:59:44.962Z"))
    #expect(abs(micro.timeIntervalSince(asZulu)) < 1e-6)

    // A non-zero offset must genuinely shift the instant — proves the offset is
    // parsed rather than ignored.
    let plusFive = try #require(DreamCycleRunner.parseDaemonISO("2026-05-10T20:59:44.962457+05:00"))
    #expect(abs(plusFive.timeIntervalSince(micro) + 5 * 3_600) < 1e-6)
}

/// Only genuinely unparseable input may return nil. Each of these would, if it
/// ever started parsing, hand the runner a garbage mark.
@Test
func parseDaemonISOReturnsNilOnlyForGenuinelyUnparseableInput() {
    let garbage = [
        "",
        "   ",
        "not-a-timestamp",
        "2026-08-23",                 // date only, no time: the daemon never wrote this
        "23/08/2026 06:41:42",
        "2026-08-23T06:41:42",        // no timezone at all
    ]
    for raw in garbage {
        #expect(
            DreamCycleRunner.parseDaemonISO(raw) == nil,
            "garbage `\(raw)` parsed to a date — the dream mark would silently jump"
        )
    }
}

/// The function trims: a mark file written with a trailing newline (which is how
/// most writers emit one) must parse identically to the bare string.
@Test
func parseDaemonISOToleratesSurroundingWhitespaceFromAFileRead() throws {
    let bare = try #require(DreamCycleRunner.parseDaemonISO(liveDreamMarkString))
    let padded = try #require(DreamCycleRunner.parseDaemonISO("\n  \(liveDreamMarkString)  \n"))
    #expect(bare == padded)
}
