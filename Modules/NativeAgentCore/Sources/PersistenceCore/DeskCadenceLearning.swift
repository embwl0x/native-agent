import Foundation

// MARK: - Desk cadence learning (Wave 5) — poll as often as reality changes
//
// A tracked ref (a GitHub project, a doc, a feed) has a TRUE change rhythm that
// no fixed polling guess matches: a release board moves hourly during a cut and
// once a fortnight otherwise. This lane replaces the guess with an interval
// LEARNED from observed change intervals, plus a quiet-period backoff so a ref
// that has gone silent stops being asked every fifteen minutes.
//
// THREE HARD RULES the code below encodes:
//   1. EXPLICIT ALWAYS WINS. If User wrote a refresh interval on the ref, the
//      learner never overrides it — learning is for the refs he never
//      configured, not a second opinion on the ones he did.
//   2. THIN EVIDENCE PRODUCES NO GUESS. Under three observed changes there is
//      no interval, only noise; `learnedIntervalSeconds` returns nil and the
//      caller falls back. A confident number from two samples is worse than
//      no number, because it silently replaces a sane default.
//   3. CLAMPED AT BOTH ENDS. A pathologically chatty ref can't talk us into
//      polling every 5 seconds (floor 15m) and a dormant one can't push the
//      interval past a day (ceiling 24h) — beyond that "learned" is just a
//      way of saying "never look again".
//
// The stat rows preserve UNKNOWN JSON KEYS verbatim: two binaries of different
// vintage share <dataRoot>/desk/cadence_stats.json across processes, and an
// old one must not silently strip a field a newer one is relying on.

// MARK: - Local JSON helpers (DeskModels' are file-private)

private func cadenceString(_ obj: [String: JSONValue], _ key: String) -> String? {
    if case .string(let s)? = obj[key], !s.isEmpty { return s }
    return nil
}

private func cadenceInt(_ obj: [String: JSONValue], _ key: String) -> Int? {
    switch obj[key] {
    case .int(let i)?: return Int(i)
    case .double(let d)?: return Int(d)
    default: return nil
    }
}

private func cadenceDouble(_ obj: [String: JSONValue], _ key: String) -> Double? {
    switch obj[key] {
    case .double(let d)?: return d
    case .int(let i)?: return Double(i)
    default: return nil
    }
}

// MARK: - Value type

/// What the desk has observed about ONE tracked ref's change rhythm.
///
/// Deliberately a handful of scalars: everything downstream needs is derivable
/// from "how many times did I look", "how many times did it move", and an EWMA
/// of the intervals between moves. No sample history — a growing array per ref
/// would turn a config file into a time-series database for no extra accuracy.
public struct DeskRefObservationStat: Sendable, Equatable {
    /// Stable identity of the tracked thing (ref id / URL / source key).
    public var refKey: String
    public var firstObservedAt: String
    public var lastObservedAt: String
    /// When the content last DIFFERED from the previous fingerprint. Seeded to
    /// first observation so the first measured interval is honest.
    public var lastChangeAt: String
    public var observations: Int
    public var changes: Int
    /// Exponentially weighted mean seconds BETWEEN changes. nil until the first
    /// change is seen (there is nothing to average yet).
    public var ewmaChangeIntervalSec: Double?
    /// Cheap content digest the caller supplies; identity is the caller's
    /// business, we only ever compare for equality.
    public var lastFingerprint: String?
    /// Keys this binary didn't recognise, re-emitted verbatim on encode.
    public var unknownFields: [String: JSONValue]

    /// Keys this version owns. Anything else on the wire is forward-compat
    /// payload and rides through untouched.
    private static let knownKeys: Set<String> = [
        "refKey", "firstObservedAt", "lastObservedAt", "lastChangeAt",
        "observations", "changes", "ewmaChangeIntervalSec", "lastFingerprint",
    ]

    public init(
        refKey: String,
        firstObservedAt: String,
        lastObservedAt: String,
        lastChangeAt: String,
        observations: Int = 0,
        changes: Int = 0,
        ewmaChangeIntervalSec: Double? = nil,
        lastFingerprint: String? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.refKey = refKey
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.lastChangeAt = lastChangeAt
        self.observations = observations
        self.changes = changes
        self.ewmaChangeIntervalSec = ewmaChangeIntervalSec
        self.lastFingerprint = lastFingerprint
        self.unknownFields = unknownFields
    }

    /// A fresh row for a ref never seen before: every stamp is `now`, no
    /// fingerprint, no observations yet.
    public static func seed(refKey: String, at now: Date) -> DeskRefObservationStat {
        let iso = DeskClock.nowISO(now)
        return DeskRefObservationStat(
            refKey: refKey,
            firstObservedAt: iso,
            lastObservedAt: iso,
            lastChangeAt: iso
        )
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = unknownFields   // unknown first: known keys win
        obj["refKey"] = .string(refKey)
        obj["firstObservedAt"] = .string(firstObservedAt)
        obj["lastObservedAt"] = .string(lastObservedAt)
        obj["lastChangeAt"] = .string(lastChangeAt)
        obj["observations"] = .int(Int64(observations))
        obj["changes"] = .int(Int64(changes))
        if let ewmaChangeIntervalSec { obj["ewmaChangeIntervalSec"] = .double(ewmaChangeIntervalSec) }
        if let lastFingerprint, !lastFingerprint.isEmpty { obj["lastFingerprint"] = .string(lastFingerprint) }
        return .object(obj)
    }

    /// Tolerant: a row missing its key is dropped (it addresses nothing), but a
    /// row missing a timestamp is repaired from whatever stamps it does have —
    /// telemetry rows are not worth failing a load over.
    public static func fromJSON(_ value: JSONValue) -> DeskRefObservationStat? {
        guard case .object(let obj) = value,
              let refKey = cadenceString(obj, "refKey") else { return nil }
        let first = cadenceString(obj, "firstObservedAt")
        let last = cadenceString(obj, "lastObservedAt")
        let change = cadenceString(obj, "lastChangeAt")
        let anyStamp = first ?? last ?? change ?? DeskClock.nowISO(Date(timeIntervalSince1970: 0))
        var unknown: [String: JSONValue] = [:]
        for (k, v) in obj where !knownKeys.contains(k) { unknown[k] = v }
        return DeskRefObservationStat(
            refKey: refKey,
            firstObservedAt: first ?? anyStamp,
            lastObservedAt: last ?? anyStamp,
            lastChangeAt: change ?? anyStamp,
            observations: max(0, cadenceInt(obj, "observations") ?? 0),
            changes: max(0, cadenceInt(obj, "changes") ?? 0),
            ewmaChangeIntervalSec: cadenceDouble(obj, "ewmaChangeIntervalSec").flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            lastFingerprint: cadenceString(obj, "lastFingerprint"),
            unknownFields: unknown
        )
    }
}

/// The whole file: refKey → stat.
public struct DeskCadenceStats: Sendable, Equatable {
    public var refs: [String: DeskRefObservationStat]

    public init(refs: [String: DeskRefObservationStat] = [:]) {
        self.refs = refs
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["version": .int(1)]
        if !refs.isEmpty { obj["refs"] = .object(refs.mapValues { $0.toJSON() }) }
        return .object(obj)
    }

    /// A missing / corrupt / alien file decodes to EMPTY. Losing cadence
    /// telemetry costs one relearning cycle; throwing would take the desk's
    /// refresh loop down with it.
    public static func fromJSON(_ value: JSONValue) -> DeskCadenceStats {
        guard case .object(let obj) = value, case .object(let rows)? = obj["refs"] else {
            return DeskCadenceStats()
        }
        var out: [String: DeskRefObservationStat] = [:]
        for (k, v) in rows {
            if let stat = DeskRefObservationStat.fromJSON(v) { out[k] = stat }
        }
        return DeskCadenceStats(refs: out)
    }
}

/// Where a resolved refresh interval came from. Surfaced so the UI can say
/// "every 6h (you set that)" vs "every 2h (learned)" — a learned number the
/// user can't attribute reads as the machine being arbitrary.
public enum DeskCadenceSource: String, Sendable, CaseIterable, Equatable {
    case explicit, learned, fallback
}

// MARK: - Pure learner

public enum DeskCadenceLearner {
    /// EWMA weight on the newest interval. 0.3 tracks a genuine rhythm change
    /// within a handful of samples without letting one outlier swing the poll
    /// rate.
    public static let alpha: Double = 0.3
    /// Poll about twice per expected change (Nyquist-ish): a ref that moves
    /// every 4h is asked every 2h, so a change is at most one interval stale.
    public static let pollFactor: Double = 0.5
    public static let minIntervalSeconds: Double = 900        // 15 minutes
    public static let maxIntervalSeconds: Double = 86_400     // 24 hours
    /// Changes required before an interval is trusted at all.
    public static let minChangesForConfidence = 3

    /// Fold one observation into a ref's stat. A CHANGE is a fingerprint that
    /// differs from the one stored; the very first fingerprint we ever see is
    /// a BASELINE, not a change (otherwise every fresh ref would report a
    /// change on sight and skew its own first interval).
    public static func record(
        _ stat: DeskRefObservationStat,
        fingerprint: String,
        at now: Date
    ) -> DeskRefObservationStat {
        var next = stat
        next.observations += 1
        next.lastObservedAt = DeskClock.nowISO(now)

        let hadBaseline = (stat.lastFingerprint?.isEmpty == false)
        let changed = hadBaseline && stat.lastFingerprint != fingerprint
        next.lastFingerprint = fingerprint
        guard changed else { return next }

        next.changes += 1
        let since = DeskClock.parseISO(stat.lastChangeAt).map { now.timeIntervalSince($0) } ?? 0
        let interval = max(0, since)
        if let prev = next.ewmaChangeIntervalSec {
            next.ewmaChangeIntervalSec = alpha * interval + (1 - alpha) * prev
        } else {
            next.ewmaChangeIntervalSec = interval      // first change seeds the mean
        }
        next.lastChangeAt = DeskClock.nowISO(now)
        return next
    }

    /// The learned poll interval, or nil when the evidence is too thin to
    /// justify replacing the caller's default.
    public static func learnedIntervalSeconds(_ stat: DeskRefObservationStat) -> Double? {
        guard stat.changes >= minChangesForConfidence,
              let ewma = stat.ewmaChangeIntervalSec, ewma.isFinite, ewma > 0 else { return nil }
        return clamp(ewma * pollFactor)
    }

    /// Learned interval widened by how long the ref has been QUIET: a ref that
    /// hasn't moved in a week doesn't deserve its busy-period cadence. Grows to
    /// half the quiet span (still capped at 24h) and collapses back to the
    /// learned interval the moment a change lands (quiet span → 0).
    public static func effectiveIntervalSeconds(_ stat: DeskRefObservationStat, now: Date) -> Double? {
        guard let learned = learnedIntervalSeconds(stat) else { return nil }
        let quietSince = DeskClock.parseISO(stat.lastChangeAt).map { now.timeIntervalSince($0) } ?? 0
        let backoff = min(max(0, quietSince) / 2, maxIntervalSeconds)
        return max(learned, backoff)
    }

    /// Parse the desk's duration vocabulary ("30m", "6h", "2d"). Delegates to
    /// the ONE parser this module already ships — a second copy would drift.
    public static func explicitInterval(_ raw: String?) -> Double? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let seconds = DeskProjection.parseDuration(trimmed), seconds > 0 else { return nil }
        return seconds
    }

    /// THE precedence point. Explicit configuration outranks everything the
    /// desk taught itself; learning only fills the silence. `fallbackSeconds`
    /// is a parameter, not a constant, because the right default differs per
    /// ref kind and this resolver has no business deciding it.
    public static func resolvedIntervalSeconds(
        explicit: String?,
        stat: DeskRefObservationStat?,
        now: Date,
        fallbackSeconds: Double
    ) -> (seconds: Double, source: DeskCadenceSource) {
        if let configured = explicitInterval(explicit) {
            return (configured, .explicit)
        }
        if let stat, let learned = effectiveIntervalSeconds(stat, now: now) {
            return (learned, .learned)
        }
        return (fallbackSeconds, .fallback)
    }

    /// How long a whole BATCH of refs fetched together may sit before the batch
    /// is refetched. `resolvedIntervalSeconds` answers for one ref; a poller that
    /// pulls a snapshot covering many refs at once needs one number.
    ///
    /// Two rules, both deliberately conservative:
    ///   • `configuredSeconds` is a FLOOR. Learning may only STRETCH the gap,
    ///     never shorten it. The explicit-beats-learned order still holds, and it
    ///     means nothing the desk teaches itself can make a poller hit a remote
    ///     API harder than it was configured to.
    ///   • PARTIAL KNOWLEDGE STRETCHES NOTHING — the same rule auto-resolution
    ///     uses for closes. One ref without a confident learned interval is one
    ///     rhythm we do not know, and unknown is polled at the configured rate.
    ///     Only an all-understood batch slows down, and then only to its
    ///     soonest-due member.
    ///
    /// Empty `refKeys` → configured: nothing observed is not evidence of quiet.
    public static func batchIntervalSeconds(
        refKeys: [String],
        stats: DeskCadenceStats,
        configuredSeconds: Double,
        now: Date
    ) -> Double {
        guard !refKeys.isEmpty else { return configuredSeconds }
        var soonest = Double.greatestFiniteMagnitude
        for key in Set(refKeys) {
            guard let stat = stats.refs[key],
                  let learned = effectiveIntervalSeconds(stat, now: now) else {
                return configuredSeconds
            }
            soonest = min(soonest, learned)
        }
        return max(configuredSeconds, soonest)
    }

    static func clamp(_ seconds: Double) -> Double {
        min(max(seconds, minIntervalSeconds), maxIntervalSeconds)
    }
}

// MARK: - Store

/// Cross-process reader/writer for `<dataRoot>/desk/cadence_stats.json`.
///
/// Same idioms as DeskNagConfigStore (withFileLock + atomic writeJSON) and the
/// same non-negotiable: EVERY mutation goes through `updating`, one flock-held
/// read-modify-write. The unlocked load → mutate → save shape has already
/// shipped lost-update bugs in this subsystem — the refresh loop and a chat
/// tool both touch this file, and a lost update here means a ref silently
/// reverts to a stale cadence with nothing in the log to say so.
public actor DeskCadenceStore {
    public let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol

    public init(dataRoot: URL, persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()) {
        self.dataRoot = dataRoot
        self.persistence = persistence
    }

    public nonisolated var statsPath: URL {
        dataRoot
            .appendingPathComponent("desk", isDirectory: true)
            .appendingPathComponent("cadence_stats.json")
    }

    /// Missing or corrupt → empty. Never throws.
    public func load() async -> DeskCadenceStats {
        let raw = await persistence.readJSON(statsPath, defaultValue: .null)
        return DeskCadenceStats.fromJSON(raw)
    }

    /// Single-transaction read-modify-write. The transform sees the file AS IT
    /// IS INSIDE THE LOCK and hands back both the next state and any value
    /// derived from that same snapshot.
    @discardableResult
    public func updating<T: Sendable>(
        _ transform: @Sendable (DeskCadenceStats) -> (DeskCadenceStats, T)
    ) async throws -> (stats: DeskCadenceStats, value: T) {
        try await persistence.withFileLock(statsPath) {
            let current = DeskCadenceStats.fromJSON(await persistence.readJSON(statsPath, defaultValue: .null))
            let (next, value) = transform(current)
            try await persistence.writeJSON(next.toJSON(), to: statsPath)
            return (next, value)
        }
    }

    /// Record one observation of one ref — built ON TOP of the locked
    /// transaction, never load/mutate/save. Returns the committed row.
    @discardableResult
    public func recordObservation(
        refKey: String,
        fingerprint: String,
        at now: Date = Date()
    ) async throws -> DeskRefObservationStat {
        try await updating { stats in
            var next = stats
            let base = next.refs[refKey] ?? DeskRefObservationStat.seed(refKey: refKey, at: now)
            let updated = DeskCadenceLearner.record(base, fingerprint: fingerprint, at: now)
            next.refs[refKey] = updated
            return (next, updated)
        }.value
    }

    /// Convenience read for the refresh loop: what interval should this ref be
    /// polled at right now, and why.
    public func resolvedInterval(
        refKey: String,
        explicit: String?,
        now: Date = Date(),
        fallbackSeconds: Double
    ) async -> (seconds: Double, source: DeskCadenceSource) {
        let stats = await load()
        return DeskCadenceLearner.resolvedIntervalSeconds(
            explicit: explicit,
            stat: stats.refs[refKey],
            now: now,
            fallbackSeconds: fallbackSeconds
        )
    }
}
