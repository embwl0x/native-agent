import Foundation
import PersistenceCore
import NativeAgentCore
import TurnTrace
import ToolExecution
import Privacy
import ProviderRouting
// Blueprint: | `SwarmRequests.swift` | Swarm policy bounds, checked current request/worker fields with prompt as the sole mission field, required authenticated origin, Work model/account binding, catalog-backed effort and access validation, and dry-run plans |

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
        let fields: Set<String> = ["objective", "agents", "reasoning_effort", "agentCount", "access", "mode", "maxParallel", "timeoutSeconds", "synthesize", "dryRun", "maxOutputChars", "digestBudgetTokens", "requestedBy", "__session_id"]
        let unknown = Set(input.keys).subtracting(fields)
        guard unknown.isEmpty else {
            throw AgentSwarmError.invalidRequest("agent_swarm has unrecognized fields: \(unknown.sorted().joined(separator: ", ")). Use the current swarm contract; no workers were started.")
        }
        guard let requestedBy = firstString(input, keys: ["requestedBy"]) else {
            throw AgentSwarmError.invalidRequest("agent_swarm requires the dispatcher's authenticated requestedBy origin")
        }
        let objective = firstString(input, keys: ["objective"])
        guard let objective, !objective.isEmpty else {
            throw AgentSwarmError.invalidRequest("objective must be non-empty text, for example objective: \"Review the proposed change\".")
        }

        // Requests keep Work's model/account and its declared Think levels.
        var supportedEfforts: [String] = []
        for name in policy.supportedReasoningEfforts {
            let effort = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !effort.isEmpty, !supportedEfforts.contains(effort) { supportedEfforts.append(effort) }
        }
        guard !supportedEfforts.isEmpty else {
            throw ToolFailureError("The selected Work model's Think levels are unavailable. No workers were started.",
                effects: .none, owner: "Providers → Work", code: "swarm_model_controls_unavailable",
                instruction: "Repair the selected Work account's model catalog before starting workers; do not guess supported Think levels.", recovery: .repair)
        }
        let requestedEffort = try parseEffort(input, defaultEffort: policy.defaultReasoningEffort, supportedEfforts: supportedEfforts)
        let defaultAccess = try workerAccess(input)
        let requestedModel = policy.defaultModel
        let explicitWorkers = try parseWorkerArray(
            input,
            defaultModel: requestedModel,
            defaultEffort: requestedEffort,
            supportedEfforts: supportedEfforts,
            defaultAccess: defaultAccess
        )
        let requestedCount = intValue(
            firstPresent(input, keys: ["agentCount"])
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

        let requestedParallel = intValue(firstPresent(input, keys: ["maxParallel"]))
            ?? min(policy.maxParallel, workers.count)
        let maxParallel = max(1, min(requestedParallel, policy.maxParallel, workers.count, AgentSwarmPolicy.hardMaxAgents))
        let synthesize = boolValue(firstPresent(input, keys: ["synthesize"]), defaultValue: workers.count > 1)
        // Synthesis uses the same checked model/account as the workers.
        let synthesisModel = requestedModel
        let timeoutSeconds = max(
            15,
            min(intValue(firstPresent(input, keys: ["timeoutSeconds"])) ?? 240, 900)
        )
        let maxOutputChars = max(
            500,
            min(intValue(firstPresent(input, keys: ["maxOutputChars"])) ?? 4_000, 12_000)
        )
        // Non-positive budgets disable the additional digest limit.
        var digestBudgetTokens: Int? = intValue(firstPresent(input, keys: ["digestBudgetTokens"]))
        if let b = digestBudgetTokens, b <= 0 { digestBudgetTokens = nil }

        return AgentSwarmRunRequest(
            objective: objective,
            mode: firstString(input, keys: ["mode"]) ?? "parallel",
            workers: workers,
            maxParallel: maxParallel,
            synthesize: synthesize,
            synthesisModel: synthesisModel,
            timeoutSeconds: timeoutSeconds,
            dryRun: boolValue(firstPresent(input, keys: ["dryRun"]), defaultValue: false),
            maxOutputChars: maxOutputChars,
            readOnly: workers.allSatisfy { $0.access == "read_only" },
            requestedModel: requestedModel,
            reasoningEffort: requestedEffort,
            requestedBy: requestedBy,
            originSessionId: firstString(input, keys: ["__session_id"]),
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
        // One current worker-list field; malformed lists fail before work starts.
        guard let raw = input["agents"], raw != .null else { return [] }
        guard case .array(let values) = raw else {
            throw AgentSwarmError.invalidRequest("agent_swarm agents must be an array of worker objects or role strings")
        }
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
                let fields: Set<String> = ["name", "role", "prompt", "reasoning_effort", "access", "contextSlice", "findingsCap"]
                let unknown = Set(obj.keys).subtracting(fields)
                guard unknown.isEmpty else {
                    throw AgentSwarmError.invalidRequest("agent_swarm worker \(idx + 1) has unrecognized fields: \(unknown.sorted().joined(separator: ", ")). Use prompt for the worker's complete mission and contextSlice for context. No workers were started.")
                }
                let role = firstString(obj, keys: ["role"]) ?? "independent analyst \(idx + 1)"
                let effort = try parseEffort(obj, defaultEffort: defaultEffort, supportedEfforts: supportedEfforts)
                let access = try workerAccess(obj, fallback: defaultAccess)
                let brief = try checkedWorkerText(obj, key: "prompt", index: idx)
                let context = try checkedWorkerText(obj, key: "contextSlice", index: idx)
                out.append(AgentSwarmWorkerSpec(
                    name: firstString(obj, keys: ["name"]) ?? "worker-\(idx + 1)",
                    role: role,
                    prompt: brief ?? "",
                    model: defaultModel,
                    reasoningEffort: effort,
                    access: access,
                    contextSlice: context,
                    findingsCap: intValue(firstPresent(obj, keys: ["findingsCap"]))
                ))
            default:
                throw AgentSwarmError.invalidRequest("agent_swarm worker \(idx + 1) must be an object or nonempty role string")
            }
        }
        return out
    }

    /// One mission field and one context field; neither has an alias.
    private static func checkedWorkerText(_ input: [String: JSONValue], key: String, index: Int) throws -> String? {
        guard let value = input[key], value != .null else { return nil }
        guard case .string(let raw) = value else {
            throw AgentSwarmError.invalidRequest("agent_swarm worker \(index + 1) field '\(key)' must be text, null, or omitted; explicit worker instructions/context were not discarded. No workers were started.")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Validate the current Think field before work starts.
    private static func parseEffort(
        _ input: [String: JSONValue],
        defaultEffort: String,
        supportedEfforts: [String]
    ) throws -> String {
        var selected: String?
        for key in ["reasoning_effort"] {
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
        let effort = selected ?? defaultEffort
        guard supportedEfforts.contains(effort) else {
            throw AgentSwarmError.invalidRequest("The Work model's saved Think level '\(effort)' is not in its catalog. Choose a supported level in Providers. No workers were started.")
        }
        return effort
    }

    private static func workerAccess(
        _ input: [String: JSONValue],
        fallback: String = "read_only"
    ) throws -> String {
        guard let value = input["access"], value != .null else { return fallback }
        guard case .string(let raw) = value else {
            throw AgentSwarmError.invalidRequest("agent_swarm access must be a worker access string")
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inherit", "read_only": return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default:
            throw AgentSwarmError.invalidRequest("agent_swarm access is not a recognized worker access mode; use read_only or inherit")
        }
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
