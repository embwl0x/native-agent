import Foundation
import PersistenceCore

// MARK: - Turn Inspector W4 — per-turn SUMMARY records for the iCloud snapshot lane
//
// The iOS read-only inspector does NOT receive the full per-event stream (size
// budget — turn_traces files run to 20k rows/day). Instead the Mac sync engine
// computes a compact summary PER TURN off the persisted day file and writes a
// single bounded `turn_summaries.json` into the iCloud snapshot dir. iOS decodes
// it with its own lenient struct (it cannot import this target) and renders a
// flat list of turn cards.
//
// PRIVACY (hard constraint): a summary carries ONLY numeric/count fields and the
// kind strings — NEVER event payloads, args, results, prompt bodies, or any
// content. Events are already redacted at emission (W1/W2); this lane goes
// further and emits counts/metrics exclusively.
//
// The mapping reuses the EXISTING `TurnInspectorGrouping.group(_:)` so grouping /
// ordering / token+ttft summarization logic is not duplicated. This file only
// projects each `InspectorTurnCard` down to the summary shape + computes the
// cheap per-kind breakdown, then applies the size budget.

// MARK: - TurnSummaryRecord

/// One turn, summarized for the iOS snapshot lane. Mirrors `InspectorTurnCard`'s
/// summary fields (id, surface, sessionId, startedAt, lastAt, eventCount, wallMs,
/// llmTokens, ttftMs) plus a `kinds` breakdown (kind → count). No content.
struct TurnSummaryRecord: Codable, Identifiable, Sendable, Equatable {
    let id: String              // turnId
    let surface: String?
    let sessionId: String?
    let startedAt: Date
    let lastAt: Date
    let eventCount: Int
    let wallMs: Int
    let llmTokens: Int?
    let ttftMs: Int?
    /// kind → count breakdown (e.g. ["tool.dispatch": 3, "llm.call": 1]). Cheap,
    /// content-free, lets iOS show a per-turn mix without the event stream.
    let kinds: [String: Int]
}

// MARK: - TurnSummaryFile (the snapshot wrapper + truncation marker)

/// The serialized `turn_summaries.json` shape. The wrapper (vs a bare array)
/// carries the size-budget bookkeeping HONESTLY: `truncated` marks that the
/// oldest turns were dropped to stay under the byte budget, and `totalTurnsSeen`
/// records how many turns the day file actually held so iOS can say "showing N
/// of M" rather than silently capping.
struct TurnSummaryFile: Codable, Sendable, Equatable {
    /// Newest-first turn summaries (matches the grouping's newest-started-on-top
    /// order; iOS renders top-down without re-sorting).
    let summaries: [TurnSummaryRecord]
    /// True when older turns were dropped to fit the byte / count budget.
    let truncated: Bool
    /// How many distinct turns the source day file held before capping.
    let totalTurnsSeen: Int
    // NO generatedAt: the snapshot writer digest-skips unchanged bytes; an
    // always-changing stamp would force a write (and a KVS sync signal) every
    // 30s pass even when no turns changed. iOS decodes it as optional.
}

// MARK: - TurnSummaryComputer (pure projection + size budget)

/// Pure transform: a flat `[TurnTraceEvent]` list (today's persisted day file,
/// optionally yesterday's appended) → a bounded `TurnSummaryFile`. No IO, no
/// actor — testable from an explicit event array.
enum TurnSummaryComputer {

    /// Hard cap on the number of turns carried in the snapshot. Newest-first;
    /// oldest turns past this count are dropped (marker set). ~200 summaries at
    /// ~250 bytes each is comfortably under the byte budget below.
    static let maxTurns = 200

    /// Hard byte budget for the serialized JSON. The snapshot lane is for compact
    /// summaries, not the event stream; well under iOS's 4 MB default snapshot
    /// read limit. If `maxTurns` summaries still exceed this, turns are dropped
    /// oldest-first until the serialized payload fits.
    static let maxBytes = 256 * 1024

    /// The ONLY kinds the summary breakdown will name. `TurnTraceEvent.kind` is a
    /// freeform String at the bus layer — a buggy emitter could put content in it
    /// and a JSON KEY would carry that content into the iCloud snapshot. Unknown
    /// kinds are bucketed as `"other"` so the snapshot never serializes a string
    /// the summarizer didn't choose.
    static let allowedKinds: Set<String> = [
        "assembly.stage", "stream.tick", "llm.call",
        "tool.dispatch", "file.touch", "thinking.delta", "memory.commit",
    ]
    static let otherKindBucket = "other"

    /// Identity fields (turnId/surface/sessionId) are also freeform strings; cap
    /// them so a pathological value can't bloat or leak through the snapshot.
    static let maxIdentityFieldLength = 120

    /// Project grouped cards to summary records (newest-first preserved) and
    /// apply the count + byte budgets, oldest-first truncation. Budgets are
    /// injectable for deterministic truncation tests; production callers use the
    /// defaults.
    static func compute(
        from events: [TurnTraceEvent],
        encoder: JSONEncoder = TurnSummaryComputer.makeEncoder(),
        maxTurns: Int = TurnSummaryComputer.maxTurns,
        maxBytes: Int = TurnSummaryComputer.maxBytes
    ) -> TurnSummaryFile {
        // Reuse the existing grouping — newest-started turn first, rows sorted
        // chronologically within each turn. We only read summary-level fields +
        // each row's kind, allow-list filtered below — never content.
        let cards = TurnInspectorGrouping.group(events)
        let totalTurnsSeen = cards.count

        func capped(_ s: String?) -> String? {
            guard let s else { return nil }
            return s.count > maxIdentityFieldLength ? String(s.prefix(maxIdentityFieldLength)) : s
        }

        var all: [TurnSummaryRecord] = cards.map { card in
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

        // Count budget first (newest-first array → keep the prefix).
        var truncated = false
        if all.count > maxTurns {
            all = Array(all.prefix(maxTurns))
            truncated = true
        }

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
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

// MARK: - TurnSummarySource (reads the persisted day file via the live root)

/// Reads today's (and optionally yesterday's) persisted turn-trace day files
/// from the SAME root the live persist lane writes to — env override
/// (`NATIVE_AGENT_TURN_TRACE_ROOT`) → process static → `defaultDataRoot()` — and
/// decodes the rows with the parse-resilient `TurnTraceReplayReader` (malformed
/// rows skipped, never crashes). Pure-ish: a directory parameter makes it
/// testable without touching the live feed.
enum TurnSummarySource {

    /// The trace root the live lane resolves to. Mirrors
    /// `TurnTracePersistLane.resolvedDataRoot()` so summaries read exactly where
    /// W1/W2 wrote, honoring the test override seam.
    static func liveRoot() -> URL {
        TurnTracePersistLane().resolvedDataRoot()
    }

    /// Load + decode today's (and optionally yesterday's) day files under `root`,
    /// returning the concatenated events. Yesterday is appended SECOND so today's
    /// events keep their natural arrival index for stable tie-breaking inside the
    /// grouping (the grouping sorts by ts anyway; index only breaks exact ties).
    static func loadEvents(root: URL, now: Date = Date(), includeYesterday: Bool = true) -> [TurnTraceEvent] {
        var out: [TurnTraceEvent] = []
        let today = TurnTraceReplayReader.read(TurnTraceReplayReader.fileURL(for: now, root: root))
        out.append(contentsOf: today.events)
        if includeYesterday {
            let yDate = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
            let yesterday = TurnTraceReplayReader.read(TurnTraceReplayReader.fileURL(for: yDate, root: root))
            out.append(contentsOf: yesterday.events)
        }
        return out
    }
}
