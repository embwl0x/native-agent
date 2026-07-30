// SwiftNative read-only port of the daemon agent-swarm RUN-LIST surface.
//
// Source of truth: the retired daemon
//   Runtime.list_agent_swarms(self, limit=50)            (L35738-35742)
//   route GET /v1/agent/swarms                            (L51013-51014)
//
// Python METHOD:
//   runs = read_json(self.agent_swarms_path, [])
//   if not isinstance(runs, list): return []
//   return sorted(runs, key=lambda item: str(item.get("createdAt") or ""),
//                 reverse=True)[:max(1, min(limit, 200))]
//   where  self.agent_swarms_path = root / "swarms" / "runs.json"  (L2315)
//
// Python ROUTE (what the HTTP GET actually emits):
//   {"status": "ready", "runs": <list_agent_swarms()>, "createdAt": now_iso()}
//
// This module ports ONLY the read path: it reads `<dataRoot>/swarms/runs.json`,
// drops non-list documents to `[]` (matching the `isinstance` guard), sorts by
// the `createdAt` field descending with Python's STABLE-sort tie semantics, and
// slices to `max(1, min(limit, 200))`. Run records are returned as the raw
// stored JSONValue objects (passthrough, no field reshaping).
//
// WRITE / EXECUTE path (POST /v1/agent/swarms/run -> Runtime.run_agent_swarm,
// ~658 LOC of live provider routing, codex CLI fan-out, threading, cost
// estimation, and the read-modify-write of swarms/runs.json under
// agent_swarms_lock) is deliberately NOT ported here. Flipping THIS read path
// to Swift-native in production additionally requires the cross-process file
// lock to wrap every
// Python write of swarms/runs.json, because run_agent_swarm mutates the same
// file the daemon process owns. See CUTOVER_PLAN.md §6.55.

import Foundation
import PersistenceCore

// MARK: - SwarmRunsStore (read-only)

/// Pure, read-only view over a loaded `swarms/runs.json` document. Construct via
/// `load(path:)` or `init(runs:)`. All query methods are deterministic functions
/// of the loaded data — no disk writes, no locks.
public struct SwarmRunsStore: Sendable {
    /// The raw run records, in file/insertion order (== the order
    /// `sorted(..., reverse=True)` ties break on, via the stable-sort port).
    public let runs: [JSONValue]

    public init(runs: [JSONValue]) {
        self.runs = runs
    }

    /// Load from the on-disk JSON file. Mirrors `read_json(path, [])` + the
    /// `if not isinstance(runs, list): return []` guard in `list_agent_swarms`.
    /// Returns an EMPTY store (not nil) when the file is missing, unreadable, or
    /// is not a JSON array — matching the Python method, which collapses any
    /// non-list document (object / scalar / null / parse-miss) to `[]`.
    public static func load(path: URL) -> SwarmRunsStore {
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .array(let arr) = parsed else {
            // Missing file, parse failure, OR a non-array top-level document all
            // collapse to [] — read_json's default is [] and the isinstance
            // guard rejects anything that isn't a list.
            return SwarmRunsStore(runs: [])
        }
        return SwarmRunsStore(runs: arr)
    }

    // MARK: Queries

    /// Mirrors `list_agent_swarms(limit)` in the retired daemon (L35738-35742).
    ///
    /// Sort key: `str(item.get("createdAt") or "")` — for each run record, the
    /// `createdAt` field is coerced via Python's `x or ""` idiom (EVERY falsy
    /// value — None/missing, "", 0, 0.0, False, [], {} — collapses to "" FIRST,
    /// so only a truthy value is stringified). A non-dict element cannot answer
    /// `.get` in Python and would raise; in practice every element is a dict
    /// written by `run_agent_swarm`, but we defensively coerce a non-object
    /// element's key to "" (strictly more robust than crashing — never observed
    /// in practice; documented divergence).
    ///
    /// Ordering: Python `sorted(..., reverse=True)` is STABLE — equal keys keep
    /// their original (file/insertion) order. Swift's `sorted(by:)` is NOT
    /// guaranteed stable, so we decorate with the original index and tie-break on
    /// it ascending (descending key, ascending index) to reproduce Python's
    /// stable behavior exactly.
    ///
    /// Slice: `[:max(1, min(limit, 200))]`.
    public func listAgentSwarms(limit: Int = 50) -> [JSONValue] {
        let cap = max(1, min(limit, 200))
        // Decorate-sort-undecorate for a stable descending sort by createdAt.
        let decorated: [(key: String, index: Int, run: JSONValue)] = runs.enumerated().map { idx, run in
            (createdAtKey(run), idx, run)
        }
        let sorted = decorated.sorted { a, b in
            // Python compares the str keys by Unicode CODE POINT
            // (`str.__lt__`), NOT Swift's default canonical/locale-aware
            // String ordering. For ASCII ISO-8601 timestamps the two agree, but
            // to stay faithful on any non-ASCII (malformed) createdAt we order by
            // unicodeScalars explicitly. Descending key, then ascending index
            // for Python's stable-reverse tie semantics.
            if a.key != b.key { return codePointGreater(a.key, b.key) }
            return a.index < b.index
        }
        return Array(sorted.prefix(cap)).map { $0.run }
    }

    /// `str(item.get("createdAt") or "")` for one run record.
    private func createdAtKey(_ run: JSONValue) -> String {
        guard case .object(let o) = run else { return "" }  // non-dict -> "" (defensive)
        return o["createdAt"].pythonStrOrEmptySwarm
    }
}

/// True iff `lhs` is greater than `rhs` under Unicode CODE-POINT ordering
/// (lexicographic over `unicodeScalars`), reproducing Python's `str` `>`.
/// Used for the descending createdAt sort so non-ASCII keys order exactly as
/// Python would (Swift's default `String` `>` uses canonical-equivalence /
/// locale-sensitive collation, which can diverge on non-ASCII input).
func codePointGreater(_ lhs: String, _ rhs: String) -> Bool {
    var l = lhs.unicodeScalars.makeIterator()
    var r = rhs.unicodeScalars.makeIterator()
    while true {
        switch (l.next(), r.next()) {
        case let (lc?, rc?):
            if lc.value != rc.value { return lc.value > rc.value }
        case (.some, .none):
            return true        // lhs is longer, rhs is a prefix -> lhs > rhs
        case (.none, .some):
            return false       // lhs is a prefix of rhs -> lhs < rhs
        case (.none, .none):
            return false       // equal -> not greater
        }
    }
}

// MARK: - JSONValue helper

extension Optional where Wrapped == JSONValue {
    /// Mirrors Python `str(x or "")` for the `createdAt` sort field. Python's
    /// `x or ""` collapses EVERY falsy value (None/missing / 0 / 0.0 / False /
    /// "" / [] / {}) to the empty string FIRST, so only a TRUTHY value is
    /// stringified. createdAt is written as an ISO-8601 string by the daemon, so
    /// the common path is just the string passthrough; the falsy/non-string
    /// branches exist for faithful parity on hand-edited or malformed records.
    var pythonStrOrEmptySwarm: String {
        guard let v = self else { return "" }
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "True" : ""           // False -> falsy -> ""
        case .int(let i): return i == 0 ? "" : String(i)     // 0 -> falsy -> ""
        case .double(let d): return d == 0 ? "" : String(d)  // 0.0 -> falsy -> ""
        case .string(let s): return s                         // "" stays ""
        case .array(let a): return a.isEmpty ? "" : "[…]"     // [] -> "" (non-empty unused as a date)
        case .object(let o): return o.isEmpty ? "" : "{…}"    // {} -> "" (non-empty unused as a date)
        }
    }
}
