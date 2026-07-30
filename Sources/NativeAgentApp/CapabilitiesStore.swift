import Foundation
import Observation
import PersistenceCore

// PATCH-Phase6b: CapabilitiesStore — fetches GET /v1/capabilities (dispatcher tool manifest)
// and caches results for 30 seconds.  Refreshes on view appear, app focus, and manual button.
//
// NOTE: This is separate from AppModel.capabilitySummary (which decodes the old
//       CapabilitySummaryResponse / capability catalog shape).  This store decodes the
//       Phase-2 dispatcher manifest: { ok, persona, active_provider, tools: [...], ... }.

// ---------------------------------------------------------------------------
// MARK: - Decodable types
// ---------------------------------------------------------------------------

// PATCH-Phase7b: InputSchema carries the JSON Schema for a tool's input.
// We decode only what we need for arg-plan resolution and form rendering.
struct ToolInputSchema: Decodable, Hashable {
    // property name → its descriptor
    let properties: [String: ToolInputProp]?
    // ordered list of required field names
    let required: [String]?

    enum CodingKeys: String, CodingKey {
        case properties, required
    }
}

struct ToolInputProp: Decodable, Hashable {
    let type: String?          // "string" | "integer" | "boolean" | "object" | "array"
    let description: String?
    // We don't need "default" or "enum" for form rendering right now.
}

struct ToolCapability: Identifiable, Decodable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let autonomy: String
    let effectiveAutonomy: String
    let autonomySource: String
    let sideEffects: Bool
    let providerConstraints: [String]?
    let availableNow: Bool
    // PATCH-Phase7b: input schema for arg-plan resolution + form rendering
    let inputSchema: ToolInputSchema?

    enum CodingKeys: String, CodingKey {
        case name, description, autonomy
        case effectiveAutonomy    = "effective_autonomy"
        case autonomySource       = "autonomy_source"
        case sideEffects          = "side_effects"
        case providerConstraints  = "provider_constraints"
        case availableNow         = "available_now"
        case inputSchema          = "input_schema"
    }
}

struct ToolChatConfig: Decodable, Hashable {
    let defaultToolLoopMaxIterations: Int
    let maxToolLoopIterationsCap: Int

    enum CodingKeys: String, CodingKey {
        case defaultToolLoopMaxIterations = "default_tool_loop_max_iterations"
        case maxToolLoopIterationsCap     = "max_tool_loop_iterations_cap"
    }
}

// ---------------------------------------------------------------------------
// MARK: - Store
// ---------------------------------------------------------------------------

@MainActor
@Observable
final class CapabilitiesStore {
    var tools: [ToolCapability] = []
    var persona: String = ""
    var activeProvider: String = ""
    var defaultIterationCap: Int = 12
    var maxIterationCap: Int = 50
    var lastFetchedAt: Date? = nil
    var fetchError: String? = nil
    var isFetching: Bool = false

    private let cacheTTL: TimeInterval = 30
    private let manifestLoader: @Sendable () async throws -> JSONValue

    init(
        manifestLoader: @escaping @Sendable () async throws -> JSONValue = {
            try await makeNativeAgentAppToolDispatchClient().dispatch(
                tool: "tool_catalog",
                input: [:],
                surface: "chat"
            )
        }
    ) {
        self.manifestLoader = manifestLoader
    }

    // Called by views.  No-ops if the cache is still fresh.
    func refresh() async {
        let now = Date()
        if let last = lastFetchedAt, now.timeIntervalSince(last) < cacheTTL {
            return
        }
        await forceRefresh()
    }

    // Bypasses TTL — used by the manual "Refresh" button. The manifest comes
    // from the same in-process app dispatcher used by chat; no retired HTTP
    // capability route or duplicate registry is involved.
    func forceRefresh() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let envelope = try await manifestLoader()
            let data = try envelope.serializedData(pretty: false)
            let manifest = try JSONDecoder().decode(ToolCapabilityManifest.self, from: data)
            tools = manifest.tools.sorted { $0.name < $1.name }
            persona = manifest.persona ?? ""
            activeProvider = manifest.activeProvider ?? ""
            defaultIterationCap = manifest.chat?.defaultToolLoopMaxIterations ?? 12
            maxIterationCap = manifest.chat?.maxToolLoopIterationsCap ?? 50
            fetchError = nil
            lastFetchedAt = Date()
        } catch {
            tools = []
            persona = ""
            activeProvider = ""
            fetchError = "Tool manifest unavailable: \(error.localizedDescription)"
            lastFetchedAt = nil
        }
    }

    // Groups tools into three display sections.
    func toolsByCategory() -> [(category: String, tools: [ToolCapability])] {
        let available = tools.filter { $0.availableNow && $0.effectiveAutonomy == "auto" }
        let needsApproval = tools.filter { $0.effectiveAutonomy == "confirm" }
        let blocked = tools.filter { $0.effectiveAutonomy == "blocked" || !$0.availableNow }

        var result: [(category: String, tools: [ToolCapability])] = []
        if !available.isEmpty    { result.append((category: "Available Now",    tools: available)) }
        if !needsApproval.isEmpty { result.append((category: "Needs Approval",  tools: needsApproval)) }
        if !blocked.isEmpty       { result.append((category: "Blocked / Unavailable", tools: blocked)) }
        return result
    }

    // Returns tools suitable for dynamic slash-command exposure:
    // no side-effects, auto autonomy, available now.
    func slashCommandTools() -> [ToolCapability] {
        tools.filter { $0.sideEffects == false && $0.effectiveAutonomy == "auto" && $0.availableNow }
    }
}

private struct ToolCapabilityManifest: Decodable {
    let tools: [ToolCapability]
    let persona: String?
    let activeProvider: String?
    let chat: ToolChatConfig?

    enum CodingKeys: String, CodingKey {
        case tools, persona, chat
        case activeProvider = "active_provider"
    }
}

// ---------------------------------------------------------------------------
// MARK: - Phase 7b: Dispatch arg-plan
// ---------------------------------------------------------------------------

/// Describes how to turn free-text slash-command args into a typed input dict.
enum DispatchPlanMode: Equatable {
    /// Tool has no required fields — dispatch immediately with input={}.
    case zeroArgs
    /// Tool has exactly one required string field — stuff freeText into it.
    case singleStringArg(field: String)
    /// Multiple/non-string required fields — open the ToolInputForm sheet.
    case formNeeded
}

struct DispatchArgPlan {
    let tool: ToolCapability
    let mode: DispatchPlanMode
    /// Pre-filled values (populated for .singleStringArg when freeText is non-empty).
    let prefilled: [String: Any]
}

extension CapabilitiesStore {
    /// Resolve how to dispatch `toolName` given raw free-text args from the slash command.
    /// Returns nil if no tool with that name exists.
    func planDispatch(toolName: String, freeText: String) -> DispatchArgPlan? {
        guard let tool = tools.first(where: { $0.name == toolName }) else { return nil }

        let schema = tool.inputSchema
        let required = schema?.required ?? []
        let props = schema?.properties ?? [:]

        // Zero required args → fire immediately.
        if required.isEmpty {
            return DispatchArgPlan(tool: tool, mode: .zeroArgs, prefilled: [:])
        }

        // Single required field that is a string → shortcut.
        if required.count == 1,
           let fieldName = required.first,
           let prop = props[fieldName],
           (prop.type == "string" || prop.type == nil) {
            let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefilled: [String: Any] = trimmed.isEmpty ? [:] : [fieldName: trimmed]
            return DispatchArgPlan(tool: tool, mode: .singleStringArg(field: fieldName), prefilled: prefilled)
        }

        // Anything else → show a form.
        return DispatchArgPlan(tool: tool, mode: .formNeeded, prefilled: [:])
    }
}
