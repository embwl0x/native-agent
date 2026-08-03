import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// MARK: - Lazy tool loading tools

extension SwiftToolDispatcher {
    func impl_tool_catalog(input: [String: JSONValue], surface: String = "chat") async throws -> JSONValue {
        let fullDetail = jsonString(input["detail"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "full"
        let access = await fullMacToolAccess(surface: surface)
        let names = await modelVisibleToolNames().sorted()
        let trustedRoots = await trustedWorkspaceRoots()
        // Full schema material used to be the default model result. On the
        // installed app that expanded one discovery call past 196 KB and
        // forced another expensive provider pass merely to choose tool_load.
        // Compact discovery is enough for routing; exact schemas arrive from
        // tool_load. Full remains an explicit diagnostic mode.
        let schemas = fullDetail
            ? ((try? await listAvailableToolSchemas()) ?? builtInToolSchemas())
                .sorted { $0.name < $1.name }
            : []
        let sessionId = Self.extractSessionId(from: input)
        let sessionActive: Set<String> = sessionId.isEmpty
            ? []
            : await activeToolsStore.load(sessionId: sessionId).activeTools
        let turnScoped = LLMCallContext.turnActiveTools ?? []
        let activeForTurn = sessionActive.union(turnScoped)
        let nameSet = Set(names)
        let mcpNameSet = Set(modelVisibleMCPToolNames())
        // gpt-5.5 review-2 NEEDS_FIX 4: MCP tools ARE always available in
        // tools[] (the bridge always includes mcpToolSchemas). So they
        // belong in currentlyLoaded too — otherwise the description's
        // "tools not in currentlyLoaded are not in your current tools[]
        // array" claim is false for MCP tools and misleads the LLM.
        let currentlyLoaded = Self.alwaysOnCoreNames
            .union(activeForTurn)
            .union(mcpNameSet)
            .intersection(nameSet)
            .sorted()
        let discoveryOnly = nameSet
            .subtracting(Self.alwaysOnCoreNames)
            .subtracting(activeForTurn)
            .subtracting(mcpNameSet)
            .sorted()
        let loadedSet = Set(currentlyLoaded)
        let rows: [JSONValue] = schemas.map { schema in
            var row: [String: JSONValue] = [
                "name": .string(schema.name),
                "description": .string(schema.description),
                "dispatchable_via": .string("swift_tool_dispatcher"),
                "load_state": .string(loadedSet.contains(schema.name) ? "loaded" : "discovery_only"),
            ]
            if let parameters = try? JSONValue.parse(schema.parametersJSON) {
                row["parameters"] = parameters
            }
            return .object(row)
        }
        let swiftBuilderTools = (Self.fullMacFileToolNames + Self.fullMacSystemToolNames + Self.fullMacBuilderToolNames + Self.fullMacRestartToolNames).sorted()
        let availableBuilderTools = swiftBuilderTools.filter { names.contains($0) }
        let lockedBuilderTools = swiftBuilderTools.filter { !names.contains($0) }
        let availableAppTools = Self.fullMacAppToolNames.sorted().filter { names.contains($0) }
        let lockedAppTools = Self.fullMacAppToolNames.sorted().filter { !names.contains($0) }
        let groupIndex = ToolPreloadHeuristics.groupIndex(
            availableToolNames: Set(names)
        )
        let codexHelper = AgentBridgeRuntime.codexHelperURL(repoRoot: rootForRead)
        let claudeHelper = AgentBridgeRuntime.claudeHelperURL(repoRoot: rootForRead)
        let codexBridge = AgentBridgeRuntime.readiness(
            helper: codexHelper,
            cliName: "codex",
            bridgeConfigRoot: agentBridgeConfigRoot
        )
        let claudeBridge = AgentBridgeRuntime.readiness(
            helper: claudeHelper,
            cliName: "claude",
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
            "tool_groups": .object(groupIndex.mapValues { names in
                .array(names.map { .string($0) })
            }),
            "lazy_load": .bool(true),
            "session_id": .string(sessionId),
            "dynamic_loading": .string("lazy_per_session"),
            "permission_source": .string("trust/policy.json"),
            "full_mac_active": .bool(access.fullMacActive),
            "permission_level": .string(access.permissionLevel),
            "outside_workspace_default": .string(access.outsideWorkspaceDefault),
            "file_ops_allowed": .bool(access.fileOpsAllowed),
            "system_allowed": .bool(access.systemAllowed),
            "app_control_allowed": .bool(access.appControlAllowed),
            "builder_mode": .string(access.fileOpsAllowed ? "available" : "policy_locked"),
            "builder_mode_detail": .string(access.fileOpsAllowed
                ? "Trust Center Full Mac file access is active. Swift-implemented file/git builder tools, Process-based shell/bash/git/apply_patch/run_tests, fixed-argv swift_build/swift_test, and app lifecycle install/restart tools are all exposed (autonomy-gated)."
                : "write_file is available only inside Trust Center workspace roots; broader file/git builder tools are locked until Trust Center Full Mac mode with file_ops_allowed is active."),
            "trusted_workspace_roots": .array(trustedRoots.map { .string($0.path) }),
            "mac_app_available_tools": .array(availableAppTools.map { .string($0) }),
            "mac_app_policy_locked_tools": .array(lockedAppTools.map { .string($0) }),
            "currently_loaded": .array(currentlyLoaded.map { .string($0) }),
            "turn_active_tools": .array(turnScoped.sorted().map { .string($0) }),
            "discovery_only_tools": .array(discoveryOnly.map { .string($0) }),
            "available_tools": .array(names.map { .string($0) }),
            "builder_available_tools": .array(availableBuilderTools.map { .string($0) }),
            "builder_policy_locked_tools": .array(lockedBuilderTools.map { .string($0) }),
            "builder_bridge_readiness": .object([
                "codex": bridgeReadinessRow(codexBridge),
                "claude_code": bridgeReadinessRow(claudeBridge),
            ]),
            "tools": .array(rows),
        ])
    }

    func impl_tool_load_category(category rawCategory: String, surface: String = "chat") async throws -> JSONValue {
        let category = rawCategory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let available = Set((try? await listAvailableTools()) ?? Self.builtInToolNames)

        func loadedEnvelope(_ names: [String]) -> JSONValue {
            let loaded = names.filter { available.contains($0) }
            return .object([
                "status": .string("ok"),
                "runtime": .string("swift-native"),
                "category": .string(category),
                "loaded": .array(loaded.map { .string($0) }),
                "active_tools": .array(Self.alwaysOnCoreNames.sorted().map { .string($0) }),
            ])
        }

        guard let loadGroup = ToolPreloadHeuristics.loadGroup(forCategory: category) else {
            return .object([
                "status": .string("failed"),
                "reason": .string("unknown_category"),
                "category": .string(category),
                "known_categories": .array(ToolPreloadHeuristics.knownLoadCategories.map { .string($0) }),
            ])
        }
        if loadGroup.group == "builder" {
            let access = await fullMacToolAccess(surface: surface)
            let allBuilder = loadGroup.tools.sorted()
            let loaded = allBuilder.filter { available.contains($0) }
            let unavailable = allBuilder.filter { !available.contains($0) }
            let activeTools = Self.alwaysOnCoreNames
                .union(["write_file"])
                .filter { available.contains($0) || $0 == "write_file" }
                .sorted()
            return .object([
                "status": .string(access.fileOpsAllowed ? "ok" : "partial"),
                "runtime": .string("swift-native"),
                "category": .string(category),
                "builder_mode": .string(access.fileOpsAllowed ? "available" : "policy_locked"),
                "full_mac_active": .bool(access.fullMacActive),
                "file_ops_allowed": .bool(access.fileOpsAllowed),
                "loaded": .array(loaded.map { .string($0) }),
                "unavailable": .array(unavailable.map { .string($0) }),
                "active_tools": .array(activeTools.map { .string($0) }),
            ])
        }
        return loadedEnvelope(loadGroup.tools.sorted())
    }

    func impl_tool_load(input: [String: JSONValue], surface: String = "chat") async throws -> JSONValue {
        let sessionId = Self.extractSessionId(from: input)
        if sessionId.isEmpty {
            if let category = jsonString(input["category"]), !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return try await impl_tool_load_category(category: category, surface: surface)
            }
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_session_id"),
                "fix": .string("Call tool_load with session_id set to your current chat session id."),
            ])
        }

        var requested = Set<String>()
        let requestedCategory = jsonString(input["category"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let category = requestedCategory, !category.isEmpty {
            guard let loadGroup = ToolPreloadHeuristics.loadGroup(forCategory: category) else {
                return .object([
                    "status": .string("failed"),
                    "reason": .string("unknown_category"),
                    "category": .string(category),
                    "known_categories": .array(ToolPreloadHeuristics.knownLoadCategories.map { .string($0) }),
                ])
            }
            requested.formUnion(loadGroup.tools)
        }
        if case .array(let arr) = input["names"] ?? .null {
            for v in arr {
                if let s = jsonString(v)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    requested.insert(s)
                }
            }
        }
        if let single = jsonString(input["name"])?.trimmingCharacters(in: .whitespacesAndNewlines), !single.isEmpty {
            requested.insert(single)
        }

        let allTools = Set((try? await listAvailableTools()) ?? Self.builtInToolNames)
        let existing = await activeToolsStore.load(sessionId: sessionId).activeTools
        let turnScoped = LLMCallContext.turnActiveTools ?? []
        let effectiveExisting = existing.union(turnScoped)

        let validNames = requested.intersection(allTools)
        let notInCatalog = requested.subtracting(allTools).sorted()
        let alreadyActive = validNames.intersection(effectiveExisting).sorted()
        let turnActive = validNames.intersection(turnScoped).sorted()
        let toAdd = validNames.subtracting(effectiveExisting)
        let toAddSorted = toAdd.sorted()

        var newActive = existing
        if !toAdd.isEmpty {
            newActive = (try await activeToolsStore.addLoaded(
                sessionId: sessionId, names: toAdd
            )).activeTools
        }

        var addedSchemas: [JSONValue] = []
        let allSchemas = (try? await listAvailableToolSchemas()) ?? builtInToolSchemas()
        for schema in allSchemas where toAdd.contains(schema.name) {
            var row: [String: JSONValue] = [
                "name": .string(schema.name),
                "description": .string(schema.description),
            ]
            if let parsed = try? JSONValue.parse(schema.parametersJSON) {
                row["parameters"] = parsed
            }
            addedSchemas.append(.object(row))
        }

        return .object([
            "status": .string("loaded"),
            "session_id": .string(sessionId),
            "category": requestedCategory.map { .string($0) } ?? .null,
            "loaded_now": .array(toAddSorted.map { .string($0) }),
            "loaded": .array(validNames.sorted().map { .string($0) }),
            "not_in_catalog": .array(notInCatalog.map { .string($0) }),
            "unavailable": .array(notInCatalog.map { .string($0) }),
            "already_active": .array(alreadyActive.map { .string($0) }),
            "turn_active": .array(turnActive.map { .string($0) }),
            "session_active_count": .int(Int64(newActive.count)),
            "schemas_added": .array(addedSchemas),
            "next_turn_note": .string(toAdd.isEmpty && !turnActive.isEmpty
                ? "Requested schemas are already available for this turn; no session loadout changed."
                : "Newly loaded schemas will be available in your next response's tool list."),
        ])
    }

    func impl_tool_unload(input: [String: JSONValue], surface: String = "chat") async throws -> JSONValue {
        let sessionId = Self.extractSessionId(from: input)
        if sessionId.isEmpty {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_session_id"),
                "fix": .string("Call tool_unload with session_id set to your current chat session id."),
            ])
        }
        let dropAll: Bool = {
            if case .bool(let b) = input["all"] ?? .null { return b }
            return false
        }()
        var names = Set<String>()
        if case .array(let arr) = input["names"] ?? .null {
            for v in arr {
                if let s = jsonString(v)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    names.insert(s)
                }
            }
        }
        let before = await activeToolsStore.load(sessionId: sessionId).activeTools
        let after = try await activeToolsStore.removeLoaded(
            sessionId: sessionId, names: names, all: dropAll
        ).activeTools
        let dropped = before.subtracting(after).sorted()
        return .object([
            "status": .string("unloaded"),
            "session_id": .string(sessionId),
            "dropped": .array(dropped.map { .string($0) }),
            "session_active_remaining_count": .int(Int64(after.count)),
        ])
    }
}
