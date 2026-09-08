import Foundation
import NativeAgentCore
import PersistenceCore

// Per-session active-tool state for lazy tool loading.
//
// The chat path ships only `SwiftToolDispatcher.alwaysOnCoreNames` schemas
// every turn; every other built-in tool is gated behind `tool_load(names:[...])`.
// Explicit tool_load entries PERSIST for the session (2026-07-25: the old
// turn-end baseline restore caused session amnesia — a reload round-trip
// before nearly every action). Mechanical per-turn route preloads live in
// `LLMCallContext.turnActiveTools` and never grow this file.
//
// DECAY IS USAGE-BASED (2026-09-01, User: "when she's done with the tool it
// should go back to being lazy"). A loaded tool stays advertised while it is
// being CALLED: `markUsed` stamps `lastUsedTurn` on every dispatch, and
// `beginTurn` drops anything not called in the last 2 completed turns. The
// wall-clock 24h TTL is no longer the primary rule — it survives only as the
// directory orphan sweep for sessions that ended without unloading.
//
// Dropping is a prompt-prefix change, so it happens at turn START only, never
// mid-turn, and every expired name goes in ONE batch. `tool_unload` still
// drops sooner on request; `tool_load` brings a tool straight back.

/// A tool schema frozen into the session contract. Mirrors `LLMToolSchema`'s
/// model-visible fields; kept as its own type so the persisted shape does not
/// drift with the provider descriptor.
public struct PinnedToolSchema: Codable, Sendable, Equatable {
    public var description: String
    public var parametersJSON: Data

    public init(description: String, parametersJSON: Data) {
        self.description = description
        self.parametersJSON = parametersJSON
    }

    public init(_ schema: LLMToolSchema) {
        self.description = schema.description
        self.parametersJSON = schema.parametersJSON
    }

    public func schema(named name: String) -> LLMToolSchema {
        LLMToolSchema(name: name, description: description, parametersJSON: parametersJSON)
    }
}

/// Everything the advertising boundary needs, resolved ONCE and then held
/// still. `applyLazyToolFilter` takes this instead of reading live catalog
/// state, which is what makes two no-load turns provably identical.
public struct SessionToolContract: Sendable, Equatable {
    /// Append-only advertised order beyond the floor (pinned MCP, then loads).
    public let order: [String]
    /// Names with a live session load row (authorizes advertisement).
    public let loaded: Set<String>
    /// Descriptors pinned when each name entered the contract.
    public let pinnedSchemas: [String: PinnedToolSchema]
    /// The session's FROZEN DECLARATION: every tool name the provider `tools`
    /// array declares, in first-seen order, pinned once and only ever extended
    /// at a turn-start re-pin.
    ///
    /// WHY IT IS SEPARATE FROM `order`: `order` is what is ADVERTISED/offered
    /// and is supposed to move (loads, promotions, idle drops). The declaration
    /// is what the mid-conversation tool-change lane puts in `tools`, and that
    /// must not move at all — not for a Full-Mac policy flip, not for an
    /// activity-capture toggle, not for a registry tool whose readiness flaps,
    /// not for an MCP server leaving the detached cache. Policy still decides
    /// what is OFFERED and what may DISPATCH; it never decides membership here.
    public let declaredOrder: [String]
    /// Descriptors frozen at FIRST DECLARATION, so a name whose live schema
    /// disappears keeps declaring the body it was declared with.
    public let declaredSchemas: [String: PinnedToolSchema]
    /// Bumped by every re-pin. A change here is the one legitimate reason the
    /// declaration array moved, and the turn trace reports it alongside the
    /// array fingerprint so a cache miss can be attributed instead of guessed.
    public let declarationGeneration: Int

    public init(
        order: [String],
        loaded: Set<String>,
        pinnedSchemas: [String: PinnedToolSchema],
        declaredOrder: [String] = [],
        declaredSchemas: [String: PinnedToolSchema] = [:],
        declarationGeneration: Int = 0
    ) {
        self.order = order
        self.loaded = loaded
        self.pinnedSchemas = pinnedSchemas
        self.declaredOrder = declaredOrder
        self.declaredSchemas = declaredSchemas
        self.declarationGeneration = declarationGeneration
    }

    /// The declaration array as schemas, in declaration order. A name with no
    /// pinned descriptor is skipped — a declared row with no body is a 400
    /// waiting to happen.
    public var declaredToolSchemas: [LLMToolSchema] {
        declaredOrder.compactMap { declaredSchemas[$0]?.schema(named: $0) }
    }

    /// Pinned MCP membership. MCP tools are no longer admitted by prefix: a
    /// server appearing or vanishing in the detached cache mid-session must
    /// not change the contract until a turn start takes a new snapshot.
    public var pinnedMCPNames: Set<String> {
        Set(order.filter { $0.hasPrefix("mcp__") })
    }
}

public struct ChatSessionActiveTools: Codable, Sendable, Equatable {
    public var sessionId: String
    public var activeTools: Set<String>
    public var loadedAt: [String: String]
    /// APPEND-ONLY order of everything this session advertises beyond the
    /// floor: pinned `mcp__*` members first (they exist from turn one), then
    /// tools as they were loaded. The advertised catalog renders this run in
    /// exactly this order and never re-sorts it, so a load or an MCP arrival
    /// adds rows at the END instead of shifting every later row. A name that
    /// leaves (unload, idle drop, MCP server gone) loses its slot; coming back
    /// appends at the tail — one prefix rewrite, not a permanent reservation.
    public var loadOrder: [String]
    /// Schema descriptors PINNED at the moment a name entered the contract.
    ///
    /// The catalog walk is not a stable oracle: a registry/custom tool's
    /// readiness can flap, and the MCP set is served from a detached-refresh
    /// disk cache. Without a pin, either one silently drops rows from the
    /// advertised contract between two turns that did nothing. While a name
    /// holds a slot in `loadOrder` it is advertised from THIS descriptor.
    /// Dispatch is unaffected — it still rereads canonical readiness and
    /// returns an honest `unavailable` if the tool really is gone.
    public var pinnedSchemas: [String: PinnedToolSchema]
    /// Per-tool last-called turn, in this session's own turn numbering.
    public var lastUsedTurn: [String: Int]
    /// Completed-turn counter for this session, bumped by `beginTurn`.
    public var turnCount: Int
    /// What the most recent `beginTurn` dropped for idleness. Read by the turn
    /// trace (`tools.droppedCount`); not authority for anything.
    public var lastDropped: [String]
    /// FROZEN DECLARATION (see `SessionToolContract.declaredOrder`). OPTIONAL
    /// on purpose: a state file written before this field existed still
    /// decodes, and gets its declaration pinned on the next turn start.
    public var declaredOrder: [String]?
    /// Descriptors frozen at first declaration. Never removed by an idle drop,
    /// an unload, or an MCP departure — those change what is OFFERED, not what
    /// is DECLARED.
    public var declaredSchemas: [String: PinnedToolSchema]?
    /// Re-pin counter. 0/absent means "never pinned".
    public var declarationGeneration: Int?
    /// PROVENANCE of each `activeTools` row: names that entered by ROUTE
    /// PRELOAD PROMOTION (`commitTurnStartContract`) rather than an explicit
    /// `tool_load`. Both land in the same `activeTools` set, which is what
    /// `session_active_count` / `session_pinned_tool_count` report — so
    /// without this marker a loadout made entirely of machine guesses is
    /// indistinguishable from one the model asked for, and its size swinging
    /// turn to turn (a preload group lands, two idle turns retire it, the next
    /// message's group lands) reads as unexplained drift. Agent 2026-09-02:
    /// 18 → 17 → 24 → 5 → 19 → 17 across relaunches with no tool_load calls.
    /// An explicit `tool_load` of a promoted name clears the marker — it is a
    /// real request from then on.
    public var promotedTools: Set<String>
    /// Per-declared-name turn at which it was FIRST seen missing from the live
    /// declarable catalog, cleared the moment it comes back. Retirement needs
    /// sustained absence (see `turnsAbsentBeforeUndeclare`) so a one-turn
    /// catalog flap cannot unpin a declared tool.
    public var declaredAbsentSince: [String: Int]?
    public var updatedAt: String

    public init(
        sessionId: String,
        activeTools: Set<String> = [],
        loadedAt: [String: String] = [:],
        loadOrder: [String] = [],
        pinnedSchemas: [String: PinnedToolSchema] = [:],
        lastUsedTurn: [String: Int] = [:],
        turnCount: Int = 0,
        lastDropped: [String] = [],
        declaredOrder: [String]? = nil,
        declaredSchemas: [String: PinnedToolSchema]? = nil,
        declarationGeneration: Int? = nil,
        promotedTools: Set<String> = [],
        declaredAbsentSince: [String: Int]? = nil,
        updatedAt: String = ""
    ) {
        self.sessionId = sessionId
        self.activeTools = activeTools
        self.loadedAt = loadedAt
        self.loadOrder = loadOrder
        self.pinnedSchemas = pinnedSchemas
        self.lastUsedTurn = lastUsedTurn
        self.turnCount = turnCount
        self.lastDropped = lastDropped
        self.declaredOrder = declaredOrder
        self.declaredSchemas = declaredSchemas
        self.declarationGeneration = declarationGeneration
        self.promotedTools = promotedTools
        self.declaredAbsentSince = declaredAbsentSince
        self.updatedAt = updatedAt
    }

    /// Rows that entered by route-preload promotion and are still held.
    /// Intersected on read so a stale marker can never overstate the count.
    public var routePromotedTools: Set<String> { promotedTools.intersection(activeTools) }
    /// Rows an explicit `tool_load` asked for.
    public var explicitlyLoadedTools: Set<String> { activeTools.subtracting(promotedTools) }

    /// The advertised order: `loadOrder` narrowed to slots that are still
    /// real — a pinned MCP member, or a name with a live load row — plus any
    /// active name that predates load-order tracking (older state files),
    /// appended in sorted order so migration is deterministic.
    ///
    /// 2026-09-06: narrowed to the MODEL-VISIBLE boundary as well. A session
    /// file written before the four-verb cutover still carries rows such as
    /// `mac_focus_app` in `activeTools`, nothing prunes them, and turn start
    /// re-freezes their descriptor from the eager catalog every turn — so this
    /// order handed a legacy organ to the advertising boundary, which restored
    /// it from its pin and declared it to the model. Same rule the `tool_load`
    /// receipt now uses. Filtered rather than set-converted to keep the
    /// established order.
    public var advertisedLoadOrder: [String] {
        var out = loadOrder.filter { activeTools.contains($0) || $0.hasPrefix("mcp__") }
        let known = Set(out)
        out.append(contentsOf: activeTools.subtracting(known).sorted())
        let visible = SwiftToolDispatcher.modelVisibleCatalogToolNames(Set(out))
        return out.filter { visible.contains($0) }
    }

    /// WHERE THIS SET CAME FROM, for the `tool_load` / `agent_introspect`
    /// receipt. The pinned count moving with nothing loaded or unloaded was
    /// undiagnosable from the outside (Agent 2026-09-02: 18/17/24/5/19/17 over
    /// one night of relaunches); these five facts settle it on sight — whether
    /// the session file was found or the loadout restarted from empty, when it
    /// was last written, the session's own turn clock, and the split between
    /// rows the model ASKED for and rows a route preload GUESSED.
    public var pinnedSetProvenance: JSONValue {
        .object([
            "source": .string(
                updatedAt.isEmpty
                    ? "new_session (no prior state file read)"
                    : "chat/active_tools/\(sessionId).json"
            ),
            "last_saved": .string(updatedAt.isEmpty ? "never" : updatedAt),
            "session_turn": .int(Int64(turnCount)),
            "explicit_tool_load_count": .int(Int64(explicitlyLoadedTools.count)),
            "route_promoted_count": .int(Int64(routePromotedTools.count)),
            "note": .string(
                "route_promoted rows were added by turn-start preload prediction, not by tool_load, and retire after \(ActiveToolsStore.idleTurnsBeforeDrop) turns without a call — they are the usual reason this count changes on its own."
            ),
        ])
    }

    /// The frozen view handed to the advertising boundary.
    public var toolContract: SessionToolContract {
        SessionToolContract(
            order: advertisedLoadOrder,
            loaded: activeTools,
            pinnedSchemas: pinnedSchemas,
            declaredOrder: declaredOrder ?? [],
            declaredSchemas: declaredSchemas ?? [:],
            declarationGeneration: declarationGeneration ?? 0
        )
    }
}

public actor ActiveToolsStore {
    public static let shared = ActiveToolsStore()

    /// ORPHAN-SWEEP horizon only (2026-09-01). This is no longer the decay
    /// rule for a live session's loadout — `beginTurn`'s idle-turn drop owns
    /// that. What remains is the long backstop that removes `<id>.json` /
    /// `<id>.json.lock` files left behind by sessions that ended or crashed.
    private static let ttlSeconds: TimeInterval = 24 * 60 * 60

    /// A loaded tool survives this many COMPLETED turns without being called
    /// before `beginTurn` drops it back to lazy. 2 keeps a tool hot across the
    /// natural "call it, read the result, call it again" rhythm while a tool
    /// the model has finished with stops paying prompt rent almost immediately.
    static let idleTurnsBeforeDrop = 2

    /// Hard bound on the persisted per-session set (gpt-5.5 MED 2026-07-25,
    /// task #48): tool_load persists for the session now, so a long-lived
    /// session could otherwise accrete most of the lazy catalog for 24h and
    /// trade the reload tax for permanent prompt/schema bloat. On overflow the
    /// OLDEST loadedAt entries evict first; the names of the current load are
    /// always kept (evicting what was just asked for would silently undo the
    /// load the model believes succeeded). 24 ≈ the full coding group plus
    /// breathing room — no observed session has legitimately held more.
    static let maxPersistedTools = 24

    /// Hard bound on the FROZEN DECLARATION. The declaration holds a descriptor
    /// per name and ships in every request, so it cannot grow without limit —
    /// but it is a whole-catalog declaration, not a loadout, so its ceiling is
    /// an order of magnitude above `maxPersistedTools`. On overflow the
    /// declaration simply stops accepting new names (first-seen wins); those
    /// tools stay undeclarable until a new session, which is honest and
    /// bounded, unlike evicting a name the model may already have been offered.
    static let maxDeclaredTools = 256

    /// CONSECUTIVE turn starts a declared name must be missing from the live
    /// declarable catalog — and unoffered — before the declaration retires it.
    /// 3 clears the known one-and-two-turn absences (a cold MCP cache right
    /// after launch, a Full-Mac posture flip, a registry tool mid-reload)
    /// without letting a genuinely removed tool be declared forever.
    static let turnsAbsentBeforeUndeclare = 3

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

    /// The FROZEN DECLARATION's descriptor blob, held beside the per-turn state
    /// file rather than inside it.
    ///
    /// The declaration pins a full schema body per declared name — ~1.4KB each,
    /// up to `maxDeclaredTools` — while the per-turn file is rewritten on EVERY
    /// turn start (`beginTurn` always bumps `turnCount`). Serializing and
    /// atomically rewriting a few hundred KB of descriptors on the turn-start
    /// critical path bought nothing: the blob only changes when the declaration
    /// itself does. Names, generation and markers stay in the hot file; the
    /// bodies move here and are written ONLY on a generation change.
    ///
    /// Deliberately NOT a `.json` extension: the orphan sweep reaps any stale
    /// `*.json` in this directory on mtime, and this file is by design written
    /// rarely, so it would be the first thing reaped out from under a live
    /// session. No lock of its own — every read and write happens while holding
    /// the session's `<id>.json.lock`.
    nonisolated private static func declarationPath(for statePath: URL) -> URL {
        statePath.deletingPathExtension().appendingPathExtension("declaration")
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
                // The declaration sidecar is deliberately not a `.json`, so it
                // is never reaped on its own mtime (it is written rarely by
                // design). It dies with the state file it belongs to.
                try? FileManager.default.removeItem(at: Self.declarationPath(for: url))
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
        await reapOrphanedChatSessionLockSidecars(
            entries: entries, now: now, ttlSeconds: Self.ttlSeconds, persistence: persistence
        )
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
                if Self.normalizeInPlace(&state) {
                    try? await self.saveLocked(state, path: path)
                } else {
                    // TOUCH: the orphan sweep's staleness test is the file's
                    // mtime, and mtime only moved when the loadout CHANGED. A
                    // session that is being read every turn but whose pins have
                    // not moved in 24h therefore looked exactly like a file left
                    // behind by a crashed session, and was reaped under the lock
                    // — after which the next load starts from empty and the
                    // loadout silently reassembles from preloads. Reading the
                    // file is proof the session is live; say so in the one place
                    // the sweep looks. Best-effort: a failed touch costs at most
                    // the pre-existing behaviour.
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date()], ofItemAtPath: path.path
                    )
                }
                return state
            }
        } catch {
            return ChatSessionActiveTools(sessionId: trimmed)
        }
    }

    /// TURN-START boundary. Advances this session's turn counter and drops, in
    /// ONE batch, every loaded tool that has not been called in the last
    /// `idleTurnsBeforeDrop` completed turns.
    ///
    /// This is the only place a tool leaves the loadout for idleness, and it is
    /// deliberately at turn START: a drop rewrites the advertised contract, and
    /// a contract that changes MID-turn is exactly the prefix kill this whole
    /// change exists to stop. Call it once per turn, before the tool catalog is
    /// read; every other reader keeps using `load(sessionId:)`.
    @discardableResult
    public func beginTurn(sessionId: String) async -> ChatSessionActiveTools {
        await sweepOrphansIfDue()
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed) else {
            return ChatSessionActiveTools(sessionId: sessionId)
        }
        let path = pathFor(sessionId: trimmed)
        do {
            return try await persistence.withFileLock(path) {
                var state = await self.loadLocked(path: path, sessionId: trimmed)
                _ = Self.normalizeInPlace(&state)
                state.turnCount += 1
                let cutoff = state.turnCount - Self.idleTurnsBeforeDrop
                let dropped = state.activeTools
                    .filter { (state.lastUsedTurn[$0] ?? state.turnCount) < cutoff }
                    .sorted()
                for name in dropped {
                    state.activeTools.remove(name)
                    state.loadedAt.removeValue(forKey: name)
                    state.lastUsedTurn.removeValue(forKey: name)
                    state.pinnedSchemas.removeValue(forKey: name)
                    state.loadOrder.removeAll { $0 == name }
                }
                state.lastDropped = dropped
                state.updatedAt = Self.iso8601Now()
                try? await self.saveLocked(state, path: path)
                return state
            }
        } catch {
            return ChatSessionActiveTools(sessionId: trimmed)
        }
    }

    /// Outcome of the turn-start contract commit.
    public struct TurnContractCommit: Sendable, Equatable {
        public let state: ChatSessionActiveTools
        /// Preload names ACTUALLY admitted. Anything the caller offered that is
        /// missing here was not admitted (no headroom, or the write failed) and
        /// MUST NOT be treated as loaded — leave it discovery-only so
        /// `tool_load` stays the honest recovery path.
        public let promoted: Set<String>
        /// True when THIS commit pinned or extended the frozen declaration
        /// array — the one legitimate reason the provider `tools` array moved
        /// this turn. Reported in the turn trace next to the array fingerprint.
        public let declarationRepinned: Bool

        public init(
            state: ChatSessionActiveTools,
            promoted: Set<String>,
            declarationRepinned: Bool = false
        ) {
            self.state = state
            self.promoted = promoted
            self.declarationRepinned = declarationRepinned
        }
    }

    /// Second half of the TURN-START boundary: the one place, other than
    /// `beginTurn`'s idle drop, where the advertised contract may change.
    ///
    /// Three things happen here, batched into a single prefix rewrite:
    ///
    /// 1. MCP MEMBERSHIP SNAPSHOT. MCP tools used to be admitted by name
    ///    prefix straight from `mcp/cache/tools.json`, which a detached warmer
    ///    rewrites whenever it likes — so the advertised set could change
    ///    between two turns that loaded nothing. Membership is now pinned in
    ///    `loadOrder` and only re-snapshotted here: arrivals append at the
    ///    tail, departures free their slot and are reported as drops.
    /// 2. DESCRIPTOR PINNING. Every name holding a slot gets its schema frozen,
    ///    so a registry tool whose readiness flaps keeps advertising the
    ///    descriptor it was loaded with instead of silently vanishing.
    /// 3. PRELOAD PROMOTION. A confident route prediction joins the load order
    ///    exactly as `tool_load` would — advertised on this turn's first call
    ///    (docs/ANATOMY_OF_A_TURN.md §3: a GitHub URL prepares the GitHub read
    ///    tools with NO discovery round) and retired by the same 2-idle-turn
    ///    rule. HEADROOM ONLY: a preload is a guess, so it fills free slots and
    ///    never evicts an explicit `tool_load` the way `addLoaded` may.
    ///
    /// It cannot live inside `beginTurn`: both the preload set and the catalog
    /// snapshot are computed FROM `beginTurn`'s own output. Call it right
    /// after, before the prefix is built. Never mid-turn.
    @discardableResult
    public func commitTurnStartContract(
        sessionId: String,
        promoting: Set<String>,
        catalog: [LLMToolSchema]
    ) async -> TurnContractCommit? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed) else { return nil }
        let path = pathFor(sessionId: trimmed)
        // `let` on purpose: this is captured by the @Sendable file-lock closure.
        let descriptors: [String: PinnedToolSchema] = {
            var out: [String: PinnedToolSchema] = [:]
            out.reserveCapacity(catalog.count)
            for schema in catalog where out[schema.name] == nil {
                out[schema.name] = PinnedToolSchema(schema)
            }
            return out
        }()
        // Catalog order is the dispatcher's own stable walk, so a first
        // snapshot of several MCP servers lands in a repeatable order.
        let liveMCP = catalog.map(\.name).filter { $0.hasPrefix("mcp__") }
        // Declaration candidates in the dispatcher's own stable walk order.
        // MODEL-VISIBLE ONLY: the legacy Mac organ tools are never advertised
        // to a model, so declaring them would put rows in the array that no
        // addition block could ever reference.
        let declarable = SwiftToolDispatcher.modelVisibleCatalogToolNames(
            Set(catalog.map(\.name))
        )
        let declarationCandidates = catalog.map(\.name).filter { declarable.contains($0) }
        let commit: TurnContractCommit? = try? await persistence.withFileLock(path) {
            var state = await self.loadLocked(path: path, sessionId: trimmed)
            _ = Self.normalizeInPlace(&state)
            let before = state

            // 0. DECLARATION PIN (mid-conversation tool changes). The provider
            //    `tools` array is built from THIS, never from the live catalog:
            //    Full-Mac posture, activity capture and registry readiness all
            //    move the catalog turn to turn, and any of those moving the
            //    declaration is the prefix rebuild this lane exists to prevent.
            //
            //    APPEND-ONLY and MONOTONIC within a session: a name is pinned
            //    with its descriptor the first time it is seen and never leaves
            //    — a flap keeps declaring the pinned body, and a departure is
            //    handled by not OFFERING it, which costs nothing. A genuinely
            //    new built-in (policy just turned a family on) is an explicit
            //    RE-PIN at this turn start, counted in `declarationGeneration`
            //    and reported as an array change rather than sneaking in.
            var declaredOrder = state.declaredOrder ?? []
            var declaredSchemas = state.declaredSchemas ?? [:]
            var declaredSeen = Set(declaredOrder)
            var declarationRepinned = false
            for name in declarationCandidates where !declaredSeen.contains(name) {
                guard declaredOrder.count < Self.maxDeclaredTools else { break }
                guard let descriptor = descriptors[name] else { continue }
                declaredOrder.append(name)
                declaredSchemas[name] = descriptor
                declaredSeen.insert(name)
                declarationRepinned = true
            }
            // The assignment is DEFERRED to after step 3: retirement (below)
            // needs the final offered set, and the declaration must move at
            // most once per turn so one generation bump covers the whole
            // change.

            // 1. MCP membership snapshot.
            let liveMCPSet = Set(liveMCP)
            let pinnedMCP = state.loadOrder.filter { $0.hasPrefix("mcp__") }
            var dropped: [String] = []
            for name in pinnedMCP where !liveMCPSet.contains(name) {
                state.loadOrder.removeAll { $0 == name }
                state.pinnedSchemas.removeValue(forKey: name)
                dropped.append(name)
            }
            let pinnedMCPSet = Set(pinnedMCP)
            for name in liveMCP where !pinnedMCPSet.contains(name) {
                state.loadOrder.append(name)
            }

            // 2. Preload promotion, into free headroom only.
            let headroom = Self.maxPersistedTools - state.activeTools.count
            // An always-on name never needs a session row; promoting one would
            // put a floor tool in the appended run and shift every row after it.
            let admit = headroom > 0
                ? Array(
                    promoting
                        .subtracting(state.activeTools)
                        .subtracting(SwiftToolDispatcher.alwaysOnCoreNames)
                        .intersection(descriptors.keys)
                        .sorted()
                        .prefix(headroom)
                )
                : []
            let stamp = Self.iso8601Now()
            for name in admit {
                state.activeTools.insert(name)
                state.loadedAt[name] = stamp
                state.loadOrder.append(name)
                state.lastUsedTurn[name] = state.turnCount
                // A promotion is a GUESS, and it is the dominant reason this
                // set changes size between two turns the model did nothing in.
                // Mark it so the receipt can say so.
                state.promotedTools.insert(name)
            }

            // 3. Freeze a descriptor for every slot. A slot whose schema is
            //    missing from THIS catalog keeps the descriptor it already has.
            for name in state.loadOrder where descriptors[name] != nil {
                state.pinnedSchemas[name] = descriptors[name]
            }
            // A slot we have never seen a schema for cannot be advertised;
            // release it rather than promise a row with no body.
            for name in state.loadOrder where state.pinnedSchemas[name] == nil {
                state.loadOrder.removeAll { $0 == name }
                if state.activeTools.remove(name) != nil {
                    state.loadedAt.removeValue(forKey: name)
                    state.lastUsedTurn.removeValue(forKey: name)
                    dropped.append(name)
                }
            }

            // 4. DECLARATION RETIREMENT. Append-only was unbounded in the one
            //    direction that matters: a name that leaves the catalog for
            //    good kept being declared to the provider forever (up to
            //    `maxDeclaredTools`), so the `tools` array only ever grew and
            //    described tools that no longer exist.
            //
            //    ABSENCE MUST BE SUSTAINED, NOT INSTANTANEOUS. A single cold
            //    turn is not evidence a tool is gone: at launch the MCP cache
            //    is cold and registry readiness has not settled, and a Full-Mac
            //    posture flip or an activity-capture toggle moves the catalog
            //    for exactly one turn. Retiring on the first absent snapshot
            //    would hand the declaration straight back to the live catalog —
            //    the churn this lane exists to prevent. A name must therefore
            //    be missing from the declarable catalog at
            //    `turnsAbsentBeforeUndeclare` CONSECUTIVE turn starts, and not
            //    be offered right now, before it is retired; reappearing at any
            //    point clears the counter.
            var absentSince = state.declaredAbsentSince ?? [:]
            var retired: [String] = []
            if !declarationCandidates.isEmpty {
                let declarableNow = Set(declarationCandidates)
                let offeredNow = Set(state.advertisedLoadOrder)
                    .union(state.activeTools)
                    .union(SwiftToolDispatcher.alwaysOnCoreNames)
                for name in declaredOrder {
                    if declarableNow.contains(name) || offeredNow.contains(name) {
                        absentSince.removeValue(forKey: name)
                        continue
                    }
                    let first = absentSince[name] ?? state.turnCount
                    absentSince[name] = first
                    if state.turnCount - first + 1 >= Self.turnsAbsentBeforeUndeclare {
                        retired.append(name)
                    }
                }
            }
            if !retired.isEmpty {
                let gone = Set(retired)
                declaredOrder.removeAll { gone.contains($0) }
                for name in retired {
                    declaredSchemas.removeValue(forKey: name)
                    absentSince.removeValue(forKey: name)
                }
                declarationRepinned = true
            }
            // Prune counters for names no longer declared at all.
            let declaredNow = Set(declaredOrder)
            absentSince = absentSince.filter { declaredNow.contains($0.key) }

            // ONE declaration move per turn, covering both the additions from
            // step 0 and the retirements above.
            var declarationDirty = false
            if declarationRepinned || state.declaredOrder == nil {
                state.declaredOrder = declaredOrder
                state.declaredSchemas = declaredSchemas
                state.declarationGeneration = (state.declarationGeneration ?? 0) + 1
                declarationDirty = true
            }
            if absentSince != (state.declaredAbsentSince ?? [:]) {
                state.declaredAbsentSince = absentSince
            }

            if !dropped.isEmpty {
                state.lastDropped = (state.lastDropped + dropped).sorted()
            }
            if state != before {
                state.updatedAt = stamp
                try? await self.saveLocked(
                    state, path: path, declarationDirty: declarationDirty
                )
            }
            return TurnContractCommit(
                state: state,
                promoted: Set(admit),
                declarationRepinned: declarationRepinned
            )
        }
        return commit
    }

    /// Dispatch-time usage stamp. Keeps a tool that is actively being CALLED
    /// out of `beginTurn`'s idle drop — including a promoted preload, which is
    /// an ordinary session load from the moment it lands: called, it stays;
    /// ignored for two turns, it retires. Names with no persisted row
    /// (always-on core, MCP, an unpromoted turn-scoped preload) are skipped —
    /// there is nothing to keep alive.
    public func markUsed(sessionId: String, names: Set<String>) async {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed), !names.isEmpty else {
            return
        }
        let path = pathFor(sessionId: trimmed)
        try? await persistence.withFileLock(path) {
            var state = await self.loadLocked(path: path, sessionId: trimmed)
            let touched = names
                .intersection(state.activeTools)
                .filter { state.lastUsedTurn[$0] != state.turnCount }
            // Repeated calls to the same tool inside one turn are the common
            // case; rewriting the (now descriptor-bearing) state file on each
            // of them buys nothing.
            guard !touched.isEmpty else { return }
            for name in touched {
                state.lastUsedTurn[name] = state.turnCount
            }
            state.updatedAt = Self.iso8601Now()
            try? await self.saveLocked(state, path: path)
        }
    }

    /// Clear the route-promoted marker for names an explicit `tool_load` asked
    /// for by name.
    ///
    /// `addLoaded` already clears the marker for everything it persists, but it
    /// never sees the case this exists for: a tool the SAME turn's preload
    /// promoted is also in `LLMCallContext.turnActiveTools`, and `tool_load`
    /// subtracts the turn-scoped set from `toPersist` (there is nothing to
    /// write — the row is already there). The row therefore stayed marked as a
    /// machine guess although the model had just named it, and the receipt's
    /// explicit/promoted split reported the opposite of what happened.
    @discardableResult
    public func markExplicitlyRequested(
        sessionId: String,
        names: Set<String>
    ) async -> ChatSessionActiveTools? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentChatSessionID.isSafePathComponent(trimmed), !names.isEmpty else {
            return nil
        }
        let path = pathFor(sessionId: trimmed)
        return try? await persistence.withFileLock(path) {
            var state = await self.loadLocked(path: path, sessionId: trimmed)
            let cleared = names.intersection(state.promotedTools)
            guard !cleared.isEmpty else { return state }
            state.promotedTools.subtract(cleared)
            state.updatedAt = Self.iso8601Now()
            try? await self.saveLocked(state, path: path)
            return state
        }
    }

    @discardableResult
    public func addLoaded(
        sessionId: String,
        names: Set<String>,
        descriptors: [String: PinnedToolSchema] = [:]
    ) async throws -> ChatSessionActiveTools {
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
            _ = Self.normalizeInPlace(&state)
            let stamp = Self.iso8601Now()
            // Sorted so one multi-name load has a deterministic appended order
            // (a Set's iteration order is not stable across processes, and the
            // catalog's byte-stability depends on this list).
            for name in names.sorted() {
                let isNew = state.activeTools.insert(name).inserted
                state.loadedAt[name] = stamp
                // Explicitly asked for: no longer a guess, whoever put it here.
                state.promotedTools.remove(name)
                if isNew || !state.loadOrder.contains(name) {
                    state.loadOrder.removeAll { $0 == name }
                    state.loadOrder.append(name)
                }
                // A just-loaded tool counts as used THIS turn — otherwise a
                // load on the final turn of a lull would be dropped before the
                // model ever got to call it.
                state.lastUsedTurn[name] = state.turnCount
                // Pin the schema the load actually saw. If this tool's
                // readiness flaps later, the contract keeps advertising THIS
                // descriptor rather than dropping the row mid-session.
                if let descriptor = descriptors[name] {
                    state.pinnedSchemas[name] = descriptor
                }
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
            state.lastUsedTurn.removeValue(forKey: name)
            state.pinnedSchemas.removeValue(forKey: name)
            state.loadOrder.removeAll { $0 == name }
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
            _ = Self.normalizeInPlace(&state)
            if all {
                state.activeTools.removeAll()
                state.loadedAt.removeAll()
                state.lastUsedTurn.removeAll()
                // Pinned MCP membership is not a load; tool_unload(all:) must
                // not silently unadvertise the MCP surface too.
                state.loadOrder.removeAll { !$0.hasPrefix("mcp__") }
                state.pinnedSchemas = state.pinnedSchemas.filter { $0.key.hasPrefix("mcp__") }
            } else {
                for n in names {
                    state.activeTools.remove(n)
                    state.loadedAt.removeValue(forKey: n)
                    state.lastUsedTurn.removeValue(forKey: n)
                    state.pinnedSchemas.removeValue(forKey: n)
                    state.loadOrder.removeAll { $0 == n }
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
        var loadOrder: [String] = []
        if case .array(let arr) = obj["loadOrder"] ?? .null {
            for v in arr {
                if case .string(let s) = v { loadOrder.append(s) }
            }
        }
        var pinnedSchemas: [String: PinnedToolSchema] = [:]
        if case .object(let map) = obj["pinnedSchemas"] ?? .null {
            for (name, value) in map {
                guard case .object(let row) = value else { continue }
                var description = ""
                if case .string(let d) = row["description"] ?? .null { description = d }
                let parameters = row["parameters"] ?? .object(["type": .string("object")])
                let data = (try? parameters.serializedData(pretty: false)) ?? Data("{}".utf8)
                pinnedSchemas[name] = PinnedToolSchema(
                    description: description,
                    parametersJSON: data
                )
            }
        }
        var lastUsedTurn: [String: Int] = [:]
        if case .object(let map) = obj["lastUsedTurn"] ?? .null {
            for (k, v) in map {
                if case .int(let n) = v { lastUsedTurn[k] = Int(n) }
            }
        }
        var turnCount = 0
        if case .int(let n) = obj["turnCount"] ?? .null { turnCount = Int(n) }
        // FROZEN DECLARATION. This decode was missing: `saveLocked` never wrote
        // the three declaration fields and `loadLocked` never read them, so the
        // "pinned once, append-only, monotonic" declaration was in fact rebuilt
        // from the LIVE catalog at every single turn start, with
        // `declarationGeneration` stuck at 1. At launch the MCP cache is cold
        // and registry readiness has not settled, so the first turns after a
        // relaunch declared a different array than the ones before it — the
        // mid-conversation tool-change protection this field exists to provide
        // was never actually in force. Now round-tripped, so
        // `commitTurnStartContract` MERGES new names into the persisted
        // declaration instead of overwriting it from whatever the catalog
        // happens to hold this launch.
        var declaredOrder: [String]?
        if case .array(let arr) = obj["declaredOrder"] ?? .null {
            declaredOrder = arr.compactMap {
                if case .string(let s) = $0 { return s } else { return nil }
            }
        }
        func decodeSchemaMap(_ value: JSONValue) -> [String: PinnedToolSchema]? {
            guard case .object(let map) = value else { return nil }
            var out: [String: PinnedToolSchema] = [:]
            for (name, row) in map {
                guard case .object(let fields) = row else { continue }
                var description = ""
                if case .string(let d) = fields["description"] ?? .null { description = d }
                let parameters = fields["parameters"] ?? .object(["type": .string("object")])
                let data = (try? parameters.serializedData(pretty: false)) ?? Data("{}".utf8)
                out[name] = PinnedToolSchema(description: description, parametersJSON: data)
            }
            return out
        }
        // Descriptor bodies come from the sidecar. The inline key is the
        // MIGRATION path for state files written while the blob still lived in
        // the hot file — read it, and the next declaration change rewrites it
        // to the sidecar.
        var declarationGeneration: Int?
        if case .int(let n) = obj["declarationGeneration"] ?? .null {
            declarationGeneration = Int(n)
        }
        var declaredSchemas = decodeSchemaMap(obj["declaredSchemas"] ?? .null)
        if declaredSchemas == nil {
            let sidecar = await persistence.readJSON(
                Self.declarationPath(for: path), defaultValue: .null
            )
            // 2026-09-06: TWO FILES, ONE DECLARATION. `saveLocked` writes the
            // hot file (names + generation) and only then the sidecar (bodies),
            // so a crash in between leaves generation N+1's NAMES beside
            // generation N's SCHEMAS — and this read used to splice them
            // together. A sidecar that does not name this session and this
            // exact generation is not this declaration's other half: ignore it,
            // and the both-halves rule below re-pins cleanly.
            if case .object(let row) = sidecar,
               row["sessionId"] == obj["sessionId"],
               case .int(let sidecarGeneration)? = row["declarationGeneration"],
               Int(sidecarGeneration) == declarationGeneration {
                declaredSchemas = decodeSchemaMap(row["declaredSchemas"] ?? .null)
            }
        }
        var declaredAbsentSince: [String: Int]?
        if case .object(let map) = obj["declaredAbsentSince"] ?? .null {
            var out: [String: Int] = [:]
            for (k, v) in map {
                if case .int(let n) = v { out[k] = Int(n) }
            }
            declaredAbsentSince = out
        }
        // BOTH HALVES OR NEITHER. A declaration whose bodies are missing would
        // declare an array of names with no schemas — `declaredToolSchemas`
        // silently drops every one, and the provider gets an empty `tools`
        // array. If the sidecar is gone, treat the declaration as never pinned
        // so the next turn start re-pins it cleanly.
        if declaredOrder?.isEmpty == false, (declaredSchemas ?? [:]).isEmpty {
            declaredOrder = nil
            declaredSchemas = nil
            declarationGeneration = nil
            declaredAbsentSince = nil
        }
        var promotedTools = Set<String>()
        if case .array(let arr) = obj["promotedTools"] ?? .null {
            for v in arr {
                if case .string(let s) = v { promotedTools.insert(s) }
            }
        }
        var lastDropped: [String] = []
        if case .array(let arr) = obj["lastDropped"] ?? .null {
            for v in arr {
                if case .string(let s) = v { lastDropped.append(s) }
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
            loadOrder: loadOrder,
            pinnedSchemas: pinnedSchemas,
            lastUsedTurn: lastUsedTurn,
            turnCount: turnCount,
            lastDropped: lastDropped,
            declaredOrder: declaredOrder,
            declaredSchemas: declaredSchemas,
            declarationGeneration: declarationGeneration,
            promotedTools: promotedTools,
            declaredAbsentSince: declaredAbsentSince,
            updatedAt: updatedAt
        )
    }

    private func saveLocked(
        _ state: ChatSessionActiveTools,
        path: URL,
        declarationDirty: Bool = false
    ) async throws {
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
        var fields: [String: JSONValue] = [
            "sessionId": .string(state.sessionId),
            "activeTools": .array(state.activeTools.sorted().map { .string($0) }),
            "loadedAt": .object(state.loadedAt.mapValues { .string($0) }),
            "loadOrder": .array(state.loadOrder.map { .string($0) }),
            "pinnedSchemas": .object(state.pinnedSchemas.mapValues { pinned in
                .object([
                    "description": .string(pinned.description),
                    // Stored parsed so the state file stays one readable
                    // document rather than JSON-inside-a-JSON-string.
                    "parameters": (try? JSONValue.parse(pinned.parametersJSON))
                        ?? .object(["type": .string("object")]),
                ])
            }),
            "lastUsedTurn": .object(state.lastUsedTurn.mapValues { .int(Int64($0)) }),
            "turnCount": .int(Int64(state.turnCount)),
            "lastDropped": .array(state.lastDropped.map { .string($0) }),
            "promotedTools": .array(state.promotedTools.sorted().map { .string($0) }),
            "updatedAt": .string(state.updatedAt),
        ]
        // The frozen declaration is only frozen if it SURVIVES the process.
        // NAMES + generation + absence counters live here (cheap, and they
        // change most turns); the DESCRIPTOR BODIES live in the sidecar and are
        // written only when the declaration actually moved. Optional keys, so a
        // file from before this change still decodes (absent → nil → pinned on
        // the next turn start).
        if let declaredOrder = state.declaredOrder {
            fields["declaredOrder"] = .array(declaredOrder.map { .string($0) })
        }
        if let generation = state.declarationGeneration {
            fields["declarationGeneration"] = .int(Int64(generation))
        }
        if let absentSince = state.declaredAbsentSince, !absentSince.isEmpty {
            fields["declaredAbsentSince"] = .object(absentSince.mapValues { .int(Int64($0)) })
        }
        try await persistence.writeJSON(.object(fields), to: path)

        guard declarationDirty, let declaredSchemas = state.declaredSchemas else { return }
        let sidecar: JSONValue = .object([
            "sessionId": .string(state.sessionId),
            "declarationGeneration": .int(Int64(state.declarationGeneration ?? 0)),
            "declaredSchemas": .object(declaredSchemas.mapValues { pinned in
                .object([
                    "description": .string(pinned.description),
                    "parameters": (try? JSONValue.parse(pinned.parametersJSON))
                        ?? .object(["type": .string("object")]),
                ])
            }),
        ])
        try await persistence.writeJSON(sidecar, to: Self.declarationPath(for: path))
    }

    /// Repairs bookkeeping and MIGRATES state written before load-order /
    /// usage tracking existed. Returns true if anything changed (caller
    /// persists).
    ///
    /// The 24h wall-clock drop that used to live here is GONE: idleness is now
    /// measured in turns by `beginTurn`, and a session sitting untouched for a
    /// day is reclaimed by the file-level orphan sweep, not by silently
    /// emptying a live session's loadout. nonisolated static so it can be
    /// called from inside the @Sendable withFileLock closure without an await.
    nonisolated private static func normalizeInPlace(_ state: inout ChatSessionActiveTools) -> Bool {
        let nowStr = Self.iso8601Now()
        var changed = false
        for name in state.activeTools where state.loadedAt[name] == nil {
            state.loadedAt[name] = nowStr
            changed = true
        }
        for (name, stamp) in state.loadedAt where Self.iso8601Parse(stamp) == nil {
            // Unparseable timestamp — replace with now so it doesn't churn forever.
            state.loadedAt[name] = nowStr
            changed = true
        }
        // Names in loadOrder that are no longer real (or duplicated) would
        // otherwise keep a dead slot in the advertised order. A pinned `mcp__*`
        // member is real without an activeTools row — its slot is membership,
        // and only a turn-start snapshot may retire it.
        var seen = Set<String>()
        let compacted = state.loadOrder.filter { name in
            guard !seen.contains(name) else { return false }
            guard state.activeTools.contains(name) || name.hasPrefix("mcp__") else { return false }
            seen.insert(name)
            return true
        }
        if compacted != state.loadOrder {
            state.loadOrder = compacted
            changed = true
        }
        // Migration: a file written before load-order tracking has active
        // tools with no slot. Seed them in sorted order — deterministic, and
        // one rewrite rather than a per-turn reshuffle.
        let missing = state.activeTools.subtracting(seen).sorted()
        seen.formUnion(missing)
        if !missing.isEmpty {
            state.loadOrder.append(contentsOf: missing)
            changed = true
        }
        for name in state.activeTools where state.lastUsedTurn[name] == nil {
            state.lastUsedTurn[name] = state.turnCount
            changed = true
        }
        for name in state.lastUsedTurn.keys where !state.activeTools.contains(name) {
            state.lastUsedTurn.removeValue(forKey: name)
            changed = true
        }
        // A descriptor outlives nothing: no slot, no pin.
        for name in state.pinnedSchemas.keys where !seen.contains(name) {
            state.pinnedSchemas.removeValue(forKey: name)
            changed = true
        }
        // Nor does a provenance marker outlive the row it describes.
        for name in state.promotedTools where !state.activeTools.contains(name) {
            state.promotedTools.remove(name)
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
