import Foundation
import os
import NativeAgentCore
import PersistenceCore

// MARK: - TriggerContentBuilder
//
// Real, native, template-built content for the two proactive triggers whose
// signals actually exist on disk today: `morning_brief` (kind `time`) and
// `idle_checkin` (kind `idle`).
//
// NO LLM. Every section is an independent, FAIL-OPEN read of a state source
// that already exists under the data root (or, for the worklog, under
// ~/.claude/state). A missing / truncated / malformed source contributes
// NOTHING and never throws — a brief that is missing one section is still a
// true statement about the sections that resolved. A brief that crashes the
// 60s scheduler tick is not.
//
// DEPENDENCY NOTE: this deliberately does NOT reach for
// `ChatOrchestration.SessionDigestProvider`. That module drags in MemoryV2,
// ProviderRouting, CognitiveSubstrate and twenty more just to reach one
// private tail-reader. The raw files are read directly instead, keeping the
// TriggerScheduler target's deps at ["PersistenceCore", "WorkshopExecution"].

/// The three fields a trigger's fire path needs to build an InboxItem.
/// `detail` is `.string(markdown)` when at least one section resolved, `.null`
/// otherwise — mirroring the InboxItem `detail` column's existing nullability.
public struct TriggerContent: Sendable, Equatable {
    public let title: String
    public let summary: String
    public let detail: JSONValue

    public init(title: String, summary: String, detail: JSONValue) {
        self.title = title
        self.summary = summary
        self.detail = detail
    }
}

public struct TriggerContentBuilder: Sendable {
    let root: URL
    let persistence: any PersistenceCoreProtocol
    let now: @Sendable () -> Date
    let worklogPath: URL

    private static let logger = Logger(subsystem: "com.nativeagent.core", category: "trigger-content")

    /// Bounded tail read for the worklog: never map an unbounded feed into memory.
    static let worklogTailBytes: Int = 128 * 1024
    static let worklogMaxEntries: Int = 5

    public init(
        root: URL,
        persistence: any PersistenceCoreProtocol,
        now: @escaping @Sendable () -> Date = { Date() },
        worklogPath: URL? = nil
    ) {
        self.root = root
        self.persistence = persistence
        self.now = now
        self.worklogPath = worklogPath ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("claude-worklog.jsonl")
    }

    // MARK: - morning_brief

    /// Title keeps the exact `"Morning brief — \(label)"` shape the UI and the
    /// existing test pin. Summary and detail are now REAL: assembled from
    /// whatever facts resolved. If nothing resolved, the summary says so
    /// plainly — which is still a true claim about real state, not a
    /// placeholder.
    public func morningBrief() async -> TriggerContent {
        let current = now()
        let label = Self.todayLabel(current)

        let desk = await deskSection()
        let worklog = worklogSection(reference: current)
        let executions = workshopExecutionsSection(reference: current)
        let unread = unreadInboxCount()
        let session = lastSessionSection()

        // Summary facts, in the order User reads them: what's on the desk, what
        // moved, what's waiting.
        var facts: [String] = []
        if desk.openCount > 0 {
            facts.append("\(desk.openCount) open desk item\(desk.openCount == 1 ? "" : "s")")
        }
        if executions.movedCount > 0 {
            facts.append("\(executions.movedCount) Workshop task\(executions.movedCount == 1 ? "" : "s") moved")
        } else if executions.activeCount > 0 {
            facts.append("\(executions.activeCount) Workshop task\(executions.activeCount == 1 ? "" : "s") active")
        }
        if let unread, unread > 0 {
            facts.append("\(unread) unread")
        }
        if !worklog.summaries.isEmpty {
            let n = worklog.summaries.count
            facts.append("\(n) log entr\(n == 1 ? "y" : "ies") since yesterday")
        }

        let summary: String
        if facts.isEmpty {
            summary = "Morning brief for \(label) — nothing new since yesterday."
        } else {
            summary = "\(label) — \(facts.joined(separator: ", "))."
        }

        // Detail: one markdown section per source that resolved.
        var sections: [String] = []
        if let body = desk.body, !body.isEmpty {
            sections.append("## Desk\n\n\(body)")
        }
        if !worklog.summaries.isEmpty {
            let bullets = worklog.summaries.map { "- \($0)" }.joined(separator: "\n")
            sections.append("## Since yesterday\n\n\(bullets)")
        }
        if executions.activeCount > 0 || executions.movedCount > 0 {
            sections.append(
                "## Workshop\n\n- \(executions.activeCount) active\n- \(executions.movedCount) moved in the last 24h"
            )
        }
        if let unread, unread > 0 {
            sections.append("## Inbox\n\n- \(unread) unread item\(unread == 1 ? "" : "s")")
        }
        if let session {
            sections.append("## Last session\n\n- \(session.title) (\(Self.relativeAge(session.updatedAt, from: current)))")
        }

        return TriggerContent(
            title: "Morning brief — \(label)",
            summary: summary,
            detail: sections.isEmpty ? .null : .string(sections.joined(separator: "\n\n"))
        )
    }

    // MARK: - idle_checkin

    /// The quiet duration comes from the cheapest honest activity signal that
    /// is already persisted: `max(updatedAt)` over `<root>/chat/sessions.json`.
    /// When no such signal resolves we SAY SO rather than inventing a duration.
    public func idleCheckin() async -> TriggerContent {
        let current = now()
        let desk = await deskSection()
        let session = lastSessionSection()

        guard let last = Self.lastActivityInstant(root: root), last <= current else {
            return TriggerContent(
                title: "Idle check-in",
                summary: "You've been quiet — I can't tell how long (no recorded session activity).",
                detail: .null
            )
        }

        let quiet = Self.durationLabel(current.timeIntervalSince(last))
        var summary = "Quiet for \(quiet)."
        if desk.openCount > 0 {
            summary += " \(desk.openCount) open desk item\(desk.openCount == 1 ? "" : "s") waiting."
        } else if let session {
            summary += " Last thread: \(session.title)."
        }

        var sections: [String] = []
        if let body = desk.body, !body.isEmpty {
            sections.append("## Desk\n\n\(body)")
        }
        if let session {
            sections.append("## Last session\n\n- \(session.title) (\(Self.relativeAge(session.updatedAt, from: current)))")
        }

        return TriggerContent(
            title: "Idle check-in",
            summary: summary,
            detail: sections.isEmpty ? .null : .string(sections.joined(separator: "\n\n"))
        )
    }

    // MARK: - Sources (each fail-open)

    struct DeskSection { var openCount: Int; var body: String? }

    /// `<root>/desk/desk_ops.jsonl` → live materialized state. Non-terminal
    /// statuses only (`done` / `canceled` are not "open").
    func deskSection() async -> DeskSection {
        // SwiftNativeDeskStore requires the concrete persistence type. The old
        // `?? SwiftNativePersistenceCore()` fallback silently substituted a
        // FRESH persistence when the injected one wasn't SwiftNative — reading
        // the real filesystem behind a test's mock (uniform-locking sweep
        // follow-up, 2026-08-01). A non-SwiftNative persistence cannot drive
        // the desk store, so the section is honestly unavailable instead.
        guard let native = persistence as? SwiftNativePersistenceCore else {
            return DeskSection(openCount: 0, body: nil)
        }
        let store = SwiftNativeDeskStore(dataRoot: root, persistence: native)
        guard let state = try? await store.liveState(), !state.items.isEmpty else {
            return DeskSection(openCount: 0, body: nil)
        }
        let open: Set<DeskStatus> = [.now, .next, .blocked, .todo, .flag, .watch]
        let count = state.items.filter { open.contains($0.status) }.count
        guard count > 0 else { return DeskSection(openCount: 0, body: nil) }
        return DeskSection(openCount: count, body: DeskProjection.render(state, now: now()))
    }

    struct WorklogSection { var summaries: [String] }

    /// Bounded tail of `~/.claude/state/claude-worklog.jsonl`, filtered to
    /// entries stamped at or after YESTERDAY 00:00 local.
    func worklogSection(reference: Date) -> WorklogSection {
        guard let cutoff = Self.startOfYesterday(reference) else { return WorklogSection(summaries: []) }
        guard let text = Self.tailText(worklogPath, maxBytes: Self.worklogTailBytes) else {
            return WorklogSection(summaries: [])
        }
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  case .object(let o)? = try? JSONValue.parse(data),
                  case .string(let ts)? = o["ts"],
                  let stamp = SwiftNativeTriggerScheduler.parseISOTimestamp(ts),
                  stamp >= cutoff, stamp <= reference,
                  case .string(let summary)? = o["summary"] else { continue }
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        // Newest N, in chronological order.
        return WorklogSection(summaries: Array(out.suffix(Self.worklogMaxEntries)))
    }

    struct WorkshopExecutionsSection { var activeCount: Int; var movedCount: Int }

    /// `<root>/workshop/legacy_executions.json` — compatibility execution rows.
    /// active  = status not terminal.
    /// moved   = `completedAt` or `updatedAt` within the last 24h.
    func workshopExecutionsSection(reference: Date) -> WorkshopExecutionsSection {
        guard case .array(let rows)? = Self.readJSONFile(
            root.appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("legacy_executions.json")
        ) else {
            return WorkshopExecutionsSection(activeCount: 0, movedCount: 0)
        }
        let terminal: Set<String> = ["done", "failed", "canceled", "cancelled"]
        let window = reference.addingTimeInterval(-24 * 60 * 60)
        var active = 0
        var moved = 0
        for row in rows {
            guard case .object(let o) = row else { continue }
            let status: String = {
                if case .string(let s)? = o["status"] { return s.lowercased() }
                return ""
            }()
            if !terminal.contains(status) { active += 1 }
            let stampKeys = ["completedAt", "updatedAt"]
            for key in stampKeys {
                guard case .string(let s)? = o[key],
                      let d = SwiftNativeTriggerScheduler.parseISOTimestamp(s) else { continue }
                if d >= window && d <= reference { moved += 1; break }
            }
        }
        return WorkshopExecutionsSection(activeCount: active, movedCount: moved)
    }

    /// `<root>/notifications/inbox.jsonl` — the LIVE inbox (A5.2 cutover
    /// 2026-07-23; was the dead `inbox/index.json` overlay). Status lives
    /// per-line, so count lines whose latest occurrence per id is `unread`.
    /// nil when the file is absent or unreadable (distinct from "zero unread").
    func unreadInboxCount() -> Int? {
        let path = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        // Last-write-wins per id: a later row (e.g. a read-status rewrite)
        // supersedes an earlier one, matching how the live store is read.
        var statusById: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  case .object(let o)? = try? JSONValue.parse(data),
                  case .string(let id)? = o["id"] else { continue }
            let status: String = {
                if case .string(let s)? = o["status"] { return s.lowercased() }
                return "unread"
            }()
            statusById[id] = status
        }
        return statusById.values.filter { $0 == "unread" }.count
    }

    struct SessionSection { var title: String; var updatedAt: Date }

    /// Newest non-archived entry in `<root>/chat/sessions.json` by `updatedAt`.
    func lastSessionSection() -> SessionSection? {
        guard let (title, at) = Self.newestSession(root: root) else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SessionSection(title: trimmed, updatedAt: at)
    }

    // MARK: - Activity signal (shared with the scheduler's `idle` condition)

    /// `max(updatedAt)` over `<root>/chat/sessions.json`. THE last-user-activity
    /// timestamp the scheduler's `idle` kind was waiting on. Synchronous and
    /// pure so `scheduledInstantIfDue` can call it from its `nonisolated`,
    /// inside-the-flock recompute. nil ⇒ no signal ⇒ idle stays dark.
    public nonisolated static func lastActivityInstant(root: URL) -> Date? {
        newestSession(root: root)?.updatedAt
    }

    /// Newest `(title, updatedAt)` across every non-archived session row.
    /// Archived rows are excluded — an archived thread is not live activity.
    nonisolated static func newestSession(root: URL) -> (title: String, updatedAt: Date)? {
        guard case .array(let rows)? = readJSONFile(
            root.appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("sessions.json")
        ) else { return nil }
        var best: (title: String, updatedAt: Date)? = nil
        for row in rows {
            guard case .object(let o) = row else { continue }
            if case .bool(true)? = o["archived"] { continue }
            guard case .string(let ts)? = o["updatedAt"],
                  let d = SwiftNativeTriggerScheduler.parseISOTimestamp(ts) else { continue }
            let title: String = {
                if case .string(let t)? = o["title"] { return t }
                return ""
            }()
            if best == nil || d > best!.updatedAt { best = (title, d) }
        }
        return best
    }

    // MARK: - Small helpers (all fail-open)

    nonisolated static func readJSONFile(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONValue.parse(data)
    }

    /// Read at most the last `maxBytes` of a file as UTF-8, dropping a leading
    /// partial line. nil when the file is missing/empty/undecodable.
    nonisolated static func tailText(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        // A non-zero start almost certainly landed mid-line: drop the fragment.
        if start > 0, let nl = text.firstIndex(of: "\n") {
            return String(text[text.index(after: nl)...])
        }
        return text
    }

    static func startOfYesterday(_ reference: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let today = cal.startOfDay(for: reference)
        return cal.date(byAdding: .day, value: -1, to: today)
    }

    /// `%A, %B %-d` (e.g. "Friday, March 5"), local tz. Single source of truth
    /// for the brief's date label.
    nonisolated static func todayLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt.string(from: date)
    }

    /// "2h 14m" / "14m" / "3d 2h". Never negative, never empty.
    nonisolated static func durationLabel(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    nonisolated static func relativeAge(_ date: Date, from reference: Date) -> String {
        let delta = reference.timeIntervalSince(date)
        if delta < 60 { return "just now" }
        return "\(durationLabel(delta)) ago"
    }
}
