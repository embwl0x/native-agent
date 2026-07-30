import Foundation
import NativeAgentCore
import PersistenceCore

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

    private static let permittedStages: Set<String> = [
        "actorAdmission",
        "bootstrap",
        "substrate",
        "organism",
        "pursuit",
    ]

    private let lock = NSLock()
    private let startedNs = DispatchTime.now().uptimeNanoseconds
    private var stagesMilliseconds: [String: Int64] = [:]
    private var cancellationObserved = false
    private var completed = false

    public init() {}

    public func recordAdmission() {
        recordElapsed("actorAdmission", since: startedNs)
    }

    public func recordElapsed(_ stage: String, since startNs: UInt64) {
        guard Self.permittedStages.contains(stage) else { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsed = nowNs >= startNs ? Int64((nowNs - startNs) / 1_000_000) : 0
        lock.lock()
        stagesMilliseconds[stage] = max(0, elapsed)
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
        flags: [String: Bool] = [:]
    ) {
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
        TurnTraceBus.fireFromContext(
            kind: milestone.rawValue,
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload)
        )
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

    mutating func record(_ name: String, since startNs: UInt64) {
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        timings.append(Timing(name: name, elapsedMs: elapsed))
    }

    mutating func setTiming(_ name: String, milliseconds: Int64) {
        timings.removeAll { $0.name == name }
        timings.append(Timing(name: name, elapsedMs: max(0, milliseconds)))
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
        name: String,
        elapsedMs: Int64,
        surface: String,
        counts: [String: Int64] = [:],
        flags: [String: Bool] = [:]
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
                "stage": .string(name),
                "elapsedMs": .int(max(0, elapsedMs)),
                "counts": .object(countObject),
                "flags": .object(flagObject),
            ])
        )
    }
}
