import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2

// MARK: - SessionDigestProvider (U3 wave 2, item 8 — 2026-06-10)
//
// Assembles a "since last session" digest from cheap local sources:
//   - chat session metadata  (data/chat/sessions.json — prior-session headline)
//   - traces                 (data/traces/events.jsonl — event counts by kind)
//   - Workshop executions    (data/workshop/executions — updated directed work)
//   - dream diary            (data/dream_diary/*.md — new entries by mtime)
//   - agent inbox standups   (<repo>/docs/agent_inbox/from_*.md — by mtime)
//   - claude worklog        (~/.claude/state/claude-worklog.jsonl)
//
// MECHANICAL assembly only — counts + headline lines, NO LLM call. Every
// source is fail-open: a missing, unreadable, or corrupt source simply drops
// out of the digest; nothing here ever throws into the turn path.
//
// CACHING CONTRACT (U1): the digest is injected at the END of the STABLE
// system-prompt segment (after persona + REM pins, before dynamic
// recall/history). It therefore MUST be PER-SESSION-CONSTANT — computed once
// on the session's first context build and byte-identical on every later
// turn, or it would churn the provider prompt-cache prefix every turn.
// Two layers make that durable and race-free (gpt-5.5 review, 2026-06-10):
//   1. DISK: the first build persists the rendered bytes to
//      <dataRoot>/chat/session_state/<sessionId>/digest.txt and every later
//      build prefers the on-disk copy — so in-memory eviction (or an app
//      restart mid-session) costs a disk read, never a rebuild from
//      sources that have moved on.
//   2. SINGLE-FLIGHT: `SessionDigestCache` (an actor) coalesces concurrent
//      first turns for the same key onto ONE in-flight build, so two racing
//      first turns can never observe two different byte sequences.
// Both layers stay fail-open: a disk write failure degrades to the
// in-memory cache (still single-flighted, still per-session-stable for the
// process lifetime).

// MARK: - SessionDigestCache

/// Process-global per-session digest cache + build single-flight. The VALUE
/// is the rendered digest ("" = computed-and-empty, also cached so a fresh
/// session never recomputes). Bounded: oldest-inserted keys are evicted past
/// `capacity` — sessions are long-lived relative to process lifetime, so
/// simple insertion-order eviction is enough (state-lifecycle rule: every
/// add has a remove; in-flight entries are removed when their build lands).
actor SessionDigestCache {
    static let shared = SessionDigestCache()

    private var store: [String: String] = [:]
    private var insertionOrder: [String] = []
    private var inFlight: [String: Task<String, Never>] = [:]
    private let capacity = 256

    /// Get-or-build with per-key single-flight: concurrent callers for the
    /// same key while a build is in flight all await that ONE build and
    /// receive identical bytes. The build closure runs off-actor (detached)
    /// so a slow disk read never blocks unrelated sessions' lookups.
    func value(forKey key: String, build: @escaping @Sendable () -> String) async -> String {
        if let cached = store[key] { return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { build() }
        inFlight[key] = task
        let value = await task.value
        // Every waiter resumes through here; the writes are idempotent
        // (insertion-order append is guarded by the store-miss check).
        inFlight[key] = nil
        set(value, forKey: key)
        return value
    }

    private func set(_ value: String, forKey key: String) {
        if store[key] == nil {
            insertionOrder.append(key)
            if insertionOrder.count > capacity {
                let evicted = insertionOrder.removeFirst()
                store.removeValue(forKey: evicted)
            }
        }
        store[key] = value
    }

    /// Test hook — clears all settled cache state (simulates eviction).
    /// In-flight builds are left to land and re-cache on their own.
    func removeAll() {
        store.removeAll()
        insertionOrder.removeAll()
    }
}

// MARK: - SessionDigestProvider

public struct SessionDigestProvider: Sendable {
    /// Root of the daemon-format data dir (data/chat, data/traces, ...).
    public let dataRoot: URL
    /// Directory holding agent standup files (from_*.md). Defaults to
    /// `<dataRoot parent>/docs/agent_inbox` — the repo-layout convention.
    public let agentInboxDir: URL
    /// Claude worklog JSONL feed. Defaults to
    /// `~/.claude/state/claude-worklog.jsonl`.
    public let worklogPath: URL

    /// ~500-token hard cap, enforced as characters at the conservative
    /// 4-chars-per-token heuristic. Truncation is sentence-safe via
    /// `MemoryTextClip.sentenceClip` (U3 wave-1 helper).
    static let digestCharCap = 2000
    /// First line of every rendered digest (tests + adapters key off it).
    public static let headerLine = "# Since last session"

    // Bounded tail reads keep the build well under the <100ms budget even
    // when the underlying logs are large.
    private static let tracesTailBytes = 256 * 1024
    private static let worklogTailBytes = 128 * 1024
    private static let standupHeadBytes = 4096
    private static let maxSourceFileBytes = 5 * 1024 * 1024

    public init(
        dataRoot: URL,
        agentInboxDir: URL? = nil,
        worklogPath: URL? = nil
    ) {
        self.dataRoot = dataRoot
        self.agentInboxDir = agentInboxDir
            ?? dataRoot
                .deletingLastPathComponent()
                .appendingPathComponent("docs", isDirectory: true)
                .appendingPathComponent("agent_inbox", isDirectory: true)
        self.worklogPath = worklogPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent("claude-worklog.jsonl")
    }

    /// The per-session digest, or nil when there is nothing to say (no prior
    /// session on disk, empty/blank sessionId, or every source failed).
    ///
    /// BYTE-STABILITY: the first call for a (sources, sessionId) pair builds
    /// the digest ONCE (single-flighted across concurrent first turns),
    /// persists the bytes to chat/session_state/<sessionId>/digest.txt, and
    /// caches them; every subsequent call returns those bytes verbatim —
    /// even if sessions.json / traces / worklog have changed since, even
    /// after in-memory eviction (disk copy wins over rebuild forever).
    /// Never throws; all source errors degrade to absence.
    public func digest(forSessionId sessionId: String) async -> String? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = [dataRoot.path, agentInboxDir.path, worklogPath.path, trimmed]
            .joined(separator: "\u{1F}")
        let provider = self
        let value = await SessionDigestCache.shared.value(forKey: key) {
            provider.loadOrBuildAndPersist(sessionId: trimmed)
        }
        return value.isEmpty ? nil : value
    }

    // MARK: durable per-session bytes (disk layer)

    /// Disk-first resolution: a previously persisted digest ALWAYS wins over
    /// a rebuild (rebuild inputs drift; persisted bytes don't). Runs inside
    /// the cache's single-flight, so one session never builds twice
    /// concurrently in-process; cross-PROCESS races (app + chat-drive over
    /// the same dataRoot) converge through the exclusive-publish below —
    /// the FIRST writer's bytes become canonical and losers adopt them
    /// (gpt-5.5 delta re-review, 2026-06-10: a plain .atomic write was
    /// last-writer-wins, so two processes could keep different bytes).
    func loadOrBuildAndPersist(sessionId: String) -> String {
        if let persisted = readPersistedDigest(sessionId: sessionId) { return persisted }
        let built = buildDigest(currentSessionId: sessionId) ?? ""
        return persistDigestExclusively(built, sessionId: sessionId)
    }

    /// chat/session_state/<sessionId>/digest.txt — the module's session-state
    /// convention (the directory ships in DoctorChecks' expected layout and
    /// the backup manifest). nil when the session id is not filesystem-safe
    /// (same `NativeAgentChatSessionID` gate the messages store uses) —
    /// such ids degrade to the in-memory cache only.
    func persistedDigestPath(sessionId: String) -> URL? {
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return nil
        }
        return dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("session_state", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("digest.txt")
    }

    /// Persisted bytes, verbatim ("" = computed-and-empty is a valid
    /// persisted value); nil when absent/unreadable.
    private func readPersistedDigest(sessionId: String) -> String? {
        guard let path = persistedDigestPath(sessionId: sessionId),
              let data = try? Data(contentsOf: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// First-writer-wins publish: writes the bytes to a temp file (atomic —
    /// never a torn final file) and publishes via hard-link, which FAILS if
    /// the destination already exists. Returns the bytes that ended up
    /// canonical for the session: ours when the link wins, the on-disk
    /// winner's when it loses. Fail-open: any filesystem error degrades to
    /// our in-memory bytes (still single-flighted, still stable for the
    /// process lifetime) — never throws into the turn path.
    private func persistDigestExclusively(_ digest: String, sessionId: String) -> String {
        guard let path = persistedDigestPath(sessionId: sessionId) else { return digest }
        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent("digest.tmp-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(digest.utf8).write(to: tmp, options: .atomic)
            try FileManager.default.linkItem(at: tmp, to: path)
            return digest
        } catch {
            // Lost the publish race (destination exists) or the write
            // failed outright: adopt the winner if one is readable, else
            // keep ours in-memory (fail-open by contract).
            return readPersistedDigest(sessionId: sessionId) ?? digest
        }
    }

    // MARK: build

    /// One uncached assembly pass. Internal so tests can exercise the builder
    /// directly; production goes through `digest(forSessionId:)`. `cap` is a
    /// test seam for the final sentence-safe truncation — per-line clips keep
    /// the natural digest size well under the production cap, so the hard cap
    /// is a safety net that fixtures can only reach with a lowered value.
    func buildDigest(
        currentSessionId: String,
        cap: Int = SessionDigestProvider.digestCharCap
    ) -> String? {
        guard let prior = latestPriorSession(excluding: currentSessionId) else {
            return nil
        }
        let anchor = prior.updatedAt

        var lines: [String] = [Self.headerLine]
        var headline = "Previous session"
        if let title = prior.title, !title.isEmpty {
            headline += " \"\(clip(title, 80))\""
        }
        if let count = prior.messageCount, count > 0 {
            headline += " (\(count) message\(count == 1 ? "" : "s"))"
        }
        headline += " ended \(Self.formatUTC(anchor))."
        lines.append(headline)
        if let preview = prior.lastMessagePreview, !preview.isEmpty {
            lines.append("Last reply: \(clip(preview, 220))")
        }

        var activity: [String] = []
        activity.append(contentsOf: worklogLines(after: anchor))
        if let m = workshopExecutionsLine(after: anchor) { activity.append(m) }
        activity.append(contentsOf: standupLines(after: anchor))
        if let d = dreamsLine(after: anchor) { activity.append(d) }
        if let t = tracesLine(after: anchor) { activity.append(t) }

        if activity.isEmpty {
            lines.append("No recorded background activity since.")
        } else {
            lines.append("Activity since then:")
            lines.append(contentsOf: activity.map { "- " + $0 })
        }

        let joined = lines.joined(separator: "\n")
        return MemoryTextClip.sentenceClip(joined, cap: cap)
    }

    // MARK: sources — chat sessions

    struct PriorSession {
        let id: String
        let title: String?
        let updatedAt: Date
        let messageCount: Int?
        let lastMessagePreview: String?
    }

    /// Most-recently-updated session in sessions.json that genuinely ENDED
    /// before the current session began. nil → fresh install / first-ever
    /// session → no digest.
    ///
    /// ANCHOR (gpt-5.5 review fix, 2026-06-10): `id != current` alone is not
    /// enough — with interleaved sessions (a second window active in
    /// parallel) or a resumed old session, the most-recently-updated OTHER
    /// session can be one still running NOW, and its title/preview would be
    /// injected as the "previous session ended" headline. So: anchor on the
    /// CURRENT session's creation time (`createdAt` in sessions.json — the
    /// field the index writer stamps on first message) and qualify only
    /// sessions whose LAST activity (`updatedAt`) strictly predates it. A
    /// brand-new session with no row yet anchors at digest-build time.
    func latestPriorSession(excluding currentSessionId: String) -> PriorSession? {
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        guard let parsed = readJSON(at: path), case .array(let arr) = parsed else {
            return nil
        }
        var anchor = Date() // no persisted row → session starts "now"
        for entry in arr {
            guard case .object(let obj) = entry,
                  string(obj["id"]) == currentSessionId else { continue }
            let stamp = string(obj["createdAt"]) ?? string(obj["updatedAt"]) ?? ""
            if let created = Self.parseTimestamp(stamp) { anchor = created }
            break
        }
        var best: PriorSession? = nil
        for entry in arr {
            guard case .object(let obj) = entry else { continue }
            guard let id = string(obj["id"]), id != currentSessionId else { continue }
            let stamp = string(obj["updatedAt"]) ?? string(obj["createdAt"]) ?? ""
            guard let updated = Self.parseTimestamp(stamp) else { continue }
            guard updated < anchor else { continue } // interleaved/later: skip
            if let current = best, current.updatedAt >= updated { continue }
            best = PriorSession(
                id: id,
                title: string(obj["title"]),
                updatedAt: updated,
                messageCount: int(obj["messageCount"]),
                lastMessagePreview: string(obj["lastMessagePreview"])
            )
        }
        return best
    }

    // MARK: sources — claude worklog

    /// Up to 3 most-recent worklog entries newer than the anchor, newest
    /// first, plus a count line when more exist.
    private func worklogLines(after anchor: Date) -> [String] {
        let rows = tailJSONLObjects(at: worklogPath, maxBytes: Self.worklogTailBytes)
        var entries: [(Date, String)] = []
        for obj in rows {
            guard let ts = string(obj["ts"]), let date = Self.parseTimestamp(ts),
                  date > anchor else { continue }
            let kind = string(obj["kind"]) ?? "work"
            let project = string(obj["project"]) ?? ""
            let summary = string(obj["summary"]) ?? ""
            guard !summary.isEmpty else { continue }
            let scope = project.isEmpty ? kind : "\(kind), \(project)"
            // Whole-line clip: kind/project come off disk too — never trust
            // them to be short.
            entries.append((date, clip("Claude worklog (\(scope)): \(clip(summary, 200))", 240)))
        }
        guard !entries.isEmpty else { return [] }
        entries.sort { $0.0 > $1.0 }
        var lines = entries.prefix(3).map { $0.1 }
        if entries.count > 3 {
            lines.append("Claude worklog: +\(entries.count - 3) more entries since.")
        }
        return lines
    }

    // MARK: sources — Workshop executions

    private func workshopExecutionsLine(after anchor: Date) -> String? {
        let path = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("legacy_executions.json")
        guard let parsed = readJSON(at: path), case .array(let arr) = parsed else {
            return nil
        }
        var touched: [(Date, String)] = []
        for entry in arr {
            guard case .object(let obj) = entry else { continue }
            let stamp = string(obj["completedAt"]) ?? string(obj["updatedAt"]) ?? ""
            guard let date = Self.parseTimestamp(stamp), date > anchor else { continue }
            let title = string(obj["title"]) ?? "untitled"
            let status = string(obj["status"]) ?? string(obj["phase"]) ?? "updated"
            touched.append((date, "\"\(clip(title, 80))\" (\(status))"))
        }
        guard !touched.isEmpty else { return nil }
        touched.sort { $0.0 > $1.0 }
        let shown = touched.prefix(3).map { $0.1 }.joined(separator: ", ")
        let suffix = touched.count > 3 ? " +\(touched.count - 3) more" : ""
        return clip("Workshop: \(touched.count) task(s) updated — \(shown)\(suffix)", 260)
    }

    // MARK: sources — agent inbox standups

    /// Headline per standup file (from_*.md) modified since the anchor:
    /// first `## ` header + first `**Worked on:**` line (newest-on-top
    /// convention — see docs/agent_inbox/REPORTING.md).
    private func standupLines(after anchor: Date) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: agentInboxDir.path) else {
            return []
        }
        var lines: [(Date, String)] = []
        for name in names.sorted() {
            guard name.hasPrefix("from_"), name.hasSuffix(".md") else { continue }
            let path = agentInboxDir.appendingPathComponent(name)
            guard let mtime = fileMTime(path), mtime > anchor else { continue }
            guard let head = readHead(at: path, maxBytes: Self.standupHeadBytes) else { continue }
            var header: String? = nil
            var workedOn: String? = nil
            for rawLine in head.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if header == nil, line.hasPrefix("## ") {
                    header = String(line.dropFirst(3))
                } else if header != nil, workedOn == nil, line.hasPrefix("**Worked on:**") {
                    workedOn = line
                        .replacingOccurrences(of: "**Worked on:**", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
                if header != nil, workedOn != nil { break }
            }
            let agent = String(name.dropFirst("from_".count).dropLast(".md".count))
            var body = "Standup from \(agent)"
            if let header { body += " (\(clip(header, 60)))" }
            if let workedOn, !workedOn.isEmpty { body += ": \(clip(workedOn, 180))" }
            lines.append((mtime, clip(body, 260)))
        }
        lines.sort { $0.0 > $1.0 }
        return Array(lines.prefix(2).map { $0.1 })
    }

    // MARK: sources — dream diary

    private func dreamsLine(after anchor: Date) -> String? {
        let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        var fresh: [(Date, String)] = []
        for name in names {
            guard name.hasSuffix(".md") else { continue }
            let path = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            guard let mtime = fileMTime(path), mtime > anchor else { continue }
            fresh.append((mtime, name))
        }
        guard !fresh.isEmpty else { return nil }
        fresh.sort { $0.0 > $1.0 }
        let latest = fresh[0].1
        let plural = fresh.count == 1 ? "entry" : "entries"
        return "Dream diary: \(fresh.count) new \(plural) (latest: \(clip(latest, 60)))"
    }

    // MARK: sources — traces

    private func tracesLine(after anchor: Date) -> String? {
        let path = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let rows = tailJSONLObjects(at: path, maxBytes: Self.tracesTailBytes)
        var total = 0
        var byKind: [String: Int] = [:]
        for obj in rows {
            guard let created = string(obj["createdAt"]),
                  let date = Self.parseTimestamp(created),
                  date > anchor else { continue }
            total += 1
            let kind = string(obj["kind"]) ?? "event"
            byKind[kind, default: 0] += 1
        }
        guard total > 0 else { return nil }
        // Deterministic ordering: count desc, then kind name.
        let top = byKind.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        return "Traces: \(total) events (\(top))"
    }

    // MARK: - file helpers (all fail-open)

    private func readJSON(at path: URL) -> JSONValue? {
        guard let size = fileSize(path), size <= Self.maxSourceFileBytes else { return nil }
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONValue.parse(data)
    }

    private func readHead(at path: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Last `maxBytes` of a JSONL file, decoded into top-level objects. The
    /// first (possibly partial) line is dropped when the read was truncated.
    private func tailJSONLObjects(at path: URL, maxBytes: Int) -> [[String: JSONValue]] {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        var out: [[String: JSONValue]] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let parsed = try? JSONValue.parse(lineData),
                  case .object(let obj) = parsed else { continue }
            out.append(obj)
        }
        return out
    }

    private func fileMTime(_ path: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    }

    private func fileSize(_ path: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue
    }

    // MARK: - value helpers

    private func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    private func clip(_ text: String, _ cap: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return MemoryTextClip.sentenceClip(normalized, cap: cap)
    }

    // MARK: - time helpers

    /// Parse the ISO8601 variants the codebase writes: "...Z", "...+00:00",
    /// and Python's 6-digit fractional seconds (normalized down to 3 —
    /// ISO8601DateFormatter only accepts millisecond fractions).
    static func parseTimestamp(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let d = MemoryRecallScoring.parseTimestamp(s) { return d }
        return MemoryRecallScoring.parseTimestamp(normalizeFraction(s))
    }

    /// "2026-05-05T23:38:45.362745+00:00" → "2026-05-05T23:38:45.362+00:00"
    private static func normalizeFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        var idx = s.index(after: dot)
        var digits = 0
        while idx < s.endIndex, s[idx].isNumber {
            digits += 1
            idx = s.index(after: idx)
        }
        guard digits > 3 else { return s }
        let keepEnd = s.index(dot, offsetBy: 4) // "." + 3 digits
        return String(s[..<keepEnd]) + String(s[idx...])
    }

    // DateFormatter is Sendable on this SDK (documented thread-safe since
    // macOS 10.9); configured once and never mutated (same convention as
    // MemoryRecallScoring's cached ISO formatters) — an explicit
    // nonisolated(unsafe) here is redundant and trips a build warning.
    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return f
    }()

    static func formatUTC(_ date: Date) -> String {
        utcFormatter.string(from: date)
    }
}
