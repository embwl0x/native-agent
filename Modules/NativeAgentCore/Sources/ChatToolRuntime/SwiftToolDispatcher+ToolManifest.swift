import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
// Blueprint: | `SwiftToolDispatcher+ToolManifest.swift` | `SwiftToolDispatcher`: `toolManifest` |

// MARK: - The Tools page's manifest

extension SwiftToolDispatcher {
    /// The manifest projects the single app contract and Trust’s reachable actions; discovery never loads extra tools.
    public func toolManifest(turn: Turn, detail: String? = nil, surface: String = "chat") async throws -> JSONValue {
        let fullDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "full"
        let catalog = try await catalogSnapshot(turn: turn, includeSchemas: fullDetail, surface: surface)
        let access = catalog.access
        let trustedRoots = try await trustedWorkspaceRoots()
        let modelNameSet = Self.modelVisibleCatalogToolNames(Set(catalog.names))
        let alwaysOnTools = Self.alwaysOnCoreNames.intersection(modelNameSet).sorted()
        let contributedBuckets = Dictionary((appTools?.descriptors ?? []).map { ($0.name, $0.bucket) }) { first, _ in first }
        let rows: [JSONValue] = try catalog.schemas.filter { modelNameSet.contains($0.name) }.sorted { $0.name < $1.name }.map { schema in
            var row: [String: JSONValue] = [
                "name": .string(schema.name),
                "description": .string(schema.description),
                "dispatchable_via": .string(contributedToolNames.contains(schema.name)
                    ? "nativeagent_app_tool_dispatcher" : "swift_tool_dispatcher"),
                "model_visible": .bool(true),
            ]
            // Use the registry’s buckets so rendered categories cannot drift from dispatch; unreviewed names stay visibly adverse.
            row["catalog_bucket"] = .string(
                (Self.catalogBucket(forRegisteredToolNamed: schema.name) ?? contributedBuckets[schema.name])?.rawValue
                    ?? ChatToolCatalogBucket.unclassified.rawValue
            )
            let parameters: JSONValue
            do { parameters = try JSONValue.parse(schema.parametersJSON) }
            catch {
                throw ToolFailureError("""
                    The catalog's input schema for \(schema.name) could not be read: \(error.localizedDescription). Repair its registered schema \
                    before reading the catalog again.
                    """,
                    effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                    instruction: "Repair the registered input schema for \(schema.name).", recovery: .repair)
            }
            guard case .object = parameters else {
                throw ToolFailureError("""
                    The catalog's input schema for \(schema.name) must be an object. Repair its registered schema before reading the catalog \
                    again.
                    """,
                    effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                    instruction: "Repair the registered input schema for \(schema.name).", recovery: .repair)
            }
            row["parameters"] = parameters
            return .object(row)
        }
        let listed = Set(catalog.names)
        let swiftBuilderTools = (Self.fullMacFileToolNames + Self.fullMacSystemToolNames + Self.fullMacBuilderToolNames + Self.fullMacRestartToolNames).sorted()
        let availableBuilderTools = swiftBuilderTools.filter { listed.contains($0) }.map { ToolNameAliases.appAction($0) ?? $0 }
        let lockedBuilderTools = swiftBuilderTools.filter { !listed.contains($0) }.map { ToolNameAliases.appAction($0) ?? $0 }
        // Only executors with app actions belong in folded discovery.
        let axReadTools = Self.fullMacAccessibilityReadToolNames.sorted()
        let availableAXReadTools = axReadTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedAXReadTools = axReadTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let activityTools = Self.activityQueryToolNames.sorted()
        let availableActivityTools = activityTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedActivityTools = activityTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let axActTools = Self.fullMacAccessibilityInjectionToolNames.sorted()
        let availableAXActTools = axActTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedAXActTools = axActTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        return .object([
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "catalog_detail": .string(fullDetail ? "full" : "compact"),
            "permission_source": .string("trust/policy.json"),
            "full_mac_active": .bool(access.fullMacActive),
            "permission_level": .string(access.permissionLevel),
            "outside_workspace_default": .string(access.outsideWorkspaceDefault),
            "file_ops_allowed": .bool(access.fileOpsAllowed),
            "system_allowed": .bool(access.systemAllowed),
            "app_control_allowed": .bool(access.accessibilityAllowed),
            "builder_mode": .string(access.fileOpsAllowed ? "available" : "policy_locked"),
            "builder_mode_detail": .string(access.fileOpsAllowed
                ? """
                    Trust Center Full Mac file access is active. app's files.*, git.*, shell.run/shell.bash, files.patch, swift.build/swift.test \
                    and app.install/app.restart actions are all available (autonomy-gated).
                    """
                : """
                    app files.write is available only inside Trust Center workspace roots; broader file, git and shell actions are locked until \
                    Trust Center Full Mac mode with file_ops_allowed is active.
                    """),
            "trusted_workspace_roots": .array(trustedRoots.map { .string($0.path) }),
            // Read-only AX perception is listed separately from app control.
            "mac_accessibility_read_available_tools": .array(availableAXReadTools.map { .string($0) }),
            "mac_accessibility_read_policy_locked_tools": .array(lockedAXReadTools.map { .string($0) }),
            // Activity and injection remain distinct from reads and app control.
            "activity_available_tools": .array(availableActivityTools.map { .string($0) }),
            "activity_policy_locked_tools": .array(lockedActivityTools.map { .string($0) }),
            "mac_accessibility_act_available_tools": .array(availableAXActTools.map { .string($0) }),
            "mac_accessibility_act_policy_locked_tools": .array(lockedAXActTools.map { .string($0) }),
            "always_on_tools": .array(alwaysOnTools.map { .string($0) }),
            "available_tools": .array(modelNameSet.sorted().map { .string($0) }),
            "builder_available_tools": .array(availableBuilderTools.map { .string($0) }),
            "builder_policy_locked_tools": .array(lockedBuilderTools.map { .string($0) }),
            "tools": .array(rows),
        ])
    }
}
