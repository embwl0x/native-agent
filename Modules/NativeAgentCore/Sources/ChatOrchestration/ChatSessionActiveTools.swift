import Foundation
import NativeAgentCore
import PersistenceCore

// Per-session active-tool state for lazy tool loading.
//
// The chat path ships only `SwiftToolDispatcher.alwaysOnCoreNames` schemas
// every turn; every other built-in tool is gated behind `tool_load(names:[...])`.
// Explicit tool_load entries PERSIST for the session (2026-07-25: the old
// turn-end baseline restore caused session amnesia — a reload round-trip
// before nearly every action). Decay is owned by this store's 24h TTL and
// the explicit tool_unload path. Mechanical per-turn route preloads live in
// `LLMCallContext.turnActiveTools` and never grow this file.
// Entries TTL after 24h since last load — pruned lazily on the next
// `load(sessionId:)` as a crash/interruption backstop.

public struct ChatSessionActiveTools: Codable, Sendable, Equatable {
    public var sessionId: String
    public var activeTools: Set<String>
    public var loadedAt: [String: String]
    public var updatedAt: String

    public init(
        sessionId: String,
        activeTools: Set<String> = [],
        loadedAt: [String: String] = [:],
        updatedAt: String = ""
    ) {
        self.sessionId = sessionId
        self.activeTools = activeTools
        self.loadedAt = loadedAt
        self.updatedAt = updatedAt
    }
}

public actor ActiveToolsStore {
    public static let shared = ActiveToolsStore()

    private static let ttlSeconds: TimeInterval = 24 * 60 * 60

    /// Hard bound on the persisted per-session set (gpt-5.5 MED 2026-07-25,
    /// task #48): tool_load persists for the session now, so a long-lived
    /// session could otherwise accrete most of the lazy catalog for 24h and
    /// trade the reload tax for permanent prompt/schema bloat. On overflow the
    /// OLDEST loadedAt entries evict first; the names of the current load are
    /// always kept (evicting what was just asked for would silently undo the
    /// load the model believes succeeded). 24 ≈ the full coding group plus
    /// breathing room — no observed session has legitimately held more.
    static let maxPersistedTools = 24

    /// Orphan-sweep cadence — at most one directory GC pass per hour,
    /// regardless of how often load() is called. (loop-A finding 2026-06-13)
    private static let sweepIntervalSeconds: TimeInterval = 60 * 60

    private static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    nonisolated private static func iso8601Now() -> String {
        return makeISO8601().string(from: Date())
    }

    nonisolated private static func iso8601Parse(_ s: String) -> Date? {
        return makeISO8601().date(from: s)
    }

    private let persistence = SwiftNativePersistenceCore()
    private let dataRootOverride: URL?

    /// Last time the orphan sweep actually ran (throttle state).
    private var lastSweepAt: Date?

    public init(dataRoot: URL? = nil) {
        self.dataRootOverride = dataRoot
    }

    private func dataRoot() -> URL {
        if let dataRootOverride { return dataRootOverride }
        return PersistenceCore.defaultDataRoot()
    }

    private func pathFor(sessionId: String) -> URL {
        let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) ?? "invalid"
        return dataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("active_tools", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).json")
    }

    /// Delete per-session `active_tools/<id>.json` files whose mtime is older
    /// than the content TTL. load() only ever touches the requested session's
    /// own file, so a file orphaned by an ended/crashed session was never
    /// reachable by the in-file stale-prune and grew the directory without
    /// bound (loop-A finding 2026-06-13). Throttled to one pass per hour;
    /// best-effort. Runs OUTSIDE the per-session file lock — it only removes
    /// OTHER sessions' files, and a file this stale has no live session (the
    /// in-file content TTL is the same 24h), so the sole race — a session idle
    /// ~24h that reloads at the exact sweep instant — merely re-creates the
    /// file harmlessly.
    private func sweepOrphansIfDue() async {
        let now = Date()
        if let last = lastSweepAt, now.timeIntervalSince(last) < Self.sweepIntervalSeconds {
            return
        }
        lastSweepAt = now
        let dir = dataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("active_tools", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries where url.pathExtension == "json" {
            // Re-stat AND delete under THAT file's lock (gpt-5.5 review): a
            // concurrent load()/addLoaded() on the same session takes the same
            // lock, so the sweep can't remove a file another writer just
            // revived. The listing snapshot above is only a candidate set; the
            // authoritative stale check happens here, holding the lock.
            try? await persistence.withFileLock(url) {
                guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = vals.contentModificationDate,
                      now.timeIntervalSince(mtime) > Self.ttlSeconds else { return }
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Second pass: the .lock SIDECARS. The loop above only ever visited
        // `pathExtension == "json"`, so every ended session left a permanent
        // 0-byte `<id>.json.lock` behind — 7159 locks against 2 live state
        // files by 2026-07-25, oldest 2026-06-08, growing without bound. This
        // is the same unbounded-directory class the loop-A sweep was written
        // to stop, just on the extension it did not match (Agent, 2026-07-25).
        //
        // Reaping a lock is safe ONLY because withFileLock now validates that
        // the inode it locked is still the one at the path: a waiter holding
        // the unlinked inode fails that check and retries against the fresh
        // file, so mutual exclusion survives the unlink. Without that check
        // this pass would trade a harmless 8K of litter for lost writes.
        //
        // Three conditions, all required: the sibling .json is gone (so no
        // live session owns this id), the lock itself is older than the TTL,
        // and we hold the lock while unlinking. Note withFileLock WAITS for
        // the lock (LOCK_NB + async retry) rather than try-locking, so a
        // sidecar held by a slow live writer stalls this pass until it
        // releases — safe, but not skip-if-busy (gpt-5.5 review 2026-07-25).
        for lockURL in entries where lockURL.pathExtension == "lock" {
            let sibling = lockURL.deletingPathExtension()
            guard sibling.pathExtension == "json" else { continue }
            guard !fm.fileExists(atPath: sibling.path) else { continue }
            guard let vals = try? lockURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = vals.contentModificationDate,
                  now.timeIntervalSince(mtime) > Self.ttlSeconds else { continue }
            // withFileLock(sibling) locks exactly this sidecar. Re-check the
            // sibling INSIDE the lock: a session that revived between the
            // listing and here holds the same lock, so it cannot be racing us.
            try? await persistence.withFileLock(sibling) {
                guard !FileManager.default.fileExists(atPath: sibling.path) else { return }
                try? FileManager.default.removeItem(at: lockURL)
            }
        }
    }

    // Removed: nowISO() wrapper referenced an undeclared `Self.iso8601`
    // property. The existing nonisolated static helpers `Self.iso8601Now()`
    // and `Self.iso8601Parse(_:)` already cover the formatting; callers
    // use those directly so no await is needed.

    public func load(sessionId: String) async -> ChatSessionActiveTools {
        // Opportunistic, throttled GC of files left behind by ended sessions.
        // Runs before the per-session lock (it locks each candidate itself).
        await sweepOrphansIfDue()
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed) else {
            return ChatSessionActiveTools(sessionId: sessionId)
        }
        let path = pathFor(sessionId: trimmed)
        // gpt-5.5 review-2 NEEDS_FIX 2: do read + prune + save_if_changed
        // INSIDE one withFileLock closure. Previous version dropped the
        // lock between read and prune-write — a concurrent addLoaded()
        // could land mutations in that window, lost when our stale-prune
        // write returned. Now atomic.
        do {
            return try await persistence.withFileLock(path) {
                var state = await self.loadLocked(path: path, sessionId: trimmed)
                if Self.pruneStaleInPlace(&state) {
                    try? await self.saveLocked(state, path: path)
                }
                return state
            }
        } catch {
            return ChatSessionActiveTools(sessionId: trimmed)
        }
    }

    @discardableResult
    public func addLoaded(sessionId: String, names: Set<String>) async throws -> ChatSessionActiveTools {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed) else {
            throw NSError(
                domain: "ActiveToolsStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "invalid sessionId"]
            )
        }
        let path = pathFor(sessionId: trimmed)
        return try await persistence.withFileLock(path) {
            var state = await self.loadLocked(path: path, sessionId: trimmed)
            _ = Self.pruneStaleInPlace(&state)
            let stamp = Self.iso8601Now()
            for name in names {
                state.activeTools.insert(name)
                state.loadedAt[name] = stamp
            }
            Self.enforceCapInPlace(&state, protected: names)
            state.updatedAt = stamp
            try await self.saveLocked(state, path: path)
            return state
        }
    }

    /// LRU bound: evict oldest-loadedAt entries until the set fits
    /// `maxPersistedTools`, never touching `protected` (the load that is
    /// happening right now). Ties and unparseable stamps break by name so
    /// eviction is deterministic. If a single load is itself larger than the
    /// cap, the whole load is kept — the bound is against accretion across
    /// loads, not a veto on one explicit request.
    nonisolated static func enforceCapInPlace(
        _ state: inout ChatSessionActiveTools,
        protected: Set<String>
    ) {
        var overflow = state.activeTools.count - maxPersistedTools
        guard overflow > 0 else { return }
        let evictable = state.activeTools.subtracting(protected)
            .sorted { a, b in
                let sa = state.loadedAt[a] ?? ""
                let sb = state.loadedAt[b] ?? ""
                if sa != sb { return sa < sb }
                return a < b
            }
        for name in evictable {
            guard overflow > 0 else { break }
            state.activeTools.remove(name)
            state.loadedAt.removeValue(forKey: name)
            overflow -= 1
        }
    }

    @discardableResult
    public func removeLoaded(sessionId: String, names: Set<String>, all: Bool = false) async throws -> ChatSessionActiveTools {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed) else {
            throw NSError(
                domain: "ActiveToolsStore",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "invalid sessionId"]
            )
        }
        let path = pathFor(sessionId: trimmed)
        return try await persistence.withFileLock(path) {
            var state = await self.loadLocked(path: path, sessionId: trimmed)
            _ = Self.pruneStaleInPlace(&state)
            if all {
                state.activeTools.removeAll()
                state.loadedAt.removeAll()
            } else {
                for n in names {
                    state.activeTools.remove(n)
                    state.loadedAt.removeValue(forKey: n)
                }
            }
            state.updatedAt = Self.iso8601Now()
            try await self.saveLocked(state, path: path)
            return state
        }
    }

    // MARK: - Helpers (must be called while holding the file lock)

    private func loadLocked(path: URL, sessionId: String) async -> ChatSessionActiveTools {
        let json = await persistence.readJSON(path, defaultValue: .null)
        guard case .object(let obj) = json else {
            return ChatSessionActiveTools(sessionId: sessionId)
        }
        var active = Set<String>()
        if case .array(let arr) = obj["activeTools"] {
            for v in arr {
                if case .string(let s) = v { active.insert(s) }
            }
        }
        var loadedAt: [String: String] = [:]
        if case .object(let map) = obj["loadedAt"] {
            for (k, v) in map {
                if case .string(let s) = v { loadedAt[k] = s }
            }
        }
        let updatedAt: String = {
            if case .string(let s) = obj["updatedAt"] ?? .null { return s }
            return ""
        }()
        return ChatSessionActiveTools(
            sessionId: sessionId,
            activeTools: active,
            loadedAt: loadedAt,
            updatedAt: updatedAt
        )
    }

    private func saveLocked(_ state: ChatSessionActiveTools, path: URL) async throws {
        // An EMPTY loadout is persisted, not deleted (2026-08-01). This used to
        // `removeItem` the `<id>.json` whenever both sets went empty — which is
        // reachable on a fully LIVE session via `removeLoaded(all: true)` or the
        // in-file TTL prune. The lock-sidecar reaper above treats "sibling .json
        // absent" as proof that no live session owns the id, and nothing ever
        // refreshes the lock's mtime, so a >24h session that unloaded all its
        // tools had its IN-USE `<id>.json.lock` reaped out from under it.
        // Mutual exclusion survived (withFileLock revalidates the inode), but
        // the repeated reap/retry race hits that helper's `attempts >= 8` throw,
        // which load()'s catch swallows into an EMPTY loadout — session tool
        // amnesia. Keeping the sibling makes the reaper's liveness premise true.
        // load() reads an empty-state file identically to an absent one (empty
        // sets, prune no-ops), and the json half of the sweep still reaps this
        // file on mtime once it really is 24h cold.
        let body: JSONValue = .object([
            "sessionId": .string(state.sessionId),
            "activeTools": .array(state.activeTools.sorted().map { .string($0) }),
            "loadedAt": .object(state.loadedAt.mapValues { .string($0) }),
            "updatedAt": .string(state.updatedAt),
        ])
        try await persistence.writeJSON(body, to: path)
    }

    /// Returns true if anything was pruned (caller persists).
    /// nonisolated static so it can be called from inside the @Sendable
    /// withFileLock closure without an await (the inout param is value-typed
    /// and Sendable; the helper touches no actor state).
    nonisolated private static func pruneStaleInPlace(_ state: inout ChatSessionActiveTools) -> Bool {
        let now = Date()
        let nowStr = Self.iso8601Now()
        var changed = false
        for (name, stamp) in state.loadedAt {
            guard let when = Self.iso8601Parse(stamp) else {
                // Unparseable timestamp — replace with now so it doesn't churn forever.
                state.loadedAt[name] = nowStr
                changed = true
                continue
            }
            if now.timeIntervalSince(when) > Self.ttlSeconds {
                state.activeTools.remove(name)
                state.loadedAt.removeValue(forKey: name)
                changed = true
            }
        }
        // Drop activeTools without a loadedAt stamp older than ttl (defensive).
        for name in state.activeTools where state.loadedAt[name] == nil {
            state.loadedAt[name] = nowStr
            changed = true
        }
        if changed {
            state.updatedAt = nowStr
        }
        return changed
    }
}

/// A dispatcher participating in the lazy-tool loop exposes the exact store
/// that authorizes its session loadout. Engine/client construction uses this
/// narrow seam to avoid creating a second owner for the same turn.
public protocol ActiveToolsStoreProviding: Sendable {
    var activeToolsStore: ActiveToolsStore { get }
}
