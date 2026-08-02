import Foundation

// MARK: - DeskNagConfig — User's nag switch, persisted (default OFF)
//
// Nagging is HIS switch, not hers: "stay on me about the release track" /
// "go quiet, I'm busy this week". So the whole lane is scoped, persisted, and
// DEFAULT OFF — a fresh install never nags, and `enabled == false` makes the
// evaluator inert (it doesn't even record observations, so an untouched config
// file is never written).
//
// WHY A SEPARATE FILE AND NOT AN OP: this is User's operating preference, not a
// fact about the work. It has no place in the desk's event history — replaying
// the op-log must not resurrect a mute he lifted last week, and a nag ledger
// entry is bookkeeping about NOTIFICATIONS, not about items. It lives at
// <dataRoot>/desk/nag_config.json, written through the SAME PersistenceCore
// idioms the desk store uses (withFileLock + atomic writeJSON), so a chat tool
// and the background loop can both touch it across processes.
//
// THE WINDOW IS THE UNIT OF ATTENTION. `windowId` increments on every unmute
// and on every global off→on transition. `ledger[handle] == windowId` means
// "this item already nagged in the current window" — the hard cap Agent made
// binding (one nag per item per unmute window). Bumping the window is the ONLY
// way to re-arm an item, which is why the bump is tied to a deliberate User
// action rather than a timer.
//
// `observed` is the evaluator's memory: the last snapshot it saw of each item.
// A nag needs a DELTA against that snapshot (blockers cleared / defer elapsed /
// content advanced while stale) — staleness alone never pings. Muted ticks
// observe but never CONSUME: while muted the evaluator only records baselines
// for items it has never seen, so accumulated drift is still visible when User
// unmutes and asks what moved.

/// What a scope entry addresses. Project scope is the common case ("stay on me
/// about the release track"); item scope is the surgical one.
public enum DeskNagScopeKind: String, Sendable, CaseIterable, Equatable {
    case project, item
}

/// One enable/disable entry. An `item` entry always wins over a `project`
/// entry (most specific scope decides), so User can mute one card inside a
/// project he otherwise wants pressure on.
public struct DeskNagScope: Sendable, Equatable {
    public var kind: DeskNagScopeKind
    /// Project name (matched case-insensitively) or a stable item handle. The
    /// chat tool resolves a visible desk number to a handle BEFORE it lands
    /// here — aliases are display, handles are identity.
    public var id: String
    public var enabled: Bool

    public init(kind: DeskNagScopeKind, id: String, enabled: Bool) {
        self.kind = kind
        self.id = id
        self.enabled = enabled
    }

    public func toJSON() -> JSONValue {
        .object([
            "kind": .string(kind.rawValue),
            "id": .string(id),
            "enabled": .bool(enabled),
        ])
    }

    /// Tolerant: an unknown kind or a missing id drops the ROW, not the file.
    /// A config that fails to decode entirely would silently revert to
    /// default-off, which is the quiet failure this whole lane is about.
    public static func fromJSON(_ value: JSONValue) -> DeskNagScope? {
        guard case .object(let obj) = value,
              case .string(let rawKind)? = obj["kind"],
              let kind = DeskNagScopeKind(rawValue: rawKind),
              case .string(let id)? = obj["id"],
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var enabled = true
        if case .bool(let b)? = obj["enabled"] { enabled = b }
        return DeskNagScope(kind: kind, id: id, enabled: enabled)
    }
}

/// The last snapshot the evaluator saw of one item — the baseline every delta
/// is measured against. Deliberately three cheap scalars: the delta vocabulary
/// is "content advanced", "blockers cleared", "defer elapsed", and nothing else
/// needs to be remembered between ticks.
public struct DeskNagObservation: Sendable, Equatable {
    public var updatedAt: String
    public var effectiveBlockerCount: Int
    /// True when the item was NOT deferred at snapshot time (i.e. its park, if
    /// any, had already elapsed). Stored in the positive sense the delta reads:
    /// false → true is "the defer date passed".
    public var deferElapsed: Bool

    public init(updatedAt: String, effectiveBlockerCount: Int, deferElapsed: Bool) {
        self.updatedAt = updatedAt
        self.effectiveBlockerCount = effectiveBlockerCount
        self.deferElapsed = deferElapsed
    }

    public func toJSON() -> JSONValue {
        .object([
            "updatedAt": .string(updatedAt),
            "effectiveBlockerCount": .int(Int64(effectiveBlockerCount)),
            "deferElapsed": .bool(deferElapsed),
        ])
    }

    public static func fromJSON(_ value: JSONValue) -> DeskNagObservation? {
        guard case .object(let obj) = value,
              case .string(let updatedAt)? = obj["updatedAt"] else { return nil }
        var blockers = 0
        if case .int(let i)? = obj["effectiveBlockerCount"] { blockers = Int(i) }
        var elapsed = true
        if case .bool(let b)? = obj["deferElapsed"] { elapsed = b }
        return DeskNagObservation(updatedAt: updatedAt, effectiveBlockerCount: blockers, deferElapsed: elapsed)
    }
}

public struct DeskNagConfig: Sendable, Equatable {
    /// GLOBAL master switch. Default false — User opts IN.
    public var enabled: Bool
    public var scopes: [DeskNagScope]
    /// ISO timestamp or `yyyy-MM-dd` day. nil = not muted. A stamp in the PAST
    /// is also not muted (a mute expires by itself; the loop notices the
    /// transition and emits the drift digest).
    public var mutedUntil: String?
    /// Attention window. Bumped on unmute and on global off→on.
    public var windowId: Int
    /// handle → the windowId this item last NAGGED in. Nag-only by design:
    /// a digest mention must never spend an item's nag budget for the window.
    public var ledger: [String: Int]
    /// handle → last snapshot the evaluator saw.
    public var observed: [String: DeskNagObservation]

    /// "Mute with no end date." A far-future sentinel rather than a separate
    /// `mutedForever` flag: one field, one comparison, and `status` can print
    /// it honestly ("muted indefinitely") by recognising the sentinel.
    public static let indefiniteMuteSentinel = "9999-12-31"

    public init(
        enabled: Bool = false,
        scopes: [DeskNagScope] = [],
        mutedUntil: String? = nil,
        windowId: Int = 1,
        ledger: [String: Int] = [:],
        observed: [String: DeskNagObservation] = [:]
    ) {
        self.enabled = enabled
        self.scopes = scopes
        self.mutedUntil = mutedUntil
        self.windowId = windowId
        self.ledger = ledger
        self.observed = observed
    }

    // MARK: - Reads

    /// True while `mutedUntil` parses and is strictly in the future.
    ///
    /// An UNPARSEABLE stamp reads as NOT muted — same call as
    /// DeskSequencing.isDeferred: silently going quiet forever because someone
    /// typed a bad date is the worse failure of the two.
    public func isMuted(now: Date) -> Bool {
        guard let raw = mutedUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let until = DeskSequencing.parseDeferStamp(raw) else { return false }
        return until > now
    }

    /// True when the mute field is SET but has already elapsed — the
    /// transition the loop watches for to fire the drift digest.
    public func muteHasElapsed(now: Date) -> Bool {
        guard let raw = mutedUntil?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        return !isMuted(now: now)
    }

    /// Scope decision for one item: item entry wins, then project entry, then
    /// NOTHING. No scope entry means no nag — enabling the global switch alone
    /// does not turn the whole desk into a nag surface (User asks for pressure
    /// on a track, not on everything he has ever written down).
    public func scopeEnabled(for item: DeskItem) -> Bool {
        if let entry = scopes.first(where: { $0.kind == .item && $0.id == item.handle }) {
            return entry.enabled
        }
        if let entry = scopes.first(where: {
            $0.kind == .project && $0.id.compare(item.project, options: .caseInsensitive) == .orderedSame
        }) {
            return entry.enabled
        }
        return false
    }

    // MARK: - Transitions (value-returning; the store persists the result)

    /// Flip the global switch. An off→on transition BUMPS the window so an
    /// item that nagged before User went quiet is re-armed when he comes back.
    public func settingGlobal(_ on: Bool) -> DeskNagConfig {
        var next = self
        next.enabled = on
        if on && !enabled { next.windowId += 1 }
        return next
    }

    /// Upsert one scope entry (kind+id is the key).
    public func settingScope(kind: DeskNagScopeKind, id: String, enabled on: Bool) -> DeskNagConfig {
        var next = self
        if let idx = next.scopes.firstIndex(where: {
            $0.kind == kind && $0.id.compare(id, options: .caseInsensitive) == .orderedSame
        }) {
            next.scopes[idx].enabled = on
            next.scopes[idx].id = id
        } else {
            next.scopes.append(DeskNagScope(kind: kind, id: id, enabled: on))
        }
        return next
    }

    /// Go quiet until `until` (nil = indefinitely). No window bump: muting
    /// doesn't re-arm anything, it suspends.
    public func muted(until: String?) -> DeskNagConfig {
        var next = self
        let trimmed = until?.trimmingCharacters(in: .whitespacesAndNewlines)
        next.mutedUntil = (trimmed?.isEmpty == false) ? trimmed : Self.indefiniteMuteSentinel
        return next
    }

    /// Come back: clear the mute and OPEN A NEW WINDOW, so every item is
    /// eligible to nag once again. Callers pair this with the drift digest —
    /// unmuting must never be blind.
    public func unmuted() -> DeskNagConfig {
        var next = self
        next.mutedUntil = nil
        next.windowId += 1
        return next
    }

    // MARK: - Wire

    /// Omit-empty: an untouched config serialises to the three scalars, so the
    /// file stays readable by a human deciding whether the machine is nagging.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "version": .int(1),
            "enabled": .bool(enabled),
            "windowId": .int(Int64(windowId)),
        ]
        if !scopes.isEmpty { obj["scopes"] = .array(scopes.map { $0.toJSON() }) }
        if let mutedUntil, !mutedUntil.isEmpty { obj["mutedUntil"] = .string(mutedUntil) }
        if !ledger.isEmpty { obj["ledger"] = .object(ledger.mapValues { .int(Int64($0)) }) }
        if !observed.isEmpty { obj["observed"] = .object(observed.mapValues { $0.toJSON() }) }
        return .object(obj)
    }

    /// TOLERANT decode — a malformed row is dropped, never the file. This is
    /// preference state, not the event log: the fail-loud rule that governs the
    /// compaction base would here turn one bad scope row into "the nag lane is
    /// dead and nobody said so".
    public static func fromJSON(_ value: JSONValue) -> DeskNagConfig {
        guard case .object(let obj) = value else { return DeskNagConfig() }
        var cfg = DeskNagConfig()
        if case .bool(let b)? = obj["enabled"] { cfg.enabled = b }
        if case .int(let i)? = obj["windowId"] { cfg.windowId = max(1, Int(i)) }
        if case .array(let rows)? = obj["scopes"] {
            cfg.scopes = rows.compactMap { DeskNagScope.fromJSON($0) }
        }
        if case .string(let m)? = obj["mutedUntil"], !m.isEmpty { cfg.mutedUntil = m }
        if case .object(let led)? = obj["ledger"] {
            for (k, v) in led {
                if case .int(let i) = v { cfg.ledger[k] = Int(i) }
            }
        }
        if case .object(let seen)? = obj["observed"] {
            for (k, v) in seen {
                if let o = DeskNagObservation.fromJSON(v) { cfg.observed[k] = o }
            }
        }
        return cfg
    }
}

// MARK: - Store

/// Flock-serialised reader/writer for `<dataRoot>/desk/nag_config.json`.
///
/// Stateless like SwiftNativeDeskStore (all state on disk) and locked on the
/// config path itself — NOT on the desk ops feed. Two locks, two concerns: a
/// nag-config write must never park behind a desk op append, and the evaluator
/// reads a state SNAPSHOT anyway (it is pure; it does not need the two files to
/// be mutually consistent to the millisecond — a lost tick is one delta later,
/// not a lost delta, because the observation baseline only advances when a
/// delta is actually consumed).
public struct DeskNagConfigStore: Sendable {
    public let dataRoot: URL
    public let persistence: any PersistenceCoreProtocol

    public init(dataRoot: URL, persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()) {
        self.dataRoot = dataRoot
        self.persistence = persistence
    }

    public var configPath: URL {
        dataRoot
            .appendingPathComponent("desk", isDirectory: true)
            .appendingPathComponent("nag_config.json")
    }

    /// A missing/unreadable file is the DEFAULT (off) config — not an error.
    /// The absence of the file is exactly the fresh-install state.
    public func load() async -> DeskNagConfig {
        let raw = await persistence.readJSON(configPath, defaultValue: .null)
        return DeskNagConfig.fromJSON(raw)
    }

    public func save(_ config: DeskNagConfig) async throws {
        try await persistence.withFileLock(configPath) {
            try await persistence.writeJSON(config.toJSON(), to: configPath)
        }
    }

    /// Read-modify-write INSIDE the flock — the only safe shape when the chat
    /// tool and the background loop both mutate (a load/mutate/save pair
    /// outside the lock loses whichever write lands first). Returns the
    /// committed config.
    @discardableResult
    public func update(_ transform: @Sendable (DeskNagConfig) -> DeskNagConfig) async throws -> DeskNagConfig {
        try await updating { (transform($0), ()) }.config
    }

    /// `update` that also hands back a value derived from the CONFIG AS IT WAS
    /// INSIDE THE LOCK — the unmute path needs the drift digest computed
    /// against the same config it then consumes, and computing it from a load
    /// outside the lock would report drift a concurrent writer had already
    /// consumed.
    public func updating<T: Sendable>(
        _ transform: @Sendable (DeskNagConfig) -> (DeskNagConfig, T)
    ) async throws -> (config: DeskNagConfig, value: T) {
        try await persistence.withFileLock(configPath) {
            let current = DeskNagConfig.fromJSON(await persistence.readJSON(configPath, defaultValue: .null))
            let (next, value) = transform(current)
            try await persistence.writeJSON(next.toJSON(), to: configPath)
            return (next, value)
        }
    }
}
