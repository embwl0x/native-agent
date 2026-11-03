import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TurnTraceThinkingReader.swift` | `TurnTraceThinkingReader`: off-main, bounded streaming counts of model calls and distinct conversation turns for Today and its trailing seven calendar days; skips unrelated JSON and caches unchanged day files |

/// Counts retained daily evidence, never prompts or standalone receipts.
public actor TurnTraceThinkingReader {
    public static let shared = TurnTraceThinkingReader()

    public struct Counts: Sendable {
        public let calls: Int
        public let turns: Int
    }
    public struct Snapshot: Sendable {
        public let today: Counts
        /// Today and the preceding six days, using the trace writer's calendar.
        public let week: Counts
    }
    private struct Day {
        var calls = 0
        var turns: Set<String> = []
    }
    private struct Cached {
        let stamp: SnapshotTailOpLog.FileStamp
        let day: Day
    }
    private struct Call: Decodable {
        struct Payload: Decodable { let purpose: String? }
        let kind: String
        let turnId: String
        let payload: Payload
    }
    private var cache: [String: Cached] = [:]
    private static let callMark = Data("\"llm.call\"".utf8)

    public func read(dataRoot: URL, now: Date = Date()) throws -> Snapshot {
        let lane = TurnTracePersistLane(dataRootOverride: dataRoot)
        let paths = (0..<7).compactMap { offset in
            TurnTracePersistLane.dayCalendar.date(byAdding: .day, value: -offset, to: now).map { lane.path(for: $0) }
        }
        let keys = Set(paths.map(\.path))
        cache = cache.filter { keys.contains($0.key) }
        var today = Day(), week = Day()
        for (offset, path) in paths.enumerated() {
            try Task.checkCancellation()
            guard let stamp = SnapshotTailOpLog.fileStamp(path) else {
                throw Self.unavailable(path, "could not read file metadata")
            }
            let day: Day
            if let old = cache[path.path], old.stamp == stamp { day = old.day }
            else {
                if stamp == .absent { day = Day() }
                else { day = try Self.count(path) }
                if SnapshotTailOpLog.fileStamp(path) == stamp {
                    cache[path.path] = Cached(stamp: stamp, day: day)
                }
            }
            if offset == 0 { today = day }
            week.calls += day.calls
            week.turns.formUnion(day.turns)
        }
        return Snapshot(today: Counts(calls: today.calls, turns: today.turns.count),
            week: Counts(calls: week.calls, turns: week.turns.count))
    }

    /// At most the writer's 12 MiB daily ceiling per file, in 64 KiB chunks;
    /// at most one 8 MiB model-call row is buffered. No tail can masquerade as
    /// a full day's ratio: oversized, unreadable or unfinished evidence fails.
    private static func count(_ path: URL) throws -> Day {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(JSONLLineCaps.turnTraceMaximumBytes) else {
            throw unavailable(path, "exceeds the daily read bound")
        }
        try handle.seek(toOffset: 0)
        var remaining = Int(size), pending = Data(), day = Day()
        let decoder = JSONDecoder()
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else {
                throw unavailable(path, "changed before its captured bytes could be read")
            }
            remaining -= chunk.count
            let pieces = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                guard pending.count + piece.count <= JSONLLineCaps.traceMaximumBytes else {
                    throw unavailable(path, "exceeds the trace row bound")
                }
                pending.append(contentsOf: piece)
                guard index < pieces.count - 1 else { continue }
                // Serialization may put spaces around the kind's colon. The
                // quoted value works for both shapes without parsing other kinds.
                if pending.range(of: callMark) != nil {
                    let call = try decoder.decode(Call.self, from: pending)
                    if call.kind == "llm.call", call.payload.purpose != "compaction" {
                        day.calls += 1
                        if call.payload.purpose == "turn" { day.turns.insert(call.turnId) }
                    }
                }
                pending.removeAll(keepingCapacity: true)
            }
        }
        guard pending.isEmpty else { throw unavailable(path, "ends in an unfinished row") }
        return day
    }

    private static func unavailable(_ path: URL, _ reason: String) -> PersistenceCoreError {
        .ioFailure("Thinking trace \(path.lastPathComponent) \(reason).")
    }
}
