import Foundation
// Blueprint: | `TurnSummaryRecord.swift` | `TurnSummaryRecord`, `TurnSummaryFile`, `TurnSummaryComputer`, `TurnSummarySource` |

// MARK: - Turn Inspector W4 — per-turn SUMMARY records for the iCloud snapshot lane
//
// The iOS read-only inspector does NOT receive the full per-event stream (size
// budget — turn_traces files run to 20k rows/day). The engine's Inspector
// projection supplies a compact summary PER TURN, and Mac sync writes a
// single bounded `turn_summaries.json` into the iCloud snapshot dir. iOS decodes
// it with its own lenient struct (it cannot import this target) and renders a
// flat list of turn cards.
//
// PRIVACY (hard constraint): a summary carries ONLY numeric/count fields and the
// kind strings — NEVER event payloads, args, results, prompt bodies, or any
// content. Events are already redacted at emission (W1/W2); this lane goes
// further and emits counts/metrics exclusively.
//
// The mapping reads the engine's already grouped `InspectorTurnCard`s, so
// grouping / ordering / token+ttft summarization is not repeated. It only
// projects each card down to the summary shape + computes the
// cheap per-kind breakdown, then applies the size budget.

// MARK: - TurnSummaryRecord

/// One turn, summarized for the iOS snapshot lane. Mirrors `TurnTraceGroup`'s
/// summary fields (id, surface, sessionId, startedAt, lastAt, eventCount, wallMs,
/// llmTokens, ttftMs) plus a `kinds` breakdown (kind → count). No content.
public struct TurnSummaryRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: String              // turnId
    public let surface: String?
    public let sessionId: String?
    public let startedAt: Date
    public let lastAt: Date
    public let eventCount: Int
    public let wallMs: Int
    public let llmTokens: Int?
    public let ttftMs: Int?
    /// kind → count breakdown (e.g. ["tool.dispatch": 3, "llm.call": 1]). Cheap,
    /// content-free, lets iOS show a per-turn mix without the event stream.
    public let kinds: [String: Int]
}

// MARK: - TurnSummaryFile (the snapshot wrapper + truncation marker)

/// The serialized `turn_summaries.json` shape. The wrapper (vs a bare array)
/// carries the size-budget bookkeeping HONESTLY: `truncated` marks that the
/// oldest turns were dropped to stay under the byte budget, and `totalTurnsSeen`
/// records how many turns the day file actually held so iOS can say "showing N
/// of M" rather than silently capping.
public struct TurnSummaryFile: Codable, Sendable, Equatable {
    /// Newest-first turn summaries (matches the grouping's newest-started-on-top
    /// order; iOS renders top-down without re-sorting).
    public let summaries: [TurnSummaryRecord]
    /// True when older turns were dropped to fit the byte / count budget.
    public let truncated: Bool
    /// How many distinct turns the source day file held before capping.
    public let totalTurnsSeen: Int
    // NO generatedAt: the snapshot writer digest-skips unchanged bytes; an
    // always-changing stamp would force a write (and a KVS sync signal) every
    // 30s pass even when no turns changed. iOS decodes it as optional.
}

// MARK: - TurnSummaryComputer (pure projection + size budget)

/// Pure transform: the engine's grouped Inspector cards → a bounded
/// content-free `TurnSummaryFile`. No independent IO or grouping.
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

    /// Project grouped cards to summary records (newest-first preserved) and
    /// apply the count + byte budgets, oldest-first truncation. Budgets are
    /// injectable for deterministic truncation tests; production callers use the
    /// defaults.
    public static func compute(
        from cards: [InspectorTurnCard],
        encoder: JSONEncoder = TurnSummaryComputer.makeEncoder(),
        maxTurns: Int = TurnSummaryComputer.maxTurns,
        maxBytes: Int = TurnSummaryComputer.maxBytes
    ) -> TurnSummaryFile {
        let totalTurnsSeen = cards.count

        func capped(_ s: String?) -> String? {
            guard let s else { return nil }
            return s.count > maxIdentityFieldLength ? String(s.prefix(maxIdentityFieldLength)) : s
        }

        var all: [TurnSummaryRecord] = cards.prefix(maxTurns).map { card in
            var kinds: [String: Int] = [:]
            for row in card.rows {
                let key = allowedKinds.contains(row.kind) ? row.kind : otherKindBucket
                kinds[key, default: 0] += 1
            }
            return TurnSummaryRecord(
                id: capped(card.id) ?? card.id,
                surface: capped(card.surface),
                sessionId: capped(card.sessionId),
                startedAt: card.startedAt,
                lastAt: card.lastAt,
                eventCount: card.eventCount,
                wallMs: card.wallMs,
                llmTokens: card.llmTokens,
                ttftMs: card.ttftMs,
                kinds: kinds
            )
        }

        var truncated = totalTurnsSeen > maxTurns

        func file(_ records: [TurnSummaryRecord], truncated: Bool) -> TurnSummaryFile {
            TurnSummaryFile(
                summaries: records,
                truncated: truncated,
                totalTurnsSeen: totalTurnsSeen
            )
        }

        // Byte budget: drop oldest-first (array tail) until the serialized file
        // fits — all the way to EMPTY if a single record alone busts the budget
        // (the wrapper itself is tiny + fixed-size). The final guard below means
        // this function can never hand the snapshot writer an over-budget file.
        var current = file(all, truncated: truncated)
        while !all.isEmpty,
              let data = try? encoder.encode(current),
              data.count > maxBytes {
            all.removeLast()
            truncated = true
            current = file(all, truncated: true)
        }
        if let data = try? encoder.encode(current), data.count > maxBytes {
            return file([], truncated: true)
        }
        return current
    }

    /// The encoder used for both the byte-budget check and the actual snapshot
    /// write — they MUST match so the in-loop size estimate equals what lands on
    /// disk. ISO8601 dates + sorted keys mirror the snapshot writer's encoder.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

// MARK: - TurnSummarySource (the engine projection's persisted reader)

/// Reads today's (and optionally yesterday's) persisted turn-trace day files
/// from the SAME root the live persist lane writes to — env override
/// (`NATIVE_AGENT_TURN_TRACE_ROOT`) → process static → `defaultDataRoot()` — and
/// decodes through `TurnTraceReplayReader`. Read failures or incomplete framing
/// throw so the snapshot publisher cannot label a partial read as a complete day.
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
            let yDate = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
            let yesterday = try await TurnTraceReplayReader.read(TurnTraceReplayReader.fileURL(for: yDate, root: root))
            guard yesterday.report.isClean else { throw CocoaError(.fileReadCorruptFile) }
            out.append(contentsOf: yesterday.events)
        }
        return out
    }
}
