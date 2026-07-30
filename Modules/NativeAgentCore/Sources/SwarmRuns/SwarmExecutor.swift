import Foundation
import NativeAgentCore
import PersistenceCore

public enum AgentSwarmError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case policyDenied(String)
    case timeout(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        case .policyDenied(let message):
            return message
        case .timeout(let seconds):
            return "swarm worker timed out after \(seconds)s"
        }
    }
}

public struct AgentSwarmPolicy: Sendable, Equatable {
    public static let hardMaxAgents = 20

    public var enabled: Bool
    public var maxAgents: Int
    public var maxParallel: Int
    public var defaultModel: String
    public var defaultReasoningEffort: String
    public var storeReceipts: Bool

    public init(
        enabled: Bool = true,
        maxAgents: Int = Self.hardMaxAgents,
        maxParallel: Int = 6,
        defaultModel: String = nativeAgentPrimaryModel,
        defaultReasoningEffort: String = "medium",
        storeReceipts: Bool = true
    ) {
        self.enabled = enabled
        self.maxAgents = max(1, min(maxAgents, Self.hardMaxAgents))
        self.maxParallel = max(1, min(maxParallel, Self.hardMaxAgents))
        self.defaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nativeAgentPrimaryModel
            : defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultReasoningEffort = defaultReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "medium"
            : defaultReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storeReceipts = storeReceipts
    }

    public static func fromTrustPolicy(_ policy: JSONValue) -> AgentSwarmPolicy {
        guard case .object(let root) = policy,
              case .object(let swarm)? = root["swarmPolicy"] else {
            return AgentSwarmPolicy()
        }
        return AgentSwarmPolicy(
            enabled: bool(swarm["enabled"], defaultValue: true),
            maxAgents: int(swarm["maxAgents"], defaultValue: Self.hardMaxAgents),
            maxParallel: int(swarm["maxParallel"], defaultValue: 6),
            defaultModel: string(swarm["defaultModel"], defaultValue: nativeAgentPrimaryModel),
            defaultReasoningEffort: string(swarm["defaultReasoningEffort"], defaultValue: "medium"),
            storeReceipts: bool(swarm["storeReceipts"], defaultValue: true)
        )
    }

    private static func string(_ value: JSONValue?, defaultValue: String) -> String {
        guard case .string(let raw)? = value else { return defaultValue }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : trimmed
    }

    private static func int(_ value: JSONValue?, defaultValue: Int) -> Int {
        switch value {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        default: return defaultValue
        }
    }

    private static func bool(_ value: JSONValue?, defaultValue: Bool) -> Bool {
        switch value {
        case .bool(let b): return b
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "y", "on": return true
            case "false", "0", "no", "n", "off": return false
            default: return defaultValue
            }
        default:
            return defaultValue
        }
    }
}

public struct AgentSwarmWorkerSpec: Sendable, Equatable {
    public var name: String
    public var role: String
    public var prompt: String
    public var model: String
    public var reasoningEffort: String
    public var access: String
    public var contextSlice: String?
    public var findingsCap: Int?

    public init(
        name: String,
        role: String,
        prompt: String = "",
        model: String,
        reasoningEffort: String,
        access: String = "read_only",
        contextSlice: String? = nil,
        findingsCap: Int? = nil
    ) {
        self.name = name
        self.role = role
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.access = access
        self.contextSlice = contextSlice
        self.findingsCap = findingsCap
    }
}

public struct AgentSwarmRunRequest: Sendable, Equatable {
    public var objective: String
    public var mode: String
    public var workers: [AgentSwarmWorkerSpec]
    public var maxParallel: Int
    public var synthesize: Bool
    public var synthesisModel: String
    public var timeoutSeconds: Int
    public var dryRun: Bool
    public var maxOutputChars: Int
    public var readOnly: Bool
    public var requestedModel: String
    public var requestedBy: String
    /// Verified parent chat identity used only for tool authorization. Swarm
    /// workers remain ephemeral and never append to that chat transcript.
    public var originSessionId: String?
    /// U6 digest-budget seam: a soft token budget for the SYNTHESIS output (the
    /// "digest" relayed back to the orchestrator). `nil` = unchanged (no
    /// truncation beyond maxOutputChars). When set, the synthesis is truncated
    /// to ~`digestBudgetTokens` tokens with an explicit truncation NOTICE
    /// appended so the reader knows the digest is clipped. Per the U6 research
    /// note: structured small digests beat raw transcript relay for orchestrator
    /// integration.
    public var digestBudgetTokens: Int?

    public static func parse(
        input: [String: JSONValue],
        policy: AgentSwarmPolicy
    ) throws -> AgentSwarmRunRequest {
        guard policy.enabled else {
            throw AgentSwarmError.policyDenied("agent_swarm is disabled by trust/policy.json swarmPolicy.enabled")
        }
        let objective = firstString(input, keys: ["objective", "query", "prompt", "task"])
        guard let objective, !objective.isEmpty else {
            throw AgentSwarmError.invalidRequest("agent_swarm requires objective, query, prompt, or task")
        }

        let requestedModel = firstString(input, keys: ["model", "defaultModel", "requestedModel"])
            ?? policy.defaultModel
        let requestedEffort = firstString(input, keys: ["reasoningEffort", "reasoning_effort"])
            ?? policy.defaultReasoningEffort
        let defaultAccess = workerAccess(
            firstString(input, keys: ["access", "workerAccess", "worker_access"]),
            legacyReadOnly: firstPresent(input, keys: ["readOnly", "read_only"])
        )
        let models = stringArray(input["models"])
        let explicitWorkers = parseWorkerArray(
            input,
            defaultModel: requestedModel,
            defaultEffort: requestedEffort,
            defaultAccess: defaultAccess,
            models: models
        )
        let requestedCount = intValue(
            firstPresent(input, keys: ["agentCount", "agent_count", "count", "n", "numAgents", "num_agents"])
        )
        let maxAllowed = max(1, min(policy.maxAgents, AgentSwarmPolicy.hardMaxAgents))
        let workerCount: Int
        if !explicitWorkers.isEmpty {
            workerCount = explicitWorkers.count
        } else {
            workerCount = requestedCount ?? 4
        }
        guard workerCount >= 1 else {
            throw AgentSwarmError.invalidRequest("agent_swarm requires at least 1 worker")
        }
        guard workerCount <= maxAllowed else {
            throw AgentSwarmError.policyDenied("agent_swarm requested \(workerCount) workers; policy allows \(maxAllowed) (hard cap \(AgentSwarmPolicy.hardMaxAgents))")
        }

        let workers: [AgentSwarmWorkerSpec]
        if explicitWorkers.isEmpty {
            workers = (0..<workerCount).map { idx in
                let model = modelFor(index: idx, explicitModel: nil, defaultModel: requestedModel, models: models)
                return AgentSwarmWorkerSpec(
                    name: "worker-\(idx + 1)",
                    role: "independent analyst \(idx + 1)",
                    model: model,
                    reasoningEffort: requestedEffort,
                    access: defaultAccess
                )
            }
        } else {
            workers = explicitWorkers
        }

        let requestedParallel = intValue(firstPresent(input, keys: ["maxParallel", "max_parallel", "parallelism"]))
            ?? min(policy.maxParallel, workers.count)
        let maxParallel = max(1, min(requestedParallel, policy.maxParallel, workers.count, AgentSwarmPolicy.hardMaxAgents))
        let synthesize = boolValue(firstPresent(input, keys: ["synthesize", "synthesis"]), defaultValue: workers.count > 1)
        let synthesisModel = firstString(input, keys: ["synthesisModel", "synthesis_model"])
            ?? requestedModel
        let timeoutSeconds = max(
            15,
            min(intValue(firstPresent(input, keys: ["timeoutSeconds", "timeout_seconds", "timeout"])) ?? 240, 900)
        )
        let maxOutputChars = max(
            500,
            min(intValue(firstPresent(input, keys: ["maxOutputChars", "max_output_chars"])) ?? 4_000, 12_000)
        )
        // U6 digest budget — optional; nil = unchanged. A non-positive value is
        // treated as "no budget" (nil) so a 0 can't silently zero the digest.
        var digestBudgetTokens: Int? = intValue(firstPresent(input, keys: ["digestBudgetTokens", "digest_budget_tokens"]))
        if let b = digestBudgetTokens, b <= 0 { digestBudgetTokens = nil }

        return AgentSwarmRunRequest(
            objective: objective,
            mode: firstString(input, keys: ["mode", "preset", "presetName", "preset_name"]) ?? "parallel",
            workers: workers,
            maxParallel: maxParallel,
            synthesize: synthesize,
            synthesisModel: synthesisModel,
            timeoutSeconds: timeoutSeconds,
            dryRun: boolValue(firstPresent(input, keys: ["dryRun", "dry_run"]), defaultValue: false),
            maxOutputChars: maxOutputChars,
            readOnly: workers.allSatisfy { $0.access == "read_only" },
            requestedModel: requestedModel,
            requestedBy: firstString(input, keys: ["requestedBy", "requested_by", "surface"]) ?? "chat_tool",
            originSessionId: firstString(input, keys: ["__session_id", "session_id", "sessionId"]),
            digestBudgetTokens: digestBudgetTokens
        )
    }

    public func planJSON(createdAt: String = AgentSwarmClock.nowISO()) -> JSONValue {
        .object([
            "id": .string(UUID().uuidString),
            "status": .string("dry_run"),
            "runtime": .string("swift-native"),
            "createdAt": .string(createdAt),
            "mode": .string(mode),
            "objective": .string(objective),
            "agentCount": .int(Int64(workers.count)),
            "maxAgents": .int(Int64(AgentSwarmPolicy.hardMaxAgents)),
            "maxParallel": .int(Int64(maxParallel)),
            "readOnly": .bool(readOnly),
            "synthesize": .bool(synthesize),
            "model": .string(requestedModel),
            "synthesisModel": .string(synthesisModel),
            "reasoningEffort": .string(workers.first?.reasoningEffort ?? "medium"),
            "workers": .array(workers.enumerated().map { idx, worker in
                worker.planJSON(index: idx)
            }),
        ])
    }

    private static func parseWorkerArray(
        _ input: [String: JSONValue],
        defaultModel: String,
        defaultEffort: String,
        defaultAccess: String,
        models: [String]
    ) -> [AgentSwarmWorkerSpec] {
        let raw = firstPresent(input, keys: ["agents", "workers", "roles", "workerConfigs", "worker_configs"])
        guard case .array(let values)? = raw else { return [] }
        var out: [AgentSwarmWorkerSpec] = []
        for (idx, value) in values.enumerated() {
            let model = modelFor(index: idx, explicitModel: nil, defaultModel: defaultModel, models: models)
            switch value {
            case .string(let role):
                let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedRole.isEmpty else { continue }
                out.append(AgentSwarmWorkerSpec(
                    name: "worker-\(idx + 1)",
                    role: trimmedRole,
                    model: model,
                    reasoningEffort: defaultEffort,
                    access: defaultAccess
                ))
            case .object(let obj):
                let role = firstString(obj, keys: ["role", "name", "title"]) ?? "independent analyst \(idx + 1)"
                let explicitModel = firstString(obj, keys: ["model", "requestedModel", "requested_model"])
                let workerModel = modelFor(index: idx, explicitModel: explicitModel, defaultModel: defaultModel, models: models)
                let effort = firstString(obj, keys: ["reasoningEffort", "reasoning_effort"]) ?? defaultEffort
                let access = workerAccess(
                    firstString(obj, keys: ["access", "workerAccess", "worker_access"]),
                    legacyReadOnly: firstPresent(obj, keys: ["readOnly", "read_only"]),
                    fallback: defaultAccess
                )
                out.append(AgentSwarmWorkerSpec(
                    name: firstString(obj, keys: ["name", "id"]) ?? "worker-\(idx + 1)",
                    role: role,
                    prompt: firstString(obj, keys: ["prompt", "lensBrief", "lens_brief", "instructions"]) ?? "",
                    model: workerModel,
                    reasoningEffort: effort,
                    access: access,
                    contextSlice: firstString(obj, keys: ["contextSlice", "context_slice", "context"]),
                    findingsCap: intValue(firstPresent(obj, keys: ["findingsCap", "findings_cap"]))
                ))
            default:
                continue
            }
        }
        return out
    }

    private static func modelFor(index: Int, explicitModel: String?, defaultModel: String, models: [String]) -> String {
        if let explicit = explicitModel?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if !models.isEmpty {
            return models[index % models.count]
        }
        return defaultModel
    }

    private static func workerAccess(
        _ raw: String?,
        legacyReadOnly: JSONValue?,
        fallback: String = "read_only"
    ) -> String {
        if let raw {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "inherit", "auto", "tools", "tool_capable", "tool-capable", "workspace", "full":
                return "inherit"
            case "read_only", "readonly", "read-only", "reasoning":
                return "read_only"
            default:
                return fallback
            }
        }
        if legacyReadOnly != nil {
            return boolValue(legacyReadOnly, defaultValue: true) ? "read_only" : "inherit"
        }
        return fallback
    }

    static func firstPresent(_ input: [String: JSONValue], keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = input[key] { return value }
        }
        return nil
    }

    static func firstString(_ input: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            guard case .string(let raw)? = input[key] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let vals)? = value else { return [] }
        return vals.compactMap { val in
            guard case .string(let raw) = val else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    static func boolValue(_ value: JSONValue?, defaultValue: Bool) -> Bool {
        switch value {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let raw):
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "y", "on": return true
            case "false", "0", "no", "n", "off": return false
            default: return defaultValue
            }
        default:
            return defaultValue
        }
    }
}

public protocol AgentSwarmExecuting: Sendable {
    func runTool(input: [String: JSONValue], policy: AgentSwarmPolicy) async throws -> JSONValue
}

/// Optional bridge into NativeAgent's existing ephemeral tool turn. SwarmRuns
/// owns fan-out and receipts; ChatOrchestration owns tools, TrustCenter,
/// approvals, workspace resolution, and effect verification.
public protocol AgentSwarmWorkerRunning: Sendable {
    func runWorker(
        prompt: String,
        model: String,
        reasoningEffort: String,
        access: String,
        originSurface: String,
        originSessionId: String?
    ) async throws -> String
}

public struct SwiftNativeAgentSwarmExecutor: AgentSwarmExecuting {
    public let llm: any LLMClient
    public let runsPath: URL
    public let persistence: any PersistenceCoreProtocol
    public let workerRunner: (any AgentSwarmWorkerRunning)?
    public let now: @Sendable () -> Date
    /// Data root for the cross-surface RunLedger row. When nil, derived from
    /// a CANONICAL runsPath (<dataRoot>/swarms/runs.json) only — a
    /// noncanonical override (tests passing <tmp>/runs.json) records nothing
    /// rather than writing outside its tree (gpt-5.5 review MED, 2026-07-02).
    public let runLedgerDataRoot: URL?

    public init(
        llm: any LLMClient,
        runsPath: URL = SwiftNativeSwarmRunsReader.defaultPath(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        workerRunner: (any AgentSwarmWorkerRunning)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        runLedgerDataRoot: URL? = nil
    ) {
        self.llm = llm
        self.runsPath = runsPath
        self.persistence = persistence
        self.workerRunner = workerRunner
        self.now = now
        if let runLedgerDataRoot {
            self.runLedgerDataRoot = runLedgerDataRoot
        } else if runsPath.deletingLastPathComponent().lastPathComponent == "swarms" {
            self.runLedgerDataRoot = runsPath
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        } else {
            self.runLedgerDataRoot = nil
        }
    }

    public func runTool(input: [String: JSONValue], policy: AgentSwarmPolicy) async throws -> JSONValue {
        let request = try AgentSwarmRunRequest.parse(input: input, policy: policy)
        if request.dryRun {
            return request.planJSON(createdAt: AgentSwarmClock.nowISO(now()))
        }
        return try await run(request: request, policy: policy).json
    }

    public func run(request: AgentSwarmRunRequest, policy: AgentSwarmPolicy) async throws -> AgentSwarmRunResult {
        let runId = UUID().uuidString
        let startedDate = now()
        let createdAt = AgentSwarmClock.nowISO(startedDate)
        let startNs = DispatchTime.now().uptimeNanoseconds
        let workerResults = await executeWorkers(request: request, runId: runId)
        let synthesis = await synthesizeIfNeeded(request: request, workerResults: workerResults)
        let completedAt = AgentSwarmClock.nowISO(now())
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        let summary = AgentSwarmSummary(
            completed: workerResults.filter { $0.status == "completed" }.count,
            failed: workerResults.filter { $0.status != "completed" }.count
        )
        let result = AgentSwarmRunResult(
            id: runId,
            status: summary.completed > 0 ? "completed" : "failed",
            runtime: "swift-native",
            createdAt: createdAt,
            completedAt: completedAt,
            elapsedMs: elapsedMs,
            objective: request.objective,
            mode: request.mode,
            requestedBy: request.requestedBy,
            agentCount: request.workers.count,
            maxAgents: AgentSwarmPolicy.hardMaxAgents,
            maxParallel: request.maxParallel,
            readOnly: request.readOnly,
            providerMode: "surface_routed",
            surface: "swarms",
            model: request.requestedModel,
            models: Array(Set(request.workers.map(\.model))).sorted(),
            reasoningEffort: request.workers.first?.reasoningEffort ?? policy.defaultReasoningEffort,
            access: request.readOnly ? "read_only" : (
                request.workers.allSatisfy { $0.access == "inherit" } ? "inherit" : "mixed"
            ),
            timeoutSeconds: request.timeoutSeconds,
            maxOutputChars: request.maxOutputChars,
            summary: summary,
            workers: workerResults,
            synthesis: synthesis,
            runsPath: runsPath.path
        )
        if policy.storeReceipts {
            try await persist(result.json)
            // Cross-surface runs ledger (Runs UI + iOS runs snapshot): one
            // summary row per swarm in <dataRoot>/runs/runs.json alongside the
            // full receipt above. nil ledger root (noncanonical test runsPath)
            // records no row; the receipt above is unaffected.
            if let ledgerRoot = runLedgerDataRoot {
                await RunLedger.append(
                    id: runId,
                    kind: "swarm",
                    status: summary.completed > 0 ? "succeeded" : "failed",
                    model: request.requestedModel,
                    prompt: request.objective,
                    output: synthesis?.output.isEmpty == false
                        ? synthesis?.output
                        : "\(summary.completed) worker(s) completed, \(summary.failed) failed",
                    error: summary.completed > 0
                        ? nil
                        : (synthesis?.error ?? "all \(summary.failed) worker(s) failed"),
                    createdAt: startedDate,
                    durationSeconds: Double(elapsedMs) / 1000.0,
                    dataRoot: ledgerRoot
                )
            }
        }
        return result
    }

    private func executeWorkers(
        request: AgentSwarmRunRequest,
        runId: String
    ) async -> [AgentSwarmWorkerResult] {
        var results = Array<AgentSwarmWorkerResult?>(repeating: nil, count: request.workers.count)
        await withTaskGroup(of: (Int, AgentSwarmWorkerResult).self) { group in
            var nextIndex = 0
            let initial = min(request.maxParallel, request.workers.count)
            for _ in 0..<initial {
                let idx = nextIndex
                nextIndex += 1
                group.addTask {
                    let worker = request.workers[idx]
                    return (idx, await self.runWorker(index: idx, worker: worker, request: request, runId: runId))
                }
            }
            while let (idx, result) = await group.next() {
                results[idx] = result
                if nextIndex < request.workers.count {
                    let enqueueIndex = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let worker = request.workers[enqueueIndex]
                        return (
                            enqueueIndex,
                            await self.runWorker(index: enqueueIndex, worker: worker, request: request, runId: runId)
                        )
                    }
                }
            }
        }
        return results.enumerated().map { idx, result in
            result ?? AgentSwarmWorkerResult(
                id: "\(runId)-\(String(format: "%02d", idx + 1))",
                index: idx + 1,
                name: request.workers[idx].name,
                role: request.workers[idx].role,
                model: request.workers[idx].model,
                requestedModel: request.workers[idx].model,
                reasoningEffort: request.workers[idx].reasoningEffort,
                access: request.workers[idx].access,
                status: "failed",
                output: "",
                outputTruncated: false,
                error: "worker did not return a result",
                durationSeconds: 0,
                findingsCap: request.workers[idx].findingsCap,
                contextSlice: request.workers[idx].contextSlice
            )
        }
    }

    private func runWorker(
        index: Int,
        worker: AgentSwarmWorkerSpec,
        request: AgentSwarmRunRequest,
        runId: String
    ) async -> AgentSwarmWorkerResult {
        let started = Date()
        let workerId = "\(runId)-\(String(format: "%02d", index + 1))"
        do {
            let prompt = Self.workerPrompt(worker: worker, request: request)
            let output = try await withTimeout(seconds: request.timeoutSeconds) {
                if worker.access == "inherit" {
                    guard let workerRunner else {
                        throw AgentSwarmError.invalidRequest(
                            "tool-capable swarm workers are unavailable in this runtime"
                        )
                    }
                    return try await workerRunner.runWorker(
                        prompt: prompt,
                        model: worker.model,
                        reasoningEffort: worker.reasoningEffort,
                        access: worker.access,
                        originSurface: request.requestedBy,
                        originSessionId: request.originSessionId
                    )
                }
                return try await llm.complete(
                    prompt: prompt,
                    system: Self.workerSystemPrompt(mode: request.mode),
                    model: worker.model,
                    surface: "swarms"
                )
            }
            let bounded = Self.bound(output, maxChars: request.maxOutputChars)
            return AgentSwarmWorkerResult(
                id: workerId,
                index: index + 1,
                name: worker.name,
                role: worker.role,
                model: worker.model,
                requestedModel: worker.model,
                reasoningEffort: worker.reasoningEffort,
                access: worker.access,
                status: "completed",
                output: bounded.text,
                outputTruncated: bounded.truncated,
                error: nil,
                durationSeconds: Date().timeIntervalSince(started),
                findingsCap: worker.findingsCap,
                contextSlice: worker.contextSlice
            )
        } catch {
            return AgentSwarmWorkerResult(
                id: workerId,
                index: index + 1,
                name: worker.name,
                role: worker.role,
                model: worker.model,
                requestedModel: worker.model,
                reasoningEffort: worker.reasoningEffort,
                access: worker.access,
                status: "failed",
                output: "",
                outputTruncated: false,
                error: Self.errorMessage(error),
                durationSeconds: Date().timeIntervalSince(started),
                findingsCap: worker.findingsCap,
                contextSlice: worker.contextSlice
            )
        }
    }

    private func synthesizeIfNeeded(
        request: AgentSwarmRunRequest,
        workerResults: [AgentSwarmWorkerResult]
    ) async -> AgentSwarmSynthesis? {
        guard request.synthesize, workerResults.count > 1 else { return nil }
        let started = Date()
        do {
            let output = try await withTimeout(seconds: request.timeoutSeconds) {
                try await llm.complete(
                    prompt: Self.synthesisPrompt(request: request, workers: workerResults),
                    system: "You synthesize read-only NativeAgent swarm worker outputs for the configured assistant. Be concise, concrete, and distinguish consensus from minority signals.",
                    model: request.synthesisModel,
                    surface: "swarms"
                )
            }
            let bounded = Self.bound(output, maxChars: request.maxOutputChars)
            // U6 digest budget: clip the synthesis (the digest relayed to the
            // orchestrator) to the token budget with an explicit notice. Applied
            // AFTER the char bound so both caps compose; nil budget = unchanged.
            let digested = Self.applyDigestBudget(bounded.text, budgetTokens: request.digestBudgetTokens)
            return AgentSwarmSynthesis(
                model: request.synthesisModel,
                status: "completed",
                output: digested.text,
                outputTruncated: bounded.truncated || digested.truncated,
                error: nil,
                durationSeconds: Date().timeIntervalSince(started)
            )
        } catch {
            return AgentSwarmSynthesis(
                model: request.synthesisModel,
                status: "failed",
                output: "",
                outputTruncated: false,
                error: Self.errorMessage(error),
                durationSeconds: Date().timeIntervalSince(started)
            )
        }
    }

    /// Cap on retained swarm-run records in runs.json (loop-A finding,
    /// 2026-06-13). Each record carries the full workers[] + synthesis, so the
    /// file is heavyweight; the retired daemon bounded this and no other writer
    /// does now. Matches the items.jsonl / activity-feed cap.
    private static let maxRetainedRuns = 1000

    private func persist(_ record: JSONValue) async throws {
        try await persistence.withFileLock(runsPath) {
            let existingRaw = await persistence.readJSON(runsPath, defaultValue: .array([]))
            var existing: [JSONValue]
            if case .array(let arr) = existingRaw {
                existing = arr
            } else {
                existing = []
            }
            existing.insert(record, at: 0)
            // Loop-A finding: keep runs.json bounded. Newest-first insert means
            // the oldest tail is dropped. Runs under the same flock as the
            // read-modify-write so a concurrent writer can't interleave.
            if existing.count > Self.maxRetainedRuns {
                existing.removeLast(existing.count - Self.maxRetainedRuns)
            }
            try await persistence.writeJSON(.array(existing), to: runsPath)
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw AgentSwarmError.timeout(seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw AgentSwarmError.invalidRequest("swarm worker produced no result")
            }
            group.cancelAll()
            return result
        }
    }

    private static func workerSystemPrompt(mode: String) -> String {
        """
        You are a read-only NativeAgent subagent in the configured assistant's Swift-native \(mode) swarm.
        You cannot call tools, mutate files, execute shell commands, send messages, or change system state.
        Work independently. Return direct findings or analysis only, with no preamble.
        """
    }

    private static func workerPrompt(worker: AgentSwarmWorkerSpec, request: AgentSwarmRunRequest) -> String {
        var parts: [String] = [
            "OBJECTIVE:\n\(request.objective)",
            "WORKER:\nname: \(worker.name)\nrole: \(worker.role)\nmodel: \(worker.model)\nreasoning_effort: \(worker.reasoningEffort)",
        ]
        if !worker.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("ROLE BRIEF:\n\(worker.prompt)")
        }
        if let cap = worker.findingsCap {
            parts.append("FINDINGS CAP:\nReturn at most \(cap) findings.")
        }
        if let context = worker.contextSlice?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            parts.append("CONTEXT SLICE:\n\(context)")
        }
        if worker.access == "read_only" {
            parts.append("READ-ONLY CONSTRAINT:\nDo not claim to have used tools or changed files. Analyze from the prompt only.")
        } else {
            parts.append("TOOL ACCESS:\nYou may use the tools exposed by NativeAgent. Every call remains subject to the same TrustCenter, workspace, autonomy, receipt, and verification gates as the parent assistant. Do not delegate to another agent or restart/install NativeAgent.")
        }
        return parts.joined(separator: "\n\n")
    }

    private static func synthesisPrompt(request: AgentSwarmRunRequest, workers: [AgentSwarmWorkerResult]) -> String {
        let rendered = workers.map { worker -> String in
            let body = worker.output.isEmpty ? (worker.error ?? "(no output)") : worker.output
            return "[\(worker.name)] role=\(worker.role) model=\(worker.model) status=\(worker.status)\n\(body)"
        }.joined(separator: "\n\n---\n\n")
        return """
        OBJECTIVE:
        \(request.objective)

        WORKER OUTPUTS:
        \(rendered)

        SYNTHESIS:
        Summarize the strongest consensus, note disagreements or failed workers, and give a concise action-oriented conclusion.
        """
    }

    private static func bound(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        if text.count <= maxChars {
            return (text, false)
        }
        return (String(text.prefix(maxChars)), true)
    }

    /// U6 digest-budget truncation. `budgetTokens == nil` returns the text
    /// unchanged (the default — no behavior change). Otherwise clip to
    /// ~budgetTokens tokens (≈4 chars/token heuristic, the standard rough
    /// estimate) and append an explicit NOTICE so the orchestrator reading the
    /// digest knows it is clipped — never a silent truncation.
    static func applyDigestBudget(_ text: String, budgetTokens: Int?) -> (text: String, truncated: Bool) {
        guard let budgetTokens, budgetTokens > 0 else { return (text, false) }
        let charBudget = budgetTokens * 4
        if text.count <= charBudget { return (text, false) }
        let clipped = String(text.prefix(charBudget))
        let notice = "\n\n[digest truncated to ~\(budgetTokens) tokens by digestBudgetTokens — request a larger budget or task_ledger/follow-up for the full output]"
        return (clipped + notice, true)
    }

    private static func errorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }
}

public struct AgentSwarmSummary: Sendable, Equatable {
    public var completed: Int
    public var failed: Int

    public var json: JSONValue {
        .object([
            "completed": .int(Int64(completed)),
            "failed": .int(Int64(failed)),
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return f.string(from: date)
    }
}

private extension AgentSwarmWorkerSpec {
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
