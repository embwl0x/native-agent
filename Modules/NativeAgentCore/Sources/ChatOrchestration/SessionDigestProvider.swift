import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2

// MARK: - The /new carry-over ANCHOR (clause 6: reach, not weight)
//
// TWO LINES, one of which is a pointer. That is the whole payload.
//
// This file used to assemble a ~500-token "since last session" briefing out
// of five background sources (claude worklog, workshop executions, agent
// standups, dream diary, trace counts) plus a verbatim quote of her own last
// reply. Two things were wrong with it, and both are fixed here:
//
//   CLUTTER (clause 6). Two-thirds of those tokens were background telemetry
//   pushed IN FRONT of her on the first turn of every session whether or not
//   the turn needed any of it. The litmus is "reachable vs in-front-of":
//   trace counts and standup headlines are reachable through their own tools;
//   they were never worth the prompt mass. Deleted, bodies and all.
//
//   DISHONESTY (clause 2). `latestPriorSession` was surface-blind, so a
//   Telegram /new could be told its "previous session" was a codex bridge
//   probe, with the probe's machine output quoted back as her own last words.
//   277 of the 532 frozen digest.txt files on disk are exactly that. The
//   resolver below is surface-scoped and bridge-excluding (PriorChatSession),
//   and the quoted `Last reply:` line — with the greeting-stripping
//   workaround it needed — is gone: a pointer does not have to put words in
//   her mouth.
//
// What survives is what the carry-over actually needs: she starts a new
// session knowing a previous one exists, on THIS surface, with a name, a
// size, an age, and the exact call that pulls it back.
//
// BYTE-STABILITY (unchanged, and now trivially true): the anchor is injected
// at the HEAD of the DYNAMIC segment on the session's FIRST turn only, and
// its bytes are frozen on first build — persisted to
// <dataRoot>/chat/session_state/<sessionId>/digest.txt, single-flighted
// through `SessionDigestCache` so racing first turns cannot observe two
// byte sequences. Freezing is now unambiguously CORRECT: the two lines
// describe a session that has already ENDED, so nothing in them can go stale
// mid-session. Both layers stay fail-open — any filesystem error degrades to
// the in-memory value, never into the turn path.

// MARK: - PriorChatSession

/// "The session before this one", resolved ONCE and shared by both halves of
/// the carry-over: the anchor that names it, and `session_search(scope:
/// "previous_session")` that opens it. One definition means the tool can
/// never land on a different session than the anchor described — which is
/// also why the anchor never has to carry a UUID.
///
/// Three qualifications, in the order they were learned:
///   1. ENDED — anchor on the current session's `createdAt` and admit only
///      rows whose last activity strictly predates it. Without this an
///      interleaved second window (or a resumed old session) reads as "your
///      previous session" while it is still running.
///   2. SURFACE — a candidate must share the current row's `source` AND
///      `sourceKey`. Telegram's /new must not resurface a Mac window, and one
///      iOS device must not resurface another's.
///   3. HUMAN — bridge and probe runs are excluded, on BOTH sides: never
///      offered as the prior session, and never handed one. The bridge titles
///      a session with its own first message, so `[from: …, via bridge]` is
///      the marking; probe/bridge runs also mint slug ids where every real
///      surface session carries a UUID — except legacy `telegram:<chatId>`
///      threads, which are human and are carved back in by row source.
///   4. LIVE — archived rows are out, on both sides: a thread User has put
///      away is not "your previous session", and an archived current row has
///      no carry-over coming to it.
///
/// Strict on every axis by design: a row we cannot positively qualify drops
/// out and the anchor simply says nothing. Silence is the honest failure.
enum PriorChatSession {
    struct Resolved: Sendable {
        let id: String
        let title: String?
        let source: String?
        let updatedAt: Date
        let messageCount: Int?
    }

    /// A malformed or absurdly large index is not worth reading on a turn.
    private static let maxIndexBytes = 5 * 1024 * 1024

    static func latest(excluding currentSessionId: String, dataRoot: URL) -> Resolved? {
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxIndexBytes,
              let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .array(let rows) = parsed else { return nil }

        // No persisted row for the current session → we cannot know which
        // surface is asking, so we do not answer. In production the turn's
        // user message is persisted (and the row stamped with source +
        // sourceKey) before context assembly, so this is the fail-closed edge,
        // not the normal path.
        var anchor: Date? = nil
        var source: String? = nil
        var sourceKey: String? = nil
        for row in rows {
            guard case .object(let obj) = row, string(obj["id"]) == currentSessionId else { continue }
            // Symmetric with the candidate rule: a machine's conversation has
            // no human carry-over to be handed either. A bridge or probe run
            // that opens a fresh session must not be told what User was last
            // talking to her about on the Mac.
            guard !isMachineOrigin(
                id: currentSessionId,
                title: string(obj["title"]),
                source: string(obj["source"])
            ) else {
                return nil
            }
            // An archived current row is a thread User has already put away;
            // it has no live carry-over to be handed.
            guard bool(obj["archived"]) != true else { return nil }
            anchor = parseTimestamp(string(obj["createdAt"]) ?? string(obj["updatedAt"]) ?? "")
            source = string(obj["source"])
            sourceKey = string(obj["sourceKey"])
            break
        }
        guard let anchor else { return nil }

        var best: Resolved? = nil
        for row in rows {
            guard case .object(let obj) = row else { continue }
            guard let id = string(obj["id"]), id != currentSessionId else { continue }
            guard string(obj["source"]) == source, string(obj["sourceKey"]) == sourceKey else { continue }
            guard !isMachineOrigin(
                id: id, title: string(obj["title"]), source: string(obj["source"])
            ) else { continue }
            // Archived: retired by hand, not "your previous session".
            guard bool(obj["archived"]) != true else { continue }
            guard let updated = parseTimestamp(
                string(obj["updatedAt"]) ?? string(obj["createdAt"]) ?? ""
            ) else { continue }
            guard updated < anchor else { continue } // interleaved/later: skip
            if let best, best.updatedAt >= updated { continue }
            best = Resolved(
                id: id,
                title: string(obj["title"]),
                source: string(obj["source"]),
                updatedAt: updated,
                messageCount: int(obj["messageCount"])
            )
        }
        return best
    }

    /// Bridge/probe rows, which are conversations WITH A MACHINE that happen
    /// to run on chat's surface and permissions. Two markings:
    ///
    ///   TITLE — the bridge titles a session with its own first message, so
    ///   `"[from: "` + `"via bridge]"` is the tell (the same two-part shape
    ///   the tool preloader uses).
    ///
    ///   ID — bridge and probe runs choose their OWN session id. There is no
    ///   minting prefix to key on: `ClaudeBridge.bridgeMessageSessionID`
    ///   simply forwards whatever the caller put on the wire, so the live
    ///   index carries free-form slugs ("generalist-outcome-proof-20260830",
    ///   "murmur-house-art-review-20260828", "codex-architecture-loop-agent",
    ///   "telegram-drive-1780552030", "telegram:codex-probe"). Every real
    ///   Mac/iOS/Telegram session id, by contrast, is a UUID.
    ///
    /// The UUID test used to stand alone, and it was over-broad: Telegram's
    /// own store still mints `telegram:<chatId>` for legacy human threads
    /// (`TelegramSessionStore.legacySessionId`), and those were being read as
    /// probes — dropped from the /new pointer AND from `previous_session`.
    /// So one carve-out, and only one: a `telegram:<chatId>` id whose ROW
    /// says `source: "telegram"` is human. The row's source is what separates
    /// it from `telegram:codex-probe`, which the live index carries with
    /// `source: "app"`. A telegram-shaped id we cannot corroborate against a
    /// telegram row stays machine — fail closed, as everywhere else here.
    static func isMachineOrigin(id: String, title: String?, source: String? = nil) -> Bool {
        let normalized = (title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.hasPrefix("[from: "), normalized.contains("via bridge]") { return true }
        if UUID(uuidString: id) != nil { return false }
        return !isLegacyTelegramHumanId(id, source: source)
    }

    /// `telegram:<chatId>` (chatId is an Int, negative for groups) on a row
    /// whose source really is telegram — the ONE non-UUID id shape a human
    /// session legitimately carries.
    static func isLegacyTelegramHumanId(_ id: String, source: String?) -> Bool {
        guard (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "telegram" else { return false }
        guard id.hasPrefix("telegram:") else { return false }
        var chatId = Substring(id.dropFirst("telegram:".count))
        if chatId.first == "-" { chatId = chatId.dropFirst() }
        return !chatId.isEmpty && chatId.allSatisfy(\.isNumber)
    }

    // MARK: value + time helpers

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        if case .bool(let b)? = value { return b }
        return nil
    }

    static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i): return Int(i)
        case .double(let d): return Int(exactly: d.rounded(.towardZero))
        default: return nil
        }
    }

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
}

// MARK: - SessionDigestCache

/// Process-global per-session digest cache + build single-flight. The VALUE
/// is the rendered anchor ("" = computed-and-empty, also cached so a fresh
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
    /// Root of the daemon-format data dir (chat/sessions.json is the only
    /// source now — the five background feeds this used to read are gone).
    public let dataRoot: URL

    /// Safety net, not a working limit: the rendered anchor is ~180 chars in
    /// practice and cannot exceed ~200 with every field at its clip. The cap
    /// exists because the title comes off disk.
    static let digestCharCap = 220
    /// Titles are user/first-message derived; keep them short enough that the
    /// pointer sentence always survives.
    static let titleCharCap = 32
    /// First line of every rendered anchor (tests + adapters key off it).
    public static let headerLine = "# Since last session"
    /// The reach half of clause 6: the exact call that expands two lines back
    /// into the conversation they point at.
    public static let pointerSentence =
        "session_search(scope: \"previous_session\", mode: \"continuity\") pulls it back."

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// The per-session anchor, or nil when there is nothing to point at (no
    /// qualifying prior session on this surface, blank sessionId, unreadable
    /// index).
    ///
    /// BYTE-STABILITY: the first call for a (dataRoot, sessionId) pair builds
    /// ONCE (single-flighted across concurrent first turns), persists the
    /// bytes, and caches them; every later call returns those bytes verbatim.
    /// Never throws; all source errors degrade to absence.
    public func digest(forSessionId sessionId: String) async -> String? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = [dataRoot.path, trimmed].joined(separator: "\u{1F}")
        let provider = self
        let value = await SessionDigestCache.shared.value(forKey: key) {
            provider.loadOrBuildAndPersist(sessionId: trimmed)
        }
        return value.isEmpty ? nil : value
    }

    // MARK: durable per-session bytes (disk layer)

    /// Disk-first resolution: a previously persisted anchor ALWAYS wins over
    /// a rebuild. Runs inside the cache's single-flight, so one session never
    /// builds twice concurrently in-process; cross-PROCESS races (app +
    /// chat-drive over the same dataRoot) converge through the
    /// exclusive-publish below — the FIRST writer's bytes become canonical
    /// and losers adopt them.
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
    ///
    /// The ~532 digest.txt files already on disk hold the OLD five-source
    /// payload. They are not migrated or deleted: each belongs to one session,
    /// is only ever read back for that session, and every new session writes
    /// the new two-line shape. Retention prunes them with their sessions.
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
    /// our in-memory bytes — never throws into the turn path.
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
            return readPersistedDigest(sessionId: sessionId) ?? digest
        }
    }

    // MARK: build

    /// One uncached assembly pass. Internal so tests can exercise the builder
    /// directly; production goes through `digest(forSessionId:)`.
    ///
    /// `now` is frozen into the rendered age on purpose — see the file header:
    /// the sentence describes a session that has ended, so an age that never
    /// moves is both honest and what makes the bytes cache-safe.
    func buildDigest(
        currentSessionId: String,
        now: Date = Date(),
        cap: Int = SessionDigestProvider.digestCharCap
    ) -> String? {
        guard let prior = PriorChatSession.latest(
            excluding: currentSessionId, dataRoot: dataRoot
        ) else { return nil }

        var detail: [String] = []
        if let title = prior.title, !title.isEmpty {
            detail.append("\"\(clip(title, Self.titleCharCap))\"")
        }
        if let count = prior.messageCount, count > 0 {
            detail.append("\(count) message\(count == 1 ? "" : "s")")
        }
        var line = "Your last \(Self.surfaceLabel(prior.source)) session"
        if !detail.isEmpty { line += " (\(detail.joined(separator: ", ")))" }
        line += " ended \(Self.relativeAge(prior.updatedAt, from: now))."
        line += " " + Self.pointerSentence
        return MemoryTextClip.sentenceClip("\(Self.headerLine)\n\(line)", cap: cap)
    }

    /// CLOSED vocabulary. `source` is a disk string whose writer has an
    /// open-ended `default:` branch, and this lands in her system prompt —
    /// an unrecognized value renders as the neutral word, never as its own
    /// raw text (same posture as the transcript provenance badges).
    static func surfaceLabel(_ source: String?) -> String {
        switch (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telegram": return "Telegram"
        case "ios": return "iOS"
        case "app", "mac", "chat", "default": return "Mac"
        default: return "chat"
        }
    }

    /// Compact, prompt-sized age: "just now", "42m ago", "6h ago", "3d ago".
    static func relativeAge(_ date: Date, from reference: Date) -> String {
        let minutes = Int(max(0, reference.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private func clip(_ text: String, _ cap: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return MemoryTextClip.sentenceClip(normalized, cap: cap)
    }
}
