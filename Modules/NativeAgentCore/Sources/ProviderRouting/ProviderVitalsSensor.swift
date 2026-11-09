import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared

// Blueprint: | `ProviderVitalsSensor.swift` | `ProviderVitalsSensor`: passive bounded lifecycle evidence |

// MARK: - INTEROCEPTION: provider vitals sensor
// Observe lifecycle evidence passively: no provider calls or turn-path I/O. Update bounded in-memory latency/error EMAs and emit only band changes;
// persistence is explicitly off-turn. Missing output timings stay unknown.

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

/// Worsening and recovery drive distinct somatic signals.
public enum ProviderVitalsDirection: String, Sendable, Codable, Equatable {
    case worsening
    case recovering
}

/// Cancellation is not provider ill-health; lifecycle samples omit throughput when it was not measured.
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

/// Stable bands emit nothing regardless of call volume.
public struct ProviderVitalsTransition: Sendable, Equatable {
    public var providerId: String
    public var from: ProviderVitalsBand
    public var to: ProviderVitalsBand
    public var direction: ProviderVitalsDirection
    public var occurredAt: Date
    /// Transition evidence retains timings, never prompt or completion text.
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

    /// Compare latency to this provider's own baseline.
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
        /// Bound row storage by last sample.
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
    /// Bound in-flight starts so a missing terminal event cannot leak memory forever.
    private var openCallStarts: [String: Date] = [:]
    private var openCallOrder: [String] = []
    private static let maxOpenCalls = 512

    public init() {}

    // MARK: Lifecycle

    /// Lifecycle observation updates memory only; its caller owns routing a band transition.
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

    /// One sample performs one bounded in-memory EMA/band update.
    @discardableResult
    public func observe(sample: ProviderVitalsSample) -> ProviderVitalsTransition? {
        guard !sample.isCancelled else { return nil }
        let key = normalizedProviderId(sample.providerId)
        guard !key.isEmpty else { return nil }
        var state = states[key] ?? State()
        let previousBand = state.band

        // Resolve this sample's band before deciding whether it may teach the slow baseline.
        if let duration = sample.durationMs {
            state.emaLatencyMs = ema(state.emaLatencyMs, duration, alpha: Self.fastAlpha)
        }
        if let ttft = sample.ttftMs {
            state.emaTTFTMs = ema(state.emaTTFTMs, ttft, alpha: Self.fastAlpha)
        }
        if let tps = sample.tokensPerSec {
            state.emaTokensPerSec = ema(state.emaTokensPerSec, tps, alpha: Self.fastAlpha)
        }
        let errorPoint = sample.isError ? 1.0 : 0.0
        state.emaErrorRate = ema(state.emaErrorRate, errorPoint, alpha: Self.fastAlpha) ?? errorPoint
        let (failures, failuresOverflow) = state.consecutiveFailures.addingReportingOverflow(1)
        let (samples, samplesOverflow) = state.sampleCount.addingReportingOverflow(1)
        state.consecutiveFailures = sample.isError ? (failuresOverflow ? Int.max : failures) : 0
        state.sampleCount = samplesOverflow ? Int.max : samples
        if samplesOverflow || (sample.isError && failuresOverflow) {
            nativeLog("Provider vitals counter exhausted for %@; count is saturated", key)
        }

        // Cold-start providers need enough evidence before EMA strain can change their band.
        let strain = state.sampleCount < Self.warmupSamples ? 0 : self.strain(for: state)
        let nextBand = resolveBand(current: state.band, strain: strain)
        state.band = nextBand

        // After warmup, the baseline learns only from samples nominal both before and after band resolution.
        if previousBand == .nominal, nextBand == .nominal, let duration = sample.durationMs {
            state.baselineLatencyMs = ema(
                state.baselineLatencyMs, duration, alpha: Self.baselineAlpha)
        }

        state.lastSampleAt = sample.occurredAt
        states[key] = state
        // Evict only nominal rows: sluggish/degraded rows retain live transition state. The same cap bounds serialized snapshots.
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

    /// Persist timestamps/generation with timing-only state so old degraded bands cannot look current after restart.
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

    /// Restore rows independently; absent, stale or future snapshots prove no current health. Never persist in-flight starts.
    @discardableResult
    public func restoreSnapshot(
        dataRoot: URL? = nil,
        now: Date = Date(),
        maxAge: TimeInterval = 6 * 60 * 60,
        futureSkewAllowance: TimeInterval = 5 * 60
    ) async throws -> Bool {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        let path = root
            .appendingPathComponent("telemetry", isDirectory: true)
            .appendingPathComponent("provider_vitals.json")
        let value = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .null)
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
                  let errorRate = row["emaErrorRate"]?.numberValue(coercingStrings: false, finiteOnly: true), errorRate >= 0, errorRate <= 1,
                  let failures = Self.integer(row["consecutiveFailures"]), failures >= 0,
                  let samples = Self.integer(row["sampleCount"]), samples >= failures else {
                continue
            }
            guard samples < Int.max, failures < Int.max else {
                nativeLog("Provider vitals restore refused exhausted counters for %@", key)
                continue
            }
            guard let lastSampleAt = Self.date(row["lastSampleAt"]),
                  now.timeIntervalSince(lastSampleAt) <= max(0, maxAge),
                  lastSampleAt.timeIntervalSince(now) <= max(0, futureSkewAllowance) else {
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
            state.lastSampleAt = lastSampleAt
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

    /// Only explicit off-turn persistence writes disk; observation never does, and snapshot faults cannot fail calls.
    public func persistSnapshot(
        dataRoot: URL? = nil
    ) async {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        let path = root
            .appendingPathComponent("telemetry", isDirectory: true)
            .appendingPathComponent("provider_vitals.json")
        do {
            try await SwiftNativePersistenceCore.writeJSON(snapshotJSON(), to: path)
        } catch {
            FileHandle.standardError.write(
                Data("ProviderVitalsSensor: snapshot write failed: \(error)\n".utf8)
            )
        }
    }

    // MARK: - Internals

    /// Scale concerning strain near 1 and degraded strain near 2; take the maximum so one bad dimension is sufficient.
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

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        return ISO8601DateFormatter().date(from: raw)
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

    /// `nil` means a valid absent optional value; outer nil means malformed.
    private static func optionalNonnegativeNumber(_ value: JSONValue?) -> Double?? {
        guard let value else { return .some(nil) }
        guard let number = value.numberValue(coercingStrings: false, finiteOnly: true), number >= 0 else { return nil }
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
