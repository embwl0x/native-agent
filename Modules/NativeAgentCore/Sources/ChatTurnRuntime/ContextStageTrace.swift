import Foundation
import Synchronization
import NativeAgentCore
import PersistenceCore
import TurnTrace

// Blueprint: | `ContextStageTrace.swift` | `ContextStageTrace`; Payload-free bounded context telemetry |

/// Keep summary stage names closed so producers cannot invent indistinguishable trace kinds.
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
    case factsClockNotes = "context.facts.clock_notes"
    case factsContacts = "context.facts.contacts"
    case factsGlance = "context.facts.glance"
    case factsPlace = "context.facts.place"
    case factsElsewhereRead = "context.facts.elsewhere_read"
    case factsJoin = "context.facts.join"
    case factsElsewhere = "context.facts.elsewhere"
    case factsArrivals = "context.facts.arrivals"
    case factsRuntime = "context.facts.runtime"
    case contextFlowAttentionActorAdmission = "contextFlow.attention.actorAdmission"
    case promptRead = "history.prompt_read"
    case recallQuery = "history.recall_query"
    case contextBase = "context.base"
    case prepare = "history.prepare"
    case render = "history.render"
    case checkpoint = "turn.checkpoint"
    case historyContext = "turn.history_context"
    case cognitionJoin = "turn.cognition_join"
    case cognitiveAppend = "turn.cognitive_append"
    case turnPart = "turn.part_open"
    case contextSnapshot = "turn.context_snapshot"
    case toolCodec = "turn.tool_codec"
    case prefixSeed = "turn.prefix_seed"
    case sentContextPersist = "turn.sent_context_persist"
    case prefixTelemetry = "turn.prefix_telemetry"
    case dispatchRemainder = "turn.dispatch_remainder"
}

/// Keep the out-of-band stage vocabulary closed so unrelated producers cannot impersonate memory promotion.
enum ContextStageEmissionName: String, CaseIterable, Sendable {
    case memoryPromotion = "memory.promotion"
}

/// The engine binds one turn-local collector so attention timings stay in the existing payload-free summary, without another writer.
public final class CognitiveAttentionTraceRecorder: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let admissionMilliseconds: Int64?
        public let cancellationObserved: Bool
        public let completed: Bool
        public let totalMilliseconds: Int64
    }

    private let startedNs = DispatchTime.now().uptimeNanoseconds
    private let state = Mutex<(admissionMilliseconds: Int64?, cancellationObserved: Bool, completed: Bool)>((nil, false, false))

    public init() {}

    public func recordAdmission() {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsed = nowNs >= startedNs ? Int64((nowNs - startedNs) / 1_000_000) : 0
        state.withLock { $0.admissionMilliseconds = max(0, elapsed) }
    }

    public func markCancellationObserved() {
        state.withLock { $0.cancellationObserved = true }
    }

    public func markCompleted() {
        state.withLock { $0.completed = true }
    }

    public func snapshot() -> Snapshot {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let total = nowNs >= startedNs ? Int64((nowNs - startedNs) / 1_000_000) : 0
        return state.withLock {
            Snapshot(admissionMilliseconds: $0.admissionMilliseconds, cancellationObserved: $0.cancellationObserved,
                     completed: $0.completed, totalMilliseconds: max(0, total))
        }
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

/// Only the owning surface or provider can name its observation boundary; trace only timings, counts and bounded identifiers.
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
        on bus: TurnTraceBus? = nil,
        turn: Turn?
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
            payload: .object(payload),
            turn: turn
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
    private let turn: Turn?
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
    private var injectedMemoryIDs: [String]?

    init(turn: Turn?) {
        self.turn = turn
        self.startedNs = DispatchTime.now().uptimeNanoseconds
    }

    mutating func measure<T>(
        _ name: ContextStageName,
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

    private mutating func record(_ name: String, since startNs: UInt64) {
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        timings.append(Timing(name: name, elapsedMs: elapsed))
    }

    /// Positive stage times round up to whole milliseconds; zero means no measured work, and counts retain raw microseconds.
    mutating func setMicroseconds(_ name: ContextStageName, microseconds: Int64) {
        let bounded = max(0, microseconds)
        setTiming(name, milliseconds: bounded == 0 ? 0 : (bounded + 999) / 1_000)
        counts[name.rawValue + "Micros"] = bounded
    }

    /// Preserve microseconds so sub-millisecond stages remain measurable on the same clock.
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

    /// Carry delivered memory IDs, including an empty set, so traces can identify which memories actually reach turns.
    mutating func setInjectedMemoryIDs(_ ids: [String]) {
        injectedMemoryIDs = ids
        counts["memory.recallHits"] = Int64(ids.count)
    }

    @discardableResult
    func emit(kind: String, surface: String) -> Int64 {
        var stageObject: [String: JSONValue] = [:]
        for timing in timings {
            stageObject[timing.name] = .int(timing.elapsedMs)
        }
        let totalMs = Int64((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
        var payload: [String: JSONValue] = [
            "totalMs": .int(totalMs),
            "preparationMs": .int(totalMs),
            "stageMs": .object(stageObject),
            "counts": .object(counts.mapValues(JSONValue.int)),
            "flags": .object(flags.mapValues(JSONValue.bool)),
            "labels": .object(labels.mapValues(JSONValue.string)),
            "stageCount": .int(Int64(timings.count)),
        ]
        if let injectedMemoryIDs {
            payload["injectedMemoryIds"] = .array(injectedMemoryIDs.map(JSONValue.string))
        }
        if let memoryRecallOutcome {
            // memory.recallHits counts direct ∪ packet hits reaching the turn; memory.recallHits.direct counts only direct reads.
            payload["memoryRecall"] = memoryRecallOutcome.payload(
                injectedHitCount: Int(counts["memory.recallHits"] ?? 0)
            )
        }
        TurnTraceBus.fireFromContext(
            kind: kind,
            surface: surface,
            payload: .object(payload),
            turn: turn
        )
        return totalMs
    }

    static func emitStage(
        name: ContextStageEmissionName,
        elapsedMs: Int64,
        surface: String,
        counts: [String: Int64] = [:],
        flags: [String: Bool] = [:],
        labels: [String: String] = [:],
        turn: Turn?
    ) {
        TurnTraceBus.fireFromContext(
            kind: "context.stage",
            surface: surface,
            payload: .object([
                "schema": .string("context.stage.v1"),
                "stage": .string(name.rawValue),
                "elapsedMs": .int(max(0, elapsedMs)),
                "counts": .object(counts.mapValues { .int(max(0, $0)) }),
                "flags": .object(flags.mapValues(JSONValue.bool)),
                "labels": .object(labels.mapValues(JSONValue.string)),
            ]),
            turn: turn
        )
    }
}
