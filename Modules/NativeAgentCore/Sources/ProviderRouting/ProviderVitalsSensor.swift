import Foundation
import NativeAgentCore
import PersistenceCore

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
// therefore feeds `durationMs` (terminal.occurredAt − started.occurredAt) and
// the error signal. Time-to-first-token and tokens/sec are modelled as first-
// class EMAs too, but the lifecycle path leaves them nil; a richer producer can
// supply them through `observe(sample:)` without any change to this actor.

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

/// One explicit vitals sample. The lifecycle path fills `durationMs` + `isError`
/// and leaves `ttftMs`/`tokensPerSec` nil; a richer telemetry producer can fill
/// all four. `isCancelled` samples are ignored by the sensor (a user-cancelled
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
    /// EMA read at transition time — carried as evidence for the felt signal
    /// and the (later) approval card wording. Never any prompt/completion text.
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

    /// True when the provider is running visibly slower than its own baseline —
    /// backs the "at half speed" card wording.
    public var latencyRatio: Double? {
        guard let ema = emaLatencyMs, let base = baselineLatencyMs, base > 0 else { return nil }
        return ema / base
    }
}

/// Card lifecycle decision surfaced by the sensor. The sensor NEVER switches a
/// provider — it decides only whether a proposal card should be staged or
/// expired; the actual staging rides the existing approval lane in the owner.
public enum ProviderVitalsCardDecision: Sendable, Equatable {
    case stage(providerId: String, transition: ProviderVitalsTransition)
    case expire(providerId: String)
}

/// Tunables. Defaults chosen so a single slow call never trips a band and a
/// genuinely stable stream never transitions.
public struct ProviderVitalsConfiguration: Sendable, Equatable {
    /// EMA smoothing for the fast (recent) latency/error signals.
    public var fastAlpha: Double
    /// EMA smoothing for the slow latency baseline.
    public var baselineAlpha: Double
    /// Samples required before a provider may leave `nominal` (cold-start guard).
    public var warmupSamples: Int
    /// Sustained-degraded dwell before a card is staged.
    public var cardStageAfter: TimeInterval
    /// Provider-row cap (LRU eviction of nominal rows past this bound) —
    /// bounds resident memory AND the telemetry snapshot.
    public var maxTrackedProviders: Int

    // Hysteresis thresholds on the composite strain scalar.
    public var enterSluggish: Double
    public var exitSluggish: Double
    public var enterDegraded: Double
    public var exitDegraded: Double

    public init(
        fastAlpha: Double = 0.4,
        baselineAlpha: Double = 0.05,
        warmupSamples: Int = 5,
        cardStageAfter: TimeInterval = 10 * 60,
        maxTrackedProviders: Int = 24,
        enterSluggish: Double = 1.0,
        exitSluggish: Double = 0.6,
        enterDegraded: Double = 2.0,
        exitDegraded: Double = 1.4
    ) {
        self.fastAlpha = fastAlpha
        self.baselineAlpha = baselineAlpha
        self.warmupSamples = max(0, warmupSamples)
        self.cardStageAfter = max(0, cardStageAfter)
        self.maxTrackedProviders = max(1, maxTrackedProviders)
        self.enterSluggish = enterSluggish
        self.exitSluggish = exitSluggish
        self.enterDegraded = enterDegraded
        self.exitDegraded = exitDegraded
    }

    public static let `default` = ProviderVitalsConfiguration()
}

// MARK: - Sensor

public actor ProviderVitalsSensor: LLMCallLifecycleObserving {
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
        public var cardActive: Bool
        public var degradedSince: Date?
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
        var degradedSince: Date?
        var cardActive: Bool = false
        /// LRU stamp for the provider-row cap (gpt-5.5 review: `states` was
        /// unbounded — an adversarial/misconfigured provider-id stream could
        /// grow memory and telemetry forever).
        var lastSampleAt: Date?
    }

    private let configuration: ProviderVitalsConfiguration
    private var states: [String: State] = [:]
    /// Start timestamps for in-flight calls, keyed by lifecycle id, so a
    /// terminal event can compute the call's duration. Bounded — a call whose
    /// terminal never arrives is evicted once the map exceeds the cap.
    private var openCallStarts: [String: Date] = [:]
    private var openCallOrder: [String] = []
    private static let maxOpenCalls = 512

    public init(configuration: ProviderVitalsConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: LLMCallLifecycleObserving (passive hook)

    /// Passive lifecycle observation. `started` events only record the call's
    /// start time; terminal events derive one sample and update the EMAs. This
    /// is the ONLY per-call work and it is all in-memory.
    public func observeProviderCall(_ event: LLMCallLifecycleEvent) async {
        _ = ingest(lifecycle: event)
    }

    /// Same as `observeProviderCall` but returns the band transition (if any) so
    /// an owner can route it onward. Kept separate because the protocol method
    /// is `Void`.
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
            let sample = ProviderVitalsSample(
                providerId: event.providerId,
                occurredAt: event.occurredAt,
                durationMs: duration,
                ttftMs: nil,
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

        // Latency EMAs (fast + slow baseline).
        if let duration = sample.durationMs {
            state.emaLatencyMs = ema(state.emaLatencyMs, duration, alpha: configuration.fastAlpha)
            state.baselineLatencyMs = ema(state.baselineLatencyMs, duration, alpha: configuration.baselineAlpha)
        }
        if let ttft = sample.ttftMs {
            state.emaTTFTMs = ema(state.emaTTFTMs, ttft, alpha: configuration.fastAlpha)
        }
        if let tps = sample.tokensPerSec {
            state.emaTokensPerSec = ema(state.emaTokensPerSec, tps, alpha: configuration.fastAlpha)
        }
        // Error-rate EMA + consecutive-failure run.
        let errorPoint = sample.isError ? 1.0 : 0.0
        state.emaErrorRate = ema(state.emaErrorRate, errorPoint, alpha: configuration.fastAlpha) ?? errorPoint
        state.consecutiveFailures = sample.isError ? state.consecutiveFailures + 1 : 0
        state.sampleCount += 1

        // Band with hysteresis. Cold-start providers are pinned nominal until
        // enough samples have accumulated to trust the EMAs.
        let strain = state.sampleCount < configuration.warmupSamples ? 0 : self.strain(for: state)
        let nextBand = resolveBand(current: state.band, strain: strain)
        state.band = nextBand

        if nextBand == .degraded {
            if state.degradedSince == nil { state.degradedSince = sample.occurredAt }
        } else {
            state.degradedSince = nil
        }

        state.lastSampleAt = sample.occurredAt
        states[key] = state
        // Provider-row cap: evict the least-recently-sampled NOMINAL rows past
        // the bound (never evict a row mid-story — sluggish/degraded rows carry
        // live band state a transition depends on; with a real provider
        // population under 10, eviction only ever hits junk ids). Snapshot
        // serialization is bounded by the same cap for free.
        if states.count > configuration.maxTrackedProviders {
            let evictable = states
                .filter { $0.value.band == .nominal && $0.key != key }
                .sorted { ($0.value.lastSampleAt ?? .distantPast) < ($1.value.lastSampleAt ?? .distantPast) }
            for (staleKey, _) in evictable.prefix(states.count - configuration.maxTrackedProviders) {
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

    // MARK: Card decision (pure; owner performs the actual staging)

    /// Evaluate whether the sustained-degradation card should be staged or
    /// expired for any provider, as of `now`. Pure state read + at-most-once
    /// latch flip per provider (a staged card is not re-staged until it expires;
    /// an expired card is not re-expired until a new one stages).
    public func evaluateCardDecisions(now: Date) -> [ProviderVitalsCardDecision] {
        var decisions: [ProviderVitalsCardDecision] = []
        for key in states.keys.sorted() {
            guard var state = states[key] else { continue }
            if state.band == .degraded,
               let since = state.degradedSince,
               now.timeIntervalSince(since) >= configuration.cardStageAfter {
                if !state.cardActive {
                    state.cardActive = true
                    states[key] = state
                    decisions.append(.stage(
                        providerId: key,
                        transition: ProviderVitalsTransition(
                            providerId: key,
                            from: .degraded,
                            to: .degraded,
                            direction: .worsening,
                            occurredAt: now,
                            emaLatencyMs: state.emaLatencyMs,
                            baselineLatencyMs: state.baselineLatencyMs,
                            emaErrorRate: state.emaErrorRate,
                            consecutiveFailures: state.consecutiveFailures
                        )
                    ))
                }
            } else if state.cardActive, state.band < .degraded {
                // Recovered below degraded → the card is stale; expire it.
                state.cardActive = false
                states[key] = state
                decisions.append(.expire(providerId: key))
            }
        }
        return decisions
    }

    // MARK: Read-only introspection / snapshot

    public func vitals(for providerId: String) -> ProviderVitals? {
        let key = normalizedProviderId(providerId)
        guard let state = states[key] else { return nil }
        return vitals(key: key, state: state)
    }

    public func allVitals() -> [ProviderVitals] {
        states.keys.sorted().compactMap { key in states[key].map { vitals(key: key, state: $0) } }
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
            sampleCount: state.sampleCount,
            cardActive: state.cardActive,
            degradedSince: state.degradedSince
        )
    }

    /// Serializable snapshot (counts/timings/band only — no prompt content).
    public func snapshotJSON() -> JSONValue {
        var providers: [String: JSONValue] = [:]
        for v in allVitals() {
            var obj: [String: JSONValue] = [
                "band": .string(v.band.label),
                "emaErrorRate": .double(v.emaErrorRate),
                "consecutiveFailures": .int(Int64(v.consecutiveFailures)),
                "sampleCount": .int(Int64(v.sampleCount)),
                "cardActive": .bool(v.cardActive),
            ]
            if let l = v.emaLatencyMs { obj["emaLatencyMs"] = .double(l) }
            if let b = v.baselineLatencyMs { obj["baselineLatencyMs"] = .double(b) }
            if let t = v.emaTTFTMs { obj["emaTTFTMs"] = .double(t) }
            if let tps = v.emaTokensPerSec { obj["emaTokensPerSec"] = .double(tps) }
            providers[v.providerId] = .object(obj)
        }
        return .object([
            "schema": .string("provider.vitals.v1"),
            "providers": .object(providers),
        ])
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
            if strain >= configuration.enterDegraded { return .degraded }
            if strain >= configuration.enterSluggish { return .sluggish }
            return .nominal
        case .sluggish:
            if strain >= configuration.enterDegraded { return .degraded }
            if strain < configuration.exitSluggish { return .nominal }
            return .sluggish
        case .degraded:
            if strain < configuration.exitSluggish { return .nominal }
            if strain < configuration.exitDegraded { return .sluggish }
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
