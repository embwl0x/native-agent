import TurnTrace
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

    /// Seed first-output samples once from retained traces, then join live receipts under the same request-to-output definition; never write another
    /// ledger.
    private struct FirstOutputKey: Hashable { let provider, model: String; let streamKind: String? }
    private var firstOutputs: [FirstOutputKey: [(seconds: Double, bytes: Int?)]] = [:]
    /// Unreadable retained rows stay a named evidence gap in Diagnostics.
    private var unreadableTraceRows = 0
    /// Guard cuts are failures beside first outputs, never timing samples.
    private var noReplyCuts: [String: Int] = [:]

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

    // MARK: First outputs

    /// Join launch traces through the cutoff ahead of live samples so neither source is double-counted.
    public func readFirstOutputs(
        dataRoot: URL, before cutoff: Date
    ) async throws {
        let read = try await TurnTraceRecentReader(dataRootOverride: dataRoot)
            .traceEvidence(now: cutoff, since: .distantPast, kinds: ["llm.call", "provider.noReply"])
        unreadableTraceRows = read.turns.unreadable
        // Retained record order, not current wall time, owns the sample window.
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
                let bytes: Int? = if case .int(let bytes)? = payload["requestBytes"] { Int(exactly: bytes) } else { nil }
                joinFirstOutput(firstOutputKey(provider, model, kind), seconds: Double(ms) / 1000, bytes: bytes)
            }
        }
        for (key, samples) in live { samples.forEach { joinFirstOutput(key, seconds: $0.seconds, bytes: $0.bytes) } }
    }

    /// First-output admission uses the actual encoded request size.
    public func firstOutputDeadline(provider: String, model: String, streamKind: String?, requestBytes: Int) -> FirstOutputDeadline {
        let samples = firstOutputs[firstOutputKey(provider, model, streamKind)] ?? []
        let perByte = samples.compactMap { sample in sample.bytes.flatMap { $0 > 0 ? sample.seconds / Double($0) : nil } }.max()
        return FirstOutputDeadline(calls: samples.count, slowest: samples.map(\.seconds).max(),
                                   slowestPerByte: perByte, requestBytes: requestBytes)
    }

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

    /// Trace retention bounds first-output history; shared trace rows may leave fewer samples after relaunch.
    private func joinFirstOutput(_ key: FirstOutputKey, seconds: Double, bytes: Int?) {
        guard seconds >= 0, UInt64(exactly: (seconds * 1_000_000_000).rounded(.up)) != nil,
              bytes.map({ $0 >= 0 }) ?? true else {
            unreadableTraceRows += 1
            return
        }
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
