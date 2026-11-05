import Foundation
import PersistenceCore

// Blueprint: | `ChatToolCatalog.swift` | `ChatToolCatalogSnapshot`: typed schema and execution policy |

// MARK: - The catalog as the Tools page reads it

/// Core declarations and the app's current Security decision share one row so schema presence cannot imply authority.
public struct ChatCatalogTool: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var parametersPreview: String?
    public var dispatchableVia: String?
    /// Only current request-contract schemas reach the model.
    public var modelVisible: Bool?
    public var effectiveAutonomy: String?
    public var availableNow: Bool?
    /// Runtime categories are the dispatcher's safety contract, independent of presentation tags.
    public var catalogBucket: String?
    /// Absent presentation tags remain ordinary; display names cannot invent catalog taxonomy.
    public var tags: Set<String>?

    public init(
        name: String,
        description: String,
        parametersPreview: String? = nil,
        dispatchableVia: String? = nil,
        modelVisible: Bool? = nil,
        effectiveAutonomy: String? = nil,
        availableNow: Bool? = nil,
        catalogBucket: String? = nil,
        tags: Set<String>? = nil
    ) {
        self.name = name
        self.description = description
        self.parametersPreview = parametersPreview
        self.dispatchableVia = dispatchableVia
        self.modelVisible = modelVisible
        self.effectiveAutonomy = effectiveAutonomy
        self.availableNow = availableNow
        self.catalogBucket = catalogBucket
        self.tags = tags
    }
}
/// Full manifest membership stays distinct from Trust's current execution authority.
public struct ChatToolCatalogSnapshot: Codable, Hashable, Sendable {
    public var tools: [ChatCatalogTool]
    /// Always-on schemas must also exist in this catalog.
    public var alwaysOnTools: Set<String>
    public var builderAvailable: [String]
    public var builderPolicyLocked: [String]
    public var macAppAvailable: [String]
    public var macAppPolicyLocked: [String]
    public var fullMacActive: Bool
    public var fileOpsAllowed: Bool
    public var systemAllowed: Bool
    public var appControlAllowed: Bool
    public var builderModeDetail: String
    public var permissionLevel: String

    public init?(envelope value: JSONValue) {
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
                var modelVisible: Bool?
                if case .bool(let visible)? = r["model_visible"] { modelVisible = visible }
                var effectiveAutonomy: String?
                if case .string(let autonomy)? = r["effective_autonomy"] {
                    effectiveAutonomy = autonomy
                }
                var availableNow: Bool?
                if case .bool(let available)? = r["available_now"] { availableNow = available }
                var catalogBucket: String?
                if case .string(let bucket)? = r["catalog_bucket"] {
                    catalogBucket = bucket
                }
                let tags: Set<String>
                if case .array(let values)? = r["tags"] {
                    tags = Set(values.compactMap { value in
                        guard case .string(let tag) = value else { return nil }
                        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                        return normalized.isEmpty ? nil : normalized
                    })
                } else {
                    tags = []
                }
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
                    modelVisible: modelVisible,
                    effectiveAutonomy: effectiveAutonomy,
                    availableNow: availableNow,
                    catalogBucket: catalogBucket,
                    tags: tags
                ))
            }
        }

        self.tools = tools
        self.alwaysOnTools = Set(stringArray("always_on_tools"))
        self.builderAvailable = stringArray("builder_available_tools")
        self.builderPolicyLocked = stringArray("builder_policy_locked_tools")
        self.macAppAvailable = stringArray("mac_app_available_tools")
        self.macAppPolicyLocked = stringArray("mac_app_policy_locked_tools")
        self.fullMacActive = boolVal("full_mac_active")
        self.fileOpsAllowed = boolVal("file_ops_allowed")
        self.systemAllowed = boolVal("system_allowed")
        self.appControlAllowed = boolVal("app_control_allowed")
        self.builderModeDetail = stringVal("builder_mode_detail")
        self.permissionLevel = stringVal("permission_level")
    }
}
