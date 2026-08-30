import Foundation
import NativeAgentCore
import PersistenceCore

/// Closed production vocabulary for stages emitted by bare turn-context
/// assembly. The replay speed budget imports this type rather than restating
/// stage strings, while the engine emits these cases directly.
enum ContextStageName: String, CaseIterable, Sendable {
    case contextFlowAttention = "contextFlow.attention"
    case contextFlowPrepare = "contextFlow.prepare"
    case providerPreferences = "provider.preferences"
    case personaCompile = "persona.compile"
    case remPinsRead = "rem_pins.read"
    case memoryRecall = "memory.recall"
    case toolsNames = "tools.names"
    case toolsSchemas = "tools.schemas"
    case promptRender = "prompt.render"
    case contextClockRuntime = "context.clock_runtime"
    case contextFlowAttentionActorAdmission = "contextFlow.attention.actorAdmission"
    case contextFlowAttentionBootstrap = "contextFlow.attention.bootstrap"
    case contextFlowAttentionSubstrate = "contextFlow.attention.substrate"
    case contextFlowAttentionOrganism = "contextFlow.attention.organism"
    case contextFlowAttentionPursuit = "contextFlow.attention.pursuit"
}

/// Closed vocabulary for the session-history wrapper. The clock has a typed
/// entry in both wrapper registries because each receipt has its own budget.
enum ContextHistoryStageName: String, CaseIterable, Sendable {
    case promptRead = "history.prompt_read"
    case middleSample = "history.middle_sample"
    case recallQuery = "history.recall_query"
    case contextBase = "context.base"
    case digest = "history.digest"
    case render = "history.render"
    case contextClockRuntime = "context.clock_runtime"
}

/// Closed vocabulary for the out-of-band `context.stage` feed. This feed is
/// intentionally separate from the per-turn context summary, so an arbitrary
/// string here would make a second producer indistinguishable from the memory
/// promotion lane that currently owns it.
enum ContextStageEmissionName: String, CaseIterable, Sendable {
    case memoryPromotion = "memory.promotion"
}

/// The only attention sub-stages cognition may add to a context trace.
enum CognitiveAttentionStage: String, CaseIterable, Sendable {
    case actorAdmission
    case bootstrap
    case substrate
    case organism
    case pursuit

    var contextStage: ContextStageName {
        switch self {
        case .actorAdmission: .contextFlowAttentionActorAdmission
        case .bootstrap: .contextFlowAttentionBootstrap
        case .substrate: .contextFlowAttentionSubstrate
        case .organism: .contextFlowAttentionOrganism
        case .pursuit: .contextFlowAttentionPursuit
        }
    }
}

/// Turn-local, payload-free timing collector for the cognition attention read.
///
/// The turn engine owns the collector and installs it with a task-local value;
/// app-owned cognition may add only the fixed stage names below. This keeps the
/// measurements inside the existing `context.summary` receipt instead of
/// creating another trace writer or persistent telemetry owner.
public final class CognitiveAttentionTraceRecorder: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let stagesMilliseconds: [String: Int64]
        public let cancellationObserved: Bool
        public let completed: Bool
        public let totalMilliseconds: Int64
    }

    private static let permittedStages = Set(CognitiveAttentionStage.allCases)

    private let lock = NSLock()
    private let startedNs = DispatchTime.now().uptimeNanoseconds
    private var stagesMilliseconds: [String: Int64] = [:]
    private var cancellationObserved = false
    private var completed = false

    public init() {}

    public func recordAdmission() {
        recordElapsed(CognitiveAttentionStage.actorAdmission.rawValue, since: startedNs)
    }

    public func recordElapsed(_ stage: String, since startNs: UInt64) {
        guard let stage = CognitiveAttentionStage(rawValue: stage),
              Self.permittedStages.contains(stage)
        else { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsed = nowNs >= startNs ? Int64((nowNs - startNs) / 1_000_000) : 0
        lock.lock()
        stagesMilliseconds[stage.rawValue] = max(0, elapsed)
        lock.unlock()
    }

    public func markCancellationObserved() {
        lock.lock()
        cancellationObserved = true
        lock.unlock()
    }

    public func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let total = nowNs >= startedNs ? Int64((nowNs - startedNs) / 1_000_000) : 0
        lock.lock()
        let snapshot = Snapshot(
            stagesMilliseconds: stagesMilliseconds,
            cancellationObserved: cancellationObserved,
            completed: completed,
            totalMilliseconds: max(0, total)
        )
        lock.unlock()
        return snapshot
    }
}

public enum CognitiveAttentionTraceContext {
    @TaskLocal public static var recorder: CognitiveAttentionTraceRecorder?
}

public enum TurnLifecycleMilestone: String, CaseIterable, Sendable {
    case turnAccepted = "turn.accepted"
    case contextReady = "context.ready"
    case providerRequestStarted = "provider.requestStarted"
    case providerFirstDelta = "provider.firstDelta"
    case surfaceOutputEnqueued = "surface.outputEnqueued"
    case surfaceFirstRender = "surface.firstRender"
}

/// Fire-and-forget FC0 lifecycle telemetry. Callers supply the observation
/// boundary because only the owning provider/surface can name these moments
/// honestly. Payloads are timings, counts, and bounded identifiers only.
public enum TurnLifecycleTelemetry {
    public static func emit(
        _ milestone: TurnLifecycleMilestone,
        surface: String,
        sessionId: String? = nil,
        observedBy: String,
        since startNs: UInt64? = nil,
        counts: [String: Int64] = [:],
        flags: [String: Bool] = [:],
        turnId: String? = TurnTraceContext.turnId,
        on bus: TurnTraceBus? = nil
    ) {
        guard let turnId else { return }
        var payload: [String: JSONValue] = [
            "schema": .string("turn.lifecycle.v1"),
            "milestone": .string(milestone.rawValue),
            "observedBy": .string(observedBy),
        ]
        if let startNs {
            payload["elapsedMs"] = .int(elapsedMs(since: startNs))
        }
        if !counts.isEmpty {
            payload["counts"] = .object(counts.mapValues { .int(max(0, $0)) })
        }
        if !flags.isEmpty {
            payload["flags"] = .object(flags.mapValues(JSONValue.bool))
        }
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId,
            kind: milestone.rawValue,
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload)
        ), on: bus ?? TurnTraceContext.bus ?? .shared)
    }

    private static func elapsedMs(since startNs: UInt64) -> Int64 {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard nowNs >= startNs else { return 0 }
        return Int64((nowNs - startNs) / 1_000_000)
    }
}

actor TurnLifecycleFirstOutputGate {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

enum MemoryRecallTraceOutcome: Sendable, Equatable {
    case notConfigured
    case contextFlow(hitCount: Int)
    case succeeded(hitCount: Int)
    case failed(errorType: String)
    case unknown

    func payload(injectedHitCount: Int) -> JSONValue {
        var object: [String: JSONValue] = [
            "injectedHitCount": .int(Int64(max(0, injectedHitCount))),
        ]
        switch self {
        case .notConfigured:
            object["outcome"] = .string("notConfigured")
        case .contextFlow(let hitCount):
            object["outcome"] = .string("contextFlow")
            object["retrievedHitCount"] = .int(Int64(max(0, hitCount)))
        case .succeeded(let hitCount):
            let boundedHitCount = max(0, hitCount)
            object["outcome"] = .string(boundedHitCount == 0 ? "zeroHits" : "hits")
            object["retrievedHitCount"] = .int(Int64(boundedHitCount))
        case .failed(let errorType):
            object["outcome"] = .string("error")
            object["errorType"] = .string(errorType)
        case .unknown:
            object["outcome"] = .string("unknown")
        }
        return .object(object)
    }
}

struct ContextStageTrace: Sendable {
    struct Timing: Sendable {
        let name: String
        let elapsedMs: Int64
    }

    private let startedNs: UInt64
    private var timings: [Timing] = []
    private var counts: [String: Int64] = [:]
    private var flags: [String: Bool] = [:]
    private var labels: [String: String] = [:]
    private var memoryRecallOutcome: MemoryRecallTraceOutcome?

    init() {
        self.startedNs = DispatchTime.now().uptimeNanoseconds
    }

    mutating func measure<T>(
        _ name: ContextStageName,
        _ work: () async throws -> T
    ) async rethrows -> T {
        return try await measure(name.rawValue, work)
    }

    mutating func measure<T>(
        _ name: ContextHistoryStageName,
        _ work: () async throws -> T
    ) async rethrows -> T {
        return try await measure(name.rawValue, work)
    }

    private mutating func measure<T>(
        _ name: String,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let value = try await work()
            record(name, since: start)
            return value
        } catch {
            record(name, since: start)
            throw error
        }
    }

    mutating func record(_ name: ContextStageName, since startNs: UInt64) {
        record(name.rawValue, since: startNs)
    }

    mutating func record(_ name: ContextHistoryStageName, since startNs: UInt64) {
        record(name.rawValue, since: startNs)
    }

    private mutating func record(_ name: String, since startNs: UInt64) {
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        timings.append(Timing(name: name, elapsedMs: elapsed))
    }

    /// Microsecond-resolution stage clock (A7, 2026-08-28).
    ///
    /// `stageMs` is a whole-millisecond lane, so a stage whose real work is
    /// sub-millisecond truncates to 0 and reads as DARK to the instrument even
    /// though it ran — which is exactly how `persona.compile` and
    /// `memory.recall` went dark once ContextFlow moved their work off the
    /// per-turn bracket. Any positive sample therefore rounds UP to 1ms (0 keeps
    /// meaning "no work measured", never "too fast to see"), and the raw
    /// microseconds ride along as a count so the lane keeps real resolution.
    mutating func setMicroseconds(_ name: ContextStageName, microseconds: Int64) {
        let bounded = max(0, microseconds)
        setTiming(name, milliseconds: bounded == 0 ? 0 : (bounded + 999) / 1_000)
        counts[name.rawValue + "Micros"] = bounded
    }

    /// Same clock as `record(_:since:)` but preserved at microsecond
    /// resolution — for stages whose per-turn work is sub-millisecond.
    mutating func recordMicroseconds(_ name: ContextStageName, since startNs: UInt64) {
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000)
        setMicroseconds(name, microseconds: elapsed)
    }

    mutating func setTiming(_ name: ContextStageName, milliseconds: Int64) {
        timings.removeAll { $0.name == name.rawValue }
        timings.append(Timing(name: name.rawValue, elapsedMs: max(0, milliseconds)))
    }

    mutating func setCount(_ key: String, _ value: Int) {
        counts[key] = Int64(max(0, value))
    }

    mutating func setCount(_ key: String, _ value: Int64) {
        counts[key] = max(0, value)
    }

    mutating func setFlag(_ key: String, _ value: Bool) {
        flags[key] = value
    }

    mutating func setLabel(_ key: String, _ value: String) {
        labels[key] = String(value.prefix(500))
    }

    mutating func setMemoryRecallOutcome(_ outcome: MemoryRecallTraceOutcome) {
        memoryRecallOutcome = outcome
    }

    func emit(kind: String, surface: String) {
        var stageObject: [String: JSONValue] = [:]
        for timing in timings {
            stageObject[timing.name] = .int(timing.elapsedMs)
        }
        var countObject: [String: JSONValue] = [:]
        for (key, value) in counts {
            countObject[key] = .int(value)
        }
        var flagObject: [String: JSONValue] = [:]
        for (key, value) in flags {
            flagObject[key] = .bool(value)
        }
        var labelObject: [String: JSONValue] = [:]
        for (key, value) in labels {
            labelObject[key] = .string(value)
        }
        let totalMs = Int64((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
        var payload: [String: JSONValue] = [
            "totalMs": .int(totalMs),
            "stageMs": .object(stageObject),
            "counts": .object(countObject),
            "flags": .object(flagObject),
            "labels": .object(labelObject),
            "stageCount": .int(Int64(timings.count)),
        ]
        if let memoryRecallOutcome {
            // `memory.recallHits` is the RESOLVED lane (legacy ∪ packet
            // provenance) since 2026-08-21; `memory.recallHits.legacy` is the
            // legacy-only count. Injected means what reached the turn.
            payload["memoryRecall"] = memoryRecallOutcome.payload(
                injectedHitCount: Int(counts["memory.recallHits"] ?? 0)
            )
        }
        TurnTraceBus.fireFromContext(
            kind: kind,
            surface: surface,
            payload: .object(payload)
        )
    }

    static func emitStage(
        name: ContextStageEmissionName,
        elapsedMs: Int64,
        surface: String,
        counts: [String: Int64] = [:],
        flags: [String: Bool] = [:],
        labels: [String: String] = [:]
    ) {
        var countObject: [String: JSONValue] = [:]
        for (key, value) in counts {
            countObject[key] = .int(max(0, value))
        }
        var flagObject: [String: JSONValue] = [:]
        for (key, value) in flags {
            flagObject[key] = .bool(value)
        }
        TurnTraceBus.fireFromContext(
            kind: "context.stage",
            surface: surface,
            payload: .object([
                "schema": .string("context.stage.v1"),
                "stage": .string(name.rawValue),
                "elapsedMs": .int(max(0, elapsedMs)),
                "counts": .object(countObject),
                "flags": .object(flagObject),
                "labels": .object(labels.mapValues(JSONValue.string)),
            ])
        )
    }
}
