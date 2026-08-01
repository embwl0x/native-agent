// SwiftNative port of the daemon's proactive-outcome ledger, scoped to the
// slice the NOTIFICATION-inbox archive/dismiss writes depend on.
//
// Source of truth in the retired daemon:
//   maybe_record_proactive_inbox_outcome(item_id, action)  L23832-23853
//   record_proactive_outcome(body)                          L23478-23492
//   _proactive_source_parts(source)                         L23545-23551
//   _proactive_outcome_exists_for_item(item_id, ...)        L23553-23571
//
// WHY THIS EXISTS (wave 32 W16 — closes the wave 31 W10 reopen-prereq):
// The notification-inbox archive/dismiss routes do MORE than flip a status
// overlay. Before the status write the daemon fires
// `maybe_record_proactive_inbox_outcome(item_id, "archive"|"dismiss")`:
//   POST /v1/inbox/<id>/archive  -> maybe_record_proactive_inbox_outcome(id,"archive"); inbox.mark_archived(id)
//   POST /v1/inbox/<id>/dismiss  -> maybe_record_proactive_inbox_outcome(id,"dismiss"); inbox.dismiss(id)
//. That ledger entry is load-bearing: the
// proactive-autonomy learning loop reads outcomes.jsonl to score whether a
// surfaced card was useful (archive => useful=True) or noise (dismiss =>
// useful=False), and the dedup guard prevents a second entry for the same item.
// Wave 31 W10 ported the READS + the status overlay but left archive/dismiss on
// HTTP precisely because this ledger was not in Swift. This module fills that
// gap so the writes can run natively without silently dropping the outcome.
//
// SCOPE — what this PORTS faithfully:
//   * _proactive_source_parts: split "proactive_autonomy:<kind>:...:<oppId>"
//   * exists-for-item dedup over the tail of outcomes.jsonl
//   * record: append the normalized outcome record to
//     <root>/nextgen/proactive/outcomes.jsonl AND mirror the daemon's
//     `record_activity("proactive", ...)` echo into <root>/activity/events.jsonl
//     (record_proactive_outcome calls record_activity at L23491).
//   * maybe_record_proactive_inbox_outcome: the gate (proactive_autonomy: only),
//     dedup, useful=archive?true:dismiss?false:nil, append.
//
// SCOPE — what it does NOT port (named retirement paths):
//   * the FULL `record_activity` machinery (68 call sites daemon-wide, with
//     redact_secret_text/redact_secret_value). We mirror ONLY the single echo
//     record_proactive_outcome emits. The outcome payload carries no
//     credential-shaped strings (ids/kind/outcome/useful/source), so the
//     daemon's redaction is a verified pass-through for this exact shape — we
//     therefore append the event verbatim rather than re-implementing the
//     regex redactor. A future wave porting the activity feed wholesale
//     (CUTOVER_PLAN.md retirement_path) subsumes this echo.
//   * record/_notify_proactive_act_outcome push notifications and the broader
//     act() follow-up turn (inbox_act) — those live behind the inbox /act and
//     /reply routes, which stay HTTP (ChatOrchestration + autonomy follow-up
//     prereq, documented in NotificationInbox.swift).
//
// CROSS-PROCESS SAFETY: outcomes.jsonl and activity/events.jsonl are append-only
// JSONL files that BOTH the daemon and (now) Swift append to. The daemon's
// `append_jsonl` is a bare O_APPEND write with no flock; POSIX O_APPEND writes
// of a single line are atomic up to PIPE_BUF and the daemon does not lock these
// either, so a separate flock here would only serialize against itself, not the
// daemon. We mirror the daemon exactly: append via PersistenceCore.appendJSONL
// (O_WRONLY|O_APPEND, which interleaves at line boundaries) and rely on the same
// single-writer-per-line atomicity the daemon relies on. The flock that DOES
// matter — the one on items.jsonl that guards the index.json overlay — is taken
// by the inbox status-write path (NotificationInboxStore), not here.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - ProactiveOutcomeLedger

/// File-backed mirror of the daemon's proactive-outcome ledger slice needed by
/// notification-inbox archive/dismiss. Reads/writes
/// `<root>/nextgen/proactive/outcomes.jsonl` and echoes to
/// `<root>/activity/events.jsonl`, exactly as the daemon does.
public struct ProactiveOutcomeLedger: Sendable {
    /// The daemon data root (the dir that holds `nextgen/`, `activity/`,
    /// `inbox/`). Mirrors `Runtime.root`.
    public let root: URL
    public let persistence: any PersistenceCoreProtocol

    public init(root: URL, persistence: any PersistenceCoreProtocol) {
        self.root = root
        self.persistence = persistence
    }

    /// `<root>/nextgen/proactive/outcomes.jsonl`.
    public var outcomesPath: URL {
        root
            .appendingPathComponent("nextgen", isDirectory: true)
            .appendingPathComponent("proactive", isDirectory: true)
            .appendingPathComponent("outcomes.jsonl")
    }

    /// `<root>/activity/events.jsonl`.
    public var activityPath: URL {
        root
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    // MARK: source parsing

    /// Mirror `_proactive_source_parts`:
    /// for "proactive_autonomy:<kind>:...:<oppId>" return (parts[1], parts[-1]);
    /// for anything else, ("", "").
    static func sourceParts(_ source: String) -> (kind: String, opportunityId: String) {
        guard source.hasPrefix("proactive_autonomy:") else { return ("", "") }
        let parts = source.components(separatedBy: ":")
        // Python: `if len(parts) < 3: return "", ""`.
        guard parts.count >= 3 else { return ("", "") }
        return (parts[1], parts[parts.count - 1])
    }

    // MARK: dedup

    /// Mirror `_proactive_outcome_exists_for_item` (the retired daemon
    /// L23553-23571). Reads `tail_jsonl(outcomes_path, 1000)` and returns true
    /// when any record's `itemId` equals `itemId`. (The opportunity-id branch
    /// in Python only returns true when itemId ALSO matches, so it is subsumed
    /// by the itemId check — we keep the same observable result.)
    ///
    /// Python early-returns False when BOTH item_id and opportunity_id are empty.
    /// Our caller always passes a non-empty item_id, but we honor the guard.
    public func outcomeExistsForItem(itemId: String, opportunityId: String) async -> Bool {
        if itemId.isEmpty && opportunityId.isEmpty { return false }
        let records = await tailOutcomes(limit: 1000)
        for record in records {
            guard case .object(let r) = record else { continue }
            if !itemId.isEmpty, jsonString(r["itemId"]) == itemId {
                return true
            }
            // Python's opportunity branch additionally requires itemId match,
            // so it cannot fire without the branch above already returning.
        }
        return false
    }

    // MARK: record

    /// Mirror `record_proactive_outcome(body)`:
    /// build the normalized record, append to outcomes.jsonl, then echo a
    /// `record_activity("proactive", "Proactive outcome recorded", outcome, "ok",
    /// payload=outcome)` event to activity/events.jsonl.
    ///
    /// Field coercion mirrors the daemon exactly:
    ///   id          = uuid4 (lowercased to match Python's str(uuid4()) shape)
    ///   opportunityId = body.opportunityId | body.id | ""
    ///   itemId      = body.itemId | ""
    ///   kind        = body.kind | "" (truncated to 80)
    ///   outcome     = body.outcome | body.action | "observed" (trunc 80)
    ///   useful      = body.useful if bool else nil
    ///   reason      = body.reason | "" (trunc 500)
    ///   source      = body.source | "proactive" (trunc 120)
    ///   createdAt   = now_iso()
    @discardableResult
    public func recordOutcome(
        opportunityId: String,
        itemId: String,
        kind: String,
        outcome: String,
        useful: Bool?,
        reason: String = "",
        source: String,
        now: String = NotificationInboxStore.nowISO()
    ) async -> JSONValue {
        let record: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "opportunityId": .string(opportunityId),
            "itemId": .string(itemId),
            "kind": .string(String(kind.prefix(80))),
            "outcome": .string(String((outcome.isEmpty ? "observed" : outcome).prefix(80))),
            "useful": useful.map { JSONValue.bool($0) } ?? .null,
            "reason": .string(String(reason.prefix(500))),
            "source": .string(String((source.isEmpty ? "proactive" : source).prefix(120))),
            "createdAt": .string(now),
        ])
        // Append the ledger record FIRST, exactly as the daemon orders it
        // (record_proactive_outcome: append_jsonl(outcomes) THEN record_activity).
        // The daemon lets append_jsonl raise; the outer `maybe_record_*` wraps the
        // WHOLE thing in try/except, so if the outcome append fails the activity
        // echo is NEVER emitted (gpt-5.5 wave-32 review finding: the echo must not
        // land with no backing outcome row). We mirror that ordering: only echo
        // the activity event when the outcome append succeeded.
        do {
            // Loop-A finding (2026-06-13): cap outcomes.jsonl. It was append-only
            // with no bound — only the read side (tailOutcomes) was byte-limited,
            // so disk grew forever. P-L5 (tightness round 2): route through THE
            // shared `appendJSONLCapped`/`enforceJSONLLineCap` path instead of the
            // hand-rolled capJSONLTail — same flock, same newest-1000 bound. On
            // SwiftNative the append+cap run under `withFileLock(outcomesPath)`;
            // the non-SwiftNative branch (tests / HTTP-backed persistence) appends
            // UNCAPPED, exactly as this helper and this file's read-path fallback
            // already do — production is always SwiftNative.
            try await appendJSONLCapped(
                record,
                to: outcomesPath,
                using: persistence,
                maxLines: 1000,
                logLabel: "ProactiveOutcomeLedger.outcomes"
            )
        } catch {
            // Outcome append failed — match the daemon: no activity echo, surface
            // the partial record to the caller (maybeRecordInboxOutcome swallows).
            return record
        }

        // Echo the activity event the daemon emits at L23491:
        //   record_activity("proactive", "Proactive outcome recorded", outcome["outcome"], "ok", payload=outcome)
        // record_activity shape: the redactor is a
        // verified pass-through for THIS payload (ids/kind/outcome/useful/source —
        // no credential-shaped strings). NOT a general replacement for the daemon
        // redactor; a future wave porting the activity feed wholesale subsumes it.
        guard case .object(let recObj) = record else { return record }
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("proactive"),
            "title": .string("Proactive outcome recorded"),
            "detail": recObj["outcome"] ?? .string("observed"),
            "status": .string("ok"),
            "missionId": .null,
            "payload": record,
            "createdAt": .string(now),
        ])
        // U5 W-G: the activity feed is now capped via a read-replace under the
        // activity flock (Connectors/Research). An unlocked append here can land
        // between that cap's read and replace and be lost — take the same lock.
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        try? await persistence.withFileLock(activityPath) { [persistence, activityPath] in
            try await appendJSONLCapped(
                event,
                to: activityPath,
                using: persistence,
                maxLines: JSONLLineCaps.activityEvents,
                logLabel: "ProactiveOutcomeLedger.activity",
                takeLock: false
            )
        }
        return record
    }

    // MARK: maybe-record gate

    /// Mirror `maybe_record_proactive_inbox_outcome(item_id, action)`
    ///. The daemon resolves the inbox item by id
    /// to read its `source`; here the caller supplies the already-resolved source
    /// (the inbox status-write path has the item in hand), avoiding a redundant
    /// load. Returns silently (no-op) unless the source is a `proactive_autonomy:`
    /// card and no outcome already exists for the item.
    ///
    /// `useful`: True for "archive", False for "dismiss", nil otherwise — exactly
    /// `True if action == "archive" else False if action == "dismiss" else None`.
    /// The whole body is wrapped so a ledger IO failure can never block or fail
    /// the status write (the daemon's `except Exception: print(...)`).
    public func maybeRecordInboxOutcome(itemSource: String, itemId: String, action: String) async {
        guard itemSource.hasPrefix("proactive_autonomy:") else { return }
        let (kind, opportunityId) = Self.sourceParts(itemSource)
        if await outcomeExistsForItem(itemId: itemId, opportunityId: opportunityId) {
            return
        }
        let useful: Bool?
        switch action {
        case "archive": useful = true
        case "dismiss": useful = false
        default: useful = nil
        }
        _ = await recordOutcome(
            opportunityId: opportunityId,
            itemId: itemId,
            kind: kind,
            outcome: action,
            useful: useful,
            source: "inbox"
        )
    }

    // MARK: helpers

    private func tailOutcomes(limit: Int) async -> [JSONValue] {
        // Mirror tail_jsonl(path, 1000) — default max_bytes=1 MiB, last `limit`
        // physical lines, malformed skipped. SwiftNativePersistenceCore.tailJSONL
        // reproduces that contract (see PersistenceCore.swift).
        //
        // NOT the lock-degrade shape (L7 sweep, 2026-08-01): this downcast
        // selects a byte-bounded TAIL read, not `withFileLock`. Nothing here
        // loses mutual exclusion — the two branches differ only in how much of
        // the file they read. Deliberately left as-is.
        if let p = persistence as? SwiftNativePersistenceCore {
            return (try? await p.tailJSONL(outcomesPath, limit: limit, maxBytes: 1_048_576)) ?? []
        }
        // Protocol fallback: full readJSONL then suffix(limit). Used only by
        // non-SwiftNative persistence (tests / HTTP-backed), which never reach
        // the native write path in practice.
        let all = (try? await persistence.readJSONL(outcomesPath)) ?? []
        return Array(all.suffix(limit))
    }

    /// `str(record.get(key) or "")` for the dedup comparison: a string value is
    /// itself; null/missing/other are treated as "" (we only compare equality
    /// against a non-empty itemId, so non-string values never match).
    private func jsonString(_ value: JSONValue?) -> String {
        if case .string(let s)? = value { return s }
        return ""
    }
}
