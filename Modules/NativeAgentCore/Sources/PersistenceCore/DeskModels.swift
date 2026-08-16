import Foundation

// MARK: - Agent Desk — durable, event-sourced user-directed tracking
//
// Personal store for the in-app assistant (Agent). CANONICAL TRUTH = structured
// item rows. All mutations are OP-BASED EVENTS appended under flock; derived
// state is REBUILT FROM OPS each append (mirrors TaskLedger EXACTLY). The
// rendered compact text (DeskProjection) is a PROJECTION, never the source of
// truth.
//
// MODULE HOME: PersistenceCore — same reasoning as TaskLedger. Pure JSONL +
// flock IO, no provider / LLM / execution dependency, zero new Package.swift
// edges.
//
// STABLE HANDLES survive everything ("desk_" + lowercased UUID). The view
// numbers ("2", "2.1") are mutable, view-local ALIASES — assigned at create
// from a monotonic per-parent sequence and NEVER renumbered when siblings close
// or archive.

// MARK: - Enums

public enum DeskKind: String, Sendable, CaseIterable, Equatable {
    case watch, plan, project, gh, standing
}

public enum DeskStatus: String, Sendable, CaseIterable, Equatable {
    case watch, flag, now, next, todo, done, blocked, canceled

    /// done / canceled are terminal — an item is archivable only once terminal,
    /// and a parent refuses archive while any child is non-terminal.
    public var isTerminal: Bool { self == .done || self == .canceled }
}

public enum CadenceMode: String, Sendable, CaseIterable, Equatable {
    case manual, on_ask, tick, event, daily, weekly, blocked_watch
}

public enum NotifyLevel: String, Sendable, CaseIterable, Equatable {
    case quiet, digest, direct, urgent
}

public enum ArchiveFinalStatus: String, Sendable, CaseIterable, Equatable {
    case done, canceled, superseded
}

/// Who put an item on the Desk. `owner` (renamed from `user` 2026-07-11 so the
/// public build carries no personal name) is the neutral default and the ONLY
/// value the generic desk_add_item path can mint; `agent` marks a self-authored
/// pursuit (created solely through the dedicated openPursuit op, store-gated on
/// a valid dossier + the open-pursuit cap); `system` is machine-authored.
///
/// The rename needs NO data migration: M10's encode rule below means the
/// default origin was never serialized, so no feed on disk contains "user" —
/// and a freak explicit "user" decodes nil and lands on the same `?? .owner`
/// default.
///
/// M10 (replay compat): decode is OPTIONAL, defaulting `.owner`, and encode OMITS
/// the field when `.owner` — so a pre-origin feed replays byte-identical. Origin
/// is IMMUTABLE after create: no op mutates it, so an item's origin is fixed by
/// its create_item event for the life of the feed.
public enum DeskOrigin: String, Sendable, CaseIterable, Equatable {
    case owner, agent, system

    /// Persisted compatibility for Desk feeds written before the self-authored
    /// role was made identity-neutral. New writes always emit `agent`; the
    /// former private-name value remains read-only migration vocabulary.
    public static func decodePersisted(_ rawValue: String) -> DeskOrigin? {
        let retiredPrivateValue = ["ay", "ala"].joined()
        return rawValue == retiredPrivateValue ? .agent : DeskOrigin(rawValue: rawValue)
    }
}

// MARK: - Clock (mirror of TaskLedgerClock — Desk stays self-contained)

public enum DeskClock {
    // DateFormatter's SSSSSS only resolves to the millisecond (the trailing
    // three digits are always zeros), so two "now" stamps in the same
    // millisecond come out byte-identical — which lets the updatedAt CAS in
    // markNotifiedIfUnchanged false-succeed and swallow a same-millisecond
    // change. Guard: quantize to integer milliseconds and never re-issue a
    // value <= the last one, so in-process nowISO() is strictly monotonic.
    // nonisolated(unsafe): every access is guarded by monotonicLock.
    private static let monotonicLock = NSLock()
    nonisolated(unsafe) private static var lastIssuedMs: Int64 = 0

    /// Strictly monotonic "now" stamp: if the wall clock hasn't advanced past
    /// the last issued millisecond (or stepped backwards), bump by 1ms.
    public static func nowISO() -> String {
        isoFromMs(issueMs(floorMs: 0))
    }

    /// Commit-time stamp for an op appended under the ops flock: strictly
    /// greater than BOTH every stamp this process has issued AND the newest
    /// ts already committed to the feed. In-process monotonicity alone is not
    /// enough at the commit point — a stamp minted at op construction can
    /// stall before the lock and commit BEHIND a later-issued notify stamp
    /// (evaluator then swallows the change), and a second writer process
    /// (e.g. chat-drive) shares the flock but not this process's monotonic
    /// state. Flooring on the committed feed makes commit order == timestamp
    /// order in both cases (Lamport-style: a corrupt far-future ts on disk
    /// would drag stamps forward, trading wall-clock accuracy for ordering).
    public static func commitStamp(notBefore lastCommitted: String?) -> String {
        var floorMs: Int64 = 0
        if let lastCommitted, let d = parseISO(lastCommitted) {
            floorMs = Int64((d.timeIntervalSince1970 * 1000.0).rounded())
        }
        return isoFromMs(issueMs(floorMs: floorMs))
    }

    private static func issueMs(floorMs: Int64) -> Int64 {
        let wallMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded(.down))
        monotonicLock.lock()
        let ms = max(wallMs, max(lastIssuedMs, floorMs) + 1)
        lastIssuedMs = ms
        monotonicLock.unlock()
        return ms
    }

    private static func isoFromMs(_ ms: Int64) -> String {
        // +0.1ms keeps Double representation error from ever landing the
        // reconstructed Date in the previous millisecond; DateFormatter
        // rounds at the half-millisecond so the output is exactly `ms`.
        nowISO(Date(timeIntervalSince1970: (Double(ms) + 0.1) / 1000.0))
    }

    /// Pure formatter for an explicit Date (tests, replay) — no monotonic
    /// bump. ISO-8601 UTC, microsecond precision — byte-identical format to
    /// TaskLedgerClock.nowISO so Desk timestamps sort lexicographically and
    /// align with the other Swift-native event feeds.
    public static func nowISO(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return f.string(from: date)
    }

    /// Parse an ISO-8601 timestamp produced by `nowISO`. Tolerant of both the
    /// microsecond `+00:00` form and a bare-seconds fallback.
    public static func parseISO(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// True when `s` parses as a calendar date — either a bare `yyyy-MM-dd` day
    /// stamp (the felt-salience / reservation day form) or a full ISO timestamp.
    /// Used by dossier structural validation: an unparseable date can't stand as
    /// evidence.
    public static func isParseableDate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        if day.date(from: t) != nil { return true }
        return parseISO(t) != nil
    }

    /// Collapse a parseable date/timestamp string to its `yyyy-MM-dd` UTC day, so
    /// distinct-DAY counting can't be fooled by two timestamps on one day or a
    /// bare day vs its midnight ISO form. nil for an unparseable string.
    public static func normalizedDay(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        if day.date(from: t) != nil { return t }   // already a bare UTC day
        if let d = parseISO(t) { return dayStamp(d) }
        return nil
    }

    /// Deterministic reservation id for a (handle, day, slot) triple — the same
    /// triple always yields the same id, so a replayed reserve op is idempotent
    /// and the caps count distinct reservations without a mutable counter. Slot
    /// is lowercased + non-alphanumerics collapsed to keep the id wire-clean.
    public static func reservationId(handle: String, day: String, slot: String) -> String {
        let bare = handle.hasPrefix("desk_") ? String(handle.dropFirst("desk_".count)) : handle
        func clean(_ s: String) -> String {
            String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        }
        return "wres_\(clean(bare))_\(clean(day))_\(clean(slot))"
    }

    public static func workAttemptId(handle: String, lane: DeskWorkAttempt.Lane, day: String, slot: String) -> String {
        "wattempt_\(lane.rawValue)_\(reservationId(handle: handle, day: day, slot: slot).dropFirst(5))"
    }

    /// The `yyyy-MM-dd` UTC day for a timestamp — the reservation/day bucket.
    public static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// New stable item handle.
    public static func newHandle() -> String { "desk_" + UUID().uuidString.lowercased() }
    /// New stable ref id (for in-place ref updates).
    public static func newRefId() -> String { "deskref_" + UUID().uuidString.lowercased() }
    /// New op id.
    public static func newOpId() -> String { "deskop_" + UUID().uuidString.lowercased() }
}

// MARK: - JSONValue read helpers (local — mirror TaskLedgerEvent.fromJSON idioms)

private func jsonString(_ obj: [String: JSONValue], _ key: String) -> String? {
    if case .string(let s)? = obj[key] { return s }
    return nil
}
private func jsonInt(_ obj: [String: JSONValue], _ key: String) -> Int? {
    if case .int(let i)? = obj[key] { return Int(i) }
    if case .string(let s)? = obj[key], let i = Int(s) { return i }
    return nil
}
private func jsonBool(_ obj: [String: JSONValue], _ key: String) -> Bool? {
    if case .bool(let b)? = obj[key] { return b }
    return nil
}
private func jsonStringArray(_ obj: [String: JSONValue], _ key: String) -> [String] {
    if case .array(let arr)? = obj[key] {
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
    return []
}

// MARK: - Ref (tagged union by `kind`, each carries a stable refId)

public enum DeskRefKind: Sendable, Equatable {
    case file(path: String, line: Int?, label: String?)
    case commit(sha: String, repo: String?, label: String?, status: String?)
    case ghIssue(repo: String, number: Int, title: String?, status: String?)
    case ghPr(repo: String, number: Int, title: String?, status: String?, checks: String?)
    case url(url: String, title: String?)
    case agent(name: String, handoffId: String?, sessionId: String?)
    case approval(id: String, status: String?)
    case trace(id: String, kind: String?)
    case note(text: String)

    /// Wire token written as the ref's `kind` field.
    public var token: String {
        switch self {
        case .file: return "file"
        case .commit: return "commit"
        case .ghIssue: return "gh_issue"
        case .ghPr: return "gh_pr"
        case .url: return "url"
        case .agent: return "agent"
        case .approval: return "approval"
        case .trace: return "trace"
        case .note: return "note"
        }
    }

    /// Live-render priority: gh_pr > gh_issue > file > commit > url > agent >
    /// approval > trace > note. LOWER number = higher priority (renders first).
    public var priority: Int {
        switch self {
        case .ghPr: return 0
        case .ghIssue: return 1
        case .file: return 2
        case .commit: return 3
        case .url: return 4
        case .agent: return 5
        case .approval: return 6
        case .trace: return 7
        case .note: return 8
        }
    }

    /// Merge a sparse `cachedFields` patch (from an `update_ref` op) into the
    /// in-place-updatable fields of this ref. Unknown / inapplicable keys are
    /// ignored; the immutable identity fields (path, sha, repo, number, url,
    /// name, id) are NOT overwritten.
    public func applyingCachedFields(_ fields: [String: JSONValue]) -> DeskRefKind {
        func str(_ k: String) -> String? { jsonString(fields, k) }
        func num(_ k: String) -> Int? { jsonInt(fields, k) }
        switch self {
        case let .file(path, line, label):
            return .file(path: path, line: num("line") ?? line, label: str("label") ?? label)
        case let .commit(sha, repo, label, status):
            // repo is part of identity (like sha) — NOT overwritten by a patch.
            return .commit(sha: sha, repo: repo, label: str("label") ?? label, status: str("status") ?? status)
        case let .ghIssue(repo, number, title, status):
            return .ghIssue(repo: repo, number: number, title: str("title") ?? title, status: str("status") ?? status)
        case let .ghPr(repo, number, title, status, checks):
            return .ghPr(repo: repo, number: number, title: str("title") ?? title, status: str("status") ?? status, checks: str("checks") ?? checks)
        case let .url(url, title):
            return .url(url: url, title: str("title") ?? title)
        case let .agent(name, handoffId, sessionId):
            return .agent(name: name, handoffId: str("handoffId") ?? handoffId, sessionId: str("sessionId") ?? sessionId)
        case let .approval(id, status):
            return .approval(id: id, status: str("status") ?? status)
        case let .trace(id, kind):
            // `traceKind` mirrors the wire key (the discriminator owns `kind`).
            return .trace(id: id, kind: str("traceKind") ?? kind)
        case let .note(text):
            return .note(text: str("text") ?? text)
        }
    }
}

public struct DeskRef: Sendable, Equatable {
    public var refId: String
    public var kind: DeskRefKind

    public init(refId: String = DeskClock.newRefId(), kind: DeskRefKind) {
        self.refId = refId
        self.kind = kind
    }

    public var priority: Int { kind.priority }

    /// Serialize to the wire form `{kind, refId, ...fields}`. Optional fields
    /// omitted when nil (NOT emitted as null), exactly like TaskLedgerEvent.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "kind": .string(kind.token),
            "refId": .string(refId),
        ]
        func put(_ k: String, _ v: String?) { if let v, !v.isEmpty { obj[k] = .string(v) } }
        func putInt(_ k: String, _ v: Int?) { if let v { obj[k] = .int(Int64(v)) } }
        switch kind {
        case let .file(path, line, label):
            obj["path"] = .string(path); putInt("line", line); put("label", label)
        case let .commit(sha, repo, label, status):
            obj["sha"] = .string(sha); put("repo", repo); put("label", label); put("status", status)
        case let .ghIssue(repo, number, title, status):
            obj["repo"] = .string(repo); obj["number"] = .int(Int64(number)); put("title", title); put("status", status)
        case let .ghPr(repo, number, title, status, checks):
            obj["repo"] = .string(repo); obj["number"] = .int(Int64(number)); put("title", title); put("status", status); put("checks", checks)
        case let .url(url, title):
            obj["url"] = .string(url); put("title", title)
        case let .agent(name, handoffId, sessionId):
            obj["name"] = .string(name); put("handoffId", handoffId); put("sessionId", sessionId)
        case let .approval(id, status):
            obj["id"] = .string(id); put("status", status)
        case let .trace(id, kind):
            // The trace payload's own "kind" is written under `traceKind` so it
            // never clobbers the union discriminator (`kind` == "trace").
            obj["id"] = .string(id); put("traceKind", kind)
        case let .note(text):
            obj["text"] = .string(text)
        }
        return .object(obj)
    }

    /// Tolerant decode. An unknown `kind` token → nil (skipped by the caller).
    public static func fromJSON(_ value: JSONValue) -> DeskRef? {
        guard case .object(let obj) = value,
              let token = jsonString(obj, "kind") else { return nil }
        // Deterministic fallback when `refId` is absent (legacy / hand-authored
        // line): an empty id, NEVER a fresh random UUID — a random one would
        // make each rebuild produce a different DeskState and drift state.json.
        let refId = jsonString(obj, "refId") ?? ""
        let kind: DeskRefKind
        switch token {
        case "file":
            guard let path = jsonString(obj, "path") else { return nil }
            kind = .file(path: path, line: jsonInt(obj, "line"), label: jsonString(obj, "label"))
        case "commit":
            guard let sha = jsonString(obj, "sha") else { return nil }
            kind = .commit(sha: sha, repo: jsonString(obj, "repo"), label: jsonString(obj, "label"), status: jsonString(obj, "status"))
        case "gh_issue":
            guard let repo = jsonString(obj, "repo"), let number = jsonInt(obj, "number") else { return nil }
            kind = .ghIssue(repo: repo, number: number, title: jsonString(obj, "title"), status: jsonString(obj, "status"))
        case "gh_pr":
            guard let repo = jsonString(obj, "repo"), let number = jsonInt(obj, "number") else { return nil }
            kind = .ghPr(repo: repo, number: number, title: jsonString(obj, "title"), status: jsonString(obj, "status"), checks: jsonString(obj, "checks"))
        case "url":
            guard let url = jsonString(obj, "url") else { return nil }
            kind = .url(url: url, title: jsonString(obj, "title"))
        case "agent":
            guard let name = jsonString(obj, "name") else { return nil }
            kind = .agent(name: name, handoffId: jsonString(obj, "handoffId"), sessionId: jsonString(obj, "sessionId"))
        case "approval":
            guard let id = jsonString(obj, "id") else { return nil }
            kind = .approval(id: id, status: jsonString(obj, "status"))
        case "trace":
            guard let id = jsonString(obj, "id") else { return nil }
            kind = .trace(id: id, kind: jsonString(obj, "traceKind"))
        case "note":
            guard let text = jsonString(obj, "text") else { return nil }
            kind = .note(text: text)
        default:
            return nil // tolerant: unknown ref kinds skipped
        }
        return DeskRef(refId: refId, kind: kind)
    }
}

// MARK: - Cadence / NotifyPolicy / Note

public struct Cadence: Sendable, Equatable {
    public var mode: CadenceMode
    public var interval: String?
    public var nextRefreshAt: String?
    public var lastRefreshAt: String?
    public var staleAfter: String?
    public var refreshSources: [String]

    public init(
        mode: CadenceMode = .on_ask,
        interval: String? = nil,
        nextRefreshAt: String? = nil,
        lastRefreshAt: String? = nil,
        staleAfter: String? = nil,
        refreshSources: [String] = []
    ) {
        self.mode = mode
        self.interval = interval
        self.nextRefreshAt = nextRefreshAt
        self.lastRefreshAt = lastRefreshAt
        self.staleAfter = staleAfter
        self.refreshSources = refreshSources
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["mode": .string(mode.rawValue)]
        if let interval, !interval.isEmpty { obj["interval"] = .string(interval) }
        if let nextRefreshAt, !nextRefreshAt.isEmpty { obj["nextRefreshAt"] = .string(nextRefreshAt) }
        if let lastRefreshAt, !lastRefreshAt.isEmpty { obj["lastRefreshAt"] = .string(lastRefreshAt) }
        if let staleAfter, !staleAfter.isEmpty { obj["staleAfter"] = .string(staleAfter) }
        if !refreshSources.isEmpty { obj["refreshSources"] = .array(refreshSources.map { .string($0) }) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> Cadence {
        guard case .object(let obj) = value else { return Cadence() }
        let mode = jsonString(obj, "mode").flatMap { CadenceMode(rawValue: $0) } ?? .on_ask
        return Cadence(
            mode: mode,
            interval: jsonString(obj, "interval"),
            nextRefreshAt: jsonString(obj, "nextRefreshAt"),
            lastRefreshAt: jsonString(obj, "lastRefreshAt"),
            staleAfter: jsonString(obj, "staleAfter"),
            refreshSources: jsonStringArray(obj, "refreshSources")
        )
    }
}

public struct NotifyPolicy: Sendable, Equatable {
    public var level: NotifyLevel
    public var on: [String]               // state_change, user_next, blocked, unblocked, big_diff, due, explicit
    public var cooldown: String?
    public var lastNotifiedAt: String?
    public var notifyReason: String?

    public init(
        level: NotifyLevel = .quiet,
        on: [String] = [],
        cooldown: String? = nil,
        lastNotifiedAt: String? = nil,
        notifyReason: String? = nil
    ) {
        self.level = level
        self.on = on
        self.cooldown = cooldown
        self.lastNotifiedAt = lastNotifiedAt
        self.notifyReason = notifyReason
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["level": .string(level.rawValue)]
        if !on.isEmpty { obj["on"] = .array(on.map { .string($0) }) }
        if let cooldown, !cooldown.isEmpty { obj["cooldown"] = .string(cooldown) }
        if let lastNotifiedAt, !lastNotifiedAt.isEmpty { obj["lastNotifiedAt"] = .string(lastNotifiedAt) }
        if let notifyReason, !notifyReason.isEmpty { obj["notifyReason"] = .string(notifyReason) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> NotifyPolicy {
        guard case .object(let obj) = value else { return NotifyPolicy() }
        let level = jsonString(obj, "level").flatMap { NotifyLevel(rawValue: $0) } ?? .quiet
        return NotifyPolicy(
            level: level,
            on: jsonStringArray(obj, "on"),
            cooldown: jsonString(obj, "cooldown"),
            lastNotifiedAt: jsonString(obj, "lastNotifiedAt"),
            notifyReason: jsonString(obj, "notifyReason")
        )
    }
}

public struct DeskNote: Sendable, Equatable {
    public var ts: String
    public var text: String

    public init(ts: String, text: String) {
        self.ts = ts
        self.text = text
    }

    public func toJSON() -> JSONValue {
        .object(["ts": .string(ts), "text": .string(text)])
    }

    public static func fromJSON(_ value: JSONValue) -> DeskNote? {
        guard case .object(let obj) = value,
              let ts = jsonString(obj, "ts"),
              let text = jsonString(obj, "text") else { return nil }
        return DeskNote(ts: ts, text: text)
    }
}

// MARK: - PromotionDossier (typed evidence for an Agent pursuit)
//
// M7 (evidence laundering): a pursuit is unrepresentable without cited evidence.
// Citations are TYPED — free-string refs can't smuggle a pursuit past the gate.
// Wave A validates STRUCTURE (ids non-empty, dates parseable, counts positive)
// and the SOURCE-MIX rule (friction alone is insufficient); resolution against
// the live standing-view / dream-digest / trace stores is Wave C's job. The type
// makes an uncited or friction-only pursuit impossible to construct at WRITE
// time — the REM evidence-date precedent (recurrence across ≥2 dates), lifted
// into the Desk.

/// One typed evidence citation. `traceFriction` is the ONLY friction source and
/// never qualifies a pursuit by itself (source-mix rule).
public enum DossierSource: Sendable, Equatable {
    case standingView(id: String)
    case dreamDigest(id: String)
    case openQuestionSeed(id: String)
    case feltSalience(dates: [String])
    case chatObservation(noteIds: [String], distinctDays: Int)
    case traceFriction(count: Int, window: String)

    /// Wire token written as the citation's `source` field.
    public var token: String {
        switch self {
        case .standingView: return "standing_view"
        case .dreamDigest: return "dream_digest"
        case .openQuestionSeed: return "open_question_seed"
        case .feltSalience: return "felt_salience"
        case .chatObservation: return "chat_observation"
        case .traceFriction: return "trace_friction"
        }
    }

    /// friction is the low-weight source the mix rule caps — see `isFriction`.
    public var isFriction: Bool { if case .traceFriction = self { return true } else { return false } }

    /// Structural validity of THIS citation in isolation. Returns a human reason
    /// on failure (ids non-empty, dates parseable + recurrent, counts positive).
    public func structuralError() -> String? {
        switch self {
        case .standingView(let id), .dreamDigest(let id), .openQuestionSeed(let id):
            return id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(token): id is empty" : nil
        case .feltSalience(let dates):
            let clean = dates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard clean.allSatisfy({ DeskClock.isParseableDate($0) }) else { return "felt_salience: an entry is not a parseable date (yyyy-MM-dd)" }
            // Recurrence across ≥2 distinct CALENDAR DAYS — normalize first, so
            // "2026-07-08" and "2026-07-08T00:00:00+00:00" (or two timestamps on
            // one day) can't masquerade as two days (2026-07-11 review MED).
            return Set(clean.compactMap { DeskClock.normalizedDay($0) }).count >= 2 ? nil : "felt_salience: needs ≥2 distinct calendar days"
        case .chatObservation(let noteIds, let distinctDays):
            let clean = noteIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !clean.isEmpty else { return "chat_observation: noteIds is empty" }
            // distinctDays is a CLAIM; it can't exceed the number of cited notes,
            // and ≥2 days needs ≥2 notes — so one self-authored note can't forge
            // "recurred across days" (2026-07-11 review MED).
            guard distinctDays >= 2 else { return "chat_observation: needs distinctDays ≥ 2" }
            return clean.count >= distinctDays ? nil : "chat_observation: distinctDays (\(distinctDays)) exceeds cited notes (\(clean.count))"
        case .traceFriction(let count, let window):
            guard count > 0 else { return "trace_friction: count must be positive" }
            let w = window.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { return "trace_friction: window is empty" }
            // A positive duration like "7d" / "24h" / "30m" — not "-7d"/"garbage"
            // (2026-07-11 review LOW). Digits followed by a unit, no leading sign.
            let ok = w.range(of: #"^[0-9]+[smhdw]$"#, options: .regularExpression) != nil
            return ok ? nil : "trace_friction: window must be a positive duration (e.g. 7d, 24h)"
        }
    }

    public func toJSON() -> JSONValue {
        switch self {
        case .standingView(let id):
            return .object(["source": .string(token), "id": .string(id)])
        case .dreamDigest(let id):
            return .object(["source": .string(token), "id": .string(id)])
        case .openQuestionSeed(let id):
            return .object(["source": .string(token), "id": .string(id)])
        case .feltSalience(let dates):
            return .object(["source": .string(token), "dates": .array(dates.map { .string($0) })])
        case .chatObservation(let noteIds, let distinctDays):
            return .object([
                "source": .string(token),
                "noteIds": .array(noteIds.map { .string($0) }),
                "distinctDays": .int(Int64(distinctDays)),
            ])
        case .traceFriction(let count, let window):
            return .object(["source": .string(token), "count": .int(Int64(count)), "window": .string(window)])
        }
    }

    /// Tolerant decode — an unknown `source` token → nil (skipped by the caller,
    /// exactly like DeskRef). A dropped citation can only WEAKEN a dossier, never
    /// strengthen it, so tolerance can't launder evidence.
    public static func fromJSON(_ value: JSONValue) -> DossierSource? {
        guard case .object(let obj) = value, let token = jsonString(obj, "source") else { return nil }
        switch token {
        case "standing_view":
            guard let id = jsonString(obj, "id") else { return nil }
            return .standingView(id: id)
        case "dream_digest":
            guard let id = jsonString(obj, "id") else { return nil }
            return .dreamDigest(id: id)
        case "open_question_seed":
            guard let id = jsonString(obj, "id") else { return nil }
            return .openQuestionSeed(id: id)
        case "felt_salience":
            return .feltSalience(dates: jsonStringArray(obj, "dates"))
        case "chat_observation":
            return .chatObservation(noteIds: jsonStringArray(obj, "noteIds"), distinctDays: jsonInt(obj, "distinctDays") ?? 0)
        case "trace_friction":
            guard let window = jsonString(obj, "window") else { return nil }
            return .traceFriction(count: jsonInt(obj, "count") ?? 0, window: window)
        default:
            return nil
        }
    }
}

public struct PromotionDossier: Sendable, Equatable {
    public var citations: [DossierSource]

    public init(citations: [DossierSource]) { self.citations = citations }

    /// The single gate a pursuit's evidence must pass at WRITE time. Returns a
    /// human reason on the first failure, or nil when the dossier is admissible:
    ///   1. at least one citation;
    ///   2. every citation structurally valid (ids/dates/counts);
    ///   3. SOURCE-MIX: at least one NON-friction source (friction alone caps out).
    public func validationError() -> String? {
        guard !citations.isEmpty else { return "dossier: no citations — a pursuit needs cited evidence" }
        for c in citations { if let e = c.structuralError() { return e } }
        guard citations.contains(where: { !$0.isFriction }) else {
            return "dossier: trace-friction alone is insufficient — needs at least one non-friction source"
        }
        return nil
    }

    public var isValid: Bool { validationError() == nil }

    public func toJSON() -> JSONValue {
        .object(["citations": .array(citations.map { $0.toJSON() })])
    }

    public static func fromJSON(_ value: JSONValue) -> PromotionDossier {
        guard case .object(let obj) = value, case .array(let arr)? = obj["citations"] else {
            return PromotionDossier(citations: [])
        }
        return PromotionDossier(citations: arr.compactMap { DossierSource.fromJSON($0) })
    }
}

// MARK: - WorkReservation (one durable work-session slot on a pursuit)
//
// Wave B's pump RESERVES a slot before spending any planner tokens (H3/H5); the
// reservation is the unforgeable admission token. Reservations are IDEMPOTENT
// per (handle, day, slot): the id is derived deterministically from that triple,
// so a replayed reserve op folds to the SAME row — the compact dedups by id and
// the caps count DISTINCT reservations from the ops feed, never a mutable
// counter that could drift.

public enum DeskWorkDisposition: String, Sendable, Equatable {
    case progress
    case goalSatisfied = "goal_satisfied"
    case blocked
    case abandon
}

public struct WorkReservation: Sendable, Equatable {
    public var reservationId: String
    public var day: String            // "yyyy-MM-dd"
    public var slot: String
    public var reservedAt: String
    public var receipt: String?       // set by completeWorkSession
    public var completedAt: String?
    public var disposition: DeskWorkDisposition?
    /// Handle-relative Workshop artifacts only. These are durable references,
    /// never copied into Memory or Fluid Context and never auto-injected.
    public var artifactRefs: [String]

    public init(reservationId: String, day: String, slot: String, reservedAt: String, receipt: String? = nil, completedAt: String? = nil, disposition: DeskWorkDisposition? = nil, artifactRefs: [String] = []) {
        self.reservationId = reservationId
        self.day = day
        self.slot = slot
        self.reservedAt = reservedAt
        self.receipt = receipt
        self.completedAt = completedAt
        self.disposition = disposition
        self.artifactRefs = artifactRefs
    }

    public var isCompleted: Bool { completedAt != nil }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "reservationId": .string(reservationId),
            "day": .string(day),
            "slot": .string(slot),
            "reservedAt": .string(reservedAt),
        ]
        if let receipt, !receipt.isEmpty { obj["receipt"] = .string(receipt) }
        if let completedAt, !completedAt.isEmpty { obj["completedAt"] = .string(completedAt) }
        if let disposition { obj["disposition"] = .string(disposition.rawValue) }
        if !artifactRefs.isEmpty { obj["artifactRefs"] = .array(artifactRefs.map(JSONValue.string)) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> WorkReservation? {
        guard case .object(let obj) = value,
              let reservationId = jsonString(obj, "reservationId"),
              let day = jsonString(obj, "day"),
              let slot = jsonString(obj, "slot"),
              let reservedAt = jsonString(obj, "reservedAt") else { return nil }
        return WorkReservation(
            reservationId: reservationId, day: day, slot: slot, reservedAt: reservedAt,
            receipt: jsonString(obj, "receipt"), completedAt: jsonString(obj, "completedAt"),
            disposition: jsonString(obj, "disposition").flatMap(DeskWorkDisposition.init(rawValue:)),
            artifactRefs: jsonStringArray(obj, "artifactRefs")
        )
    }
}

/// A typed execution attempt owned directly by a Desk item. Pursuit
/// reservations keep their existing compatibility ledger; ordinary owner
/// cadence work uses this sibling ledger so it can be admitted and settled
/// without pretending the owner's task is a self-authored pursuit.
public struct DeskWorkAttempt: Sendable, Equatable {
    public enum Lane: String, Sendable, Equatable {
        case ownerCadence = "owner_cadence"
    }

    public var attemptId: String
    public var lane: Lane
    public var day: String
    public var slot: String
    public var reservedAt: String
    public var receipt: String?
    public var completedAt: String?

    public init(
        attemptId: String,
        lane: Lane,
        day: String,
        slot: String,
        reservedAt: String,
        receipt: String? = nil,
        completedAt: String? = nil
    ) {
        self.attemptId = attemptId
        self.lane = lane
        self.day = day
        self.slot = slot
        self.reservedAt = reservedAt
        self.receipt = receipt
        self.completedAt = completedAt
    }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "attemptId": .string(attemptId),
            "lane": .string(lane.rawValue),
            "day": .string(day),
            "slot": .string(slot),
            "reservedAt": .string(reservedAt),
        ]
        if let receipt, !receipt.isEmpty { object["receipt"] = .string(receipt) }
        if let completedAt, !completedAt.isEmpty { object["completedAt"] = .string(completedAt) }
        return .object(object)
    }

    public static func fromJSON(_ value: JSONValue) -> DeskWorkAttempt? {
        guard case .object(let object) = value,
              let attemptId = jsonString(object, "attemptId"),
              let laneRaw = jsonString(object, "lane"),
              let lane = Lane(rawValue: laneRaw),
              let day = jsonString(object, "day"),
              let slot = jsonString(object, "slot"),
              let reservedAt = jsonString(object, "reservedAt") else { return nil }
        return DeskWorkAttempt(
            attemptId: attemptId,
            lane: lane,
            day: day,
            slot: slot,
            reservedAt: reservedAt,
            receipt: jsonString(object, "receipt"),
            completedAt: jsonString(object, "completedAt")
        )
    }
}

// MARK: - Pursuit (the origin=agent, kind=project payload — carried on create)
//
// All REQUIRED fields (why/evidence/doneLooksLike/abandonCondition) ride the
// create_item op payload (M10) so a pursuit is fully evidenced the moment it
// exists; the store REFUSES a create missing any of them. maxSessions/maxDays
// bound the pursuit ("unbounded pursuits are theater") — defaulted and capped.
// The reservation ledger + workSessionsToday/lastWorkedAt are the work-session
// seam Wave B drives; they start empty/zero at create and only ops move them.

public struct Pursuit: Sendable, Equatable {
    public static let defaultMaxSessions = 12
    public static let maxMaxSessions = 24
    public static let defaultMaxDays = 10
    public static let maxMaxDays = 21

    public var why: String                 // first-person, required
    public var evidence: PromotionDossier   // required, source-mix enforced
    public var doneLooksLike: String        // required
    public var maxSessions: Int             // default 12, cap 24
    public var maxDays: Int                 // default 10, cap 21
    public var abandonCondition: String     // required
    public var privateName: String?         // hers, optional
    public var workSessionsToday: Int        // derived from the reservation ledger
    public var lastWorkedAt: String?
    public var reservations: [WorkReservation]

    public init(
        why: String,
        evidence: PromotionDossier,
        doneLooksLike: String,
        maxSessions: Int = Pursuit.defaultMaxSessions,
        maxDays: Int = Pursuit.defaultMaxDays,
        abandonCondition: String,
        privateName: String? = nil,
        workSessionsToday: Int = 0,
        lastWorkedAt: String? = nil,
        reservations: [WorkReservation] = []
    ) {
        self.why = why
        self.evidence = evidence
        self.doneLooksLike = doneLooksLike
        // Clamp to [1, cap] — a create can only tighten the bound, never lift it.
        self.maxSessions = max(1, min(maxSessions, Pursuit.maxMaxSessions))
        self.maxDays = max(1, min(maxDays, Pursuit.maxMaxDays))
        self.abandonCondition = abandonCondition
        self.privateName = privateName
        self.workSessionsToday = workSessionsToday
        self.lastWorkedAt = lastWorkedAt
        self.reservations = reservations
    }

    /// The required-field gate (structural). Trimmed-empty required strings are
    /// refused; evidence must pass the dossier gate. Returns a human reason or
    /// nil. Enforced at WRITE time only (M10).
    public func validationError() -> String? {
        if why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "pursuit: 'why' is required" }
        if doneLooksLike.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "pursuit: 'doneLooksLike' is required" }
        if abandonCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "pursuit: 'abandonCondition' is required" }
        if let e = evidence.validationError() { return e }
        return nil
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "why": .string(why),
            "evidence": evidence.toJSON(),
            "doneLooksLike": .string(doneLooksLike),
            "maxSessions": .int(Int64(maxSessions)),
            "maxDays": .int(Int64(maxDays)),
            "abandonCondition": .string(abandonCondition),
            "workSessionsToday": .int(Int64(workSessionsToday)),
        ]
        if let privateName, !privateName.isEmpty { obj["privateName"] = .string(privateName) }
        if let lastWorkedAt, !lastWorkedAt.isEmpty { obj["lastWorkedAt"] = .string(lastWorkedAt) }
        if !reservations.isEmpty { obj["reservations"] = .array(reservations.map { $0.toJSON() }) }
        return .object(obj)
    }

    /// Decode a pursuit from a create-op payload or a state.json row. Missing
    /// required fields decode to empty strings so the store's WRITE-time gate
    /// (validationError) is the single refusal point — decode stays tolerant.
    public static func fromJSON(_ value: JSONValue) -> Pursuit {
        guard case .object(let obj) = value else {
            return Pursuit(why: "", evidence: PromotionDossier(citations: []), doneLooksLike: "", abandonCondition: "")
        }
        var reservations: [WorkReservation] = []
        if case .array(let arr)? = obj["reservations"] { reservations = arr.compactMap { WorkReservation.fromJSON($0) } }
        return Pursuit(
            why: jsonString(obj, "why") ?? "",
            evidence: obj["evidence"].map { PromotionDossier.fromJSON($0) } ?? PromotionDossier(citations: []),
            doneLooksLike: jsonString(obj, "doneLooksLike") ?? "",
            maxSessions: jsonInt(obj, "maxSessions") ?? Pursuit.defaultMaxSessions,
            maxDays: jsonInt(obj, "maxDays") ?? Pursuit.defaultMaxDays,
            abandonCondition: jsonString(obj, "abandonCondition") ?? "",
            privateName: jsonString(obj, "privateName"),
            workSessionsToday: jsonInt(obj, "workSessionsToday") ?? 0,
            lastWorkedAt: jsonString(obj, "lastWorkedAt"),
            reservations: reservations
        )
    }
}

// MARK: - Item (a derived row — never serialized as a mutation, only state.json)

public struct DeskItem: Sendable, Equatable {
    public var handle: String           // stable
    public var alias: String            // view number "2" / "2.1" — stable, never renumbered
    public var parent: String?
    public var kind: DeskKind
    public var status: DeskStatus
    public var project: String
    public var title: String
    public var summary: String?
    public var refs: [DeskRef]
    public var cadence: Cadence
    public var notify: NotifyPolicy
    public var notes: [DeskNote]
    public var openedAt: String
    public var updatedAt: String
    public var closedAt: String?
    public var pinned: Bool
    public var blockedReason: String?
    public var waitingOn: String?
    /// Stable handles of the items that block this one. The SEQUENCING edge set
    /// (Agent's #1): prose in `blockedReason` rots, an edge self-clears when the
    /// blocker closes. Blockedness itself is DERIVED on every read
    /// (`DeskSequencing`) — never stored — so a blocker closing auto-unblocks
    /// its dependents with no writer running and no op to fire.
    public var blockedOn: [String]
    /// `yyyy-MM-dd` day or full ISO stamp this item is deliberately parked
    /// until. A deferred item is not ready AND is never flagged stale
    /// (Agent's #3 — half her "stale" items are parked on purpose).
    public var deferUntil: String?
    public var origin: DeskOrigin       // immutable after create; default .owner
    public var pursuit: Pursuit?        // present only for origin=agent, kind=project
    /// Direct Desk-owned execution attempts for non-pursuit lanes.
    public var workAttempts: [DeskWorkAttempt]

    /// True for a store-recognized pursuit: self-authored project. The
    /// work-session ops and the open-pursuit cap key on exactly this shape.
    public var isPursuit: Bool { origin == .agent && kind == .project && pursuit != nil }

    /// True only when canonical Desk state explicitly names the human owner as
    /// the party that must unblock a nonterminal item. A generic `blocked`
    /// status is not enough: verification failures, unavailable external
    /// systems, and domain-owned reconciliation can all be blocked without
    /// requiring user action.
    public var requiresOwnerInput: Bool {
        guard !status.isTerminal,
              let waiting = waitingOn?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !waiting.isEmpty else {
            return false
        }
        return waiting == "owner" || waiting == "user" || waiting == "human"
    }

    public init(
        handle: String,
        alias: String,
        parent: String? = nil,
        kind: DeskKind,
        status: DeskStatus = .watch,
        project: String,
        title: String,
        summary: String? = nil,
        refs: [DeskRef] = [],
        cadence: Cadence = Cadence(),
        notify: NotifyPolicy = NotifyPolicy(),
        notes: [DeskNote] = [],
        openedAt: String,
        updatedAt: String,
        closedAt: String? = nil,
        pinned: Bool = false,
        blockedReason: String? = nil,
        waitingOn: String? = nil,
        origin: DeskOrigin = .owner,
        pursuit: Pursuit? = nil,
        blockedOn: [String] = [],
        deferUntil: String? = nil,
        workAttempts: [DeskWorkAttempt] = []
    ) {
        self.handle = handle
        self.alias = alias
        self.parent = parent
        self.kind = kind
        self.status = status
        self.project = project
        self.title = title
        self.summary = summary
        self.refs = refs
        self.cadence = cadence
        self.notify = notify
        self.notes = notes
        self.openedAt = openedAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.pinned = pinned
        self.blockedReason = blockedReason
        self.waitingOn = waitingOn
        self.origin = origin
        self.pursuit = pursuit
        self.blockedOn = blockedOn
        self.deferUntil = deferUntil
        self.workAttempts = workAttempts
    }

    /// Live refs in render priority order (gh_pr > gh_issue > … > note), capped.
    public func liveRefs(limit: Int = 3) -> [DeskRef] {
        Array(refs.sorted { $0.priority < $1.priority }.prefix(limit))
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "handle": .string(handle),
            "alias": .string(alias),
            "kind": .string(kind.rawValue),
            "status": .string(status.rawValue),
            "project": .string(project),
            "title": .string(title),
            "cadence": cadence.toJSON(),
            "notify": notify.toJSON(),
            "openedAt": .string(openedAt),
            "updatedAt": .string(updatedAt),
            "pinned": .bool(pinned),
        ]
        if let parent, !parent.isEmpty { obj["parent"] = .string(parent) }
        if let summary, !summary.isEmpty { obj["summary"] = .string(summary) }
        if !refs.isEmpty { obj["refs"] = .array(refs.map { $0.toJSON() }) }
        if !notes.isEmpty { obj["notes"] = .array(notes.map { $0.toJSON() }) }
        if let closedAt, !closedAt.isEmpty { obj["closedAt"] = .string(closedAt) }
        if let blockedReason, !blockedReason.isEmpty { obj["blockedReason"] = .string(blockedReason) }
        if let waitingOn, !waitingOn.isEmpty { obj["waitingOn"] = .string(waitingOn) }
        // M10 again: both sequencing fields are OMITTED at their default, so a
        // pre-wave row round-trips BYTE-IDENTICAL and the compaction base's
        // shape gate (deskJSONShapeMatches) sees no new keys.
        if !blockedOn.isEmpty { obj["blockedOn"] = .array(blockedOn.map { .string($0) }) }
        if let deferUntil, !deferUntil.isEmpty { obj["deferUntil"] = .string(deferUntil) }
        // origin OMITTED when the neutral default — a pre-origin state.json row
        // round-trips byte-identical (M10). pursuit emitted only when present.
        if origin != .owner { obj["origin"] = .string(origin.rawValue) }
        if let pursuit { obj["pursuit"] = pursuit.toJSON() }
        if !workAttempts.isEmpty { obj["workAttempts"] = .array(workAttempts.map { $0.toJSON() }) }
        return .object(obj)
    }

    /// Tolerant by default (unknown ref kinds / malformed rows are skipped —
    /// forward compat for state.json readers). `strictCollections: true` is
    /// the COMPACTION-BASE mode: a base row whose refs/notes/reservations/
    /// citations partially decode must fail the whole decode — after the
    /// op-log truncate the base is the only copy, and a silently dropped
    /// reservation row would shrink the work-session cap ledger (gpt-5.5
    /// compaction review MED).
    public static func fromJSON(_ value: JSONValue, strictCollections: Bool = false) -> DeskItem? {
        guard case .object(let obj) = value,
              let handle = jsonString(obj, "handle"),
              let alias = jsonString(obj, "alias"),
              let kindRaw = jsonString(obj, "kind"), let kind = DeskKind(rawValue: kindRaw),
              let statusRaw = jsonString(obj, "status"), let status = DeskStatus(rawValue: statusRaw),
              let project = jsonString(obj, "project"),
              let title = jsonString(obj, "title"),
              let openedAt = jsonString(obj, "openedAt"),
              let updatedAt = jsonString(obj, "updatedAt") else { return nil }
        var refs: [DeskRef] = []
        if case .array(let arr)? = obj["refs"] {
            refs = arr.compactMap { DeskRef.fromJSON($0) }
            if strictCollections, refs.count != arr.count { return nil }
        } else if strictCollections, obj["refs"] != nil {
            return nil   // present but not an array — corrupt, never "empty"
        }
        var notes: [DeskNote] = []
        if case .array(let arr)? = obj["notes"] {
            notes = arr.compactMap { DeskNote.fromJSON($0) }
            if strictCollections, notes.count != arr.count { return nil }
        } else if strictCollections, obj["notes"] != nil {
            return nil   // present but not an array — corrupt, never "empty"
        }
        // blockedOn: same strict rule as refs/notes/reservations. In the
        // compaction base this snapshot is the ONLY copy — a silently-dropped
        // blocker edge would vanish a dependency FOREVER, and the item would
        // read as ready when it is not.
        var blockedOn: [String] = []
        if case .array(let arr)? = obj["blockedOn"] {
            blockedOn = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            if strictCollections, blockedOn.count != arr.count { return nil }
        } else if strictCollections, obj["blockedOn"] != nil {
            return nil   // present but not an array — corrupt, never "empty"
        }
        var workAttempts: [DeskWorkAttempt] = []
        if case .array(let rows)? = obj["workAttempts"] {
            workAttempts = rows.compactMap { DeskWorkAttempt.fromJSON($0) }
            if strictCollections, workAttempts.count != rows.count { return nil }
        } else if strictCollections, obj["workAttempts"] != nil {
            return nil
        }
        if strictCollections, let pursuitValue = obj["pursuit"] {
            // A present pursuit must be an OBJECT, and every nested ledger
            // collection that is present must be a fully-decodable array —
            // a wrong-typed value decoding to empty/default would silently
            // shrink the reservation cap ledger or the dossier.
            guard case .object(let pursuitObj) = pursuitValue else { return nil }
            let decoded = Pursuit.fromJSON(pursuitValue)
            if let reservationsValue = pursuitObj["reservations"] {
                guard case .array(let rows) = reservationsValue,
                      decoded.reservations.count == rows.count else { return nil }
            }
            if let evidenceValue = pursuitObj["evidence"] {
                guard case .object(let evidenceObj) = evidenceValue else { return nil }
                if let citationsValue = evidenceObj["citations"] {
                    guard case .array(let citationRows) = citationsValue,
                          decoded.evidence.citations.count == citationRows.count else { return nil }
                }
            }
        }
        return DeskItem(
            handle: handle, alias: alias, parent: jsonString(obj, "parent"),
            kind: kind, status: status, project: project, title: title,
            summary: jsonString(obj, "summary"), refs: refs,
            cadence: obj["cadence"].map { Cadence.fromJSON($0) } ?? Cadence(),
            notify: obj["notify"].map { NotifyPolicy.fromJSON($0) } ?? NotifyPolicy(),
            notes: notes, openedAt: openedAt, updatedAt: updatedAt,
            closedAt: jsonString(obj, "closedAt"),
            pinned: jsonBool(obj, "pinned") ?? false,
            blockedReason: jsonString(obj, "blockedReason"),
            waitingOn: jsonString(obj, "waitingOn"),
            // M10: origin decodes OPTIONAL defaulting .owner; pursuit optional.
            origin: jsonString(obj, "origin").flatMap(DeskOrigin.decodePersisted) ?? .owner,
            pursuit: obj["pursuit"].map { Pursuit.fromJSON($0) },
            blockedOn: blockedOn,
            deferUntil: jsonString(obj, "deferUntil"),
            workAttempts: workAttempts
        )
    }
}

// MARK: - ArchiveRecord (append-only archived item record)

public struct ArchiveRecord: Sendable, Equatable {
    public var handle: String
    public var title: String
    public var project: String
    public var finalStatus: ArchiveFinalStatus
    public var openedAt: String
    public var closedAt: String
    public var summary: String
    public var refs: [DeskRef]              // final important only
    public var decisions: [String]
    public var artifacts: [String]
    public var supersededBy: String?

    public init(
        handle: String, title: String, project: String,
        finalStatus: ArchiveFinalStatus, openedAt: String, closedAt: String,
        summary: String, refs: [DeskRef] = [], decisions: [String] = [],
        artifacts: [String] = [], supersededBy: String? = nil
    ) {
        self.handle = handle
        self.title = title
        self.project = project
        self.finalStatus = finalStatus
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.summary = summary
        self.refs = refs
        self.decisions = decisions
        self.artifacts = artifacts
        self.supersededBy = supersededBy
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "handle": .string(handle),
            "title": .string(title),
            "project": .string(project),
            "finalStatus": .string(finalStatus.rawValue),
            "openedAt": .string(openedAt),
            "closedAt": .string(closedAt),
            "summary": .string(summary),
        ]
        if !refs.isEmpty { obj["refs"] = .array(refs.map { $0.toJSON() }) }
        if !decisions.isEmpty { obj["decisions"] = .array(decisions.map { .string($0) }) }
        if !artifacts.isEmpty { obj["artifacts"] = .array(artifacts.map { .string($0) }) }
        if let supersededBy, !supersededBy.isEmpty { obj["supersededBy"] = .string(supersededBy) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> ArchiveRecord? {
        guard case .object(let obj) = value,
              let handle = jsonString(obj, "handle"),
              let title = jsonString(obj, "title"),
              let project = jsonString(obj, "project"),
              let finalRaw = jsonString(obj, "finalStatus"),
              let finalStatus = ArchiveFinalStatus(rawValue: finalRaw),
              let openedAt = jsonString(obj, "openedAt"),
              let closedAt = jsonString(obj, "closedAt"),
              let summary = jsonString(obj, "summary") else { return nil }
        var refs: [DeskRef] = []
        if case .array(let arr)? = obj["refs"] { refs = arr.compactMap { DeskRef.fromJSON($0) } }
        return ArchiveRecord(
            handle: handle, title: title, project: project, finalStatus: finalStatus,
            openedAt: openedAt, closedAt: closedAt, summary: summary, refs: refs,
            decisions: jsonStringArray(obj, "decisions"),
            artifacts: jsonStringArray(obj, "artifacts"),
            supersededBy: jsonString(obj, "supersededBy")
        )
    }
}

// MARK: - Ops (DeskOp) — one event each; compact() folds into DeskState

/// The mutation payload. Every op also carries a `handle` (the item it targets,
/// or — for create — the newly assigned handle). Tolerant decode: an unknown
/// `op` token yields nil and is skipped by the rebuild.
public enum DeskOpBody: Sendable, Equatable {
    case createItem(alias: String, kind: DeskKind, project: String, title: String, parent: String?, summary: String?, origin: DeskOrigin, pursuit: Pursuit?)
    /// Agent self-pursuit creation under a DEDICATED op token (H2, 2026-07-11
    /// review). A pre-Workshop binary sharing the ops flock decodes an unknown
    /// token to nil and SKIPS it — so an old writer can never see a pursuit as
    /// an ordinary user project, mutate it past the cap, or drop its fields on
    /// reserialize. origin is implicitly .agent, kind implicitly .project.
    case openPursuit(alias: String, project: String, title: String, summary: String?, pursuit: Pursuit, notify: NotifyPolicy)
    case setStatus(status: DeskStatus, blockedReason: String?, waitingOn: String?)
    case updateTitle(title: String?, summary: String?)
    case addRef(ref: DeskRef)
    case updateRef(refId: String, cachedFields: [String: JSONValue])
    case appendNote(text: String)
    case setCadence(cadence: Cadence)
    case setNotify(policy: NotifyPolicy)
    case closeItem(outcomeSummary: String, status: DeskStatus)   // status ∈ {done, canceled}
    case markNotified(at: String)   // notify fired — stamps notify.lastNotifiedAt, NOT updatedAt
    case archiveItem
    // Workshop work-session seam (Wave B drives these; Wave A designs them).
    case reserveWorkSession(reservationId: String, day: String, slot: String)
    case completeWorkSession(reservationId: String, receipt: String)
    case settleWorkSession(reservationId: String, receipt: String, disposition: DeskWorkDisposition, artifactRefs: [String])
    case reserveWorkAttempt(attemptId: String, lane: DeskWorkAttempt.Lane, day: String, slot: String)
    case completeWorkAttempt(attemptId: String, receipt: String)
    case workLog(receipt: String)   // desk_work_log — a plain work receipt note
    // Sequencing seam. Both REPLACE (never merge) so the op is the whole truth
    // of the field at that point in the feed.
    case setBlockedOn(handles: [String])   // replaces the WHOLE blocker set
    case setDeferUntil(until: String?)     // nil / "" CLEARS the parked date

    public var token: String {
        switch self {
        case .createItem: return "create_item"
        case .openPursuit: return "open_pursuit"
        case .setStatus: return "set_status"
        case .updateTitle: return "update_title"
        case .addRef: return "add_ref"
        case .updateRef: return "update_ref"
        case .appendNote: return "append_note"
        case .setCadence: return "set_cadence"
        case .setNotify: return "set_notify"
        case .closeItem: return "close_item"
        case .markNotified: return "mark_notified"
        case .archiveItem: return "archive_item"
        case .reserveWorkSession: return "reserve_work_session"
        case .completeWorkSession: return "complete_work_session"
        case .settleWorkSession: return "complete_work_session"
        case .reserveWorkAttempt: return "reserve_work_attempt"
        case .completeWorkAttempt: return "complete_work_attempt"
        case .workLog: return "work_log"
        case .setBlockedOn: return "set_blocked_on"
        case .setDeferUntil: return "set_defer_until"
        }
    }
}

public struct DeskOp: Sendable, Equatable {
    public var opId: String
    public var ts: String
    public var handle: String
    public var body: DeskOpBody

    public init(opId: String = DeskClock.newOpId(), ts: String? = nil, handle: String, body: DeskOpBody) {
        self.opId = opId
        self.ts = ts ?? DeskClock.nowISO()
        self.handle = handle
        self.body = body
    }

    public var op: String { body.token }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "opId": .string(opId),
            "ts": .string(ts),
            "op": .string(body.token),
            "handle": .string(handle),
        ]
        func put(_ k: String, _ v: String?) { if let v, !v.isEmpty { obj[k] = .string(v) } }
        switch body {
        case let .createItem(alias, kind, project, title, parent, summary, origin, pursuit):
            obj["alias"] = .string(alias)
            obj["kind"] = .string(kind.rawValue)
            obj["project"] = .string(project)
            obj["title"] = .string(title)
            put("parent", parent)
            put("summary", summary)
            // M10: origin OMITTED when .owner so a pre-origin create op re-serializes
            // BYTE-IDENTICAL; pursuit emitted only for an origin=agent create.
            if origin != .owner { obj["origin"] = .string(origin.rawValue) }
            if let pursuit { obj["pursuit"] = pursuit.toJSON() }
        case let .openPursuit(alias, project, title, summary, pursuit, notify):
            obj["alias"] = .string(alias)
            obj["project"] = .string(project)
            obj["title"] = .string(title)
            put("summary", summary)
            obj["pursuit"] = pursuit.toJSON()
            if notify != NotifyPolicy() { obj["notify"] = notify.toJSON() }
        case let .setStatus(status, blockedReason, waitingOn):
            obj["status"] = .string(status.rawValue)
            put("blockedReason", blockedReason)
            put("waitingOn", waitingOn)
        case let .updateTitle(title, summary):
            put("title", title)
            put("summary", summary)
        case let .addRef(ref):
            obj["ref"] = ref.toJSON()
        case let .updateRef(refId, cachedFields):
            obj["refId"] = .string(refId)
            obj["cachedFields"] = .object(cachedFields)
        case let .appendNote(text):
            obj["text"] = .string(text)
        case let .setCadence(cadence):
            obj["cadence"] = cadence.toJSON()
        case let .setNotify(policy):
            obj["policy"] = policy.toJSON()
        case let .closeItem(outcomeSummary, status):
            obj["outcomeSummary"] = .string(outcomeSummary)
            // close_item is terminal by definition — clamp on encode too so a
            // directly-constructed op can never persist a non-terminal status.
            obj["status"] = .string((status.isTerminal ? status : .done).rawValue)
        case let .markNotified(at):
            obj["at"] = .string(at)
        case .archiveItem:
            break
        case let .reserveWorkSession(reservationId, day, slot):
            obj["reservationId"] = .string(reservationId)
            obj["day"] = .string(day)
            obj["slot"] = .string(slot)
        case let .completeWorkSession(reservationId, receipt):
            obj["reservationId"] = .string(reservationId)
            obj["receipt"] = .string(receipt)
        case let .settleWorkSession(reservationId, receipt, disposition, artifactRefs):
            obj["reservationId"] = .string(reservationId)
            obj["receipt"] = .string(receipt)
            obj["disposition"] = .string(disposition.rawValue)
            obj["artifactRefs"] = .array(artifactRefs.map(JSONValue.string))
        case let .reserveWorkAttempt(attemptId, lane, day, slot):
            obj["attemptId"] = .string(attemptId)
            obj["lane"] = .string(lane.rawValue)
            obj["day"] = .string(day)
            obj["slot"] = .string(slot)
        case let .completeWorkAttempt(attemptId, receipt):
            obj["attemptId"] = .string(attemptId)
            obj["receipt"] = .string(receipt)
        case let .workLog(receipt):
            obj["receipt"] = .string(receipt)
        case let .setBlockedOn(handles):
            // ALWAYS emitted, even EMPTY — an empty set is a CLEAR, and the
            // omit-empty `put` helper above would drop it and silently lose the
            // clear on replay (the exact shape of the update_title empty-summary
            // bug this file already carries a scar from).
            obj["blockedOn"] = .array(handles.map { .string($0) })
        case let .setDeferUntil(until):
            // Same reason: "" IS the clear and must survive the round-trip.
            obj["until"] = .string(until ?? "")
        }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> DeskOp? {
        guard case .object(let obj) = value,
              let opId = jsonString(obj, "opId"),
              let ts = jsonString(obj, "ts"),
              let token = jsonString(obj, "op"),
              let handle = jsonString(obj, "handle") else { return nil }
        let body: DeskOpBody
        switch token {
        case "create_item":
            guard let alias = jsonString(obj, "alias"),
                  let kindRaw = jsonString(obj, "kind"), let kind = DeskKind(rawValue: kindRaw),
                  let project = jsonString(obj, "project"),
                  let title = jsonString(obj, "title") else { return nil }
            // M10: origin decodes OPTIONAL defaulting .owner; pursuit optional.
            body = .createItem(alias: alias, kind: kind, project: project, title: title,
                               parent: jsonString(obj, "parent"), summary: jsonString(obj, "summary"),
                               origin: jsonString(obj, "origin").flatMap(DeskOrigin.decodePersisted) ?? .owner,
                               pursuit: obj["pursuit"].map { Pursuit.fromJSON($0) })
        case "open_pursuit":
            guard let alias = jsonString(obj, "alias"),
                  let project = jsonString(obj, "project"),
                  let title = jsonString(obj, "title"),
                  let pursuitVal = obj["pursuit"] else { return nil }
            body = .openPursuit(
                alias: alias,
                project: project,
                title: title,
                summary: jsonString(obj, "summary"),
                pursuit: Pursuit.fromJSON(pursuitVal),
                notify: obj["notify"].map { NotifyPolicy.fromJSON($0) } ?? NotifyPolicy()
            )
        case "set_status":
            guard let statusRaw = jsonString(obj, "status"), let status = DeskStatus(rawValue: statusRaw) else { return nil }
            body = .setStatus(status: status, blockedReason: jsonString(obj, "blockedReason"), waitingOn: jsonString(obj, "waitingOn"))
        case "update_title":
            body = .updateTitle(title: jsonString(obj, "title"), summary: jsonString(obj, "summary"))
        case "add_ref":
            guard let refVal = obj["ref"], let ref = DeskRef.fromJSON(refVal) else { return nil }
            body = .addRef(ref: ref)
        case "update_ref":
            guard let refId = jsonString(obj, "refId") else { return nil }
            var fields: [String: JSONValue] = [:]
            if case .object(let f)? = obj["cachedFields"] { fields = f }
            body = .updateRef(refId: refId, cachedFields: fields)
        case "append_note":
            guard let text = jsonString(obj, "text") else { return nil }
            body = .appendNote(text: text)
        case "set_cadence":
            guard let c = obj["cadence"] else { return nil }
            body = .setCadence(cadence: Cadence.fromJSON(c))
        case "set_notify":
            guard let p = obj["policy"] else { return nil }
            body = .setNotify(policy: NotifyPolicy.fromJSON(p))
        case "close_item":
            guard let outcome = jsonString(obj, "outcomeSummary") else { return nil }
            let decoded = jsonString(obj, "status").flatMap { DeskStatus(rawValue: $0) } ?? .done
            // close_item is terminal by definition — a non-terminal token clamps
            // to .done rather than materializing a half-closed lifecycle row.
            body = .closeItem(outcomeSummary: outcome, status: decoded.isTerminal ? decoded : .done)
        case "mark_notified":
            guard let at = jsonString(obj, "at") else { return nil }
            body = .markNotified(at: at)
        case "archive_item":
            body = .archiveItem
        case "reserve_work_session":
            guard let reservationId = jsonString(obj, "reservationId"),
                  let day = jsonString(obj, "day"),
                  let slot = jsonString(obj, "slot") else { return nil }
            body = .reserveWorkSession(reservationId: reservationId, day: day, slot: slot)
        case "complete_work_session":
            guard let reservationId = jsonString(obj, "reservationId"),
                  let receipt = jsonString(obj, "receipt") else { return nil }
            if let raw = jsonString(obj, "disposition"),
               let disposition = DeskWorkDisposition(rawValue: raw) {
                body = .settleWorkSession(
                    reservationId: reservationId,
                    receipt: receipt,
                    disposition: disposition,
                    artifactRefs: jsonStringArray(obj, "artifactRefs")
                )
            } else {
                body = .completeWorkSession(reservationId: reservationId, receipt: receipt)
            }
        case "reserve_work_attempt":
            guard let attemptId = jsonString(obj, "attemptId"),
                  let laneRaw = jsonString(obj, "lane"),
                  let lane = DeskWorkAttempt.Lane(rawValue: laneRaw),
                  let day = jsonString(obj, "day"),
                  let slot = jsonString(obj, "slot") else { return nil }
            body = .reserveWorkAttempt(attemptId: attemptId, lane: lane, day: day, slot: slot)
        case "complete_work_attempt":
            guard let attemptId = jsonString(obj, "attemptId"),
                  let receipt = jsonString(obj, "receipt") else { return nil }
            body = .completeWorkAttempt(attemptId: attemptId, receipt: receipt)
        case "work_log":
            guard let receipt = jsonString(obj, "receipt") else { return nil }
            body = .workLog(receipt: receipt)
        case "set_blocked_on":
            // Absent / wrong-typed → [] , which is the CLEAR. The op is a
            // whole-set replace, so there is nothing to preserve on a partial read.
            body = .setBlockedOn(handles: jsonStringArray(obj, "blockedOn"))
        case "set_defer_until":
            let raw = jsonString(obj, "until") ?? ""
            body = .setDeferUntil(until: raw.isEmpty ? nil : raw)
        default:
            return nil // tolerant: unknown op tokens skipped
        }
        return DeskOp(opId: opId, ts: ts, handle: handle, body: body)
    }
}

// MARK: - DeskState (derived — the materialized live view)

public struct DeskState: Sendable, Equatable {
    /// All LIVE items (archived excluded), in ALIAS ORDER: top-level by numeric
    /// seq, each immediately followed by its children in child-seq order.
    public var items: [DeskItem]
    public var generatedTs: String

    public init(items: [DeskItem], generatedTs: String) {
        self.items = items
        self.generatedTs = generatedTs
    }

    public var topLevel: [DeskItem] { items.filter { $0.parent == nil } }
    public func children(of handle: String) -> [DeskItem] { items.filter { $0.parent == handle } }

    public func toJSON() -> JSONValue {
        .object([
            "version": .int(1),
            "generatedTs": .string(generatedTs),
            "items": .array(items.map { $0.toJSON() }),
        ])
    }

    /// Decode a materialized state (compaction base / state.json). STRICT on
    /// items: any row that fails DeskItem.fromJSON fails the WHOLE decode —
    /// a compaction base that silently dropped one item would vanish it from
    /// every future replay, so the caller must fail loud instead of folding
    /// from a partial base.
    public static func fromJSON(_ value: JSONValue) -> DeskState? {
        guard case .object(let obj) = value,
              case .string(let generatedTs)? = obj["generatedTs"],
              case .array(let rows)? = obj["items"] else { return nil }
        var items: [DeskItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            guard let item = DeskItem.fromJSON(row, strictCollections: true) else { return nil }
            items.append(item)
        }
        return DeskState(items: items, generatedTs: generatedTs)
    }
}
