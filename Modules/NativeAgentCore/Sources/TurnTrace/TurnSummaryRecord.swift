import Foundation
import NativeAgentShared
// Blueprint: | `TurnSummaryRecord.swift` | `TurnSummaryComputer`, `TurnSummarySource`: Mac-owned Inspector privacy projection and byte budgets |

// MARK: - Per-turn summaries for the iCloud snapshot lane
//
// The iOS read-only inspector does NOT receive the full per-event stream (size
// budget — turn_traces files run to 20k rows/day). The engine's Inspector
// projection supplies a compact summary PER TURN, and Mac sync writes a
// single bounded `turn_summaries.json` into the iCloud snapshot dir. iOS decodes
// it through NativeAgentShared's lenient wire value and renders a
// flat list of turn cards.
//
// Phone summaries carry bounded identities, dates, metrics and allowlisted kind
// counts; event payloads and content previews stay local (TurnTraceRedactor).
//
// Project the engine's grouped trace evidence directly, preserving its order
// and metrics without constructing Inspector presentation rows.

// MARK: - TurnSummaryComputer (pure projection + size budget)

/// Pure transform: the engine's grouped trace evidence → a bounded
/// encoded content-free `TurnSummaryFile`. No independent IO or grouping.
public enum TurnSummaryComputer {

    /// Hard cap on the number of turns carried in the snapshot. Newest-first;
    /// oldest turns past this count are dropped (marker set). ~200 summaries at
    /// ~250 bytes each is comfortably under the byte budget below.
    public static let maxTurns = 200

    /// Hard byte budget for the serialized JSON. The snapshot lane is for compact
    /// summaries, not the event stream; well under iOS's 4 MB default snapshot
    /// read limit. If `maxTurns` summaries still exceed this, turns are dropped
    /// oldest-first until the serialized payload fits.
    public static let maxBytes = 256 * 1024

    /// The ONLY kinds the summary breakdown will name. `TurnTraceEvent.kind` is a
    /// freeform String at the bus layer — a buggy emitter could put content in it
    /// and a JSON KEY would carry that content into the iCloud snapshot. Unknown
    /// kinds are bucketed as `"other"` so the snapshot never serializes a string
    /// the summarizer didn't choose.
    public static let allowedKinds: Set<String> = [
        "assembly.stage", "stream.tick", "llm.call",
        "tool.dispatch", "file.touch", "thinking.delta", "memory.commit",
    ]
    public static let otherKindBucket = "other"

    /// Identity fields (turnId/surface/sessionId) are also freeform strings; cap
    /// them so a pathological value can't bloat or leak through the snapshot.
    public static let maxIdentityFieldLength = 120

    /// Project grouped evidence to summaries, preserving newest-first order
    /// and applying count and byte budgets with oldest-first truncation.
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

    /// ISO8601 dates + sorted keys for the measured snapshot bytes.
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

/// Reads today's and optionally yesterday's canonical day files under the supplied root.
/// Read failures or incomplete framing throw.
public enum TurnSummarySource {

    /// Load + decode today's (and optionally yesterday's) day files under `root`,
    /// returning the concatenated events. Yesterday is appended SECOND so today's
    /// events keep their natural arrival index for stable tie-breaking inside the
    /// grouping (the grouping sorts by ts anyway; index only breaks exact ties).
    public static func loadEvents(root: URL, now: Date = Date(), includeYesterday: Bool = true) async throws -> [TurnTraceEvent] {
        var out: [TurnTraceEvent] = []
        let today = try await TurnTraceReplayReader.read(TurnTraceReplayReader.fileURL(for: now, root: root))
        guard today.report.isClean else { throw CocoaError(.fileReadCorruptFile) }
        out.append(contentsOf: today.events)
        if includeYesterday {
            let yDate = TurnTracePersistLane.dayCalendar.date(byAdding: .day, value: -1, to: now) ?? now
            let yesterday = try await TurnTraceReplayReader.read(TurnTraceReplayReader.fileURL(for: yDate, root: root))
            guard yesterday.report.isClean else { throw CocoaError(.fileReadCorruptFile) }
            out.append(contentsOf: yesterday.events)
        }
        return out
    }
}
