// SwiftNative port of the daemon proactive NOTIFICATION inbox store.
//
// Source of truth: the retired daemon (class Inbox) + the daemon route handlers in
// the retired daemon:
//   GET  /v1/inbox?unread=        -> inbox.list(unread_only, limit=50)        [LIST]
//   GET  /v1/inbox/<id>           -> inbox.get(id) (404 when missing)         [GET]
//   POST /v1/inbox/<id>/read      -> inbox.mark_read(id)                      [READ]
//   POST /v1/inbox/<id>/archive   -> inbox.mark_archived(id) (+outcome hook)  [ARCHIVE]
//   POST /v1/inbox/<id>/dismiss   -> inbox.dismiss(id)       (+outcome hook)  [DISMISS]
//
// This is DISTINCT from the ApprovalInbox module (the human-gate approvals
// QUEUE). The notification Inbox is the agent's proactively-surfaced-item feed:
// trigger fires, mission-complete notices, proactive-autonomy ideas,
// harness-learning cards, idle check-ins, etc. Wave 30 W20 documented that it
// had NO Swift module; this module fills that gap.
//
// Layout the daemon writes:
//   <dataRoot>/inbox/items.jsonl   — append-only item log (one InboxItem JSON / line)
//   <dataRoot>/inbox/index.json    — status overlay (id -> {status, read_at})
//
// SCOPE — what this module PORTS (the pure, file-backed core of inbox.py):
//   * load_all      : read items.jsonl, apply index.json status/read_at overlay
//                     (Inbox._load_all, the retired daemon)
//   * list          : unread filter + most-recent-first sort + limit
//                     (Inbox.list, the retired daemon)
//   * get           : first item whose id matches (Inbox.get, L200-204)
//   * markRead      : index overlay write, status="read", read_at=now
//                     (Inbox.mark_read -> _update_status, L208-209 / L285-295)
//   * markArchived  : index overlay write, status="archived" (L211-212)
//   * dismiss       : index overlay write, status="dismissed" (L214-215)
//   * unreadCount   : count of status=="unread" (L226-227)
//
// SCOPE — what this module does NOT port (each has a named retirement_path in
// the worker's StructuredOutput, so a future wave can sequence the closure):
//   * surface()/_append_jsonl()/items.jsonl WRITE + 1000-line cap + desktop
//     notify: the daemon is the sole writer of items.jsonl on the Mac, and
//     cross-process append needs the file_lock(2) wrap on BOTH sides. Read +
//     status-overlay write are safe to serve natively because the overlay write
//     is a separate file (index.json) and is itself flock-wrapped in Python; we
//     mirror that with PersistenceCore atomic writes, but the surface() WRITE
//     stays HTTP (see CUTOVER_PLAN.md §6.55 prereqs).
//   * inbox_act / inbox_reply (POST .../act, .../reply): these are NOT inbox
//     methods — the daemon runtime intercepts them to queue an LLM autonomy
//     follow-up turn (inbox_act, the retired daemon) or invoke chat()
//     (inbox_reply, L41364). Porting needs a DAEMON-SIDE Swift turn engine
//     (the daemon's OWN Runtime.chat, NOT the Mac-client `.chatOrchestration`
//     seam — that bypasses the daemon for the UI's chat, not for these
//     server-side autonomy turns) plus the proactive autonomy machinery
//     (direct-action dispatch, duplicate suppression, bounded-tool synthesis,
//     `_notify_proactive_act_outcome` push). Native relay handling remains a
//     separate subsystem; this module only owns inbox-local state transitions.
//   * POST .../approve, .../reject: bridge to the approvals/REM resolver
//     (resolve_approval_request / REMCycle.apply_proposal) — a DIFFERENT
//     subsystem. They are inbox-shaped only at the URL.
//   * /v1/inbox/triggers/* : the ProactiveTriggerScheduler surface — already
//     owned by the TriggerScheduler Swift module (wave 15), not this one.
//
// The status-transition writes (read/archive/dismiss) ARE ported because they
// only mutate index.json. Swift takes the same file lock target used by other
// NativeAgent processes before writing — see SwiftNativeNotificationInbox.markStatus.

import Foundation
import PersistenceCore

// MARK: - InboxStatus

/// The four lifecycle states an inbox item can hold.
public enum InboxItemStatus: String, Sendable, Equatable {
    case unread
    case read
    case archived
    case dismissed
}

// MARK: - InboxItemRecord

/// A single proactive-inbox item, mirroring `InboxItem.to_dict()` in
/// the retired daemon (L88-104). Fields are passthrough JSONValue where the daemon
/// stores free-form (`related_groups`), so the Mac/iOS decode models
/// (`InboxItemRecord` in InboxView.swift) decode the re-serialized payload
/// identically. We model the strongly-typed scalar fields and keep `actions` /
/// `related_groups` / `related_paths` as JSONValue passthrough.
public struct NotificationInboxItem: Sendable, Equatable {
    public let id: String
    public let createdAt: String          // ISO-8601 string, stored verbatim
    public let source: String
    public let severity: String           // "info" | "important" | "actionable"
    public let title: String
    public let summary: String
    public let detail: String?
    public let relatedWorkshopExecutionId: String?
    public let relatedApprovalId: String?
    public let relatedPaths: [String]?
    public let relatedGroups: [JSONValue]?
    public let actions: [JSONValue]
    public var status: String             // overlaid from index.json
    public var readAt: String?            // overlaid from index.json

    public init(
        id: String,
        createdAt: String,
        source: String,
        severity: String,
        title: String,
        summary: String,
        detail: String?,
        relatedWorkshopExecutionId: String?,
        relatedApprovalId: String?,
        relatedPaths: [String]?,
        relatedGroups: [JSONValue]?,
        actions: [JSONValue],
        status: String,
        readAt: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.severity = severity
        self.title = title
        self.summary = summary
        self.detail = detail
        self.relatedWorkshopExecutionId = relatedWorkshopExecutionId
        self.relatedApprovalId = relatedApprovalId
        self.relatedPaths = relatedPaths
        self.relatedGroups = relatedGroups
        self.actions = actions
        self.status = status
        self.readAt = readAt
    }

    /// Construct from one parsed `items.jsonl` line object, mirroring
    /// `InboxItem.from_dict(d)`. Python coerces every
    /// scalar with `str(d.get(k, default))`: a MISSING key uses the default;
    /// a PRESENT value is stringified the Python way (JSON null -> "None",
    /// bool -> "True"/"False", int -> its digits) — present falsy values do NOT
    /// collapse to the default. We mirror that exactly (missing `severity`
    /// defaults to "info", missing `status` to "unread"; a non-string `title` is
    /// stringified, not blanked).
    static func fromLine(_ d: [String: JSONValue]) -> NotificationInboxItem {
        NotificationInboxItem(
            id: d["id"].pyStr(default: ""),
            createdAt: d["created_at"].pyStr(default: ""),
            source: d["source"].pyStr(default: ""),
            severity: d["severity"].pyStr(default: "info"),
            title: d["title"].pyStr(default: ""),
            summary: d["summary"].pyStr(default: ""),
            // detail/related_* are `d.get(k)` (no str()) — kept as optional
            // strings when present-and-string, else nil (Python: passes None
            // through; a non-string would be carried verbatim, but the wire
            // contract is string|null so we surface string|nil).
            detail: d["detail"].optString,
            relatedWorkshopExecutionId: d["related_mission_id"].optString,
            relatedApprovalId: d["related_approval_id"].optString,
            // Python: `list(d["related_paths"]) if isinstance(list) else None`.
            // The daemon stores related_paths as a list of strings; coerce each
            // element via the Optional-keyed helpers (wrap in .some).
            relatedPaths: {
                if case .array(let a)? = d["related_paths"] {
                    return a.map { (Optional($0)).optString ?? (Optional($0)).pyStr(default: "") }
                }
                return nil
            }(),
            // related_groups: `list(...) if isinstance(list) else None` — kept
            // as JSONValue passthrough (free-form dicts).
            relatedGroups: {
                if case .array(let a)? = d["related_groups"] { return a }
                return nil
            }(),
            // actions: `list(d.get("actions") or [])` — falsy -> [].
            actions: {
                if case .array(let a)? = d["actions"] { return a }
                return []
            }(),
            status: d["status"].pyStr(default: "unread"),
            readAt: d["read_at"].optString
        )
    }

    /// Re-serialize to the daemon's `to_dict()` wire shape (the retired daemon
    /// L88-104). Key order is irrelevant to the Swift/iOS Decodable models.
    /// `detail` / `related_*` / `read_at` emit JSON `null` when nil (matching
    /// Python, which always includes the keys with `None`).
    public func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id),
            "created_at": .string(createdAt),
            "source": .string(source),
            "severity": .string(severity),
            "title": .string(title),
            "summary": .string(summary),
            "detail": detail.map { JSONValue.string($0) } ?? .null,
            "related_mission_id": relatedWorkshopExecutionId.map { JSONValue.string($0) } ?? .null,
            "related_approval_id": relatedApprovalId.map { JSONValue.string($0) } ?? .null,
            "related_paths": relatedPaths.map { JSONValue.array($0.map { JSONValue.string($0) }) } ?? .null,
            "related_groups": relatedGroups.map { JSONValue.array($0) } ?? .null,
            "actions": .array(actions),
            "status": .string(status),
            "read_at": readAt.map { JSONValue.string($0) } ?? .null,
        ])
    }
}

// MARK: - NotificationInboxStore (read + status overlay)

/// Pure file-backed view over the daemon's inbox directory. Read methods are
/// deterministic functions of the on-disk `items.jsonl` + `index.json`; the
/// status-transition methods mutate ONLY `index.json` (the overlay), never the
/// append-only log — exactly as `Inbox._update_status` does in the daemon.
///
/// This struct does NOT take a process-wide lock by itself. The daemon wraps
/// every overlay write in `file_lock(self._items_path)` (a cross-process flock
/// keyed on items.jsonl). The factory below leaves status writes returning the
/// HTTP-fallback signal until the Swift side wires the SAME flock target (see
/// CUTOVER_PLAN.md §6.55). Read methods are always safe.
public struct NotificationInboxStore: Sendable {
    /// `<dataRoot>/inbox` directory.
    public let inboxDir: URL

    public var itemsPath: URL { inboxDir.appendingPathComponent("items.jsonl") }
    public var indexPath: URL { inboxDir.appendingPathComponent("index.json") }

    public init(inboxDir: URL) {
        self.inboxDir = inboxDir
    }

    // MARK: Load

    /// Mirror `Inbox._load_all()`: read each non-blank
    /// line of items.jsonl, parse the JSON object, build a record, then apply the
    /// index.json status/read_at overlay when the id is present. Malformed lines
    /// are silently skipped (Python: `except Exception: pass`). A missing
    /// items.jsonl yields [] (Python returns [] before reading).
    public func loadAll() -> [NotificationInboxItem] {
        guard let itemsData = try? Data(contentsOf: itemsPath) else { return [] }
        guard let text = String(data: itemsData, encoding: .utf8) else { return [] }

        // index.json overlay: id -> {status, read_at}. `_read_json(path, {})`
        // returns {} on any error/missing.
        let index = loadIndex()

        var items: [NotificationInboxItem] = []
        // Python splits on universal newlines via str.splitlines(); Swift's
        // `Character.isNewline` covers the same set (LF, CR, CRLF, NEL, LS, PS,
        // VT, FF) so this is faithful to str.splitlines() rather than the
        // narrower LF/CRLF-only split. `line.strip()` then drops blank lines.
        // (gpt-5.5 review finding #15 — splitlines parity.)
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let lineData = line.data(using: .utf8),
                  let parsed = try? JSONValue.parse(lineData),
                  case .object(let d) = parsed else {
                continue   // malformed line -> skip (Python: except: pass)
            }
            var item = NotificationInboxItem.fromLine(d)
            // Apply overlay (Python L276-279):
            //   if item.id in index:
            //       overlay = index[item.id]
            //       item.status  = str(overlay.get("status", item.status))
            //       item.read_at = overlay.get("read_at")
            // Python enters this branch whenever the id is a KEY in the index.
            // If `index[id]` is non-dict, `overlay.get(...)` raises AttributeError
            // and the surrounding `except Exception: pass` (L281-282) DROPS the
            // whole item. Mirror that: a present-but-non-object overlay skips the
            // item entirely rather than silently keeping the base record.
            // (gpt-5.5 review finding #2 — malformed-overlay parity.)
            if let overlayValue = index[item.id] {
                guard case .object(let overlay) = overlayValue else {
                    continue   // non-dict overlay -> Python raises -> item dropped
                }
                item.status = overlay["status"].pyStr(default: item.status)
                // Python sets read_at to overlay.get("read_at") UNCONDITIONALLY
                // when the id is in the index — even to None if the overlay has
                // no read_at key. Mirror exactly: present overlay -> read_at is
                // whatever the overlay says (string or nil).
                item.readAt = overlay["read_at"].optString
            }
            items.append(item)
        }
        return items
    }

    /// Read index.json as `{id: {status, read_at}}`. Returns [:] on any
    /// error/missing (mirrors `_read_json(self._index_path, {})`).
    func loadIndex() -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: indexPath),
              let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed else {
            return [:]
        }
        return obj
    }

    // MARK: Read queries

    /// Mirror `Inbox.list(unread_only, limit=50)`:
    /// optional unread filter, sort most-recent-first by `created_at`
    /// (descending), then take the first `limit`.
    ///
    /// Python sorts strings with `reverse=True` on the raw `created_at` string.
    /// ISO-8601 timestamps sort lexicographically == chronologically, so a string
    /// descending sort matches. We use a STABLE descending sort with original
    /// index as tie-break to mirror Python's stable `list.sort`.
    public func list(unreadOnly: Bool = false, limit: Int = 50) -> [NotificationInboxItem] {
        var items = loadAll()
        if unreadOnly {
            items = items.filter { $0.status == InboxItemStatus.unread.rawValue }
        }
        let decorated = items.enumerated().map { ($0.offset, $0.element) }
        let sorted = decorated.sorted { a, b in
            if a.1.createdAt != b.1.createdAt {
                return a.1.createdAt > b.1.createdAt   // most-recent first
            }
            return a.0 < b.0                            // stable tie-break
        }
        let result = sorted.map { $0.1 }
        // Python slices `items[:limit]`. For a negative limit that is "all but
        // the last |limit| items", NOT "all". The daemon route always passes
        // limit=50, so a negative limit never reaches
        // this over HTTP — but match Python's slice semantics exactly for the
        // direct-call surface. (gpt-5.5 review finding #4.)
        let take = limit < 0 ? max(result.count + limit, 0) : min(limit, result.count)
        return Array(result.prefix(take))
    }

    /// Mirror `Inbox.get(item_id)`: first item whose
    /// id matches, else nil. NOTE: Python's `get` calls `_load_all()` WITHOUT
    /// re-applying any sort, so it returns the FIRST matching line in file order.
    public func get(_ itemId: String) -> NotificationInboxItem? {
        for item in loadAll() where item.id == itemId {
            return item
        }
        return nil
    }

    /// Mirror `Inbox.unread_count()`.
    public func unreadCount() -> Int {
        loadAll().filter { $0.status == InboxItemStatus.unread.rawValue }.count
    }

    // MARK: Status transitions (index.json overlay only)

    /// Mirror `Inbox._update_status(item_id, status, read_at)` (the retired daemon
    /// L285-295): read index.json, merge `{status, read_at?}` onto the id's entry
    /// (preserving any other keys already there), atomic-write index.json.
    ///
    /// Returns FALSE iff the on-disk write failed. Python's `_update_status`
    /// returns True unconditionally, but it ALSO lets a write exception
    /// propagate out of `_write_json` (it is not caught at the method level), so
    /// a failed write surfaces as an error rather than a silent True. We mirror
    /// the "do not acknowledge a write that never hit disk" contract by
    /// returning False on IO failure — the caller (the reader's markRead etc.)
    /// then declines to claim a native handle. (gpt-5.5 review finding #12.)
    ///
    /// `read_at == nil` means "leave read_at untouched" (Python only sets it
    /// `if read_at is not None`); pass a value to set it.
    ///
    /// NOTE: this UNLOCKED variant performs the index.json read-modify-write with
    /// no cross-process flock. It is retained for the direct-call / test surface
    /// where no daemon is co-running. The PRODUCTION write path used by the
    /// reader goes through `updateStatusLocked` (below), which wraps the SAME
    /// read-modify-write in `withFileLock(itemsPath)` so it cannot tear against
    /// the daemon's concurrent `_update_status` (which locks the same target).
    @discardableResult
    public func updateStatus(_ itemId: String, status: InboxItemStatus, readAt: String? = nil) -> Bool {
        writeIndex(applyStatus(loadIndex(), itemId: itemId, status: status, readAt: readAt))
    }

    /// Pure read-modify of the index overlay: merge `{status, read_at?}` onto the
    /// id's entry, preserving any other keys. Mirrors the body of Python's
    /// `_update_status` between the read and the write (native_agentd inbox.py
    /// L288-293). Factored out so the locked + unlocked writers share one source
    /// of truth for the overlay mutation.
    func applyStatus(
        _ index: [String: JSONValue],
        itemId: String,
        status: InboxItemStatus,
        readAt: String?
    ) -> [String: JSONValue] {
        var index = index
        var entry: [String: JSONValue]
        if case .object(let existing)? = index[itemId] {
            entry = existing
        } else {
            entry = [:]
        }
        entry["status"] = .string(status.rawValue)
        if let readAt {
            entry["read_at"] = .string(readAt)
        }
        index[itemId] = .object(entry)
        return index
    }

    /// CROSS-PROCESS-SAFE status write. Mirrors `Inbox._update_status`
    /// INCLUDING its `file_lock(self._items_path)`
    /// wrap: the daemon locks on items.jsonl while mutating index.json, so the
    /// Swift side MUST take the SAME lock target (`<inboxDir>/items.jsonl.lock`,
    /// via PersistenceCore.withFileLock(itemsPath)) or a native overlay write
    /// could interleave with the daemon's read-modify-write and lose an update.
    /// The entire read-index → merge → write-index sequence runs INSIDE the lock
    /// (matching Python, which reads `_read_json(index)` inside the lock too).
    ///
    /// Returns FALSE iff the write failed (same contract as `updateStatus`), so
    /// the reader can decline to acknowledge a write that never hit disk and fall
    /// back to HTTP (gpt-5.5 wave-31 review finding #12).
    @discardableResult
    public func updateStatusLocked(
        _ itemId: String,
        status: InboxItemStatus,
        readAt: String? = nil,
        persistence: any PersistenceCoreProtocol
    ) async -> Bool {
        let work: @Sendable () async -> Bool = {
            let merged = self.applyStatus(self.loadIndex(), itemId: itemId, status: status, readAt: readAt)
            return self.writeIndex(merged)
        }
        if let p = persistence as? SwiftNativePersistenceCore {
            // withFileLock can throw only on lock-acquire failure; treat that as
            // a write failure (return false) rather than crash.
            return (try? await p.withFileLock(itemsPath, work)) ?? false
        }
        // Non-SwiftNative persistence (tests) has no flock surface; run unlocked.
        return await work()
    }

    /// Mirror `Inbox.mark_read` (L208-209): status=read, read_at=now-iso.
    @discardableResult
    public func markRead(_ itemId: String, now: String = NotificationInboxStore.nowISO()) -> Bool {
        updateStatus(itemId, status: .read, readAt: now)
    }

    /// Mirror `Inbox.mark_archived` (L211-212): status=archived (no read_at).
    @discardableResult
    public func markArchived(_ itemId: String) -> Bool {
        updateStatus(itemId, status: .archived)
    }

    /// Mirror `Inbox.dismiss` (L214-215): status=dismissed (no read_at).
    @discardableResult
    public func dismiss(_ itemId: String) -> Bool {
        updateStatus(itemId, status: .dismissed)
    }

    // MARK: Internal write

    /// Write index.json. The daemon's `_write_json`
    /// does `mkdir(parents=True)` + `write_text(json.dumps(indent=2))`. We mirror
    /// with a directory ensure + an atomic write (`Data.write(.atomic)` does a
    /// tmp-file-then-rename, which is strictly safer than Python's plain
    /// write_text and produces no torn reads for the daemon's concurrent
    /// `_read_json`). Object key order differs from Python's (irrelevant to the
    /// `{status, read_at}` overlay readers).
    ///
    /// Returns FALSE on any IO/serialization failure so `updateStatus` can
    /// decline to acknowledge a write that never hit disk (gpt-5.5 review
    /// finding #12). The caller's HTTP-fallback gating is then the safety net.
    @discardableResult
    func writeIndex(_ index: [String: JSONValue]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
            let data = try JSONValue.object(index).serializedData(pretty: true)
            try data.write(to: indexPath, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Timestamp mirroring `_now_iso()` == `datetime.now(timezone.utc).isoformat()`.
    /// Python emits the OFFSET form `2026-06-01T13:00:00.123456+00:00` (NOT the
    /// `Z` military form), with microsecond fractional precision when present.
    /// ISO8601DateFormatter only emits `Z` + millisecond precision, so we format
    /// manually to match Python's `isoformat()` shape. (gpt-5.5 review finding
    /// #13.) Fractional seconds are rendered to 6 digits (microseconds), the
    /// max Python datetime carries.
    public static func nowISO(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date
        )
        let micros = (c.nanosecond ?? 0) / 1000
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        // Python isoformat() omits the fractional part entirely when microsecond
        // == 0; otherwise it prints exactly 6 digits.
        let frac = micros == 0 ? "" : String(format: ".%06d", micros)
        return base + frac + "+00:00"
    }
}

// MARK: - JSONValue Python-coercion helpers (file-private)

private extension Optional where Wrapped == JSONValue {
    /// Mirror Python `str(d.get(k, default))`: missing/None -> default; scalars
    /// stringified the Python way; containers stringified via repr-ish fallback
    /// (not used on the inbox scalar fields in practice).
    func pyStr(default def: String) -> String {
        switch self {
        case .none:
            return def
        case .some(.null):
            // Python `str(None)` == "None", but `from_dict` uses
            // `str(d.get(k, default))` where a JSON null becomes Python None ->
            // "None". HOWEVER the daemon never writes null for these scalar
            // fields (it writes "" or omits), and "None" would be a wire-shape
            // regression. The faithful behavior for a literal stored null is
            // "None"; we keep that to match Python exactly.
            return "None"
        case .some(.bool(let b)):
            return b ? "True" : "False"          // Python str(True/False)
        case .some(.int(let i)):
            return String(i)
        case .some(.double(let d)):
            return JSONValue.double(d).pyNumberString
        case .some(.string(let s)):
            return s
        case .some(.array), .some(.object):
            // Not reached for inbox scalar fields; fall back to default.
            return def
        }
    }

    /// String when present-and-string, else nil. Used for the optional fields
    /// the daemon stores as `string | null` (detail, related_*, read_at).
    var optString: String? {
        if case .some(.string(let s)) = self { return s }
        return nil
    }
}

private extension JSONValue {
    /// Render a double the way Python `str(float)` would for the common cases
    /// (integral doubles still show a trailing `.0`). Inbox fields are strings
    /// in practice; this only matters if a producer wrote a numeric title.
    var pyNumberString: String {
        if case .double(let d) = self {
            if d == d.rounded() && abs(d) < 1e16 {
                return String(format: "%.1f", d)
            }
            return String(d)
        }
        return ""
    }
}
