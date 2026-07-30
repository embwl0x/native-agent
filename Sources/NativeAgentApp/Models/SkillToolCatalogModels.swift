import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct SkillRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var description: String
    var triggers: [String]
    var kind: String?
    var status: String?
    var autoCreated: Bool?
    var sourceRunId: String?
    var bodyPath: String?
    var createdAt: String?
    var updatedAt: String?
    var useCount: Int?
    var lastUsedAt: String?
    /// "runtime_registry" (default for in-registry rows), "runtime_body" (a
    /// markdown body under data/skills/bodies/ with no registry entry yet),
    /// or "persona_body" (a markdown body under persona/skills/bodies/). UI
    /// uses this to gate destructive actions — Disable/Delete only make sense
    /// for registry rows; body-only rows have no entry to mutate.
    var source: String?
}

struct ToolRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var description: String
    var triggers: [String]
    var language: String?
    var entrypoint: String?
    var permissions: [String]?
    var status: String?
    var phase: String?
    var autoCreated: Bool?
    var autoPromote: Bool?
    var autoRun: Bool?
    var autoPromotable: Bool?
    var validationStatus: String?
    var validationErrors: [String]?
    var proposalPath: String?
    var activePath: String?
    var quarantinePath: String?
    var quarantineReason: String?
    var sourceRunId: String?
    var createdAt: String?
    var updatedAt: String?
    var useCount: Int?
    var lastUsedAt: String?
}

struct ChatCatalogTool: Identifiable, Codable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    var parametersPreview: String?
    var dispatchableVia: String?
    var loadState: String?
    var effectiveAutonomy: String?
    var availableNow: Bool?
}

struct ChatToolCatalogSnapshot: Codable, Hashable, Sendable {
    var tools: [ChatCatalogTool]
    var currentlyLoaded: Set<String>
    var builderAvailable: [String]
    var builderPolicyLocked: [String]
    var builderNotImplemented: [String]
    var macAppAvailable: [String]
    var macAppPolicyLocked: [String]
    var fullMacActive: Bool
    var fileOpsAllowed: Bool
    var systemAllowed: Bool
    var appControlAllowed: Bool
    var builderModeDetail: String
    var permissionLevel: String

    static func from(jsonValue value: JSONValue) -> ChatToolCatalogSnapshot? {
        guard case .object(let obj) = value else { return nil }

        func stringArray(_ key: String) -> [String] {
            guard case .array(let arr)? = obj[key] else { return [] }
            return arr.compactMap { v in
                if case .string(let s) = v { return s }
                return nil
            }
        }
        func boolVal(_ key: String) -> Bool {
            if case .bool(let b)? = obj[key] { return b }
            return false
        }
        func stringVal(_ key: String) -> String {
            if case .string(let s)? = obj[key] { return s }
            return ""
        }

        var tools: [ChatCatalogTool] = []
        if case .array(let rows)? = obj["tools"] {
            for row in rows {
                guard case .object(let r) = row,
                      case .string(let name)? = r["name"] else { continue }
                let desc: String = {
                    if case .string(let s)? = r["description"] { return s }
                    return ""
                }()
                var dispatchVia: String?
                if case .string(let dv)? = r["dispatchable_via"] { dispatchVia = dv }
                var loadState: String?
                if case .string(let state)? = r["load_state"] { loadState = state }
                var effectiveAutonomy: String?
                if case .string(let autonomy)? = r["effective_autonomy"] {
                    effectiveAutonomy = autonomy
                }
                var availableNow: Bool?
                if case .bool(let available)? = r["available_now"] { availableNow = available }
                var paramsPreview: String?
                if case .object(let pobj)? = r["parameters"],
                   case .object(let props)? = pobj["properties"] {
                    let keys = props.keys.sorted()
                    if !keys.isEmpty {
                        paramsPreview = keys.prefix(6).joined(separator: ", ")
                            + (keys.count > 6 ? ", …" : "")
                    }
                }
                tools.append(ChatCatalogTool(
                    name: name,
                    description: desc,
                    parametersPreview: paramsPreview,
                    dispatchableVia: dispatchVia,
                    loadState: loadState,
                    effectiveAutonomy: effectiveAutonomy,
                    availableNow: availableNow
                ))
            }
        }

        return ChatToolCatalogSnapshot(
            tools: tools,
            currentlyLoaded: Set(stringArray("currently_loaded")),
            builderAvailable: stringArray("builder_available_tools"),
            builderPolicyLocked: stringArray("builder_policy_locked_tools"),
            builderNotImplemented: stringArray("builder_not_implemented_tools"),
            macAppAvailable: stringArray("mac_app_available_tools"),
            macAppPolicyLocked: stringArray("mac_app_policy_locked_tools"),
            fullMacActive: boolVal("full_mac_active"),
            fileOpsAllowed: boolVal("file_ops_allowed"),
            systemAllowed: boolVal("system_allowed"),
            appControlAllowed: boolVal("app_control_allowed"),
            builderModeDetail: stringVal("builder_mode_detail"),
            permissionLevel: stringVal("permission_level")
        )
    }
}
