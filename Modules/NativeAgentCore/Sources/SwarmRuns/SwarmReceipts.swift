import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import TurnTrace
import ToolExecution
import Privacy
import ProviderRouting
// Blueprint: | `SwarmReceipts.swift` | Swarm result values and JSON receipts, persistence errors, wire timestamps, worker plan/progress JSON and `SwarmLiveBoard`; live progress delegates storage and recovery to `SwiftNativeSwarmRunsReader` |

/// Settled work with unconfirmed receipt durability; retain the cause for diagnostics without exposing its paths/prose to the parent.
public struct AgentSwarmReceiptPersistenceError: Error, LocalizedError, Sendable {
    public let runID: String
    public let runStatus: String
    public let summary: AgentSwarmSummary
    public let underlyingError: Error

    public var errorDescription: String? {
        let cause: String
        let nsError = underlyingError as NSError
        if underlyingError is PersistenceCoreError {
            cause = "receipt_store_io_failure"
        } else if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            cause = "filesystem_error_\(nsError.code)"
        } else {
            cause = "persistence_error"
        }
        return "Swarm \(runID) workers settled: execution status \(runStatus), \(summary.completed) completed, \(summary.failed) failed, \(summary.cancelled) cancelled. Receipt persistence is unconfirmed (\(cause)). Inspect app agent.jobs(agent='swarm', run_id='\(runID)') and reconcile attempted effects; a missing receipt does not prove work never ran. Do not rerun workers merely to recover a receipt."
    }
}

public struct AgentSwarmSummary: Sendable, Equatable {
    public var completed: Int
    public var failed: Int
    public var cancelled: Int = 0

    public var json: JSONValue {
        .object([
            "completed": .int(Int64(completed)),
            "failed": .int(Int64(failed)),
            "cancelled": .int(Int64(cancelled)),
        ])
    }
}

public struct AgentSwarmSynthesis: Sendable, Equatable {
    public var model: String
    public var status: String
    public var output: String
    public var outputTruncated: Bool
    public var error: String?
    public var durationSeconds: Double

    public var json: JSONValue {
        var obj: [String: JSONValue] = [
            "model": .string(model),
            "status": .string(status),
            "output": .string(output),
            "outputTruncated": .bool(outputTruncated),
            "durationSeconds": .double(durationSeconds),
        ]
        if let error { obj["error"] = .string(error) }
        return .object(obj)
    }
}

public struct AgentSwarmWorkerResult: Sendable, Equatable {
    public var id: String
    public var index: Int
    public var name: String
    public var role: String
    public var model: String
    public var requestedModel: String
    public var reasoningEffort: String
    public var access: String
    public var status: String
    public var output: String
    public var outputTruncated: Bool
    public var error: String?
    public var durationSeconds: Double
    public var findingsCap: Int?
    public var contextSlice: String?

    public var json: JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "index": .int(Int64(index)),
            "name": .string(name),
            "role": .string(role),
            "model": .string(model),
            "requestedModel": .string(requestedModel),
            "reasoningEffort": .string(reasoningEffort),
            "access": .string(access),
            "status": .string(status),
            "output": .string(output),
            "outputTruncated": .bool(outputTruncated),
            "durationSeconds": .double(durationSeconds),
        ]
        if let error { obj["error"] = .string(error) }
        if let findingsCap { obj["findingsCap"] = .int(Int64(findingsCap)) }
        if let contextSlice { obj["contextSlice"] = .string(contextSlice) }
        return .object(obj)
    }
}

public struct AgentSwarmRunResult: Sendable, Equatable {
    public var id: String
    public var status: String
    public var runtime: String
    public var createdAt: String
    public var completedAt: String
    public var elapsedMs: Int
    public var objective: String
    public var mode: String
    public var requestedBy: String
    public var agentCount: Int
    public var maxAgents: Int
    public var maxParallel: Int
    public var readOnly: Bool
    public var providerMode: String
    public var surface: String
    public var model: String
    public var models: [String]
    public var reasoningEffort: String
    public var access: String
    public var timeoutSeconds: Int
    public var maxOutputChars: Int
    public var summary: AgentSwarmSummary
    public var workers: [AgentSwarmWorkerResult]
    public var synthesis: AgentSwarmSynthesis?
    public var runsPath: String

    public var json: JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "status": .string(status),
            "runtime": .string(runtime),
            "createdAt": .string(createdAt),
            "completedAt": .string(completedAt),
            "elapsedMs": .int(Int64(elapsedMs)),
            "objective": .string(objective),
            "mode": .string(mode),
            "requestedBy": .string(requestedBy),
            "agentCount": .int(Int64(agentCount)),
            "maxAgents": .int(Int64(maxAgents)),
            "maxParallel": .int(Int64(maxParallel)),
            "readOnly": .bool(readOnly),
            "providerMode": .string(providerMode),
            "surface": .string(surface),
            "model": .string(model),
            "models": .array(models.map { .string($0) }),
            "reasoningEffort": .string(reasoningEffort),
            "access": .string(access),
            "timeoutSeconds": .int(Int64(timeoutSeconds)),
            "maxOutputChars": .int(Int64(maxOutputChars)),
            "summary": summary.json,
            "workers": .array(workers.map(\.json)),
            "runsPath": .string(runsPath),
        ]
        if let synthesis { obj["synthesis"] = synthesis.json }
        return .object(obj)
    }
}

public enum AgentSwarmClock {
    public static func nowISO(_ date: Date = Date()) -> String {
        NativeTimestampFormat.sixDigitUTCOffset(date)
    }
}

/// Execution progress; the shared runs owner stores it for display and recovery.
struct SwarmLiveBoard: Sendable {
    let store: SwiftNativeSwarmRunsReader
    let id: String
    let objective: String
    let createdAt: String
    let synthesize: Bool
    let pending: [JSONValue]

    func put(settled: [Int: JSONValue]) async throws {
        let workers = pending.enumerated().map { settled[$0.offset] ?? $0.element }
        try store.updateLive(id: id, record: .object([
            "id": .string(id), "status": .string("running"), "objective": .string(objective),
            "createdAt": .string(createdAt), "pid": .int(Int64(getpid())),
            "pidStartedAt": { if case .started(let at) = SwiftNativeSwarmRunsReader.processStart(getpid()) { .double(at) } else { .null } }(),
            "workers": .array(workers),
            "synthesize": .bool(synthesize),
        ]))
    }

    // Synchronous storage also completes when its caller has been cancelled.
    func remove() async throws { try store.updateLive(id: id, record: nil) }
}

extension AgentSwarmWorkerSpec {
    func pendingJSON(index: Int) -> JSONValue {
        .object(["index": .int(Int64(index + 1)), "name": .string(name), "role": .string(role), "status": .string("working")])
    }

    func planJSON(index: Int) -> JSONValue {
        var obj: [String: JSONValue] = [
            "index": .int(Int64(index + 1)),
            "name": .string(name),
            "role": .string(role),
            "model": .string(model),
            "requestedModel": .string(model),
            "reasoningEffort": .string(reasoningEffort),
            "readOnly": .bool(access == "read_only"),
            "access": .string(access),
        ]
        if !prompt.isEmpty { obj["prompt"] = .string(prompt) }
        if let findingsCap { obj["findingsCap"] = .int(Int64(findingsCap)) }
        if let contextSlice { obj["contextSlice"] = .string(contextSlice) }
        return .object(obj)
    }
}
