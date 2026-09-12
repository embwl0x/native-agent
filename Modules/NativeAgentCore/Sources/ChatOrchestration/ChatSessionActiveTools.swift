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
    ///
    /// NOT dispatch evidence: `beginTurn`'s promotion stamps the current turn
    /// on every tool it admits, before the model has called anything. Anything
    /// that needs "this tool actually ran" reads `dispatchedTurn`.
    public var lastUsedTurn: [String: Int]
    /// Per-tool last turn the DISPATCHER gated a real call on. Written in
    /// exactly one place — `markUsed`, from the gated dispatch path — and never
    /// by promotion, load or migration, so a name here was executed this turn
    /// (GPT-5.6 round review, 2026-09-11). Under-reports (always-on core and
    /// `mcp__*` names carry no session row); missing evidence is the safe side.
    public var dispatchedTurn: [String: Int]
    /// WALL-CLOCK last dispatch per tool, ISO8601.
    ///
    /// `dispatchedTurn` is cleared at every turn start, so it can only answer
    /// "called THIS turn". The idle-boundary floor rebuild
    /// (`commitTurnStartContract` step 1a) asks "called in the last 24 hours",
    /// which has to survive turns, relaunches and overnight gaps. Same single
    /// writer as `dispatchedTurn` — `markUsed`, from the gated dispatch path —
    /// and therefore the same evidence: a real call, never a promotion, a load
    /// or a migration. Rows older than `floorDispatchWindowSeconds` are pruned
    /// by `normalizeInPlace`, so this cannot grow without bound.
    public var lastDispatchedAt: [String: String]
    /// The turn counter at the last GATED dispatch, and the turn a name joined
    /// the offer floor. Together they are the only evidence the two-idle-turn
    /// unload reads (docs/TOOL_LOADING.md): `lastUsedTurn` is also stamped by
    /// turn-start promotion, which is a guess, not a call.
    public var lastDispatchedTurn: [String: Int]
    public var floorJoinedTurn: [String: Int]
    /// The turn a name was idle-dropped. A route promotion is a GUESS; a guess
    /// that sat unused for two turns does not get re-promoted for
    /// `promotionCooldownTurns` unless the model loads it or calls it. Without
    /// this the same 20 desk/github/mail guesses were re-promoted on every
    /// bridge turn and never left the wire (docs/TOOL_LOADING.md rule 2).
    public var idleDroppedTurn: [String: Int]
    /// Wall clock of the most recent `beginTurn` for this session, ISO8601.
    public var lastTurnAt: String?
    /// Seconds between the previous turn start and the most recent one, as
    /// measured by `beginTurn`. nil on a session's first turn in this file.
    /// Read once per turn by the idle-boundary floor rebuild.
    public var lastIdleGapSeconds: Double?
    /// RECEIPT of the most recent idle-boundary floor rebuild: the turn it ran
    /// on (also the once-per-turn guard), what it retired, how many floor
    /// entries it kept, and the idle gap that triggered it. Reporting only.
    public var lastFloorRebuildTurn: Int?
    public var lastFloorRetired: [String]?
    public var lastFloorKeptCount: Int?
    public var lastFloorRebuildGapSeconds: Double?
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
    /// DURABLE record of every name an explicit `tool_load` asked for, for as
    /// long as the session holds it.
    ///
    /// `explicitlyLoadedTools` derives provenance from what is still in
    /// `activeTools`, which makes it unusable as protection against the thing
    /// that protection is for: `beginTurn` idle-drops a row BEFORE the floor
    /// rebuild runs, so an explicitly loaded tool the model had not called
    /// recently arrived at the rebuild looking exactly like a machine guess and
    /// was retired — the user's own load vanishing on the first qualifying
    /// return. This set is therefore NOT pruned against `activeTools`; it is
    /// cleared only by `tool_unload` of that name (or of `all`).
    public var explicitLoads: Set<String>
    /// Per-declared-name turn at which it was FIRST seen missing from the live
    /// declarable catalog, cleared the moment it comes back. Retirement needs
    /// sustained absence (see `turnsAbsentBeforeUndeclare`) so a one-turn
    /// catalog flap cannot unpin a declared tool.
    public var declaredAbsentSince: [String: Int]?
    /// APPEND-ONLY SESSION DECLARATION for routes with NO defer lane (every
    /// non-Anthropic-api-key route, ChatGPT included). There the provider
    /// `tools` array IS the cached prefix and there is no way to declare a
    /// tool without offering it, so anything that moves the offered set — an
    /// idle drop, a different route prediction — costs the whole prefix at
    /// full price on the next turn's FIRST call.
    ///
    /// A name that has been offered once in this session therefore KEEPS its
    /// slot: `commitTurnStartContract` re-admits it after `beginTurn`'s idle
    /// drop, in this order, so the array only ever appends. Bounded by
    /// `maxStableDeclaredTools`; overflow evicts least-recently-used AT THE
    /// TURN BOUNDARY only, and the names land in `lastOfferEvicted` so a
    /// fingerprint change has a reason next to it.
    ///
    /// nil on a route that can declare without offering — there the frozen
    /// `declaredOrder` already does this job and the offered set is free to
    /// move behind the cache breakpoint.
    public var offerFloor: [String]?
    /// What the last turn-boundary LRU eviction removed from `offerFloor`.
    /// Reporting only; the array fingerprint is authority.
    public var lastOfferEvicted: [String]?
    public var updatedAt: String

    public init(
        sessionId: String,
        activeTools: Set<String> = [],
        loadedAt: [String: String] = [:],
        loadOrder: [String] = [],
        pinnedSchemas: [String: PinnedToolSchema] = [:],
        lastUsedTurn: [String: Int] = [:],
        dispatchedTurn: [String: Int] = [:],
        lastDispatchedAt: [String: String] = [:],
        lastDispatchedTurn: [String: Int] = [:],
        floorJoinedTurn: [String: Int] = [:],
        idleDroppedTurn: [String: Int] = [:],
        lastTurnAt: String? = nil,
        lastIdleGapSeconds: Double? = nil,
        lastFloorRebuildTurn: Int? = nil,
        lastFloorRetired: [String]? = nil,
        lastFloorKeptCount: Int? = nil,
        lastFloorRebuildGapSeconds: Double? = nil,
        turnCount: Int = 0,
        lastDropped: [String] = [],
        declaredOrder: [String]? = nil,
        declaredSchemas: [String: PinnedToolSchema]? = nil,
        declarationGeneration: Int? = nil,
        promotedTools: Set<String> = [],
        explicitLoads: Set<String> = [],
        declaredAbsentSince: [String: Int]? = nil,
        offerFloor: [String]? = nil,
        lastOfferEvicted: [String]? = nil,
        updatedAt: String = ""
    ) {
        self.sessionId = sessionId
        self.activeTools = activeTools
        self.loadedAt = loadedAt
        self.loadOrder = loadOrder
        self.pinnedSchemas = pinnedSchemas
        self.lastUsedTurn = lastUsedTurn
        self.dispatchedTurn = dispatchedTurn
        self.lastDispatchedAt = lastDispatchedAt
        self.lastDispatchedTurn = lastDispatchedTurn
        self.floorJoinedTurn = floorJoinedTurn
        self.idleDroppedTurn = idleDroppedTurn
        self.lastTurnAt = lastTurnAt
        self.lastIdleGapSeconds = lastIdleGapSeconds
        self.lastFloorRebuildTurn = lastFloorRebuildTurn
        self.lastFloorRetired = lastFloorRetired
        self.lastFloorKeptCount = lastFloorKeptCount
        self.lastFloorRebuildGapSeconds = lastFloorRebuildGapSeconds
        self.turnCount = turnCount
        self.lastDropped = lastDropped
        self.declaredOrder = declaredOrder
        self.declaredSchemas = declaredSchemas
        self.declarationGeneration = declarationGeneration
        self.promotedTools = promotedTools
        self.explicitLoads = explicitLoads
        self.declaredAbsentSince = declaredAbsentSince
        self.offerFloor = offerFloor
        self.lastOfferEvicted = lastOfferEvicted
        self.updatedAt = updatedAt
    }

    /// Rows that entered by route-preload promotion and are still held.
    /// Intersected on read so a stale marker can never overstate the count.
    public var routePromotedTools: Set<String> { promotedTools.intersection(activeTools) }
    /// Rows an explicit `tool_load` asked for.
    public var explicitlyLoadedTools: Set<String> { activeTools.subtracting(promotedTools) }
    /// Every name the user's own `tool_load` is responsible for, whether or not
    /// it currently holds an `activeTools` row. This — never
    /// `explicitlyLoadedTools` — is what floor retirement and make-room
    /// eviction must protect, because both run after an idle drop has already
    /// taken the row away.
    public var durableExplicitTools: Set<String> {
        explicitLoads.union(explicitlyLoadedTools)
    }

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
    static let promotionCooldownTurns = 12

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

    /// Hard bound on the APPEND-ONLY OFFER FLOOR (`offerFloor`) that routes
    /// with no defer lane use instead of an idle-dropping loadout. It is a
    /// loadout, not a whole-catalog declaration — every name in it is both
    /// advertised AND dispatchable — so it sits far below the declaration's
    /// ceiling. 40 is `maxPersistedTools` plus room for a couple more
    /// families: the floor never retires on idleness, so a session that
    /// preloads GitHub, then mail, then calendar must be able to keep all
    /// three declared rather than trade one for the next. On overflow the
    /// LEAST-RECENTLY-USED names go, at a turn boundary only, and are
    /// reported in `lastOfferEvicted` so a fingerprint move has a reason
    /// next to it.
    static let maxStableDeclaredTools = 40

    /// IDLE GAP that opens an offer-floor REBUILD (Astra comb 4 lane 3, accepted
    /// by Agent as a trial 2026-09-12). The floor never retires on idleness, so
    /// a burst that preloaded GitHub yesterday kept paying for 15 GitHub schemas
    /// on every call today — bounded retention, but no evidence of a useful
    /// working set. 30 minutes without a turn is the quiet boundary: long enough
    /// that the provider prefix is cold anyway (the measured 5h09m return read
    /// zero cached tokens on its first call), short enough to catch the start of
    /// a new working session. Inside a burst the gap is seconds, so the floor is
    /// preserved exactly as before — the rebuild happens once, at the seam.
    static let floorRebuildIdleSeconds: TimeInterval = 30 * 60

    /// How far back a floor entry may have been DISPATCHED and still be kept by
    /// the rebuild. Evidence is `lastDispatchedAt` — a real gated call — never a
    /// preload guess. 24h covers a working day plus a night, so a tool used
    /// yesterday afternoon survives this morning's first turn.
    static let floorDispatchWindowSeconds: TimeInterval = 24 * 60 * 60

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

    /// Turn number THIS process's `beginTurn` last set, per session.
    ///
    /// `beginTurn` bumps `turnCount` and clears `dispatchedTurn` in one write,
    /// but that write is best-effort: a suppressed failure leaves the PREVIOUS
    /// turn's number and the previous turn's stamps on disk, mutually
    /// consistent and therefore indistinguishable from this turn's evidence.
    /// This is the authority a dispatch-evidence reader compares against
    /// (GPT-5.6 round review r2, 2026-09-11); a mismatch under-reports, which
    /// is the safe direction.
    private var turnInMemory: [String: Int] = [:]

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
            let state = try await persistence.withFileLock(path) {
                var state = await self.loadLocked(path: path, sessionId: trimmed)
                _ = Self.normalizeInPlace(&state)
                state.turnCount += 1
                // LAST TURN'S DISPATCH EVIDENCE DIES HERE, before the save.
                // The stamps describe the turn that just ended; carried into
                // this one they let a correction be narrowed by a tool the
                // model never called this turn.
                state.dispatchedTurn.removeAll()
                // IDLE GAP, measured once here and read once by
                // `commitTurnStartContract`'s floor rebuild. Recomputed every
                // turn from the PREVIOUS turn start, so it is seconds inside a
                // conversation burst and hours on a return.
                let now = Date()
                state.lastIdleGapSeconds = state.lastTurnAt
                    .flatMap(Self.iso8601Parse)
                    .map { max(0, now.timeIntervalSince($0)) }
                state.lastTurnAt = Self.makeISO8601().string(from: now)
                let cutoff = state.turnCount - Self.idleTurnsBeforeDrop
                // Idle = no GATED CALL for `idleTurnsBeforeDrop` turns, counted
                // from the later of its last dispatch and the turn it joined
                // the floor (or was loaded). Promotion stamps are not calls.
                func lastEvidenceTurn(_ name: String) -> Int {
                    // A real call is the evidence; the join stamp only stands
                    // in for a tool that has never been called (otherwise the
                    // restore's later stamp bought a third idle turn).
                    state.lastDispatchedTurn[name]
                        ?? state.floorJoinedTurn[name]
                        ?? state.lastUsedTurn[name]
                        ?? state.turnCount
                }
                let dropped = state.activeTools
                    .filter { lastEvidenceTurn($0) < cutoff }
                    .sorted()
                // THE AGREED RULE (User, 2026-09-12): a tool not called for
                // `idleTurnsBeforeDrop` turns UNLOADS — from the offer floor
                // too, not only from the active set. The append-only floor of
                // 2026-09-11 restored every idle-dropped name for cache
                // stability and silently overrode this; the one missed cache
                // read after a drop is the accepted price. Explicit loads and
                // the always-on core stay.
                // Only the always-on core is exempt from the idle unload. An
                // explicit `tool_load` is one call away from coming back; a tool
                // the model loaded and then did not use for two turns is the
                // exact case the rule exists for (User, 2026-09-12).
                let protected = SwiftToolDispatcher.alwaysOnCoreNames
                for name in dropped {
                    state.activeTools.remove(name)
                    state.loadedAt.removeValue(forKey: name)
                    state.lastUsedTurn.removeValue(forKey: name)
                    state.pinnedSchemas.removeValue(forKey: name)
                    state.loadOrder.removeAll { $0 == name }
                    if !protected.contains(name) {
                        state.offerFloor?.removeAll { $0 == name }
                        state.floorJoinedTurn.removeValue(forKey: name)
                        state.lastDispatchedTurn.removeValue(forKey: name)
                        state.idleDroppedTurn[name] = state.turnCount
                        state.explicitLoads.remove(name)
                    }
                }
                state.lastDropped = dropped
                state.updatedAt = Self.iso8601Now()
                try? await self.saveLocked(state, path: path)
                return state
            }
            turnInMemory[trimmed] = state.turnCount
            return state
        } catch {
            // The turn boundary never happened, so nothing on disk can be
            // trusted as THIS turn's dispatch evidence. A sentinel no stamp
            // can equal leaves every correction global until a turn start
            // succeeds again.
            turnInMemory[trimmed] = Int.min
            return ChatSessionActiveTools(sessionId: trimmed)
        }
    }

    /// The current turn number as THIS process set it at the last `beginTurn`,
    /// or nil for a session this process has not started a turn for. Readers
    /// of `dispatchedTurn` must compare against this rather than the
    /// `turnCount` reloaded from disk — see `turnInMemory`.
    public func currentTurn(sessionId: String) -> Int? {
        turnInMemory[sessionId.trimmingCharacters(in: .whitespacesAndNewlines)]
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
        /// Non-nil when THIS commit rebuilt the offer floor at an idle
        /// boundary. Feeds the `tools.floorRebuilt` receipt row so the trial
        /// can be measured.
        public let floorRebuild: FloorRebuild?

        public init(
            state: ChatSessionActiveTools,
            promoted: Set<String>,
            declarationRepinned: Bool = false,
            floorRebuild: FloorRebuild? = nil
        ) {
            self.state = state
            self.promoted = promoted
            self.declarationRepinned = declarationRepinned
            self.floorRebuild = floorRebuild
        }
    }

    /// One idle-boundary offer-floor rebuild, as measured.
    public struct FloorRebuild: Sendable, Equatable {
        /// Floor entries retired for want of dispatch evidence. Every one of
        /// them stays discoverable and `tool_load`-able.
        public let retired: [String]
        /// Floor entries that survived: dispatched inside the window, held by
        /// an explicit `tool_load`, or wanted by this turn's preload.
        public let kept: Int
        /// The gap that opened the rebuild.
        public let idleGapSeconds: Double

        public init(retired: [String], kept: Int, idleGapSeconds: Double) {
            self.retired = retired
            self.kept = kept
            self.idleGapSeconds = idleGapSeconds
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
        catalog: [LLMToolSchema],
        stableToolArray: Bool = false
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

            // 1a. IDLE-BOUNDARY FLOOR REBUILD (stable-array routes only).
            //     Astra comb 4 lane 3, accepted by Agent as a trial: at the
            //     first turn after `floorRebuildIdleSeconds` without one,
            //     rebuild the floor from tools ACTUALLY DISPATCHED in the last
            //     `floorDispatchWindowSeconds`, plus this turn's explicit loads
            //     and confident preloads. Measured on live session D53339E5:
            //     none of its 40 floor entries had been dispatched in the 24h
            //     before a 5h09m return, yet all 40 rode every call.
            //
            //     Evidence is `lastDispatchedAt` ONLY — a gated call. A preload
            //     stamp (`lastUsedTurn`) is a guess and is deliberately not
            //     consulted: that conflation is the finding. Explicit
            //     `tool_load` rows are protected, the 20 always-on core names
            //     and the pinned MCP run are untouched, and everything retired
            //     stays discoverable and loadable.
            //
            //     ONCE PER TURN, at the seam only: inside the ensuing burst the
            //     measured gap is seconds, so the floor is preserved exactly as
            //     before. `lastFloorRebuildTurn` also makes a second commit in
            //     the same turn a no-op.
            // The 30-minute idle-boundary rebuild (Astra comb 4 trial) was
            // withdrawn on 2026-09-12: the unload rule is TURNS, not time
            // (docs/TOOL_LOADING.md rule 2); with the two-turn rule restored the
            // timer had nothing left to do.
            let floorRebuild: FloorRebuild? = nil

            // 1b. OFFER-FLOOR MAKE-ROOM (stable-array routes only). The floor
            //     never retires on idleness, so a session that has filled it
            //     would otherwise have zero headroom and never preload another
            //     family again. Evict the least-recently-used entries — at
            //     this turn boundary, never mid-turn — for exactly the number
            //     of new names this turn wants to promote.
            var floor = stableToolArray ? (state.offerFloor ?? []) : []
            var floorSeen = Set(floor)
            var offerEvicted: [String] = []
            // Promotions this pass could not make room for without evicting a
            // protected entry. Subtracted from the admission set in step 2.
            var promotionRefused = Set<String>()
            if stableToolArray {
                let cooled = Set(state.idleDroppedTurn.filter {
                    state.turnCount - $0.value < Self.promotionCooldownTurns
                }.keys)
                let wanted = promoting
                    .subtracting(cooled)
                    .subtracting(SwiftToolDispatcher.alwaysOnCoreNames)
                    .intersection(descriptors.keys)
                    .subtracting(floorSeen)
                let overflow = floor.count + wanted.count - Self.maxStableDeclaredTools
                if overflow > 0 {
                    // ONLY UNPROTECTED FLOOR ENTRIES ARE RANKED. Ranking the
                    // whole floor let this pass retire an older explicit load
                    // (or an always-on core row) in the same commit that the
                    // rebuild above had just protected — a machine guess
                    // displacing a user's own request.
                    let protected = state.durableExplicitTools
                        .union(SwiftToolDispatcher.alwaysOnCoreNames)
                    let ranked = floor.enumerated()
                        .filter { !protected.contains($0.element) }
                        .sorted {
                            let a = state.lastUsedTurn[$0.element] ?? 0
                            let b = state.lastUsedTurn[$1.element] ?? 0
                            return a == b ? $0.offset < $1.offset : a < b
                        }
                    offerEvicted = ranked.prefix(overflow).map(\.element).sorted()
                    // Nothing unprotected left to give: REFUSE the weakest
                    // promotions rather than evict a protected entry. Same tail
                    // that step 2's headroom cap would have dropped, so the
                    // admitted set stays the sorted prefix either way.
                    if offerEvicted.count < overflow {
                        promotionRefused = Set(
                            wanted.sorted().suffix(overflow - offerEvicted.count)
                        )
                    }
                    let gone = Set(offerEvicted)
                    floor.removeAll { gone.contains($0) }
                    floorSeen.subtract(gone)
                    for name in offerEvicted {
                        state.activeTools.remove(name)
                        state.loadedAt.removeValue(forKey: name)
                        state.lastUsedTurn.removeValue(forKey: name)
                        state.pinnedSchemas.removeValue(forKey: name)
                        state.promotedTools.remove(name)
                        state.loadOrder.removeAll { $0 == name }
                    }
                }
            }

            // 2. Preload promotion, into free headroom only. On a
            //    stable-array route the floor IS the loadout, so its own
            //    ceiling is the budget — capping at `maxPersistedTools` there
            //    would stop admitting anything the moment the append-only
            //    floor passed 24 and the route would never preload again.
            let capacity = stableToolArray
                ? Self.maxStableDeclaredTools
                : Self.maxPersistedTools
            let headroom = capacity - state.activeTools.count
            // An always-on name never needs a session row; promoting one would
            // put a floor tool in the appended run and shift every row after it.
            let admit = headroom > 0
                ? Array(
                    promoting
                        .subtracting(promotionRefused)
                        .subtracting(Set(state.idleDroppedTurn.filter {
                            state.turnCount - $0.value < Self.promotionCooldownTurns
                        }.keys))
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

            // 3b. OFFER-FLOOR APPEND + RESTORE (stable-array routes only).
            //     Everything offered this turn joins the floor, and every name
            //     already in the floor that `beginTurn` idle-dropped comes
            //     back — same slot, same order — so two ordinary turns with no
            //     tool use produce a byte-identical `tools` array. Dispatch
            //     authorization is still the caller's own request-scoped set;
            //     this decides only what holds a session slot.
            if stableToolArray {
                for name in state.loadOrder
                where !name.hasPrefix("mcp__") && !floorSeen.contains(name) {
                    floor.append(name)
                    floorSeen.insert(name)
                }
                for name in state.activeTools.subtracting(floorSeen).sorted() {
                    floor.append(name)
                    floorSeen.insert(name)
                }
                // A floor name absent from THIS turn's live catalog cannot be
                // dispatched, so it must not be advertised either: the old
                // behaviour restored it from a stale declared schema and the
                // model could call a row the dispatcher has no body for. Drop
                // it from the floor instead — a later `tool_load` is the
                // honest way back once the catalog carries it again.
                var floorGone: [String] = []
                for name in floor {
                    guard let descriptor = descriptors[name] else {
                        floorGone.append(name)
                        continue
                    }
                    state.activeTools.insert(name)
                    if state.loadedAt[name] == nil { state.loadedAt[name] = stamp }
                    if state.floorJoinedTurn[name] == nil { state.floorJoinedTurn[name] = state.turnCount }
                    state.pinnedSchemas[name] = descriptor
                }
                if !floorGone.isEmpty {
                    let gone = Set(floorGone)
                    floor.removeAll { gone.contains($0) }
                    floorSeen.subtract(gone)
                    for name in floorGone {
                        state.activeTools.remove(name)
                        state.loadedAt.removeValue(forKey: name)
                        state.lastUsedTurn.removeValue(forKey: name)
                        state.pinnedSchemas.removeValue(forKey: name)
                        state.promotedTools.remove(name)
                        state.loadOrder.removeAll { $0 == name }
                    }
                    dropped.append(contentsOf: floorGone)
                }
                // The non-MCP run is rewritten in FLOOR order: that is the
                // append-only order, and rebuilding from it is what keeps a
                // restored name in the slot it already had.
                let mcpRun = state.loadOrder.filter { $0.hasPrefix("mcp__") }
                state.loadOrder = mcpRun + floor.filter { state.activeTools.contains($0) }
                state.offerFloor = floor
                // The floor just absorbed everything the session holds,
                // including names an explicit `tool_load` added after the
                // make-room pass above. The ceiling is enforced AFTER the
                // append, on every path that grows it, not only for route
                // promotions.
                let lateEvicted = Self.enforceFloorBoundInPlace(&state, protected: []) ?? []
                let evicted = (offerEvicted + lateEvicted).sorted()
                state.lastOfferEvicted = evicted.isEmpty ? nil : evicted
                if !evicted.isEmpty {
                    dropped.append(contentsOf: lateEvicted)
                    dropped.append(contentsOf: offerEvicted)
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
                declarationRepinned: declarationRepinned,
                floorRebuild: floorRebuild
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
                .filter {
                    state.lastUsedTurn[$0] != state.turnCount
                        || state.dispatchedTurn[$0] != state.turnCount
                }
            // Repeated calls to the same tool inside one turn are the common
            // case; rewriting the (now descriptor-bearing) state file on each
            // of them buys nothing.
            guard !touched.isEmpty else { return }
            let stamp = Self.iso8601Now()
            for name in touched {
                state.lastUsedTurn[name] = state.turnCount
                // The dispatch-only stamps. This is the ONLY writer of both.
                state.dispatchedTurn[name] = state.turnCount
                // Wall clock, so the evidence outlives the turn counter's
                // per-turn reset and feeds the idle-boundary floor rebuild.
                state.lastDispatchedAt[name] = stamp
                state.lastDispatchedTurn[name] = state.turnCount
                state.idleDroppedTurn.removeValue(forKey: name)
            }
            state.updatedAt = stamp
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
            let recorded = names.subtracting(state.explicitLoads)
            guard !cleared.isEmpty || !recorded.isEmpty else { return state }
            state.promotedTools.subtract(cleared)
            state.explicitLoads.formUnion(recorded)
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
                // DURABLE, unlike the row: an idle drop must not be able to
                // erase the fact that the user asked for this tool.
                state.explicitLoads.insert(name)
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
            // STABLE-ARRAY ROUTES: everything the session holds joins the
            // append-only floor at the next turn start, so the floor's ceiling
            // has to be enforced HERE — an explicit load was previously
            // protected from every bound and could push the advertised array
            // past 40 indefinitely. Evict LRU non-protected names to make
            // room; if the request still cannot fit, refuse it rather than
            // exceed the bound.
            if Self.enforceFloorBoundInPlace(&state, protected: names) == nil {
                throw NSError(
                    domain: "ActiveToolsStore",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "tool_load refused: this session already advertises the maximum "
                        + "\(Self.maxStableDeclaredTools) tools and the requested "
                        + "\(names.count) cannot fit. Unload tools first."]
                )
            }
            state.updatedAt = stamp
            try await self.saveLocked(state, path: path)
            return state
        }
    }

    /// HARD BOUND for the append-only offer floor (`maxStableDeclaredTools`).
    /// Applies only to stable-array sessions (a non-nil `offerFloor`); every
    /// other route is untouched. Everything the session holds joins the floor
    /// at the next turn start, so the membership counted here is the floor
    /// UNION the non-MCP active set. Overflow evicts least-recently-used
    /// names, never `protected` and never an always-on core tool.
    ///
    /// Returns the evicted names, or nil when the bound cannot be met without
    /// touching `protected` — the caller must then refuse rather than exceed.
    nonisolated static func enforceFloorBoundInPlace(
        _ state: inout ChatSessionActiveTools,
        protected: Set<String>
    ) -> [String]? {
        guard var floor = state.offerFloor else { return [] }
        var members = Set(floor)
        for name in state.activeTools where !name.hasPrefix("mcp__") {
            members.insert(name)
        }
        members.subtract(SwiftToolDispatcher.alwaysOnCoreNames)
        var overflow = members.count - maxStableDeclaredTools
        guard overflow > 0 else { return [] }
        let evictable = members.subtracting(protected).sorted { a, b in
            let ua = state.lastUsedTurn[a] ?? 0
            let ub = state.lastUsedTurn[b] ?? 0
            return ua == ub ? a < b : ua < ub
        }
        var evicted: [String] = []
        for name in evictable {
            guard overflow > 0 else { break }
            state.activeTools.remove(name)
            state.loadedAt.removeValue(forKey: name)
            state.lastUsedTurn.removeValue(forKey: name)
            state.pinnedSchemas.removeValue(forKey: name)
            state.promotedTools.remove(name)
            state.loadOrder.removeAll { $0 == name }
            floor.removeAll { $0 == name }
            evicted.append(name)
            overflow -= 1
        }
        state.offerFloor = floor
        return overflow > 0 ? nil : evicted.sorted()
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
        // A stable-array session's append-only floor outranks this bound: it
        // is the whole point that a declared name keeps its slot, and evicting
        // one here would shrink the `tools` array MID-TURN — the prefix kill
        // the floor exists to stop. Floor names are protected and the cap
        // rises to hold them. nil floor (every other route) = untouched.
        let floor = Set(state.offerFloor ?? [])
        var overflow = state.activeTools.count - max(maxPersistedTools, floor.count)
        guard overflow > 0 else { return }
        let evictable = state.activeTools.subtracting(protected).subtracting(floor)
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
                // The floor restores its names at every turn start, so an
                // unload that leaves it alone is undone one turn later.
                if state.offerFloor != nil { state.offerFloor = [] }
                // `tool_unload(all:)` is one of the two ways the durable
                // explicit record is cleared.
                state.explicitLoads.removeAll()
            } else {
                for n in names {
                    state.activeTools.remove(n)
                    state.loadedAt.removeValue(forKey: n)
                    state.lastUsedTurn.removeValue(forKey: n)
                    state.pinnedSchemas.removeValue(forKey: n)
                    state.loadOrder.removeAll { $0 == n }
                    // Same reason as the `all` branch: a floor entry comes
                    // back at the next turn start unless it leaves the floor.
                    state.offerFloor?.removeAll { $0 == n }
                    // The other clearer: an unload BY NAME retracts the
                    // explicit request, so the floor may retire it again.
                    state.explicitLoads.remove(n)
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
        var dispatchedTurn: [String: Int] = [:]
        if case .object(let map) = obj["dispatchedTurn"] ?? .null {
            for (k, v) in map {
                if case .int(let n) = v { dispatchedTurn[k] = Int(n) }
            }
        }
        // Wall-clock dispatch evidence. Must survive the process: the whole
        // point is a 24h window that a relaunch or an overnight gap cannot
        // erase. Absent (a file from before this field) = no evidence, which
        // retires a floor entry at the next idle boundary — the safe side.
        var lastDispatchedAt: [String: String] = [:]
        if case .object(let map) = obj["lastDispatchedAt"] ?? .null {
            for (k, v) in map {
                if case .string(let s) = v { lastDispatchedAt[k] = s }
            }
        }
        var lastDispatchedTurn: [String: Int] = [:]
        if case .object(let map) = obj["lastDispatchedTurn"] ?? .null {
            for (k, v) in map { if case .int(let n) = v { lastDispatchedTurn[k] = Int(n) } }
        }
        var floorJoinedTurn: [String: Int] = [:]
        if case .object(let map) = obj["floorJoinedTurn"] ?? .null {
            for (k, v) in map { if case .int(let n) = v { floorJoinedTurn[k] = Int(n) } }
        }
        var idleDroppedTurn: [String: Int] = [:]
        if case .object(let map) = obj["idleDroppedTurn"] ?? .null {
            for (k, v) in map { if case .int(let n) = v { idleDroppedTurn[k] = Int(n) } }
        }
        func optString(_ key: String) -> String? {
            if case .string(let s) = obj[key] ?? .null { return s }
            return nil
        }
        func optDouble(_ key: String) -> Double? {
            switch obj[key] ?? .null {
            case .double(let d): return d
            case .int(let n): return Double(n)
            default: return nil
            }
        }
        func optInt(_ key: String) -> Int? {
            if case .int(let n) = obj[key] ?? .null { return Int(n) }
            return nil
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
        var explicitLoads = Set<String>()
        if case .array(let arr) = obj["explicitLoads"] ?? .null {
            for v in arr {
                if case .string(let s) = v { explicitLoads.insert(s) }
            }
        }
        var lastDropped: [String] = []
        if case .array(let arr) = obj["lastDropped"] ?? .null {
            for v in arr {
                if case .string(let s) = v { lastDropped.append(s) }
            }
        }
        // The offer floor is the whole point of the stable-array lane: if it
        // does not survive the process, the array it pins does not either.
        func stringArray(_ key: String) -> [String]? {
            guard case .array(let arr) = obj[key] ?? .null else { return nil }
            var out: [String] = []
            for v in arr {
                if case .string(let s) = v { out.append(s) }
            }
            return out.isEmpty ? nil : out
        }
        let offerFloor = stringArray("offerFloor")
        let lastOfferEvicted = stringArray("lastOfferEvicted")
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
            dispatchedTurn: dispatchedTurn,
            lastDispatchedAt: lastDispatchedAt,
            lastDispatchedTurn: lastDispatchedTurn,
            floorJoinedTurn: floorJoinedTurn,
            idleDroppedTurn: idleDroppedTurn,
            lastTurnAt: optString("lastTurnAt"),
            lastIdleGapSeconds: optDouble("lastIdleGapSeconds"),
            lastFloorRebuildTurn: optInt("lastFloorRebuildTurn"),
            lastFloorRetired: stringArray("lastFloorRetired"),
            lastFloorKeptCount: optInt("lastFloorKeptCount"),
            lastFloorRebuildGapSeconds: optDouble("lastFloorRebuildGapSeconds"),
            turnCount: turnCount,
            lastDropped: lastDropped,
            declaredOrder: declaredOrder,
            declaredSchemas: declaredSchemas,
            declarationGeneration: declarationGeneration,
            promotedTools: promotedTools,
            explicitLoads: explicitLoads,
            declaredAbsentSince: declaredAbsentSince,
            offerFloor: offerFloor,
            lastOfferEvicted: lastOfferEvicted,
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
            "dispatchedTurn": .object(state.dispatchedTurn.mapValues { .int(Int64($0)) }),
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
        if let offerFloor = state.offerFloor, !offerFloor.isEmpty {
            fields["offerFloor"] = .array(offerFloor.map { .string($0) })
        }
        if !state.lastDispatchedTurn.isEmpty {
            fields["lastDispatchedTurn"] = .object(state.lastDispatchedTurn.mapValues { .int(Int64($0)) })
        }
        if !state.floorJoinedTurn.isEmpty {
            fields["floorJoinedTurn"] = .object(state.floorJoinedTurn.mapValues { .int(Int64($0)) })
        }
        if !state.idleDroppedTurn.isEmpty {
            fields["idleDroppedTurn"] = .object(state.idleDroppedTurn.mapValues { .int(Int64($0)) })
        }
        // Optional key: a file written before this field existed decodes to an
        // empty set, which simply means no protection until the next load.
        if !state.explicitLoads.isEmpty {
            fields["explicitLoads"] = .array(
                state.explicitLoads.sorted().map { .string($0) }
            )
        }
        if let evicted = state.lastOfferEvicted, !evicted.isEmpty {
            fields["lastOfferEvicted"] = .array(evicted.map { .string($0) })
        }
        // Wall-clock dispatch evidence and the idle-boundary rebuild receipt.
        // Optional keys throughout, so a state file written before this change
        // still decodes (absent → no evidence → rebuilt at the next boundary).
        if !state.lastDispatchedAt.isEmpty {
            fields["lastDispatchedAt"] = .object(state.lastDispatchedAt.mapValues { .string($0) })
        }
        if let lastTurnAt = state.lastTurnAt {
            fields["lastTurnAt"] = .string(lastTurnAt)
        }
        if let gap = state.lastIdleGapSeconds {
            fields["lastIdleGapSeconds"] = .double(gap)
        }
        if let turn = state.lastFloorRebuildTurn {
            fields["lastFloorRebuildTurn"] = .int(Int64(turn))
        }
        if let retired = state.lastFloorRetired, !retired.isEmpty {
            fields["lastFloorRetired"] = .array(retired.map { .string($0) })
        }
        if let kept = state.lastFloorKeptCount {
            fields["lastFloorKeptCount"] = .int(Int64(kept))
        }
        if let gap = state.lastFloorRebuildGapSeconds {
            fields["lastFloorRebuildGapSeconds"] = .double(gap)
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
        // Never seeded, only pruned: a dropped name carries no dispatch history.
        for name in state.dispatchedTurn.keys where !state.activeTools.contains(name) {
            state.dispatchedTurn.removeValue(forKey: name)
            changed = true
        }
        // Wall-clock evidence is pruned BY AGE, not by membership: a name the
        // floor rebuild just retired keeps its history until the window closes,
        // so a tool called an hour ago is not permanently forgotten because one
        // idle boundary dropped it. Past the window the row can no longer keep
        // anything alive, which also bounds the map.
        let evidenceCutoff = Date().addingTimeInterval(-floorDispatchWindowSeconds)
        for (name, iso) in state.lastDispatchedAt {
            guard let at = iso8601Parse(iso), at >= evidenceCutoff else {
                state.lastDispatchedAt.removeValue(forKey: name)
                changed = true
                continue
            }
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
