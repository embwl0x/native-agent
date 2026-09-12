import Testing
import Foundation
@testable import PersistenceCore
import NativeAgentCore

@Suite("Abandoned turn terminal reconciliation")
struct AbandonedTurnReconcilerTests {
    private func tmpRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("abandoned-turns-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ rows: [JSONValue], day: Date, lane: TurnTracePersistLane) throws {
        let path = lane.path(for: day)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let lines = try rows.map {
            String(decoding: try $0.serializedData(pretty: false), as: UTF8.self)
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: path, atomically: true, encoding: .utf8)
    }

    private func row(kind: String, turnId: String, ts: String) -> JSONValue {
        .object([
            "id": .string(UUID().uuidString),
            "kind": .string(kind),
            "turnId": .string(turnId),
            "ts": .string(ts),
            "sessionId": .string("S1"),
            "surface": .string("chat"),
            "payload": .object([:]),
        ])
    }

    @Test("an accepted turn past the wall-clock ceiling gets one abandoned terminal row")
    func writesAbandonedTerminal() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let reconciler = AbandonedTurnReconciler(lane: lane, now: { now })

        try write([
            // Abandoned: accepted 9h ago, nothing ever finished it.
            row(kind: "turn.accepted", turnId: "abandoned-1",
                ts: iso(now.addingTimeInterval(-9 * 3600))),
            // Healthy: accepted and completed.
            row(kind: "turn.accepted", turnId: "finished",
                ts: iso(now.addingTimeInterval(-8 * 3600))),
            row(kind: "turn.terminal", turnId: "finished",
                ts: iso(now.addingTimeInterval(-8 * 3600 + 20))),
            // Still inside the 6h window: may be running right now.
            row(kind: "turn.accepted", turnId: "young",
                ts: iso(now.addingTimeInterval(-60))),
        ], day: now, lane: lane)

        let first = await reconciler.sweep()
        #expect(first.acceptedScanned == 3)
        #expect(first.reconciled == ["abandoned-1"])
        #expect(first.tooRecentToJudge == 1)

        let written = try String(contentsOf: lane.path(for: now), encoding: .utf8)
        #expect(written.contains("abandoned: no terminal after 540 minutes"))
        #expect(written.contains("terminal_reconciliation"))

        // IDEMPOTENT: the row it just wrote is itself a terminal, so a second
        // sweep has nothing left to reconcile.
        let second = await reconciler.sweep()
        #expect(second.reconciled.isEmpty)
    }

    @Test("a turn accepted in THIS process is never reconciled")
    func neverReconcilesATurnFromThisProcess() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        // This process started 12h ago: the 9h-old accepted turn below is OURS.
        // It is past the wall-clock ceiling, but a live turn that keeps earning
        // extensions must never be stamped abandoned by its own process.
        let reconciler = AbandonedTurnReconciler(
            lane: lane,
            now: { now },
            processEpoch: now.addingTimeInterval(-12 * 3600)
        )

        try write([
            row(kind: "turn.accepted", turnId: "ours-and-still-running",
                ts: iso(now.addingTimeInterval(-9 * 3600))),
        ], day: now, lane: lane)

        let outcome = await reconciler.sweep()
        #expect(outcome.reconciled.isEmpty)
        #expect(outcome.tooRecentToJudge == 1)
        let written = try String(contentsOf: lane.path(for: now), encoding: .utf8)
        #expect(!written.contains("terminal_reconciliation"))
    }

    @Test("a terminal landing between the scan and the append wins")
    func realTerminalBeatsTheAbandonedVerdict() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let reconciler = AbandonedTurnReconciler(
            lane: lane,
            now: { now },
            processEpoch: now.addingTimeInterval(12 * 3600)
        )
        let path = lane.path(for: now)
        try write([
            row(kind: "turn.accepted", turnId: "racing",
                ts: iso(now.addingTimeInterval(-9 * 3600))),
        ], day: now, lane: lane)

        // Hold the day file's write lock, let the sweep complete its unlocked
        // scan (it finds no terminal) and block on the lock, then write the
        // REAL terminal and release. The guarded append must re-read and stand
        // down.
        let persistence = SwiftNativePersistenceCore()
        let sweep = Task { await reconciler.sweep() }
        try await persistence.withFileLock(path) {
            try await Task.sleep(nanoseconds: 400_000_000)
            let terminal = self.row(
                kind: "turn.terminal", turnId: "racing", ts: self.iso(now)
            )
            let line = String(
                decoding: try terminal.serializedData(pretty: false), as: UTF8.self
            )
            let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            try (existing + line + "\n").write(to: path, atomically: true, encoding: .utf8)
        }
        let outcome = await sweep.value

        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(!written.contains("terminal_reconciliation"),
                "the real terminal must not be followed by an abandoned verdict")
        #expect(outcome.reconciled.isEmpty)
    }

    @Test("a terminal in ANOTHER day file still beats the abandoned verdict")
    func realTerminalInTheTurnsOwnDayFileWins() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let reconciler = AbandonedTurnReconciler(
            lane: lane,
            now: { now },
            processEpoch: now.addingTimeInterval(12 * 3600)
        )
        let todayPath = lane.path(for: now)
        let yesterdayPath = lane.path(for: yesterday)
        #expect(todayPath != yesterdayPath)
        try write([
            row(kind: "turn.accepted", turnId: "crossing-midnight", ts: iso(yesterday)),
        ], day: yesterday, lane: lane)

        // GPT-5.6 review 2026-09-11: the guard only re-read the file the
        // abandoned row is appended to (today's). A real terminal for a turn
        // accepted yesterday lands in YESTERDAY's file, so the verdict was
        // written next to a genuine terminal that the guard never saw.
        let persistence = SwiftNativePersistenceCore()
        let sweep = Task { await reconciler.sweep() }
        try await persistence.withFileLock(todayPath) {
            try await Task.sleep(nanoseconds: 400_000_000)
            let terminal = self.row(
                kind: "turn.terminal", turnId: "crossing-midnight", ts: self.iso(yesterday)
            )
            let line = String(
                decoding: try terminal.serializedData(pretty: false), as: UTF8.self
            )
            let existing = (try? String(contentsOf: yesterdayPath, encoding: .utf8)) ?? ""
            try (existing + line + "\n")
                .write(to: yesterdayPath, atomically: true, encoding: .utf8)
        }
        let outcome = await sweep.value
        #expect(outcome.reconciled.isEmpty)
        let written = (try? String(contentsOf: todayPath, encoding: .utf8)) ?? ""
        #expect(!written.contains("terminal_reconciliation"))
    }

    @Test("a backlog larger than the old per-sweep cap drains in one sweep")
    func backlogDrainsWithoutWaitingForAnotherTrigger() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let reconciler = AbandonedTurnReconciler(
            lane: lane,
            now: { now },
            processEpoch: now.addingTimeInterval(12 * 3600)
        )
        // 30 > the old 25-row cap, which had no guaranteed continuation: the
        // remainder waited on a trigger that might never come.
        let rows = (0..<30).map {
            row(kind: "turn.accepted", turnId: "stale-\($0)",
                ts: iso(now.addingTimeInterval(-9 * 3600)))
        }
        try write(rows, day: now, lane: lane)

        let outcome = await reconciler.sweep()
        #expect(outcome.reconciled.count == 30)
        let second = await reconciler.sweep()
        #expect(second.reconciled.isEmpty)
    }

    @Test("with no cursor the sweep starts at the OLDEST day file, not today")
    func firstRunStartsAtOldestDayFile() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let reconciler = AbandonedTurnReconciler(
            lane: lane,
            now: { now },
            processEpoch: now.addingTimeInterval(12 * 3600)
        )
        // 40 days back: outside the 30-day window if the sweep starts at
        // today, which is what every pre-cursor install looks like.
        let calendar = AbandonedTurnReconciler.dayCalendar
        let oldDay = try #require(calendar.date(byAdding: .day, value: -40, to: now))
        try write([
            row(kind: "turn.accepted", turnId: "ancient", ts: iso(oldDay))
        ], day: oldDay, lane: lane)

        let outcome = await reconciler.sweep()
        #expect(outcome.reconciled == ["ancient"])
        // The cursor stopped at the end of the window it actually scanned, so
        // the days between there and today are still ahead of it.
        let cursor = try String(
            contentsOf: root
                .appendingPathComponent("turn_traces", isDirectory: true)
                .appendingPathComponent("abandoned-reconciler-cursor.json"),
            encoding: .utf8
        )
        let stopped = try #require(calendar.date(byAdding: .day, value: -12, to: now))
        #expect(cursor.contains(TurnTracePersistLane.dayFormatter.string(from: stopped)))
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
