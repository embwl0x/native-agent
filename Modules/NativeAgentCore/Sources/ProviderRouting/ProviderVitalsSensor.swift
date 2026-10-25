import TurnTrace
import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ProviderVitalsSensor.swift` | `ProviderVitalsSensor`: passive lifecycle-derived latency/error bands, first-output evidence and persisted bounded health state |

// MARK: - INTEROCEPTION: provider vitals sensor
//
// A passive body-sense organ (prerelease campaign §"INTEROCEPTION stays").
// It listens to the EXISTING `LLMCallLifecycleEvent` seam that the shared
// provider router (SwiftNativeLLMClient / LLMClient+Real.swift) already threads
// around every real adapter call, and maintains per-provider exponential moving
// averages of latency, error rate and consecutive-failure runs. From those it
// derives a BANDED health state (nominal / sluggish / degraded) with hysteresis,
// and emits a transition ONLY when a provider's band actually changes.
//
// HARD CONSTRAINTS (proof obligations):
//  - Passive: the sensor NEVER issues a provider call. It has no LLMClient and
//    no network capability — it only observes lifecycle evidence it is handed.
//  - Turn-path zero-I/O: `observe(_:)` performs at most one in-memory EMA
//    update and one band recomputation. It touches no disk. Snapshotting to the
//    telemetry dir is a SEPARATE, explicitly-called, off-turn-path method.
//  - Transition-only emission: while a provider's band is stable, `observe`
//    returns nil regardless of call volume — no downstream organism ingest.
//
// The lifecycle seam is payload-free (start/terminal timings + phase). It
// therefore feeds `durationMs` (terminal.occurredAt − started.occurredAt), the
// error signal, and time-to-first-output (terminal.firstOutputAt − started) for
// a streamed call that produced output. Tokens/sec is modelled as an EMA too,
// but the lifecycle path leaves it nil; a richer producer can supply it
// through `observe(sample:)` without any change to this actor.

public enum ProviderVitalsBand: Int, Sendable, Codable, Equatable, Comparable, CaseIterable {
    case nominal = 0
    case sluggish = 1
    case degraded = 2

    public static func < (lhs: ProviderVitalsBand, rhs: ProviderVitalsBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .nominal: return "nominal"
        case .sluggish: return "sluggish"
        case .degraded: return "degraded"
        }
    }
}

/// Direction of a band change — whether the provider got worse or recovered.
/// Drives whether the somatic sibling reads as sluggishness (worsening) or
/// relief (recovery).
public enum ProviderVitalsDirection: String, Sendable, Codable, Equatable {
    case worsening
    case recovering
}

/// One explicit vitals sample. The lifecycle path fills `durationMs`, `isError`
/// and, for a streamed call with output, `ttftMs`; it leaves `tokensPerSec`
/// nil. `isCancelled` samples are ignored by the sensor (a user-cancelled
/// call is not provider ill-health).
public struct ProviderVitalsSample: Sendable, Equatable {
    public var providerId: String
    public var occurredAt: Date
    public var durationMs: Double?
    public var ttftMs: Double?
    public var tokensPerSec: Double?
    public var isError: Bool
    public var isCancelled: Bool

    public init(
        providerId: String,
        occurredAt: Date,
        durationMs: Double? = nil,
        ttftMs: Double? = nil,
        tokensPerSec: Double? = nil,
        isError: Bool,
        isCancelled: Bool = false
    ) {
        self.providerId = providerId
        self.occurredAt = occurredAt
        self.durationMs = durationMs
        self.ttftMs = ttftMs
        self.tokensPerSec = tokensPerSec
        self.isError = isError
        self.isCancelled = isCancelled
    }
}

/// Emitted only on a real band transition for one provider.
public struct ProviderVitalsTransition: Sendable, Equatable {
    public var providerId: String
    public var from: ProviderVitalsBand
    public var to: ProviderVitalsBand
    public var direction: ProviderVitalsDirection
    public var occurredAt: Date
    /// EMA read at transition time — carried as evidence for the felt signal.
    /// Never any prompt/completion text.
    public var emaLatencyMs: Double?
    public var baselineLatencyMs: Double?
    public var emaErrorRate: Double
    public var consecutiveFailures: Int

    public init(
        providerId: String,
        from: ProviderVitalsBand,
        to: ProviderVitalsBand,
        direction: ProviderVitalsDirection,
        occurredAt: Date,
        emaLatencyMs: Double?,
        baselineLatencyMs: Double?,
        emaErrorRate: Double,
        consecutiveFailures: Int
    ) {
        self.providerId = providerId
        self.from = from
        self.to = to
        self.direction = direction
        self.occurredAt = occurredAt
        self.emaLatencyMs = emaLatencyMs
        self.baselineLatencyMs = baselineLatencyMs
        self.emaErrorRate = emaErrorRate
        self.consecutiveFailures = consecutiveFailures
    }

    /// How far the provider is running from its own baseline latency.
    public var latencyRatio: Double? {
        guard let ema = emaLatencyMs, let base = baselineLatencyMs, base > 0 else { return nil }
        return ema / base
    }
}

// MARK: - Sensor

public actor ProviderVitalsSensor {
    public struct ProviderVitals: Sendable, Equatable {
        public var providerId: String
        public var band: ProviderVitalsBand
        public var emaLatencyMs: Double?
        public var baselineLatencyMs: Double?
        public var emaTTFTMs: Double?
        public var emaTokensPerSec: Double?
        public var emaErrorRate: Double
        public var consecutiveFailures: Int
        public var sampleCount: Int
    }

    private struct State {
        var band: ProviderVitalsBand = .nominal
        var emaLatencyMs: Double?
        var baselineLatencyMs: Double?
        var emaTTFTMs: Double?
        var emaTokensPerSec: Double?
        var emaErrorRate: Double = 0
        var consecutiveFailures: Int = 0
        var sampleCount: Int = 0
        /// LRU stamp for the provider-row cap (gpt-5.5 review: `states` was
        /// unbounded — an adversarial/misconfigured provider-id stream could
        /// grow memory and telemetry forever).
        var lastSampleAt: Date?
    }

    private static let fastAlpha = 0.4
    private static let baselineAlpha = 0.05
    private static let warmupSamples = 5
    private static let maxTrackedProviders = 24
    private static let enterSluggish = 1.0
    private static let exitSluggish = 0.6
    private static let enterDegraded = 2.0
    private static let exitDegraded = 1.4
    private var states: [String: State] = [:]
    /// Start timestamps for in-flight calls, keyed by lifecycle id, so a
    /// terminal event can compute the call's duration. Bounded — a call whose
    /// terminal never arrives is evicted once the map exceeds the cap.
    private var openCallStarts: [String: Date] = [:]
    private var openCallOrder: [String] = []
    private static let maxOpenCalls = 512

    /// First outputs, per provider + model + stream kind: the adapter's
    /// `ttftMs` (request to first text or tool output) in seconds, oldest first.
    /// The trace is their durable record: read once at launch, then each live
    /// call's `ttftMs` joins here under the same definition. Nothing is written.
    private struct FirstOutputKey: Hashable { let provider, model: String; let streamKind: String? }
    private var firstOutputs: [FirstOutputKey: [(seconds: Double, bytes: Int?)]] = [:]
    /// Rows the retained trace sources could not decode at launch: their first
    /// outputs are missing from the sample, and Diagnostics says how many.
    private var unreadableTraceRows = 0
    /// Stream-guard cuts per provider id (`provider.noReply`): not first
    /// outputs, counted beside them.
    private var noReplyCuts: [String: Int] = [:]

    public init() {}

    // MARK: Lifecycle

    /// Passive lifecycle observation: `started` events only record the call's
    /// start time; terminal events derive one sample, update the EMAs and join
    /// a first output or a cut, all in memory. Returns the band transition (if
    /// any) so an owner can route it onward.
    @discardableResult
    public func ingest(lifecycle event: LLMCallLifecycleEvent) -> ProviderVitalsTransition? {
        switch event.phase {
        case .started:
            rememberStart(id: event.id, at: event.occurredAt)
            return nil
        case .cancelled:
            forgetStart(id: event.id)
            return nil
        case .succeeded, .failed:
            let started = takeStart(id: event.id)
            let duration = started.map { max(0, event.occurredAt.timeIntervalSince($0) * 1000) }
            let ttft = event.firstOutputMs.map(Double.init)
            if event.streaming, let ttft {
                joinFirstOutput(firstOutputKey(event.providerId, event.model, event.streamKind), seconds: ttft / 1000,
                                bytes: event.requestBytes)
            }
            if event.noReply { noReplyCuts[normalizedProviderId(event.providerId), default: 0] += 1 }
            let sample = ProviderVitalsSample(
                providerId: event.providerId,
                occurredAt: event.occurredAt,
                durationMs: duration,
                ttftMs: ttft,
                tokensPerSec: nil,
                isError: event.phase == .failed
            )
            return observe(sample: sample)
        }
    }

    /// Ingest one explicit sample. Returns a transition iff the band changed.
    /// This is the single in-memory EMA update the proof obligations require.
    @discardableResult
    public func observe(sample: ProviderVitalsSample) -> ProviderVitalsTransition? {
        guard !sample.isCancelled else { return nil }
        let key = normalizedProviderId(sample.providerId)
        guard !key.isEmpty else { return nil }
        var state = states[key] ?? State()
        let previousBand = state.band

        // Fast latency EMA. The slow baseline is deliberately NOT updated here
        // — see below, after the band for this sample is known.
        if let duration = sample.durationMs {
            state.emaLatencyMs = ema(state.emaLatencyMs, duration, alpha: Self.fastAlpha)
        }
        if let ttft = sample.ttftMs {
            state.emaTTFTMs = ema(state.emaTTFTMs, ttft, alpha: Self.fastAlpha)
        }
        if let tps = sample.tokensPerSec {
            state.emaTokensPerSec = ema(state.emaTokensPerSec, tps, alpha: Self.fastAlpha)
        }
        // Error-rate EMA + consecutive-failure run.
        let errorPoint = sample.isError ? 1.0 : 0.0
        state.emaErrorRate = ema(state.emaErrorRate, errorPoint, alpha: Self.fastAlpha) ?? errorPoint
        state.consecutiveFailures = sample.isError ? state.consecutiveFailures + 1 : 0
        state.sampleCount += 1

        // Band with hysteresis. Cold-start providers are pinned nominal until
        // enough samples have accumulated to trust the EMAs.
        let strain = state.sampleCount < Self.warmupSamples ? 0 : self.strain(for: state)
        let nextBand = resolveBand(current: state.band, strain: strain)
        state.band = nextBand

        // User, 2026-09-06: the baseline is what NORMAL looks like, so it learns
        // only from samples that were nominal going in AND coming out.
        //
        // Folding every sample in taught the baseline the provider's own
        // degradation: under sustained slowness `ratio = ema / base` walked
        // back toward 1, the latency contributor fell out of the strain, and
        // the sensor announced a recovery that never happened. Gating on the
        // PREVIOUS band alone still let the transition sample through — the
        // one sample that broke the band is the worst one to call normal, and
        // on a flapping provider every excursion donated its first bad sample
        // to the baseline. The band is resolved first (against the established
        // baseline, which is the comparison that makes it meaningful), and the
        // baseline learns only if the sample left the provider nominal too.
        // Cold start still learns freely — a warming provider is pinned
        // nominal until `warmupSamples`.
        if previousBand == .nominal, nextBand == .nominal, let duration = sample.durationMs {
            state.baselineLatencyMs = ema(
                state.baselineLatencyMs, duration, alpha: Self.baselineAlpha)
        }

        state.lastSampleAt = sample.occurredAt
        states[key] = state
        // Provider-row cap: evict the least-recently-sampled NOMINAL rows past
        // the bound (never evict a row mid-story — sluggish/degraded rows carry
        // live band state a transition depends on; with a real provider
        // population under 10, eviction only ever hits junk ids). Snapshot
        // serialization is bounded by the same cap for free.
        if states.count > Self.maxTrackedProviders {
            let evictable = states
                .filter { $0.value.band == .nominal && $0.key != key }
                .sorted { ($0.value.lastSampleAt ?? .distantPast) < ($1.value.lastSampleAt ?? .distantPast) }
            for (staleKey, _) in evictable.prefix(states.count - Self.maxTrackedProviders) {
                states.removeValue(forKey: staleKey)
            }
        }

        guard nextBand != previousBand else { return nil }
        let direction: ProviderVitalsDirection = nextBand > previousBand ? .worsening : .recovering
        return ProviderVitalsTransition(
            providerId: key,
            from: previousBand,
            to: nextBand,
            direction: direction,
            occurredAt: sample.occurredAt,
            emaLatencyMs: state.emaLatencyMs,
            baselineLatencyMs: state.baselineLatencyMs,
            emaErrorRate: state.emaErrorRate,
            consecutiveFailures: state.consecutiveFailures
        )
    }

    // MARK: First outputs

    /// Launch-owned, once, read behind her: the retained trace's first outputs
    /// and cuts up to `cutoff`, joined ahead of the calls this run has already
    /// observed live (their rows are the ones after the cutoff).
    public func readFirstOutputs(
        dataRoot: URL, before cutoff: Date
    ) async throws {
        let read = try await TurnTraceRecentReader(dataRootOverride: dataRoot)
            .traceEvidence(now: cutoff, since: .distantPast)
        unreadableTraceRows = read.report.malformedLineCount
        // Oldest first; the ledger part is not windowed by `now`.
        var rows = read.rows[...]
        while case .object(let last)? = rows.last, case .string(let raw)? = last["createdAt"],
              let at = TurnTraceEvent.parseISO8601(raw), at > cutoff {
            rows.removeLast()
        }
        let live = firstOutputs
        firstOutputs = [:]
        for case .object(let row) in rows {
            guard case .object(let payload)? = row["payload"], case .string(let provider)? = payload["provider"]
            else { continue }
            if row["kind"] == .string("provider.noReply") {
                noReplyCuts[normalizedProviderId(provider), default: 0] += 1
            } else if row["kind"] == .string("llm.call"), payload["streaming"] == .bool(true),
                      case .int(let ms)? = payload["ttftMs"], case .string(let model)? = payload["model"] {
                let kind: String? = if case .string(let kind)? = payload["streamKind"] { kind } else { nil }
                let bytes: Int? = if case .int(let bytes)? = payload["requestBytes"] { Int(bytes) } else { nil }
                joinFirstOutput(firstOutputKey(provider, model, kind), seconds: Double(ms) / 1000, bytes: bytes)
            }
        }
        for (key, samples) in live { samples.forEach { joinFirstOutput(key, seconds: $0.seconds, bytes: $0.bytes) } }
    }

    /// The stream guard's question at stream start, for a request of `requestBytes`.
    public func firstOutputDeadline(provider: String, model: String, streamKind: String?, requestBytes: Int) -> FirstOutputDeadline {
        let samples = firstOutputs[firstOutputKey(provider, model, streamKind)] ?? []
        let perByte = samples.compactMap { sample in sample.bytes.flatMap { $0 > 0 ? sample.seconds / Double($0) : nil } }.max()
        return FirstOutputDeadline(calls: samples.count, slowest: samples.map(\.seconds).max(),
                                   slowestPerByte: perByte, requestBytes: requestBytes)
    }

    /// Diagnostics: each provider's first outputs beside its cuts.
    public func firstOutputReport() -> String {
        "Retained traces at launch: \(unreadableTraceRows) rows unreadable\n"
        + Set(firstOutputs.keys.map(\.provider)).union(noReplyCuts.keys).sorted().map { provider in
            "\(provider): \(noReplyCuts[provider] ?? 0) no-reply cuts" + firstOutputs.keys
                .filter { $0.provider == provider }
                .sorted { ($0.model, $0.streamKind ?? "") < ($1.model, $1.streamKind ?? "") }
                .map { key in
                    let sorted = (firstOutputs[key] ?? []).map(\.seconds).sorted()
                    func rank(_ q: Double) -> String {
                        sorted.isEmpty ? "-" : String(format: "%.1f s", sorted[Int((q * Double(sorted.count)).rounded(.up)) - 1])
                    }
                    let deadline = FirstOutputDeadline(calls: sorted.count, slowest: sorted.last).seconds
                        .map { String(format: "%.1f s", $0) }
                        ?? "unmeasured (\(sorted.count) of \(FirstOutputDeadline.callsNeeded) calls)"
                    return "\n  \(key.model) \(key.streamKind ?? "stream"): first output p50 \(rank(0.5)), "
                        + "p99 \(rank(0.99)), slowest \(rank(1)) over \(sorted.count) calls"
                        + (unreadableTraceRows == 0 ? "" : " (\(unreadableTraceRows) trace rows unreadable)")
                        + "; deadline \(deadline)"
                }.joined()
        }.joined(separator: "\n")
    }

    private func firstOutputKey(_ provider: String, _ model: String, _ streamKind: String?) -> FirstOutputKey {
        FirstOutputKey(provider: normalizedProviderId(provider), model: model.lowercased(), streamKind: streamKind)
    }

    /// The trace's own retention rule, no clock: it keeps its newest
    /// `JSONLLineCaps.traceEvents` rows, so a key keeps at most that many first
    /// outputs and one leaves only when a newer one pushes it out. (The trace
    /// is shared with other rows, so after a relaunch a key may hold fewer.)
    private func joinFirstOutput(_ key: FirstOutputKey, seconds: Double, bytes: Int?) {
        firstOutputs[key, default: []].append((seconds, bytes))
        let over = firstOutputs[key, default: []].count - JSONLLineCaps.traceEvents
        if over > 0 { firstOutputs[key]?.removeFirst(over) }
    }

    // MARK: Read-only introspection / snapshot

    public func vitals(for providerId: String) -> ProviderVitals? {
        let key = normalizedProviderId(providerId)
        guard let state = states[key] else { return nil }
        return vitals(key: key, state: state)
    }

    private func vitals(key: String, state: State) -> ProviderVitals {
        ProviderVitals(
            providerId: key,
            band: state.band,
            emaLatencyMs: state.emaLatencyMs,
            baselineLatencyMs: state.baselineLatencyMs,
            emaTTFTMs: state.emaTTFTMs,
            emaTokensPerSec: state.emaTokensPerSec,
            emaErrorRate: state.emaErrorRate,
            consecutiveFailures: state.consecutiveFailures,
            sampleCount: state.sampleCount
        )
    }

    /// Serializable snapshot (counts/timings/band only — no prompt content).
    /// The generation and state timestamps make restart restore age-bounded;
    /// without them a months-old degraded band could be mistaken for live
    /// provider health.
    public func snapshotJSON(generatedAt: Date = Date()) -> JSONValue {
        var providers: [String: JSONValue] = [:]
        for key in states.keys.sorted() {
            guard let state = states[key] else { continue }
            let v = vitals(key: key, state: state)
            var obj: [String: JSONValue] = [
                "band": .string(v.band.label),
                "emaErrorRate": .double(v.emaErrorRate),
                "consecutiveFailures": .int(Int64(v.consecutiveFailures)),
                "sampleCount": .int(Int64(v.sampleCount)),
            ]
            if let l = v.emaLatencyMs { obj["emaLatencyMs"] = .double(l) }
            if let b = v.baselineLatencyMs { obj["baselineLatencyMs"] = .double(b) }
            if let t = v.emaTTFTMs { obj["emaTTFTMs"] = .double(t) }
            if let tps = v.emaTokensPerSec { obj["emaTokensPerSec"] = .double(tps) }
            if let date = state.lastSampleAt { obj["lastSampleAt"] = .string(Self.formatDate(date)) }
            providers[v.providerId] = .object(obj)
        }
        return .object([
            "schema": .string("provider.vitals.v1"),
            "generatedAt": .string(Self.formatDate(generatedAt)),
            "providers": .object(providers),
        ])
    }

    /// Restore recent provider health at process bootstrap. Invalid rows are
    /// ignored independently, while an absent/stale/future snapshot restores
    /// nothing. In-flight lifecycle starts are intentionally never persisted.
    @discardableResult
    public func restoreSnapshot(
        dataRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        now: Date = Date(),
        maxAge: TimeInterval = 6 * 60 * 60,
        futureSkewAllowance: TimeInterval = 5 * 60
    ) async throws -> Bool {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        let path = root
            .appendingPathComponent("telemetry", isDirectory: true)
            .appendingPathComponent("provider_vitals.json")
        let value = try await persistence.readJSON(path, ifMissing: .null)
        guard case .object(let snapshot) = value,
              case .string("provider.vitals.v1")? = snapshot["schema"],
              let generatedAt = Self.date(snapshot["generatedAt"]),
              now.timeIntervalSince(generatedAt) <= max(0, maxAge),
              generatedAt.timeIntervalSince(now) <= max(0, futureSkewAllowance),
              case .object(let rows)? = snapshot["providers"] else {
            return false
        }

        var restored: [(String, State)] = []
        restored.reserveCapacity(min(rows.count, Self.maxTrackedProviders))
        for (rawKey, value) in rows {
            let key = normalizedProviderId(rawKey)
            guard !key.isEmpty,
                  case .object(let row) = value,
                  let band = Self.band(row["band"]),
                  let errorRate = Self.number(row["emaErrorRate"]), errorRate >= 0, errorRate <= 1,
                  let failures = Self.integer(row["consecutiveFailures"]), failures >= 0,
                  let samples = Self.integer(row["sampleCount"]), samples >= failures else {
                continue
            }
            let lastSampleAt = Self.optionalDate(row["lastSampleAt"])
            guard lastSampleAt != .invalid,
                  let sampledAt = lastSampleAt.value,
                  now.timeIntervalSince(sampledAt) <= max(0, maxAge),
                  (lastSampleAt.value?.timeIntervalSince(now) ?? 0) <= max(0, futureSkewAllowance) else {
                continue
            }
            guard let latency = Self.optionalNonnegativeNumber(row["emaLatencyMs"]),
                  let baseline = Self.optionalNonnegativeNumber(row["baselineLatencyMs"]),
                  let ttft = Self.optionalNonnegativeNumber(row["emaTTFTMs"]),
                  let tokensPerSec = Self.optionalNonnegativeNumber(row["emaTokensPerSec"]) else {
                continue
            }
            var state = State()
            state.band = band
            state.emaLatencyMs = latency
            state.baselineLatencyMs = baseline
            state.emaTTFTMs = ttft
            state.emaTokensPerSec = tokensPerSec
            state.emaErrorRate = errorRate
            state.consecutiveFailures = failures
            state.sampleCount = samples
            state.lastSampleAt = lastSampleAt.value
            restored.append((key, state))
        }

        restored.sort {
            if $0.1.band != $1.1.band { return $0.1.band > $1.1.band }
            if $0.1.lastSampleAt != $1.1.lastSampleAt {
                return ($0.1.lastSampleAt ?? .distantPast) > ($1.1.lastSampleAt ?? .distantPast)
            }
            return $0.0 < $1.0
        }
        states = Dictionary(
            restored.prefix(Self.maxTrackedProviders),
            uniquingKeysWith: { first, _ in first }
        )
        openCallStarts.removeAll(keepingCapacity: true)
        openCallOrder.removeAll(keepingCapacity: true)
        return true
    }

    /// Off-turn-path snapshot persistence. This is the ONLY disk write in the
    /// organ and it is never called from `observe(_:)` — an owner schedules it
    /// on a periodic/idle timer. Non-fatal on failure.
    public func persistSnapshot(
        dataRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        let path = root
            .appendingPathComponent("telemetry", isDirectory: true)
            .appendingPathComponent("provider_vitals.json")
        do {
            try await persistence.writeJSON(snapshotJSON(), to: path)
        } catch {
            FileHandle.standardError.write(
                Data("ProviderVitalsSensor: snapshot write failed: \(error)\n".utf8)
            )
        }
    }

    // MARK: - Internals

    /// Composite strain scalar. Bands map at ~1.0 (sluggish) and ~2.0
    /// (degraded); each contributor is scaled so its own "concerning" level
    /// lands near those anchors. Strain is the max across contributors — any one
    /// bad dimension is enough.
    private func strain(for state: State) -> Double {
        var contributors: [Double] = []
        // Error rate: 25% → 1.0, 50% → 2.0.
        contributors.append(state.emaErrorRate / 0.25)
        // Consecutive failures: 2 → 1.0, 4 → 2.0.
        contributors.append(Double(state.consecutiveFailures) / 2.0)
        // Latency ratio vs baseline: 1.6× → 1.0, 2.2× → 2.0.
        if let ema = state.emaLatencyMs, let base = state.baselineLatencyMs, base > 0 {
            let ratio = ema / base
            if ratio > 1 { contributors.append((ratio - 1.0) / 0.6) }
        }
        return contributors.max() ?? 0
    }

    private func resolveBand(current: ProviderVitalsBand, strain: Double) -> ProviderVitalsBand {
        switch current {
        case .nominal:
            if strain >= Self.enterDegraded { return .degraded }
            if strain >= Self.enterSluggish { return .sluggish }
            return .nominal
        case .sluggish:
            if strain >= Self.enterDegraded { return .degraded }
            if strain < Self.exitSluggish { return .nominal }
            return .sluggish
        case .degraded:
            if strain < Self.exitSluggish { return .nominal }
            if strain < Self.exitDegraded { return .sluggish }
            return .degraded
        }
    }

    private func ema(_ current: Double?, _ value: Double, alpha: Double) -> Double? {
        guard let current else { return value }
        return current + alpha * (value - current)
    }

    private func normalizedProviderId(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(80))
    }

    private enum OptionalDate: Equatable {
        case value(Date?)
        case invalid

        var value: Date? {
            guard case .value(let date) = self else { return nil }
            return date
        }
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func optionalDate(_ value: JSONValue?) -> OptionalDate {
        guard let value else { return .value(nil) }
        guard let parsed = date(value) else { return .invalid }
        return .value(parsed)
    }

    private static func band(_ value: JSONValue?) -> ProviderVitalsBand? {
        guard case .string(let raw)? = value else { return nil }
        return ProviderVitalsBand.allCases.first { $0.label == raw }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .int(let raw)? = value,
              raw >= 0,
              raw <= Int64(Int.max) else { return nil }
        return Int(raw)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        let result: Double
        switch value {
        case .double(let raw)?: result = raw
        case .int(let raw)?: result = Double(raw)
        default: return nil
        }
        return result.isFinite ? result : nil
    }

    /// `nil` means a valid absent optional value; outer nil means malformed.
    private static func optionalNonnegativeNumber(_ value: JSONValue?) -> Double?? {
        guard let value else { return .some(nil) }
        guard let number = number(value), number >= 0 else { return nil }
        return .some(number)
    }

    private func rememberStart(id: String, at date: Date) {
        guard !id.isEmpty else { return }
        if openCallStarts[id] == nil { openCallOrder.append(id) }
        openCallStarts[id] = date
        if openCallOrder.count > Self.maxOpenCalls {
            let drop = openCallOrder.count - Self.maxOpenCalls
            for stale in openCallOrder.prefix(drop) { openCallStarts.removeValue(forKey: stale) }
            openCallOrder.removeFirst(drop)
        }
    }

    private func takeStart(id: String) -> Date? {
        guard let date = openCallStarts.removeValue(forKey: id) else { return nil }
        if let idx = openCallOrder.firstIndex(of: id) { openCallOrder.remove(at: idx) }
        return date
    }

    private func forgetStart(id: String) {
        _ = takeStart(id: id)
    }
}
