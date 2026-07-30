import Foundation
import PersistenceCore
import Testing

@testable import NativeAgentApp

/// M12 honesty chip: the Observatory fallback chip must count ContextFlow
/// per-turn fallbacks from the REAL persisted turn traces, and a read failure
/// must never look like a healthy zero. Window semantics are DISTINCT TURNS
/// (last summary per turnId wins) and the denominator is ACTIVE-mode turns
/// only (gpt-5.5 review, 2026-07-10).
@Suite
struct ContextFlowFallbackReaderTests {
    /// Build a `context.summary` turn-trace event with the contextFlow
    /// flags/labels the turn engine writes. `active` mirrors the engine:
    /// enabled+non-shadow unless overridden; a fallback event carries the
    /// fallback flag (the engine only sets it on the active branch).
    private func summaryEvent(
        turnId: String,
        fallback: Bool,
        fallbackError: String? = nil,
        active: Bool = true,
        shadow: Bool = false,
        ts: Date = Date()
    ) -> TurnTraceEvent {
        var flags: [String: JSONValue] = [:]
        if fallback { flags["contextFlow.fallback"] = .bool(true) }
        if active { flags["contextFlow.enabled"] = .bool(true) }
        if shadow {
            flags["contextFlow.enabled"] = .bool(true)
            flags["contextFlow.shadow"] = .bool(true)
        }
        var labels: [String: JSONValue] = [:]
        if let fallbackError {
            labels["contextFlow.fallbackError"] = .string(fallbackError)
        }
        return TurnTraceEvent(
            turnId: turnId,
            ts: ts,
            kind: "context.summary",
            payload: .object([
                "flags": .object(flags),
                "labels": .object(labels),
            ])
        )
    }

    @Test
    func zeroFallbacksProducesNoNotice() {
        let events = [
            summaryEvent(turnId: "t1", fallback: false),
            summaryEvent(turnId: "t2", fallback: false),
            // A non-summary event must be ignored entirely.
            TurnTraceEvent(turnId: "t2", kind: "llm.call", payload: .object([:])),
        ]
        let summary = ContextFlowFallbackReader.summarize(events: events)
        #expect(summary.observedTurns == 2)
        #expect(summary.shadowTurns == 0)
        #expect(summary.windowTurns == 2)
        #expect(summary.fallbackCount == 0)
        #expect(summary.latestError == nil)
    }

    @Test
    func twoFallbacksCountAndSurfaceLatestError() {
        let events = [
            summaryEvent(turnId: "t1", fallback: true, fallbackError: "first error"),
            summaryEvent(turnId: "t2", fallback: false),
            summaryEvent(turnId: "t3", fallback: true, fallbackError: "latest error"),
        ]
        let summary = ContextFlowFallbackReader.summarize(events: events)
        #expect(summary.windowTurns == 3)
        #expect(summary.fallbackCount == 2)
        // Latest-wins: newest-last, so the most recent fallback's error surfaces.
        #expect(summary.latestError == "latest error")
    }

    @Test
    func fallbackWithoutErrorLabelStillCounts() {
        let events = [
            summaryEvent(turnId: "t1", fallback: true, fallbackError: nil),
        ]
        let summary = ContextFlowFallbackReader.summarize(events: events)
        #expect(summary.fallbackCount == 1)
        #expect(summary.latestError == nil)
    }

    /// One user turn can emit SEVERAL context.summary events (a rebuild per
    /// tool-loop iteration). They must collapse to one turn — last summary
    /// wins — so a single turn can neither eat window slots nor multi-count
    /// its fallback (gpt-5.5 HIGH, 2026-07-10).
    @Test
    func multipleSummariesForOneTurnCollapseToItsLatest() {
        let events = [
            summaryEvent(turnId: "t1", fallback: true, fallbackError: "early rebuild fell back"),
            summaryEvent(turnId: "t1", fallback: true, fallbackError: "second rebuild fell back"),
            summaryEvent(turnId: "t1", fallback: false),   // final rebuild recovered
            summaryEvent(turnId: "t2", fallback: false),
        ]
        let summary = ContextFlowFallbackReader.summarize(events: events)
        #expect(summary.windowTurns == 2, "3 summaries for t1 are ONE turn")
        #expect(summary.fallbackCount == 0, "t1's LAST summary is clean — no multi-count")
    }

    /// turnId "unknown"/empty can't be correlated — each event stays its own
    /// pseudo-turn instead of collapsing unrelated turns into one.
    @Test
    func unknownTurnIdsDoNotCollapseTogether() {
        let events = [
            summaryEvent(turnId: "unknown", fallback: true, fallbackError: "a"),
            summaryEvent(turnId: "unknown", fallback: true, fallbackError: "b"),
        ]
        let summary = ContextFlowFallbackReader.summarize(events: events)
        #expect(summary.windowTurns == 2)
        #expect(summary.fallbackCount == 2)
        #expect(summary.latestError == "b")
    }

    /// Shadow/off summaries are observed but cannot vouch for clean active
    /// circulation: a shadow-only window reports zero ACTIVE turns, which the
    /// UI renders as the neutral no-turns state, not green (gpt-5.5 LOW).
    @Test
    func shadowOnlyWindowIsNotCirculatingCleanly() {
        let events = [
            summaryEvent(turnId: "s1", fallback: false, active: false, shadow: true),
            summaryEvent(turnId: "s2", fallback: false, active: false, shadow: true),
            summaryEvent(turnId: "off1", fallback: false, active: false),
        ]
        let summary = ContextFlowFallbackReader.summarize(events: events)
        #expect(summary.windowTurns == 0, "no ACTIVE turns → neutral, not green")
        #expect(summary.observedTurns == 3)
        #expect(summary.shadowTurns == 2, "shadow turns remain visible as observed work")
        #expect(summary.fallbackCount == 0)
    }

    @Test
    func windowKeepsOnlyMostRecentTurns() {
        // 60 distinct clean turns then 1 fallback — the fallback is inside the
        // 50-turn window; the window is DISTINCT turns, not raw events.
        var events: [TurnTraceEvent] = (0..<60).map {
            summaryEvent(turnId: "clean\($0)", fallback: false)
        }
        events.append(summaryEvent(turnId: "fell", fallback: true, fallbackError: "boom"))
        let summary = ContextFlowFallbackReader.summarize(
            events: events,
            window: ContextFlowFallbackReader.windowLimit
        )
        #expect(summary.windowTurns == ContextFlowFallbackReader.windowLimit)
        #expect(summary.observedTurns == ContextFlowFallbackReader.windowLimit)
        #expect(summary.fallbackCount == 1)
        #expect(summary.latestError == "boom")
    }

    @Test
    func longErrorIsBounded() {
        let long = String(repeating: "x", count: 5_000)
        let events = [summaryEvent(turnId: "t1", fallback: true, fallbackError: long)]
        let summary = ContextFlowFallbackReader.summarize(events: events)
        #expect(summary.latestError?.count == ContextFlowFallbackReader.maxErrorChars)
    }

    @Test
    func missingFileIsHonestEmptyNotUnavailable() async throws {
        // A data root with no turn_traces file at all — an honest "no turns
        // observed", NOT an error.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-fallback-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reader = TurnTraceRecentReader(dataRootOverride: tmp)
        let state = await ContextFlowFallbackReader.load(reader: reader)
        guard case .summary(let summary) = state else {
            Issue.record("expected .summary for a missing file, got \(state)")
            return
        }
        #expect(summary.windowTurns == 0)
        #expect(summary.fallbackCount == 0)
    }

    /// The ledger is day-keyed; the chip reads yesterday + today so a 23:59
    /// fallback survives midnight instead of vanishing into a fresh file
    /// (gpt-5.5 HIGH, 2026-07-10).
    @Test
    func yesterdaysFallbackSurvivesMidnight() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-fallback-midnight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)

        // Write one fallback summary into YESTERDAY's day file via the real
        // lane — the lane keys the day file off the event's own timestamp.
        let lane = TurnTracePersistLane(dataRootOverride: tmp)
        await lane.append(
            summaryEvent(
                turnId: "late-night", fallback: true,
                fallbackError: "23:59 fallback", ts: yesterday
            )
        )

        let reader = TurnTraceRecentReader(dataRootOverride: tmp)
        let state = await ContextFlowFallbackReader.load(reader: reader, now: now)
        guard case .summary(let summary) = state else {
            Issue.record("expected .summary, got \(state)")
            return
        }
        #expect(summary.fallbackCount == 1, "yesterday's fallback must not vanish at midnight")
        #expect(summary.latestError == "23:59 fallback")
    }

    @Test
    func unreadableStoreRendersUnavailableNotZero() async throws {
        // Force the reader's directory-at-path failure: create the day file
        // path AS A DIRECTORY so `read` throws instead of returning events.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-fallback-bad-\(UUID().uuidString)", isDirectory: true)
        let now = Date()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayFilePath = tmp
            .appendingPathComponent("turn_traces", isDirectory: true)
            .appendingPathComponent("\(dayFormatter.string(from: now)).jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: dayFilePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reader = TurnTraceRecentReader(dataRootOverride: tmp)
        let state = await ContextFlowFallbackReader.load(reader: reader, now: now)
        guard case .unavailable = state else {
            Issue.record("expected .unavailable for an unreadable store, got \(state)")
            return
        }
    }
}
