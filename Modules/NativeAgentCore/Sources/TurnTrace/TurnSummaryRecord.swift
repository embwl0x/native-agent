import Foundation
import NativeAgentShared
import Experiences
// Blueprint: | `TurnSummaryRecord.swift` | `TurnSummaryComputer`, `TurnSummarySource`: Mac-owned Inspector privacy projection and byte budgets |

// MARK: - Per-turn summaries for the iCloud snapshot lane
// Bound phone snapshots to content-free per-turn summaries: the full daily event stream exceeds the transport budget. Reuse the engine's grouped order and
// metrics; event payloads and previews stay local.

// MARK: - TurnSummaryComputer (pure projection + size budget)

/// Pure transform: the engine's grouped trace evidence → a bounded encoded content-free `TurnSummaryFile`. No independent IO or grouping.
public enum TurnSummaryComputer {

    /// About 200 summaries at 250 bytes each fit comfortably below the snapshot byte cap.
    public static let maxTurns = 200

    /// Stay well below the phone's 4 MB read limit; drop oldest turns until the encoded payload fits.
    public static let maxBytes = 256 * 1024

    /// Allowlist kind keys so freeform emitter content cannot enter phone snapshots; bucket unknown kinds as other.
    public static let allowedKinds: Set<String> = [
        "assembly.stage", "stream.tick", "llm.call",
        "tool.dispatch", "file.touch", "thinking.delta", "memory.commit",
    ]
    public static let otherKindBucket = "other"

    /// Cap freeform identities so they cannot bloat snapshots or leak unbounded content.
    public static let maxIdentityFieldLength = 120

    public static func compute(
        from groups: [TurnTraceGroup],
        encoder: JSONEncoder = TurnSummaryComputer.makeEncoder(),
        maxTurns: Int = TurnSummaryComputer.maxTurns,
        maxBytes: Int = TurnSummaryComputer.maxBytes
    ) throws -> Data {
        let totalTurnsSeen = groups.count

        func capped(_ s: String?) -> String? {
            guard let s else { return nil }
            return s.count > maxIdentityFieldLength ? String(s.prefix(maxIdentityFieldLength)) : s
        }

        let all: [TurnSummaryRecord] = groups.prefix(maxTurns).map { group in
            var kinds: [String: Int] = [:]
            for event in group.events {
                let key = allowedKinds.contains(event.kind) ? event.kind : otherKindBucket
                kinds[key, default: 0] += 1
            }
            return TurnSummaryRecord(
                id: capped(group.id) ?? group.id,
                surface: capped(group.surface),
                sessionId: capped(group.sessionId),
                startedAt: group.startedAt,
                lastAt: group.lastAt,
                eventCount: group.eventCount,
                wallMs: group.wallMs,
                llmTokens: group.llmTokens,
                ttftMs: group.ttftMs,
                kinds: kinds
            )
        }

        func file(_ count: Int, truncated: Bool = true) -> TurnSummaryFile {
            TurnSummaryFile(
                summaries: Array(all.prefix(count)),
                truncated: truncated,
                totalTurnsSeen: totalTurnsSeen
            )
        }

        var current = file(all.count, truncated: totalTurnsSeen > maxTurns)
        let bounded = try? EncodedPrefix.largestPrefix(count: all.count, maximumEncodedBytes: maxBytes) { count in
            current = file(count, truncated: totalTurnsSeen > count)
            return try encoder.encode(current)
        }
        guard let bounded else { return try encoder.encode(current) }
        if totalTurnsSeen == 0 && bounded.data.count > maxBytes { return try encoder.encode(file(0)) }
        return bounded.data
    }

    /// Measure the same sorted-key, ISO8601 encoding the snapshot writes.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

public enum EncodedPrefix {
    /// Measures the caller's complete envelope; encoded size grows with the prefix.
    public static func largestPrefix(count: Int, maximumEncodedBytes: Int,
                                     encode: (Int) throws -> Data) throws -> (data: Data, included: Int) {
        let fullData = try encode(count)
        guard fullData.count > maximumEncodedBytes else { return (fullData, count) }
        var low = 0, high = count - 1
        var bestData = try encode(0)
        var bestCount = 0
        while low <= high {
            let midpoint = low + (high - low) / 2
            let data = try encode(midpoint)
            if data.count <= maximumEncodedBytes {
                bestData = data
                bestCount = midpoint
                low = midpoint + 1
            } else {
                high = midpoint - 1
            }
        }
        return (bestData, bestCount)
    }
}

// MARK: - TurnSummarySource (the engine projection's persisted reader)

/// Reads this day's and optionally the previous day's details under the supplied root. Read failures or unreadable details throw.
public enum TurnSummarySource {

    /// A clock-skewed detail is retained behind the sequence cursor but does not appear before its recorded time. No second pending-row cache.
    public static func visibleGroups(_ groups: [TurnTraceGroup], now: Date = Date()) -> [TurnTraceGroup] {
        guard groups.contains(where: { $0.lastAt > now }) else { return groups }
        var visible: [TurnTraceGroup] = []
        for group in groups {
            if group.lastAt <= now { visible.append(group) }
            else { visible += TurnTraceGrouping.group(group.events.filter { $0.ts <= now }) }
        }
        return visible.sorted { $0.startedAt == $1.startedAt ? $0.id > $1.id : $0.startedAt > $1.startedAt }
    }

    /// The feed retains its grouped display and the record's sequence, not a second history cache. Only newly appended details are decoded;
    /// only turns they touch (or that cross the day boundary) are regrouped. A failed/corrupt read advances neither cursor nor display.
    public static func readNewGroups(root: URL, groups: [TurnTraceGroup], after: Int64?, now: Date = Date()) async throws
        -> (groups: [TurnTraceGroup], lastSeq: Int64?, changed: Bool) {
        let calendar = TurnTracePersistLane.dayCalendar
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -1, to: today) else { throw CocoaError(.fileReadUnknown) }
        // No upper timestamp bound: a late append's sequence must be consumed even if its recorded clock is ahead of ours.
        let read = try await TurnTraceReplayReader.read(.init(from: from, after: after ?? 0), root: root)
        guard read.isClean else { throw CocoaError(.fileReadCorruptFile) }
        let newEvents = read.events.filter { $0.turnId != "unknown" }
        let touched = Set(newEvents.map(\.turnId))
        var unchanged: [TurnTraceGroup] = []
        var old: [TurnTraceEvent] = []
        var changed = !newEvents.isEmpty
        for group in groups {
            if touched.contains(group.id) || group.startedAt < from {
                old += group.events.filter { $0.ts >= from }
                changed = true
            } else { unchanged.append(group) }
        }
        guard changed else { return (groups, read.lastSeq ?? after, false) }
        // Preserve today's equal-time precedence, then append order within each day (old rows precede new ones).
        let rebuilding = old + newEvents
        let ordered = rebuilding.filter { $0.ts >= today } + rebuilding.filter { $0.ts < today }
        let next = (unchanged + TurnTraceGrouping.group(ordered)).sorted {
            $0.startedAt == $1.startedAt ? $0.id > $1.id : $0.startedAt > $1.startedAt
        }
        return (next, read.lastSeq ?? after, true)
    }

    /// Append yesterday after today so equal-time grouping retains today's original arrival precedence.
    public static func loadEvents(root: URL, now: Date = Date(), includeYesterday: Bool = true) async throws -> [TurnTraceEvent] {
        let calendar = TurnTracePersistLane.dayCalendar
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: includeYesterday ? -1 : 0, to: today) else {
            throw CocoaError(.fileReadUnknown)
        }
        let read = try await TurnTraceReplayReader.read(.init(from: from, through: now), root: root)
        guard read.isClean else { throw CocoaError(.fileReadCorruptFile) }
        // Today's equal-time arrival precedence is the same on both faces.
        let turns = read.events.filter { $0.turnId != "unknown" }
        return turns.filter { $0.ts >= today } + turns.filter { $0.ts < today }
    }
}
