// 2026-07-18 tightness-round2 U-H1 + U-L1: regression harness for the
// shared timestamp-style + truncation helpers that five view files now route
// through. The canonical regression here is the SkillLifecycleView bug: a bare
// ISO8601DateFormatter (no .withFractionalSeconds) failed to parse every
// daemon timestamp and rendered "recently". These pin fractional AND
// non-fractional inputs so the shared path can't regress to the broken one.

import Foundation
import Testing
@testable import NativeAgentApp

// A daemon timestamp WITH fractional seconds — the exact shape the old bare
// formatter choked on.
private let fractionalISO = "2020-01-02T03:04:05.245005+00:00"
// The same instant WITHOUT fractional seconds.
private let plainISO = "2020-01-02T03:04:05+00:00"

// MARK: - relativeISOTimestamp (backs SkillLifecycle friendlyTime + Memory relativeTimeString)

@Test
func relativeISOTimestamp_parsesFractionalSeconds_doesNotReturnFallback() {
    // THE SkillLifecycleView regression: fractional input must NOT fall back.
    let out = UserDisplayFormatters.relativeISOTimestamp(
        fractionalISO, unitsStyle: .short, fallback: "recently"
    )
    #expect(out != "recently")
    #expect(out.contains("ago")) // 2020 is firmly in the past
}

@Test
func relativeISOTimestamp_parsesNonFractionalSeconds() {
    let out = UserDisplayFormatters.relativeISOTimestamp(
        plainISO, unitsStyle: .abbreviated, fallback: plainISO
    )
    #expect(out != plainISO)
    #expect(out.contains("ago"))
}

@Test
func relativeISOTimestamp_returnsFallbackOnGarbage() {
    #expect(UserDisplayFormatters.relativeISOTimestamp("not-a-date", unitsStyle: .short, fallback: "recently") == "recently")
    #expect(UserDisplayFormatters.relativeISOTimestamp("", unitsStyle: .short, fallback: "recently") == "recently")
}

// MARK: - shortTime (backs DreamsView shortTimestamp)

@Test
func shortTime_parsesFractionalAndPlain_returnsRawOnGarbage() {
    // Both parse to the same instant → same rendered time-of-day string.
    let a = UserDisplayFormatters.shortTime(fractionalISO)
    let b = UserDisplayFormatters.shortTime(plainISO)
    #expect(a != fractionalISO) // parsed, not echoed raw
    #expect(a == b)
    // Garbage echoes the raw input (never drops the field).
    #expect(UserDisplayFormatters.shortTime("garbage") == "garbage")
}

// MARK: - mediumDateTime (backs MemoryView localTimestamp)

@Test
func mediumDateTime_parsesFractionalAndPlain_returnsRawOnGarbage() {
    let a = UserDisplayFormatters.mediumDateTime(fractionalISO)
    let b = UserDisplayFormatters.mediumDateTime(plainISO)
    #expect(a != fractionalISO)
    #expect(a == b)
    #expect(UserDisplayFormatters.mediumDateTime("garbage") == "garbage")
}

// MARK: - String.truncated (backs the 5 chat/observatory truncation sites)

@Test
func truncated_shorterThanOrEqualToLimit_returnedWhole() {
    #expect("abc".truncated(to: 5) == "abc")
    // Exactly `limit` chars is NOT truncated — matches the `> limit` guard.
    #expect("abcde".truncated(to: 5) == "abcde")
}

@Test
func truncated_longerThanLimit_appendsSuffix() {
    #expect("abcdef".truncated(to: 5) == "abcde…")
    // Custom suffix (the 8000-char JSON sites use a multi-char one).
    #expect("abcdef".truncated(to: 3, suffix: "\n…[truncated]") == "abc\n…[truncated]")
}

@Test
func truncated_keepingDecouplesTriggerFromRetainedPrefix() {
    // The 80/77 sites: trip at >80 but keep only 77. A 78-char string is
    // NOT over the 80 threshold, so it must be returned whole.
    let s78 = String(repeating: "x", count: 78)
    #expect(s78.truncated(to: 80, keeping: 77) == s78)
    // An 81-char string trips and keeps 77 + ellipsis.
    let s81 = String(repeating: "x", count: 81)
    let out = s81.truncated(to: 80, keeping: 77)
    #expect(out == String(repeating: "x", count: 77) + "…")
    #expect(out.count == 78)
}
