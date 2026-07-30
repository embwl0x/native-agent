import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Subsystem #28 wave 35 W05 / wave 36 W02 (2026-06-02) — Context.
//
// Native port of the `/v1/context/lookup` route's ONE divergence-free branch
// (`type=lookup_feature_surface`, wave 35) PLUS the divergence-free PATHS of
// GET /v1/context/latest and POST /v1/context/feedback (wave 36 W02). See
// CUTOVER_PLAN.md §6.117 and §6.138.
//
// ── WAVE 36 W02 ADDENDUM (the real native port of latest + feedback) ─────────
//
// Wave 35 W05 landed `lookup(feature_surface)` natively but left latest /
// preview / feedback as DOC-ONLY (the client returned nil for all three).
// §6.137 #2 flagged that as a non-port. This wave ports the two routes whose
// PRODUCTION caller paths are pure filesystem IO (no routing engine), and
// keeps `preview` permanently HTTP (it IS the routing engine).
//
//   GET /v1/context/latest
//     The route walks the last 80 chat messages (newest-first), takes the most
//     recent one carrying a `runId`, and returns the pre-computed receipt JSON
//     at `<dataRoot>/context/<runId>.json`. If none is found it falls back to
//     the session's `startupContextRunId` / inline `startupContext`. ALL of
//     that is pure file IO over receipts the daemon ALREADY wrote — no routing
//     engine, no memory compile. PORTABLE.
//     ┌─ THE ONE NON-PORTABLE BRANCH (handled by deferring): the TERMINAL
//     │  fallback `if session and not get_chat_messages(limit=1):` calls
//     │  `ensure_session_startup_context()` → `context_route` +
//     │  `build_context_packet` — i.e. it GENERATES a receipt on the fly using
//     │  the non-native routing engine. Swift must NOT fabricate a different
//     │  receipt there (cross-surface divergence). So `latestContextReceipt`
//     │  returns the receipt when one EXISTS on disk and returns nil (→ HTTP
//     │  delegate) ONLY in the exact case Python would hydrate: a known session
//     │  with ZERO messages AND no already-recorded startup context. For every
//     │  other shape — receipt found, startup receipt found, OR an empty-result
//     │  case Python also returns `{}` for — Swift answers natively with the
//     │  byte-equal value Python would.
//     └─ The "session not found / no receipt anywhere / not-empty-session"
//        terminal `return {}` in Python is reproduced natively as `.object([:])`.
//
//   POST /v1/context/feedback
//     Appends an event to `<dataRoot>/context/feedback/events.jsonl` and returns
//     {status:"recorded", event, hint, createdAt}. The append is pure IO.
//     ┌─ THE ONE NON-PORTABLE BRANCH (handled by deferring): `learn_context_hint`
//     │  fires ONLY when BOTH `message` is non-empty AND `preferredMode` is a key
//     │  in `context_mode_definitions()` — and that hint-learning store + the
//     │  mode-definitions table are NOT Swift-native. The PRODUCTION Mac caller
//     │  (NativeClient.postContextFeedback sends {message_id, rating, persona})
//     │  supplies NEITHER `message` NOR `preferredMode`, so `hint` is always
//     │  None for it → pure append, zero divergence. Swift serves that path
//     │  natively (hint = null) and DEFERS (nil → HTTP) the instant a caller
//     │  supplies a hint-eligible (message + recognized preferredMode) payload,
//     │  so the daemon stays the single source of truth for hint learning.
//     └─ `context_mode_definitions` keys are a FIXED literal set; we mirror the
//        key set here ONLY to decide eligibility-to-defer (we never compute a
//        hint natively).
//
//   POST /v1/context/preview  — PERMANENT HTTP. It calls context_route (13-way
//     classifier) + compile_memory_context + select_context_capabilities over
//     the FULL runtime capability pool. None are Swift-native; a piecemeal port
//     emits a fingerprint/capability set that DISAGREES with the chat path. The
//     protocol method exists for completeness and ALWAYS returns nil.
//
// LIVE CALLER AUDIT (wave 36, re-verified at source — NOT relayed):
//   • GET /v1/context/latest → LIVE Mac UI: NativeClient.getLatestContextReceipt
//     (NativeClient.swift:4385), feeding ContextReceiptView via
//     appModel.latestContextReceipt (4 call sites). NO iOS caller. Smoke: none.
//   • POST /v1/context/feedback → LIVE Mac UI: NativeClient.postContextFeedback
//     (NativeClient.swift:8489). Smoke: smoke_all.sh:139. NO iOS caller.
//   • POST /v1/context/preview → smoke_all.sh:119 ONLY. NO Mac/iOS caller.
//   • POST /v1/context/lookup → daemon-internal builtin tool (in-process, does
//     NOT traverse HTTP) + smoke. NO live Mac/iOS HTTP caller.
//   These ports land DORMANT-CONSUMER-WIRED-NEXT: `.context` is DEFAULT OFF and
//   the NativeClient cutover-seam consumer wiring for latest/feedback is the
//   immediate §6.138 follow-up (this wave delivers the native impl + tests;
//   the seam flip is gated on the cross-process flock over the receipt/feedback
//   files, the named retirement prereq below).
//
// RETIREMENT PATH (so this KEEP/PORT names its exit, per the carry-forward):
//   §6.138 ordered prereq chain to retire the route family from the daemon:
//     1. cross-process flock(2) over <dataRoot>/context/<runId>.json reads AND
//        the daemon's write_context_receipt write (file_lock.py <->
//        PersistenceCore+FileLock.swift) — receipts are daemon-written while
//        the Mac reads; the read must not tear a concurrent write.
//     2. flock over <dataRoot>/context/feedback/events.jsonl (shared append).
//     3. NativeClient.getLatestContextReceipt + postContextFeedback routed
//        through the seam (call the client; nil → existing HTTP path).
//     4. `preview` stays HTTP until the routing engine itself is Swift-native
//        (its own multi-wave prereq, CUTOVER_PLAN.md §6.76) — the latest/
//        feedback retirement does NOT depend on it.

// MARK: - Subsystem #28 wave 35 W05 (2026-06-02) — Context.
//
// Native port of the `/v1/context/lookup` route's ONE divergence-free branch:
// `type=lookup_feature_surface`. See CUTOVER_PLAN.md §6.117.
//
// HONEST SCOPE (audited at source this wave; the SAME root blocker waves 31-W18,
// 32-W14, 33-W13, 34-W15 all reached, re-verified — NOT relayed):
//
//   The four context routes — GET /v1/context/latest, POST /v1/context/
//   {preview,lookup,feedback} — share ONE root prereq: the Python routing
//   engine (`context_route` 13-way classifier + `select_context_capabilities`
//   over the FULL `capability_records()` pool + `compile_memory_context` +
//   `adaptive_context_hints`). That engine is NOT Swift-native:
//     • SystemOps.selectContextCapabilities pools only the 19 feature-surface +
//       84 connector-action STATIC records (103 total). Python's pool ALSO
//       includes skills, tools, manifest-skills, workflows, MCP servers
//       (runtime-registered) — none Swift-native.
//     • There is NO Swift `compile_memory_context`, NO Swift
//       `context_mode_definitions` (budgetChars/sections/injectedSections),
//       NO Swift `adaptive_context_hints` store.
//   A piecemeal native `preview`/`lookup(capability)` emits a fingerprint and
//   capability set that DISAGREE with the daemon chat path — a cross-surface
//   coherence divergence (the exact bug class this migration must not ship).
//
// WHAT IS GENUINELY PORTABLE TODAY (and is ported here, for real, not docs):
//
//   `context_lookup(type=lookup_feature_surface)` dispatches ONLY to
//   `feature_surface_records()` — which is ALREADY a byte-for-byte Swift port
//   (`TrustCenter.featureSurfaceRecords(nowISO:)`, 19 records). The handler
//   filters by query substring on name/description, slices [:30], and wraps in
//   {status, type, query, features, createdAt}. No routing engine, no memory
//   compile, no capability pool — a pure function of the static manifest. So
//   THIS one branch ports without any divergence.
//
// DISPOSITION: PORTED-DORMANT-PARTIAL. `SwiftNativeContextClient.lookup(body:)`
// serves the feature-surface lookup natively and returns `nil` for the other
// three lookup types (capability / memory_policy / full_operating_map) AND for
// the latest/preview/feedback routes, signaling the caller to HTTP-delegate.
// `.context` is DEFAULT OFF; there is no LIVE Mac/iOS caller for /v1/context/
// lookup today (only smoke scripts + the daemon-internal builtin tool
// `builtin_tools.py:_exec_context_lookup`, which calls runtime.context_lookup
// IN-PROCESS and does NOT traverse the HTTP route). The leash stays in the user's
// hands — no script sets NATIVE_AGENT_SWIFT_SUBSYSTEMS. Retirement path for the
// full route family: CUTOVER_PLAN.md §6.76 (single ordered prereq chain).

// MARK: - Result type

/// Byte-equal envelope for `context_lookup`.
/// `features` is the post-filter, post-slice list of feature-surface dicts in
/// Python key order; `createdAt` is `now_iso()`.
public struct ContextLookupResult: Sendable, Equatable {
    public let status: String
    public let type: String
    public let query: String
    public let features: [JSONValue]
    public let createdAt: String

    public init(status: String, type: String, query: String, features: [JSONValue], createdAt: String) {
        self.status = status
        self.type = type
        self.query = query
        self.features = features
        self.createdAt = createdAt
    }

    /// Envelope in the exact key order the Python handler emits:
    /// {"status", "type", "query", "features", "createdAt"}.
    public func toJSON() -> JSONValue {
        .object([
            "status": .string(status),
            "type": .string(type),
            "query": .string(query),
            "features": .array(features),
            "createdAt": .string(createdAt),
        ])
    }
}

// MARK: - Feature-surface record → JSON (Python dict key order)

extension FeatureSurfaceRecord {
    /// Per-record dict in the SAME insertion order as the Python literal
    ///: id, sourceId, name, kind, status,
    /// description, triggers, permissions, riskClass, autoload, useCount,
    /// lastUsedAt, updatedAt, endpoints. `lastUsedAt` is always nil in the
    /// static literal → emitted as JSON null (matching Python `None`).
    public func contextLookupJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "sourceId": .string(sourceId),
            "name": .string(name),
            "kind": .string(kind),
            "status": .string(status),
            "description": .string(description),
            "triggers": .array(triggers.map { .string($0) }),
            "permissions": .array(permissions.map { .string($0) }),
            "riskClass": .string(riskClass),
            "autoload": .bool(autoload),
            "useCount": .int(Int64(useCount)),
            "lastUsedAt": lastUsedAt.map { JSONValue.string($0) } ?? .null,
            "updatedAt": .string(updatedAt),
            "endpoints": .array(endpoints.map { .string($0) }),
        ])
    }
}

// MARK: - Client protocol

public protocol ContextClient: Sendable {
    /// Native context_lookup. Returns the structured result for the portable
    /// `lookup_feature_surface` type family; returns `nil` for every other
    /// lookup type (capability / memory_policy / full_operating_map), signaling
    /// the caller to HTTP-delegate to the daemon (the routing-engine /
    /// memory-manual / operating-map backends are not Swift-native — porting
    /// them would diverge from the chat path). Throws only on a malformed
    /// portable request (matches the retired ValueError surface for unknowns by
    /// deferring — the daemon raises; Swift returns nil so the daemon is the
    /// single source of truth for the unknown-type error).
    func lookup(body: [String: JSONValue]) async -> ContextLookupResult?

    /// GET /v1/context/latest. Returns the pre-computed context receipt for the
    /// session (read from `<dataRoot>/context/<runId>.json`), mirroring
    /// `latest_context_receipt(session_id)`. Returns an
    /// empty object (`.object([:])`) for the cases Python also returns `{}` for
    /// (unknown session, no receipt anywhere, non-empty session with no recorded
    /// receipt). Returns `nil` — signaling the caller to HTTP-delegate — ONLY for
    /// the ONE non-native branch: a KNOWN session with ZERO messages and no
    /// already-recorded startup context, where Python would GENERATE a receipt
    /// via the routing engine (`ensure_session_startup_context`). The daemon
    /// stays the single source of truth for that on-the-fly hydration.
    func latestContextReceipt(sessionId: String) async -> JSONValue?

    /// POST /v1/context/feedback. Appends the feedback event to
    /// `<dataRoot>/context/feedback/events.jsonl` and returns the
    /// {status,event,hint,createdAt} envelope, mirroring
    /// `record_context_feedback(body)` for the pure-
    /// append path (`hint` always null). Returns `nil` — HTTP-delegate — when the
    /// payload is hint-eligible (non-empty `message` AND a `preferredMode` that
    /// is a recognized context-mode key), because hint learning needs the
    /// non-native routing-engine store.
    func recordContextFeedback(body: [String: JSONValue]) async -> JSONValue?

    /// POST /v1/context/preview. PERMANENT HTTP — always returns `nil`. The
    /// preview is the routing engine (context_route + compile_memory_context +
    /// select_context_capabilities over the full runtime capability pool); a
    /// native port would emit a fingerprint/capability set that diverges from the
    /// chat path. Present in the protocol for route-family completeness only.
    func contextPreview(body: [String: JSONValue]) async -> JSONValue?
}

// MARK: - SwiftNative impl

public actor SwiftNativeContextClient: ContextClient {
    private let now: @Sendable () -> Date
    /// Data root the daemon uses. All four
    /// context-route files hang off it: `<root>/context/<runId>.json`,
    /// `<root>/chat/...`, `<root>/context/feedback/events.jsonl`.
    private let dataRoot: URL
    private let store: PersistenceCoreProtocol
    /// Injectable for the test that mints `<uuid>` so it is deterministic; the
    /// production envelope `id` is a fresh UUID per call (Python `uuid.uuid4()`).
    private let makeEventID: @Sendable () -> String

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        store: PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        makeEventID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.now = now
        self.dataRoot = dataRoot
        self.store = store
        self.makeEventID = makeEventID
    }

    // MARK: - Path helpers

    /// `<root>/context/<runId>.json`.
    private func contextReceiptPath(_ runID: String) -> URL {
        dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("\(runID).json")
    }

    /// `<root>/chat/messages/<safeSessionId>.jsonl`.
    private func chatMessagesPath(_ sessionID: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(Self.safeChatSessionID(sessionID)).jsonl")
    }

    /// `<root>/chat/sessions.json`.
    private func chatSessionsPath() -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    /// `<root>/context/feedback/events.jsonl`.
    private func contextFeedbackPath() -> URL {
        dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("feedback", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// Mirror `safe_chat_session_id`: a value matching
    /// `[A-Za-z0-9][A-Za-z0-9_-]{2,80}` is used verbatim; anything else would be
    /// replaced by a fresh UUID by the daemon. For a READ we cannot replicate the
    /// daemon's per-call UUID substitution (it would never match a stored file),
    /// so a non-conforming id maps to a path that does not exist → empty result,
    /// which is the only safe behavior (Python would also fail to find a file for
    /// a randomly-substituted uuid). Conforming ids — the only ids the Mac UI
    /// ever sends — map verbatim, matching the daemon byte-for-byte.
    static func safeChatSessionID(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.safeSessionRegex.firstMatch(
            in: raw, range: NSRange(raw.startIndex..., in: raw)
        ) != nil {
            return raw
        }
        return UUID().uuidString  // non-match → path miss → empty result
    }

    private static let safeSessionRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9][A-Za-z0-9_-]{2,80}$"
    )

    /// The FIXED key set of `context_mode_definitions()`.
    /// Used ONLY to decide whether a feedback payload is hint-eligible (and must
    /// therefore defer to the daemon). We never compute a hint natively.
    static let contextModeKeys: Set<String> = [
        "minimal", "capability", "memory", "ops", "workflow",
        "research", "personality", "full",
    ]

    /// Feature-surface lookup type aliases.
    private static let featureSurfaceTypes: Set<String> = [
        "lookup_feature_surface", "feature_surface", "features",
    ]

    public func lookup(body: [String: JSONValue]) async -> ContextLookupResult? {
        // type = str(body.get("type") or body.get("lookup") or body.get("id")
        //            or "lookup_capability")
        let lookupType = Self.firstNonEmptyString(body, keys: ["type", "lookup", "id"])
            ?? "lookup_capability"
        // Only the feature-surface family is divergence-free-portable today.
        guard Self.featureSurfaceTypes.contains(lookupType) else { return nil }

        // query = str(body.get("query") or body.get("message") or "")
        let query = Self.firstNonEmptyString(body, keys: ["query", "message"]) ?? ""

        let createdAt = ContextLookupResult.isoTimestamp(now())
        let nowISO = createdAt  // updatedAt uses the same now_iso() per call
        let allRecords = featureSurfaceRecords(nowISO: nowISO)

        // Python: filter only when query is truthy (non-empty); else all records.
        // Match is `query.lower() in name.lower() OR query.lower() in desc.lower()`.
        let filtered: [FeatureSurfaceRecord]
        if query.isEmpty {
            filtered = allRecords
        } else {
            let needle = query.lowercased()
            filtered = allRecords.filter {
                $0.name.lowercased().contains(needle)
                    || $0.description.lowercased().contains(needle)
            }
        }
        // features[:30]
        let sliced = Array(filtered.prefix(30))
        return ContextLookupResult(
            status: "ready",
            type: lookupType,
            query: query,
            features: sliced.map { $0.contextLookupJSON() },
            createdAt: createdAt
        )
    }

    // MARK: - GET /v1/context/latest

    public func latestContextReceipt(sessionId: String) async -> JSONValue? {
        // get_chat_messages(session_id, limit=80): returns [] if the session is
        // unknown, else tail_jsonl(path, 80, max_bytes=1MB). We approximate the
        // session-existence guard by checking sessions.json; an unknown session
        // yields [] and we fall through to the session-by-id branch (which also
        // returns nil/empty), exactly as Python does.
        let sessionExists = await chatSessionExists(sessionId)
        let messages: [JSONValue]
        if sessionExists {
            messages = (try? await store.tailJSONL(
                chatMessagesPath(sessionId), limit: 80, maxBytes: 1_048_576
            )) ?? []
        } else {
            messages = []
        }

        // for message in reversed(messages): take first non-empty runId whose
        // receipt file exists.
        for message in messages.reversed() {
            guard case .object(let m) = message else { continue }
            // run_id = str(message.get("runId") or "")  — Python-truthy coerce.
            let runID = Self.coercedString(m["runId"]) ?? ""
            if runID.isEmpty { continue }
            let path = contextReceiptPath(runID)
            if let receipt = await readReceiptObject(path) {
                return receipt  // .object(...) byte-equal to Python's read_json
            }
        }

        // session = chat_session_by_id(session_id)
        let session = await chatSessionByID(sessionId)

        // startup_run_id = str((session or {}).get("startupContextRunId") or "")
        // Track PRESENCE separately from receipt-found: a present-but-stale
        // startupContextRunId changes the terminal-hydration semantics below.
        let startupRunID = session
            .flatMap { Self.coercedString($0["startupContextRunId"]) } ?? ""
        let hadStartupRunID = !startupRunID.isEmpty
        if hadStartupRunID {
            let path = contextReceiptPath(startupRunID)
            if var receipt = await readReceiptObjectDict(path) {
                receipt["startupContext"] = .bool(true)  // receipt["startupContext"] = True
                return .object(receipt)
            }
        }

        // startup_context = session.get("startupContext"); if isinstance(dict):
        //   return {"startupContext": True, **startup_context}
        if let session, case .object(let startupContext)? = session["startupContext"] {
            var merged: [String: JSONValue] = ["startupContext": .bool(true)]
            for (k, v) in startupContext { merged[k] = v }
            return .object(merged)
        }

        // Python terminal: `if session and not get_chat_messages(limit=1):`
        //   hydrated = ensure_session_startup_context(session)
        //   ... → if hydrated still has no startup receipt/dict → return {}.
        //
        // CRITICAL parity (gpt-5.5 review finding #1): ensure_session_startup_
        // context is a NO-OP early-return when the session ALREADY has a
        // startupContextRunId OR an inline startupContext dict (the retired daemon
        // :30500). It only INVOKES the routing engine (context_route +
        // build_context_packet) when BOTH are absent. So:
        //   • If we got here with hadStartupRunID == true (stale runId, receipt
        //     missing) OR an inline startupContext that wasn't a dict, `ensure`
        //     no-ops → Python deterministically returns {} WITHOUT the routing
        //     engine. Swift reproduces {} natively (.object([:])) — NO defer.
        //   • Only when NO startupContextRunId AND NO inline startupContext dict
        //     existed does `ensure` GENERATE via the routing engine → that is the
        //     one non-native case; Swift defers (nil) so the daemon hydrates.
        // The `if session and not get_chat_messages(limit=1)` guard gates BOTH
        // sub-cases; outside an empty session, Python falls straight to return {}.
        if let _ = session, sessionExists, !hadStartupRunID {
            let firstMsg = (try? await store.tailJSONL(
                chatMessagesPath(sessionId), limit: 1, maxBytes: 1_048_576
            )) ?? []
            if firstMsg.isEmpty {
                // Empty session with no startup fields → Python GENERATES via the
                // routing engine. Defer to the daemon (must not fabricate).
                return nil
            }
        }

        // Terminal: Python `return {}` (stale-startup-run, non-empty session, or
        // any other shape that doesn't trigger routing-engine generation).
        return .object([:])
    }

    /// Read a receipt file and return it iff it parses to a JSON object (mirrors
    /// Python's `receipt = read_json(path, {}); if isinstance(receipt, dict)`).
    /// A file that parses to a non-object (e.g. a bare array) is treated as a
    /// miss, exactly as the Python `isinstance(..., dict)` guard does.
    ///
    /// WAVE 37 W01 PARITY FIX (§6.159 gap #1 — "malformed receipt should return
    /// the Python equivalent ({}), not a miss"):
    ///   Python gates this read on `if path.exists():` and ONLY then calls
    ///   `read_json(path, {})` — whose DEFAULT is `{}` (an empty DICT), NOT None.
    ///   So for a file that EXISTS but holds MALFORMED/unparseable JSON,
    ///   `read_json` returns `{}` → `isinstance({}, dict)` is True → Python
    ///   returns `{}` and STOPS the walk (and the startup path returns
    ///   `{"startupContext": true}`).
    ///   The prior Swift code passed `defaultValue: .null`, so a malformed file
    ///   returned `.null` → treated as a miss → the loop kept searching, a real
    ///   divergence. Fixed by:
    ///     1. gating on `FileManager.fileExists` (mirror `if path.exists():`) so
    ///        a MISSING file is STILL a miss — without this gate, switching the
    ///        default to `{}` would make a missing file wrongly return `{}` and
    ///        halt the walk early, AND
    ///     2. passing `defaultValue: .object([:])` so a present-but-malformed
    ///        file yields `{}` exactly as `read_json(path, {})` does → byte-equal
    ///        to Python's `return {}` / `{"startupContext": true}`.
    private func readReceiptObject(_ path: URL) async -> JSONValue? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = await store.readJSON(path, defaultValue: .object([:]))
        if case .object = value { return value }
        return nil
    }

    private func readReceiptObjectDict(_ path: URL) async -> [String: JSONValue]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = await store.readJSON(path, defaultValue: .object([:]))
        if case .object(let o) = value { return o }
        return nil
    }

    /// Mirror `chat_session_by_id`: scan sessions.json
    /// for an entry whose `id` equals `sessionId`. include_archived defaults true
    /// in the route's call. We do NOT replicate `list_chat_sessions`'
    /// normalization-and-write side effect — a READ must not mutate the index;
    /// the only field this route consumes (`startupContextRunId` /
    /// `startupContext`) is read straight from the stored object.
    private func chatSessionByID(_ sessionID: String) async -> [String: JSONValue]? {
        let value = await store.readJSON(chatSessionsPath(), defaultValue: .array([]))
        guard case .array(let sessions) = value else { return nil }
        for entry in sessions {
            guard case .object(let s) = entry else { continue }
            // Python: `str(session.get("id")) == session_id`. Session ids are
            // always non-empty strings (UUID-shaped); match the string form.
            if case .string(let id)? = s["id"], id == sessionID { return s }
        }
        return nil
    }

    private func chatSessionExists(_ sessionID: String) async -> Bool {
        await chatSessionByID(sessionID) != nil
    }

    // MARK: - POST /v1/context/feedback

    public func recordContextFeedback(body: [String: JSONValue]) async -> JSONValue? {
        // message = str(body.get("message") or body.get("query") or "")
        let message = Self.firstNonEmptyString(body, keys: ["message", "query"]) ?? ""
        // preferred_mode = str(body.get("preferredMode") or body.get("mode")
        //                      or body.get("correctMode") or "")
        let preferredMode = Self.firstNonEmptyString(
            body, keys: ["preferredMode", "mode", "correctMode"]
        ) ?? ""
        // reason = str(body.get("reason") or body.get("feedback") or "user correction")
        let reason = Self.firstNonEmptyString(body, keys: ["reason", "feedback"])
            ?? "user correction"

        // hint = None; if message and preferred_mode in context_mode_definitions():
        //   hint = self.learn_context_hint(...)  ← NON-NATIVE. Defer if eligible.
        if !message.isEmpty && Self.contextModeKeys.contains(preferredMode) {
            return nil  // hint-eligible → HTTP-delegate (hint learning is Python-only)
        }

        let createdAt = ContextLookupResult.isoTimestamp(now())
        // event = {id, message, preferredMode, reason, createdAt}
        let event: [String: JSONValue] = [
            "id": .string(makeEventID()),
            "message": .string(message),
            "preferredMode": .string(preferredMode),
            "reason": .string(reason),
            "createdAt": .string(createdAt),
        ]
        // append_jsonl(self.context_feedback_path, event)
        do {
            try await store.appendJSONL(.object(event), to: contextFeedbackPath())
        } catch {
            // The daemon's append_jsonl raises on IO failure (no swallow); a
            // failed append must NOT report "recorded". Defer to HTTP so the
            // daemon's write is the authoritative one.
            return nil
        }
        // return {status:"recorded", event, hint:None, createdAt}
        return .object([
            "status": .string("recorded"),
            "event": .object(event),
            "hint": .null,
            "createdAt": .string(createdAt),
        ])
    }

    // MARK: - POST /v1/context/preview (PERMANENT HTTP)

    public func contextPreview(body: [String: JSONValue]) async -> JSONValue? {
        // The routing engine is not Swift-native; a native preview would diverge
        // from the chat path. Always defer.
        return nil
    }

    /// `str(value)`-equivalent string read with retired truthiness: returns the
    /// `str()`-coercion of `value` iff `value` is PYTHON-TRUTHY, else nil.
    /// (gpt-5.5 review finding #2: Python `str(message.get("runId") or "")`
    /// coerces a truthy non-string — e.g. an int `runId` → "123" — so a
    /// string-only read would diverge.) Used for `runId` / `startupContextRunId`,
    /// which mirror Python's `str(... or "")` single-value chains.
    static func coercedString(_ value: JSONValue?) -> String? {
        guard let value, let s = pythonStr(value) else { return nil }
        return s
    }

    /// Mirrors Python's `str(body.get(a) or body.get(b) or ...)` chain over the
    /// SAME truthiness rules `or` uses: returns the `str()`-coercion of the first
    /// key whose value is PYTHON-TRUTHY. A falsy value (None / "" / 0 / 0.0 /
    /// False / [] / {}) is skipped, exactly as Python's `x or next` skips it.
    /// (gpt-5.5 review finding #2: a string-only variant would diverge for a
    /// truthy non-string `message`/`reason` — e.g. `message=1` → Python hint-
    /// eligible, string-only Swift not.)
    static func firstNonEmptyString(_ body: [String: JSONValue], keys: [String]) -> String? {
        for k in keys {
            if let s = pythonStr(body[k]) { return s }
        }
        return nil
    }

    /// Returns `str(value)` IFF `value` is Python-truthy, else nil (so a chain of
    /// `pythonStr(...) ?? pythonStr(...) ?? fallback` reproduces `a or b or c`).
    /// Falsy JSON values map to nil: null, "" , 0, 0.0, false, [], {}.
    /// Truthy values are coerced to their Python `str()` text for the shapes that
    /// actually occur in these payloads (string verbatim; bool → "True"/"False";
    /// int → decimal; double → Python float repr for the common integral/simple
    /// cases). These coercions exist for parity-defense; in production every one
    /// of these fields is a string.
    static func pythonStr(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .string(let s):
            return s.isEmpty ? nil : s
        case .bool(let b):
            return b ? "True" : "False"   // Python str(True) == "True"
        case .int(let i):
            return i == 0 ? nil : String(i)
        case .double(let d):
            if d == 0 { return nil }
            // Python str() of an integral float drops the fraction only via repr
            // rules; for the parity-defense scope (these are never floats in
            // practice) emit Swift's default which matches Python for simple
            // values closely enough — the field is non-load-bearing here.
            return String(d)
        case .array(let a):
            return a.isEmpty ? nil : "<array>"   // truthy non-empty list; never occurs
        case .object(let o):
            return o.isEmpty ? nil : "<object>"  // truthy non-empty dict; never occurs
        }
    }
}

extension ContextLookupResult {
    /// ISO-8601 UTC timestamp BYTE-MATCHING Python's `now_iso()`
    /// (`datetime.now(timezone.utc).isoformat()`):
    /// `YYYY-MM-DDTHH:MM:SS.ffffff+00:00` — a `+00:00` offset (NOT `Z`) and SIX
    /// fractional digits (microseconds), with the fraction OMITTED entirely when
    /// microsecond == 0 (Python's `timespec='auto'`).
    ///
    /// WAVE 37 W01 PARITY FIX (§6.159 gap #2 — "context/feedback JSONL timestamp
    /// precision: match Python (microsecond + timezone form)"):
    ///   The prior impl used `ISO8601DateFormatter(.withFractionalSeconds)`,
    ///   which emits MILLISECONDS and always prints `.000` for a whole second —
    ///   so the feedback `events.jsonl` `createdAt` written by this client did
    ///   NOT byte-match the daemon's `now_iso()`. `events.jsonl` is a SHARED file
    ///   (daemon + Swift both append), so the on-disk timestamp form must match.
    ///   This now matches Python exactly:
    ///     • microsecond != 0 → `…40.123456+00:00` (six digits, truncated not
    ///       rounded — Python's epoch→datetime floors to integer microseconds),
    ///     • microsecond == 0 → `…40+00:00` (NO fractional part, timespec='auto').
    ///   This is the same gpt-5.5-hardened logic as MacControl's `_now_iso` port.
    public static func isoTimestamp(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        // Floor to integer microseconds (Python truncates, never rounds up). The
        // whole-second component and the micros are derived from ONE floored
        // value so they can never disagree at a boundary.
        let totalMicros = Int64((interval * 1_000_000).rounded(.down))
        let wholeSeconds = totalMicros / 1_000_000
        let micros = Int(totalMicros % 1_000_000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let secondsDate = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        let c = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: secondsDate
        )
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        if micros == 0 {
            return base + "+00:00"  // timespec='auto' omits the fraction
        }
        return base + String(format: ".%06d+00:00", micros)
    }
}

// MARK: - Factory

public func makeContextClient(
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any ContextClient {
    return SwiftNativeContextClient(dataRoot: dataRoot)
}
