import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// MARK: - The Tools page's manifest

extension SwiftToolDispatcher {
    /// What the Tools page and the slash-command menu read: the tools a chat
    /// request carries (only `app` since one-door phase 2 step 7), each with
    /// its schema when detail is full, and what Trust lets the folded Mac,
    /// file and builder actions reach. Not a tool: she finds actions with
    /// `app {find}`, and nothing is loaded.
    public func toolManifest(detail: String? = nil, surface: String = "chat") async throws -> JSONValue {
        let fullDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "full"
        let access = await fullMacToolAccess(surface: surface)
        let names = try await modelVisibleToolNames().sorted()
        let trustedRoots = await trustedWorkspaceRoots()
        let schemas = try await (fullDetail ? listAvailableToolSchemas() : [])
            .sorted { $0.name < $1.name }
        let modelNameSet = Self.modelVisibleCatalogToolNames(Set(names))
        let currentlyLoaded = Self.alwaysOnCoreNames.intersection(modelNameSet).sorted()
        let loadedSet = Set(currentlyLoaded)
        let contributedBuckets = Dictionary((appTools?.descriptors ?? []).map { ($0.name, $0.bucket) }) { first, _ in first }
        let rows: [JSONValue] = schemas.filter { modelNameSet.contains($0.name) }.map { schema in
            var row: [String: JSONValue] = [
                "name": .string(schema.name),
                "description": .string(schema.description),
                "dispatchable_via": .string(contributedToolNames.contains(schema.name)
                    ? "nativeagent_app_tool_dispatcher" : "swift_tool_dispatcher"),
                "load_state": .string(loadedSet.contains(schema.name) ? "loaded" : "hidden"),
            ]
            if Self.skillReaderToolNames.contains(schema.name) {
                row["tags"] = .array([.string("skill_reader")])
            }
            // A registry-owned bucket makes the rendered catalog reflect the
            // dispatch table rather than a second UI-only name list. An
            // unreviewed runtime name is never fabricated as a safe category;
            // the mounted Tools UI renders that adverse condition explicitly.
            row["catalog_bucket"] = .string(
                (schema.name.hasPrefix("mcp__") ? ChatToolCatalogBucket.mcp
                    : Self.catalogBucket(forRegisteredToolNamed: schema.name) ?? contributedBuckets[schema.name])?.rawValue
                    ?? ChatToolCatalogBucket.unclassified.rawValue
            )
            if let parameters = try? JSONValue.parse(schema.parametersJSON) {
                row["parameters"] = parameters
            }
            return .object(row)
        }
        // Folded into app: listed as the actions they are, available by the
        // whole catalog rather than the model-visible names.
        let listed = Set(try await listAvailableTools())
        let swiftBuilderTools = (Self.fullMacFileToolNames + Self.fullMacSystemToolNames + Self.fullMacBuilderToolNames + Self.fullMacRestartToolNames).sorted()
        let availableBuilderTools = swiftBuilderTools.filter { listed.contains($0) }.map { ToolNameAliases.appAction($0) ?? $0 }
        let lockedBuilderTools = swiftBuilderTools.filter { !listed.contains($0) }.map { ToolNameAliases.appAction($0) ?? $0 }
        // Report folded Mac actions from the underlying catalog; legacy
        // diagnostic tools without an app action stay out of discovery.
        let axReadTools = Self.fullMacAccessibilityReadToolNames.sorted()
        let availableAXReadTools = axReadTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedAXReadTools = axReadTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let activityTools = Self.activityQueryToolNames.sorted()
        let availableActivityTools = activityTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedActivityTools = activityTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let axActTools = Self.fullMacAccessibilityInjectionToolNames.sorted()
        let availableAXActTools = axActTools.filter { listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let lockedAXActTools = axActTools.filter { !listed.contains($0) }.compactMap { ToolNameAliases.appAction($0) }
        let codexHelper = AgentBridgeRuntime.codexHelperURL(dataRoot: dataRoot)
        let codexBridge = AgentBridgeRuntime.readiness(
            helper: codexHelper,
            cliName: "codex",
            bridgeConfigRoot: agentBridgeConfigRoot
        )
        func bridgeReadinessRow(_ readiness: AgentBridgeRuntime.Readiness) -> JSONValue {
            .object([
                "status": .string(readiness.readyForAsyncRoundTrip
                    ? "ready"
                    : (readiness.readyToAttempt ? "return_path_unavailable" : "unavailable")),
                "execution_ready": .bool(readiness.readyToAttempt),
                "return_path_ready": .bool(readiness.returnPath.isReady),
                "return_path_reason": .string(readiness.returnPath.reason),
                "helper_present": .bool(readiness.helper != nil),
                "runtime_present": .bool(readiness.runtime != nil),
                "cli_present": .bool(readiness.cli != nil),
                "authentication": .string("verified_on_execution"),
            ])
        }
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
            "app_control_allowed": .bool(access.appControlAllowed),
            "builder_mode": .string(access.fileOpsAllowed ? "available" : "policy_locked"),
            "builder_mode_detail": .string(access.fileOpsAllowed
                ? "Trust Center Full Mac file access is active. app's files.*, git.*, shell.run/shell.bash, files.patch, swift.build/swift.test and app.install/app.restart actions are all available (autonomy-gated)."
                : "app files.write is available only inside Trust Center workspace roots; broader file, git and shell actions are locked until Trust Center Full Mac mode with file_ops_allowed is active."),
            "trusted_workspace_roots": .array(trustedRoots.map { .string($0.path) }),
            // W1b — read-only AX perception, listed separately from app control
            // so the discovery surface does not label reads "app control".
            "mac_accessibility_read_available_tools": .array(availableAXReadTools.map { .string($0) }),
            "mac_accessibility_read_policy_locked_tools": .array(lockedAXReadTools.map { .string($0) }),
            // W2/W3 — listed apart from BOTH the reads and app control, so the
            // discovery surface never lets an injection tool look like a read.
            "activity_available_tools": .array(availableActivityTools.map { .string($0) }),
            "activity_policy_locked_tools": .array(lockedActivityTools.map { .string($0) }),
            "mac_accessibility_act_available_tools": .array(availableAXActTools.map { .string($0) }),
            "mac_accessibility_act_policy_locked_tools": .array(lockedAXActTools.map { .string($0) }),
            "currently_loaded": .array(currentlyLoaded.map { .string($0) }),
            "available_tools": .array(modelNameSet.sorted().map { .string($0) }),
            "builder_available_tools": .array(availableBuilderTools.map { .string($0) }),
            "builder_policy_locked_tools": .array(lockedBuilderTools.map { .string($0) }),
            "builder_bridge_readiness": .object([
                "codex": bridgeReadinessRow(codexBridge),
            ]),
            "tools": .array(rows),
        ])
    }
}
