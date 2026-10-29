import Foundation
import PersistenceCore
import NativeAgentCore
import TurnTrace
import ToolExecution
import Privacy
import ProviderRouting
// Blueprint: | `SwarmRequests.swift` | `AgentSwarmError`, `AgentSwarmPolicy`, `AgentSwarmWorkerSpec`, `AgentSwarmRunRequest`: policy bounds, request aliases, Work model/account binding, worker access and effort validation, and dry-run plans |

public enum AgentSwarmError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case policyDenied(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        case .policyDenied(let message):
            return message
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
    /// Extra effort names from the bound provider/model's catalog, not Trust.
    public var supportedReasoningEfforts: [String] = []
    public var storeReceipts: Bool

    public init(
        enabled: Bool = true,
        maxAgents: Int = Self.hardMaxAgents,
        maxParallel: Int = 6,
        // Empty selects the Work surface's model from the routing snapshot.
        defaultModel: String = "",
        defaultReasoningEffort: String = "medium",
        storeReceipts: Bool = true
    ) {
        self.enabled = enabled
        self.maxAgents = max(1, min(maxAgents, Self.hardMaxAgents))
        self.maxParallel = max(1, min(maxParallel, Self.hardMaxAgents))
        self.defaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
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
            maxAgents: AgentSwarmRunRequest.intValue(swarm["maxAgents"]) ?? Self.hardMaxAgents,
            maxParallel: AgentSwarmRunRequest.intValue(swarm["maxParallel"]) ?? 6,
            defaultModel: AgentSwarmRunRequest.firstString(swarm, keys: ["defaultModel"]) ?? "",
            defaultReasoningEffort: AgentSwarmRunRequest.firstString(swarm, keys: ["defaultReasoningEffort"]) ?? "medium",
            storeReceipts: bool(swarm["storeReceipts"], defaultValue: true)
        )
    }

    private static func bool(_ value: JSONValue?, defaultValue: Bool) -> Bool {
        switch value {
        case .bool?, .string?: return AgentSwarmRunRequest.boolValue(value, defaultValue: defaultValue)
        default: return defaultValue
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
    public var reasoningEffort: String
    public var requestedBy: String
    /// Verified parent chat identity only authorizes tools; ephemeral workers never append to its transcript.
    public var originSessionId: String?
    /// Optional synthesis token budget; nil keeps maxOutputChars, and budget clipping appends a notice.
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
            throw AgentSwarmError.invalidRequest("objective must be non-empty text, for example objective: \"Review the proposed change\". query, prompt and task are also accepted.")
        }

        // Requests keep Work's model/account; effort defaults to its Think level and must match its catalog, or low/medium/high/xhigh without one.
        var supportedEfforts: [String] = []
        for name in policy.supportedReasoningEfforts {
            let effort = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !effort.isEmpty, !supportedEfforts.contains(effort) { supportedEfforts.append(effort) }
        }
        if supportedEfforts.isEmpty { supportedEfforts = ["low", "medium", "high", "xhigh"] }
        let requestedEffort = try parseEffort(input, defaultEffort: policy.defaultReasoningEffort, supportedEfforts: supportedEfforts)
        let defaultAccess = try workerAccess(input)
        let models = stringArray(input["models"])
        try requireBoundModel(input, models: models, bound: policy.defaultModel)
        let requestedModel = policy.defaultModel
        let explicitWorkers = try parseWorkerArray(
            input,
            defaultModel: requestedModel,
            defaultEffort: requestedEffort,
            supportedEfforts: supportedEfforts,
            defaultAccess: defaultAccess
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
                return AgentSwarmWorkerSpec(
                    name: "worker-\(idx + 1)",
                    role: "independent analyst \(idx + 1)",
                    model: requestedModel,
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
        // Synthesis uses the same checked model/account as the workers.
        let synthesisModel = requestedModel
        let timeoutSeconds = max(
            15,
            min(intValue(firstPresent(input, keys: ["timeoutSeconds", "timeout_seconds", "timeout"])) ?? 240, 900)
        )
        let maxOutputChars = max(
            500,
            min(intValue(firstPresent(input, keys: ["maxOutputChars", "max_output_chars"])) ?? 4_000, 12_000)
        )
        // Non-positive budgets disable the additional digest limit.
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
            reasoningEffort: requestedEffort,
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
            "reasoningEffort": .string(reasoningEffort),
            "workers": .array(workers.enumerated().map { idx, worker in
                worker.planJSON(index: idx)
            }),
        ])
    }

    private static func parseWorkerArray(
        _ input: [String: JSONValue],
        defaultModel: String,
        defaultEffort: String,
        supportedEfforts: [String],
        defaultAccess: String
    ) throws -> [AgentSwarmWorkerSpec] {
        // Populated aliases win over placeholders; malformed lists fail instead of starting default workers.
        var selected: [JSONValue]?
        for key in ["agents", "workers", "roles", "workerConfigs", "worker_configs"] {
            guard let raw = input[key], raw != .null else { continue }
            guard case .array(let values) = raw else {
                throw AgentSwarmError.invalidRequest("agent_swarm \(key) must be an array of worker objects or role strings")
            }
            if !values.isEmpty { selected = values; break }
        }
        guard let values = selected else { return [] }
        var out: [AgentSwarmWorkerSpec] = []
        for (idx, value) in values.enumerated() {
            switch value {
            case .string(let role):
                let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedRole.isEmpty else {
                    throw AgentSwarmError.invalidRequest("agent_swarm worker \(idx + 1) has an empty role string")
                }
                out.append(AgentSwarmWorkerSpec(
                    name: "worker-\(idx + 1)",
                    role: trimmedRole,
                    model: defaultModel,
                    reasoningEffort: defaultEffort,
                    access: defaultAccess
                ))
            case .object(let obj):
                let role = firstString(obj, keys: ["role", "name", "title"]) ?? "independent analyst \(idx + 1)"
                let effort = try parseEffort(obj, defaultEffort: defaultEffort, supportedEfforts: supportedEfforts)
                let access = try workerAccess(obj, fallback: defaultAccess)
                let brief = try checkedWorkerText(obj, keys: ["prompt", "lensBrief", "lens_brief", "instructions"], index: idx)
                let context = try checkedWorkerText(obj, keys: ["contextSlice", "context_slice", "context"], index: idx)
                out.append(AgentSwarmWorkerSpec(
                    name: firstString(obj, keys: ["name", "id"]) ?? "worker-\(idx + 1)",
                    role: role,
                    prompt: brief ?? "",
                    model: defaultModel,
                    reasoningEffort: effort,
                    access: access,
                    contextSlice: context,
                    findingsCap: intValue(firstPresent(obj, keys: ["findingsCap", "findings_cap"]))
                ))
            default:
                throw AgentSwarmError.invalidRequest("agent_swarm worker \(idx + 1) must be an object or nonempty role string")
            }
        }
        return out
    }

    /// Validate every supplied mission/context alias and retain the first nonblank text.
    private static func checkedWorkerText(_ input: [String: JSONValue], keys: [String], index: Int) throws -> String? {
        var selected: String?
        for key in keys {
            guard let value = input[key], value != .null else { continue }
            guard case .string(let raw) = value else {
                throw AgentSwarmError.invalidRequest("agent_swarm worker \(index + 1) field '\(key)' must be text, null, or omitted; explicit worker instructions/context were not discarded. No workers were started.")
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if selected == nil && !text.isEmpty { selected = text }
        }
        return selected
    }

    /// Every supplied default, rota, worker and synthesis model must name Work's model or nothing.
    private static func requireBoundModel(
        _ input: [String: JSONValue],
        models: [String],
        bound: String
    ) throws {
        var supplied: [String] = []
        if let top = firstString(input, keys: ["model", "defaultModel", "requestedModel"]) {
            supplied.append(top)
        }
        if let synth = firstString(input, keys: ["synthesisModel", "synthesis_model"]) {
            supplied.append(synth)
        }
        supplied.append(contentsOf: models)
        for key in ["agents", "workers", "roles", "workerConfigs", "worker_configs"] {
            guard case .array(let values)? = input[key] else { continue }
            for value in values {
                guard case .object(let obj) = value else { continue }
                if let worker = firstString(obj, keys: ["model", "requestedModel", "requested_model"]) {
                    supplied.append(worker)
                }
            }
        }
        let boundName = bound.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in supplied {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != boundName else { continue }
            throw AgentSwarmError.invalidRequest(
                "agent_swarm cannot choose its own model: it runs on the model picked for Work"
                    + (boundName.isEmpty ? "" : " (\(boundName))")
                    + ". Remove model/models/synthesisModel/per-worker model, or change the Work group in Providers."
                    + " Requested: \(trimmed). No workers were started."
            )
        }
    }

    /// Validate both spellings so a malformed alias cannot silently disappear.
    private static func parseEffort(
        _ input: [String: JSONValue],
        defaultEffort: String,
        supportedEfforts: [String]
    ) throws -> String {
        var selected: String?
        for key in ["reasoningEffort", "reasoning_effort"] {
            guard let value = input[key], value != .null else { continue }
            guard case .string(let raw) = value else {
                throw AgentSwarmError.invalidRequest("agent_swarm \(key) must be text, null, or omitted. No workers were started.")
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let effort = trimmed.lowercased()
            guard supportedEfforts.contains(effort) else {
                throw AgentSwarmError.invalidRequest("agent_swarm reasoning_effort '\(trimmed)' isn't a level the Work model supports. Use one of: \(supportedEfforts.joined(separator: ", ")). No workers were started.")
            }
            if selected == nil { selected = effort }
        }
        return selected ?? defaultEffort
    }

    private static func workerAccess(
        _ input: [String: JSONValue],
        fallback: String = "read_only"
    ) throws -> String {
        for key in ["access", "workerAccess", "worker_access"] {
            guard let value = input[key], value != .null else { continue }
            guard case .string(let raw) = value else {
                throw AgentSwarmError.invalidRequest("agent_swarm \(key) must be a worker access string")
            }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty { continue }
            switch normalized {
            case "inherit", "auto", "tools", "tool_capable", "tool-capable", "workspace", "full":
                return "inherit"
            case "read_only", "readonly", "read-only", "reasoning":
                return "read_only"
            default:
                throw AgentSwarmError.invalidRequest("agent_swarm \(key) is not a recognized worker access mode; use read_only or inherit")
            }
        }
        for key in ["readOnly", "read_only"] {
            guard let value = input[key], value != .null else { continue }
            if case .string(let raw) = value, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return boolValue(value, defaultValue: true) ? "read_only" : "inherit"
        }
        return fallback
    }

    static func firstPresent(_ input: [String: JSONValue], keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = input[key], value != .null { return value }
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
        case .double(let d):
            guard d.isFinite else { return nil }
            // Truncate toward zero; unrepresentable numbers return nil instead of trapping.
            return Int(exactly: d.rounded(.towardZero))
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    static func boolValue(_ value: JSONValue?, defaultValue: Bool) -> Bool {
        switch value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "y": return true
        case "n": return false
        default: return ConnectorInputValue.bool(value, default: defaultValue)
        }
    }
}
