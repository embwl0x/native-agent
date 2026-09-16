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
        let selection = Self.catalogCategorySelection(input["category"])
        if let error = selection.error { return error }
        let group = selection.category.flatMap { ToolPreloadHeuristics.loadGroup(forCategory: $0) }
        if let category = selection.category, group == nil {
            return .object([
                "status": .string("failed"), "reason": .string("unknown_category"),
                "category": .string(category),
                "known_categories": .array(ToolPreloadHeuristics.knownLoadCategories.map(JSONValue.string)),
                "fix": .string("Choose a category from known_categories or omit category to browse all tools."),
            ])
        }
        let fullDetail = jsonString(input["detail"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "full"
        let access = await fullMacToolAccess(surface: surface)
        let availableNames = await modelVisibleToolNames()
        let names = availableNames.filter { group?.tools.contains($0) ?? true }.sorted()
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
        let modelVisibleTurnScoped = Self.modelVisibleCatalogToolNames(turnScoped)
        let activeForTurn = sessionActive.union(turnScoped)
        let nameSet = Set(names)
        let mcpNameSet = Set(modelVisibleMCPToolNames())
        // gpt-5.5 review-2 NEEDS_FIX 4: MCP tools ARE always available in
        // tools[] (the bridge always includes mcpToolSchemas). So they
        // belong in currentlyLoaded too — otherwise the description's
        // "tools not in currentlyLoaded are not in your current tools[]
        // array" claim is false for MCP tools and misleads the LLM.
        let modelNameSet = Self.modelVisibleCatalogToolNames(nameSet)
        let currentlyLoaded = Self.normalModelToolNames(activeTools: activeForTurn)
            .union(mcpNameSet)
            .intersection(modelNameSet)
            .sorted()
        let discoveryOnly = modelNameSet
            .subtracting(Self.alwaysOnCoreNames)
            .subtracting(activeForTurn)
            .subtracting(mcpNameSet)
            .sorted()
        let loadedSet = Set(currentlyLoaded)
        // Intention-based discovery. Compact discovery answers "what is there";
        // a caller who knows what they want to accomplish but not this
        // implementation's vocabulary was left guessing names or paying for a
        // full-schema dump. `query` searches names, descriptions and group
        // names and returns a few one-line rows — no schemas, so the lazy
        // contract in docs/TOOL_LOADING.md is unchanged: loading stays explicit.
        if let rawQuery = jsonString(input["query"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawQuery.isEmpty {
            let limit = max(1, min(jsonInt(input["limit"]) ?? 10, 25))
            let groupIndex = ToolPreloadHeuristics.groupIndex(availableToolNames: Set(names))
            var groupsByTool: [String: [String]] = [:]
            for (group, members) in groupIndex {
                for member in members { groupsByTool[member, default: []].append(group) }
            }
            let searchSchemas = ((try? await listAvailableToolSchemas()) ?? builtInToolSchemas())
                .filter { modelNameSet.contains($0.name) }
            let needles = Self.catalogSearchNeedles(rawQuery)
            func score(_ schema: LLMToolSchema) -> Int {
                Self.catalogSearchScore(
                    name: schema.name,
                    description: schema.description,
                    groups: groupsByTool[schema.name] ?? [],
                    needles: needles, query: rawQuery
                )
            }
            var ranked: [(schema: LLMToolSchema, score: Int)] = []
            for schema in searchSchemas {
                let total = score(schema)
                if total > 0 { ranked.append((schema: schema, score: total)) }
            }
            ranked.sort { left, right in
                left.score == right.score ? left.schema.name < right.schema.name : left.score > right.score
            }
            let matchCount = ranked.count
            let bestScore = ranked.first?.score ?? 0
            ranked.removeAll { !Self.catalogSearchIsShortlisted(score: $0.score, bestScore: bestScore) }
            // Agent, 2026-09-13: `truncated: true` on five of nineteen matches
            // read as a CUT PAYLOAD — as though rows were missing from the
            // answer. Five of nineteen is a limit honoured, not damage, and
            // `match_count` + `shown` say that plainly. `truncated` is kept for
            // the one thing it can honestly mean: a line that was shortened.
            var lineWasCut = false
            let matches: [JSONValue] = ranked.prefix(limit).map { hit -> JSONValue in
                // One line, capped: enough to choose a tool, never a schema.
                let firstLine = hit.schema.description
                    .split(whereSeparator: { $0.isNewline })
                    .first.map(String.init) ?? hit.schema.description
                if firstLine.count > 180 || firstLine.count < hit.schema.description.count {
                    lineWasCut = true
                }
                let summary = firstLine.count > 180
                    ? String(firstLine.prefix(180)) + "…"
                    : firstLine
                var row: [String: JSONValue] = [
                    "name": .string(hit.schema.name),
                    "description": .string(summary),
                    "load_state": .string(loadedSet.contains(hit.schema.name) ? "loaded" : "discovery_only"),
                    // The score travels with the row so the app wrapper can
                    // merge its own app-owned matches into ONE ranking without
                    // rescoring a description this row already truncated.
                    "match_score": .int(Int64(hit.score)),
                ]
                if let groups = groupsByTool[hit.schema.name], !groups.isEmpty {
                    row["groups"] = .array(groups.sorted().map { .string($0) })
                }
                return .object(row)
            }
            // A ready best match is already a complete discovery answer.
            // Do not manufacture extra loads from lower-ranked alternatives.
            let unloaded = ranked.prefix(limit).filter {
                $0.score == bestScore && !loadedSet.contains($0.schema.name)
            }.map { $0.schema.name }
            var envelope: [String: JSONValue] = [:]
            envelope["status"] = .string("ok")
            envelope["runtime"] = .string("swift-native")
            envelope["catalog_detail"] = .string("search")
            if let group {
                envelope["category"] = .string(group.group)
                envelope["category_available_count"] = .int(Int64(modelNameSet.count))
            }
            envelope["query"] = .string(rawQuery)
            envelope["limit"] = .int(Int64(limit))
            envelope["session_id"] = .string(sessionId)
            envelope["match_count"] = .int(Int64(matchCount))
            envelope["shortlist_omitted"] = .int(Int64(matchCount - matches.count))
            envelope["shown"] = .int(Int64(matches.count))
            envelope["truncated"] = .bool(lineWasCut)
            envelope["matches"] = .array(matches)
            if !unloaded.isEmpty {
                let names: [JSONValue] = unloaded.map { JSONValue.string($0) }
                envelope["load_next"] = .object([
                    "tool": .string("tool_load"),
                    "session_id": .string(sessionId),
                    "names": .array(names),
                ])
            }
            envelope["note"] = .string("Search returns a relevance shortlist capped by limit, not an availability inventory. match_count includes all lexical matches; shortlist_omitted includes weaker and over-limit matches. load_next suggests only unloaded best matches. Omit query for the full compact catalog.")
            return .object(envelope)
        }
        let rows: [JSONValue] = schemas.filter { modelNameSet.contains($0.name) }.map { schema in
            var row: [String: JSONValue] = [
                "name": .string(schema.name),
                "description": .string(schema.description),
                "dispatchable_via": .string("swift_tool_dispatcher"),
                "load_state": .string(loadedSet.contains(schema.name) ? "loaded" : "discovery_only"),
            ]
            if Self.skillReaderToolNames.contains(schema.name) {
                row["tags"] = .array([.string("skill_reader")])
            }
            // A registry-owned bucket makes the rendered catalog reflect the
            // dispatch table rather than a second UI-only name list. An
            // unreviewed runtime name is never fabricated as a safe category;
            // the mounted Tools UI renders that adverse condition explicitly.
            row["catalog_bucket"] = .string(
                (schema.name.hasPrefix("mcp__") ? ChatToolCatalogBucket.mcp : Self.catalogBucket(forRegisteredToolNamed: schema.name))?.rawValue
                    ?? ChatToolCatalogBucket.unclassified.rawValue
            )
            if let parameters = try? JSONValue.parse(schema.parametersJSON) {
                row["parameters"] = parameters
            }
            return .object(row)
        }
        if let group {
            return .object([
                "status": .string("ok"), "runtime": .string("swift-native"),
                "catalog_detail": .string(fullDetail ? "full" : "compact"),
                "category": .string(group.group),
                "category_available_count": .int(Int64(modelNameSet.count)),
                "session_id": .string(sessionId), "lazy_load": .bool(true),
                "available_tools": .array(modelNameSet.sorted().map(JSONValue.string)),
                "currently_loaded": .array(currentlyLoaded.map(JSONValue.string)),
                "discovery_only_tools": .array(discoveryOnly.map(JSONValue.string)),
                "turn_active_tools": .array(modelVisibleTurnScoped.intersection(modelNameSet).sorted().map(JSONValue.string)),
                "tool_groups": .object([group.group: .array(modelNameSet.sorted().map(JSONValue.string))]),
                "tools": .array(rows),
                "note": .string("Only currently catalog-visible members of this tool_load category are shown. Omitted tools may exist in other categories; no tools were loaded."),
            ])
        }
        let swiftBuilderTools = (Self.fullMacFileToolNames + Self.fullMacSystemToolNames + Self.fullMacBuilderToolNames + Self.fullMacRestartToolNames).sorted()
        let availableBuilderTools = swiftBuilderTools.filter { names.contains($0) }
        let lockedBuilderTools = swiftBuilderTools.filter { !names.contains($0) }
        // mac_focus_app/mac_quit_app remain internal compatibility routes, not
        // conversational model tools. These legacy fields must obey the same
        // model-visible set as available_tools or they contradict the schemas.
        let availableAppTools = Self.fullMacAppToolNames.sorted().filter { modelNameSet.contains($0) }
        let lockedAppTools = Self.fullMacAppToolNames.sorted().filter {
            modelNameSet.contains($0) && !names.contains($0)
        }
        // These summary arrays are model-facing discovery just like
        // `available_tools`. Keep them on the same four-verb cutover boundary:
        // the underlying mac_* organs remain callable by direct diagnostics,
        // but a conversational catalog must never advertise one that
        // `tool_load` intentionally rejects as internal-only.
        let axReadTools = Self.fullMacAccessibilityReadToolNames
            .filter { modelNameSet.contains($0) }
            .sorted()
        let availableAXReadTools = axReadTools.filter { names.contains($0) }
        let lockedAXReadTools = axReadTools.filter { !names.contains($0) }
        let nudgeTools = Self.fullMacNudgeToolNames
            .filter { modelNameSet.contains($0) }
            .sorted()
        let availableNudgeTools = nudgeTools.filter { names.contains($0) }
        let lockedNudgeTools = nudgeTools.filter { !names.contains($0) }
        // W7 — activity_query. Reported in the discovery surface like every
        // other gated group, so a model that cannot see the tool can find out
        // WHY (the Trust Center capture toggle is off) instead of concluding
        // the capability does not exist.
        let activityTools = Self.activityQueryToolNames.sorted()
        let availableActivityTools = activityTools.filter { names.contains($0) }
        let lockedActivityTools = activityTools.filter { !names.contains($0) }
        let axActTools = Self.fullMacAccessibilityInjectionToolNames
            .filter { modelNameSet.contains($0) }
            .sorted()
        let availableAXActTools = axActTools.filter { names.contains($0) }
        let lockedAXActTools = axActTools.filter { !names.contains($0) }
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
            // W1b — read-only AX perception, listed separately from app control
            // so the discovery surface does not label reads "app control".
            "mac_accessibility_read_available_tools": .array(availableAXReadTools.map { .string($0) }),
            "mac_accessibility_read_policy_locked_tools": .array(lockedAXReadTools.map { .string($0) }),
            // W7 — mac_nudge, listed apart from both again: it posts an event
            // (so it is not a read) but only a bare move (so it is not an act
            // the way the four below are), and the discovery surface should
            // say so rather than let it borrow either label.
            "mac_nudge_available_tools": .array(availableNudgeTools.map { .string($0) }),
            "mac_nudge_policy_locked_tools": .array(lockedNudgeTools.map { .string($0) }),
            // W2/W3 — listed apart from BOTH the reads and app control, so the
            // discovery surface never lets an injection tool look like a read.
            "activity_available_tools": .array(availableActivityTools.map { .string($0) }),
            "activity_policy_locked_tools": .array(lockedActivityTools.map { .string($0) }),
            "mac_accessibility_act_available_tools": .array(availableAXActTools.map { .string($0) }),
            "mac_accessibility_act_policy_locked_tools": .array(lockedAXActTools.map { .string($0) }),
            "currently_loaded": .array(currentlyLoaded.map { .string($0) }),
            "turn_active_tools": .array(modelVisibleTurnScoped.sorted().map { .string($0) }),
            "discovery_only_tools": .array(discoveryOnly.map { .string($0) }),
            "available_tools": .array(modelNameSet.sorted().map { .string($0) }),
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
                "status": .string("preview"),
                "runtime": .string("swift-native"),
                "category": .string(category),
                "available": .array(loaded.map { .string($0) }),
                "loaded": .array([]),
                "mode": .string("sessionless_preview"),
                "reason": .string("missing_session_id"),
                "fix": .string("Call tool_load with session_id set to your current chat session id. No tools were loaded."),
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
                "status": .string("preview"),
                "runtime": .string("swift-native"),
                "category": .string(category),
                "builder_mode": .string(access.fileOpsAllowed ? "available" : "policy_locked"),
                "full_mac_active": .bool(access.fullMacActive),
                "file_ops_allowed": .bool(access.fileOpsAllowed),
                "available": .array(loaded.map { .string($0) }),
                "loaded": .array([]),
                "mode": .string("sessionless_preview"),
                "reason": .string("missing_session_id"),
                "fix": .string("Call tool_load with session_id set to your current chat session id. No tools were loaded."),
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

        guard !requested.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_tool_selection"),
                "fix": .string("Call tool_load with names, name, or category from tool_catalog."),
            ])
        }

        let allTools = Set((try? await listAvailableTools()) ?? Self.builtInToolNames)
            .subtracting(Self.legacyMacModelToolNames)
        var sessionState = await activeToolsStore.load(sessionId: sessionId)
        let existing = sessionState.activeTools
        let turnScoped = LLMCallContext.turnActiveTools ?? []
        let effectiveExisting = existing.union(turnScoped)
        // A tool unloaded earlier in THIS turn is being asked for again. It is
        // still in the turn-start set, so without this it would be treated as
        // already available: neither persisted nor returned as a schema, and
        // gone again next turn while the receipt said "loaded". One call brings
        // it back (docs/TOOL_LOADING.md), so it is persisted and reported new.
        let unloadedThisTurn = await activeToolsStore.turnUnloadedNames(sessionId: sessionId)

        // `mac.look` → `mac_look`: the registry id and the catalog name are one
        // tool (see SwiftToolDispatcher.canonicalToolName). Report what was
        // aliased so the caller learns the catalog spelling.
        var aliased: [String: JSONValue] = [:]
        let canonicalRequested = Set(requested.map { name -> String in
            let canonical = Self.canonicalToolName(name) { allTools.contains($0) }
            if canonical != name { aliased[name] = .string(canonical) }
            return canonical
        })
        requested = canonicalRequested

        let allSchemas = (try? await listAvailableToolSchemas()) ?? builtInToolSchemas()
        // Registry discovery deliberately includes inactive names. Loading is
        // narrower: without a current active schema there is nothing to offer
        // the model. Keep built-in and MCP readiness/authority unchanged.
        let customRegistryNames = Set(readRegistryNames().filter {
            !Self.reservedBuiltInNames.contains($0) && !$0.hasPrefix("mcp__")
        })
        let schemaNames = Set(allSchemas.map(\.name))
        let registryUnavailable = requested.intersection(customRegistryNames).subtracting(schemaNames)
        let validNames = requested.intersection(allTools).subtracting(registryUnavailable)
        let notInCatalog = requested.subtracting(allTools).sorted()
        let revived = validNames.intersection(unloadedThisTurn)
        let alreadyActive = validNames.intersection(effectiveExisting).subtracting(revived).sorted()
        let turnActive = validNames.intersection(turnScoped).subtracting(revived).sorted()
        let toAdd = validNames.subtracting(effectiveExisting).union(revived)
        let toAddSorted = toAdd.sorted()

        var newActive = existing
        // The store protects its input set from cap eviction and refreshes
        // its load timestamps. Pass the whole explicit persistent request,
        // not only the delta: otherwise an already-active requested tool can
        // be evicted by the new names while the receipt claims it is loaded.
        // Mechanical turn-only readiness must still never become persistent.
        let toPersist = validNames.subtracting(turnScoped).union(revived)
        if !toPersist.isEmpty {
            // Pin the descriptor this load actually SAW. Without it the slot
            // reaches the next turn start with no pinned schema, and if the
            // tool is missing from that catalog snapshot — a registry/custom
            // tool whose readiness flapped, exactly the case pinning exists
            // for — `commitTurnStartContract` releases the row rather than
            // promise a body it does not have. The contract is the authority
            // now, so a released row is a tool the model was told it loaded
            // and then silently cannot see.
            var descriptors: [String: PinnedToolSchema] = [:]
            for schema in allSchemas
            where toPersist.contains(schema.name) && descriptors[schema.name] == nil {
                descriptors[schema.name] = PinnedToolSchema(schema)
            }
            do {
                sessionState = try await activeToolsStore.addLoaded(
                    sessionId: sessionId, names: toPersist, descriptors: descriptors
                )
            } catch {
                // The session's advertised set is at its hard ceiling and this
                // request cannot be made to fit. Refusing is the contract:
                // exceeding the bound would grow the provider tools array
                // without limit for the rest of the session.
                return .object([
                    "status": .string("refused"),
                    "session_id": .string(sessionId),
                    "reason": .string("offer_limit_reached"),
                    "detail": .string((error as NSError).localizedDescription),
                    "fix": .string("Call tool_unload for tools you no longer need, then retry tool_load."),
                ])
            }
            newActive = sessionState.activeTools
        }
        // Everything the caller VALIDLY named is now explicit, including names
        // that needed no write because this turn's preload had already promoted
        // them (those are subtracted from `toPersist`, so `addLoaded` never saw
        // them and their promoted marker would otherwise stand forever).
        if let reclassified = await activeToolsStore.markExplicitlyRequested(
            sessionId: sessionId, names: validNames
        ) {
            sessionState = reclassified
        }
        // An explicit load is the reload that lifts a current-turn unload: a
        // name unloaded earlier in this turn becomes callable again here, and
        // only here (see `noteTurnUnloaded`).
        await activeToolsStore.clearTurnUnloaded(sessionId: sessionId, names: validNames)

        var addedSchemas: [JSONValue] = []
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

        let readinessNote = registryUnavailable.isEmpty ? (notInCatalog.isEmpty ? "" : "Some requested names are not in the current catalog. Use tool_catalog to select exact available names. ") :
            "Some known registry tools have no active callable schema. Enable or repair them through tool management, then retry tool_load. "
        let loadNote = toAdd.isEmpty
            ? (!turnActive.isEmpty
                ? "Requested schemas are already available for this turn; no session loadout changed."
                : "No new schemas were loaded.")
            : "Newly loaded schemas will be available in your next response's tool list."
        return .object([
            "status": .string(notInCatalog.isEmpty && registryUnavailable.isEmpty ? "loaded" : (validNames.isEmpty ? "unavailable" : "partial")),
            "session_id": .string(sessionId),
            "category": requestedCategory.map { .string($0) } ?? .null,
            "loaded_now": .array(toAddSorted.map { .string($0) }),
            "loaded": .array(validNames.sorted().map { .string($0) }),
            "not_in_catalog": .array(notInCatalog.map { .string($0) }),
            "unavailable": .array(Set(notInCatalog).union(registryUnavailable).sorted().map { .string($0) }),
            "aliased": .object(aliased),
            "already_active": .array(alreadyActive.map { .string($0) }),
            "turn_active": .array(turnActive.map { .string($0) }),
            "session_active_count": .int(Int64(newActive.count)),
            // Where this number came from and when it was last written, so a
            // count that moved without a load or an unload is diagnosable from
            // the receipt alone instead of from the state file on disk.
            "pinned_set_provenance": sessionState.pinnedSetProvenance,
            "schemas_added": .array(addedSchemas),
            "next_turn_note": .string(readinessNote + loadNote),
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
        // The persisted row is gone, but this turn's `turnActiveTools` is a
        // frozen TaskLocal the dispatch gates union in — so an unloaded tool
        // stayed callable until the next turn start. Record the retraction for
        // the rest of THIS turn; `tool_load` is the way back in.
        let turnScoped = LLMCallContext.turnActiveTools ?? []
        let retracted = dropAll ? before.union(turnScoped) : names.union(dropped)
        await activeToolsStore.noteTurnUnloaded(sessionId: sessionId, names: retracted)
        return .object([
            "status": .string("unloaded"),
            "session_id": .string(sessionId),
            "dropped": .array(dropped.map { .string($0) }),
            "session_active_remaining_count": .int(Int64(after.count)),
        ])
    }
}

// MARK: - Catalog search scoring
//
// Shared with the app-side wrapper (AppChatToolDispatcher.toolCatalog), which
// runs the SAME scoring over its app-owned schemas so app tools rank in one
// list with core tools instead of never matching at all.
extension SwiftToolDispatcher {
    /// Optional category parsing shared by the app overlay and core catalog.
    public static func catalogCategorySelection(_ value: JSONValue?) -> (category: String?, error: JSONValue?) {
        switch value {
        case nil, .null: return (nil, nil)
        case .string(let raw):
            let category = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (category.isEmpty ? nil : category, nil)
        default:
            return (nil, .object([
                "status": .string("failed"), "reason": .string("invalid_category"),
                "fix": .string("category must be a tool_load category string, null, or omitted."),
            ]))
        }
    }

    /// Grammatical glue is not discovery evidence. Deduplicate so repeating a
    /// word does not outrank a better capability match.
    public static func catalogSearchNeedles(_ rawQuery: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "the", "and", "or", "in", "on", "at", "by", "to", "of",
            "for", "from", "with", "within", "into", "as", "is", "are", "be",
            "it", "this", "that", "these", "those", "i", "me", "my", "we",
            "you", "your", "can", "could", "would", "please", "how", "using",
        ]
        var seen = Set<String>()
        return catalogSearchTokens(rawQuery).filter {
            $0.count > 1 && !stopwords.contains($0) && seen.insert($0).inserted
        }
    }

    /// Words, splitting a tool name on `_` as well as on punctuation, so
    /// `rewrite_memory` is the two words it is written as.
    private static func catalogSearchTokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Stem overlap, not a synonym table: plural/singular and a shared stem of
    /// four or more characters ("memories"/"memory", "correct"/"corrections").
    private static func catalogSearchTokenMatches(_ token: String, _ needle: String) -> Bool {
        if token == needle { return true }
        func singular(_ word: String) -> String {
            if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
            if word.count > 3, word.hasSuffix("es") { return String(word.dropLast(2)) }
            if word.count > 3, word.hasSuffix("s") { return String(word.dropLast()) }
            return word
        }
        if singular(token) == singular(needle) { return true }
        let shorter = token.count <= needle.count ? token : needle
        let longer = token.count <= needle.count ? needle : token
        return shorter.count >= 4 && longer.hasPrefix(shorter)
    }

    /// Words that name the same OPERATION.
    ///
    /// Agent on the glass, 2026-09-13: "correct a memory" put `list_memories`
    /// first and `rewrite_memory` fifth. Stem overlap cannot fix that — the
    /// word "correct" appears in no tool's name and in no tool's description;
    /// the tool that does the thing says "Replace one memory's text". So the
    /// query's ACTION word is resolved to the handful of words the catalog
    /// uses for that same action, and a tool that performs it outranks a tool
    /// that merely shares a noun with it. Deliberately tiny and about verbs
    /// only: it is not a synonym table for the catalog's nouns.
    private static let catalogActionFamilies: [Set<String>] = [
        ["correct", "fix", "change", "update", "rewrite", "edit", "amend",
         "revise", "replace", "modify", "set"],
        ["delete", "remove", "drop", "forget", "erase", "clear", "discard"],
        ["list", "show", "browse", "walk", "view", "enumerate"],
        ["create", "add", "make", "save", "store", "record", "write", "remember"],
        ["search", "find", "recall", "lookup", "query", "filter"],
        ["read", "inspect", "fetch", "retrieve"],
    ]

    private static func catalogActionFamily(for needle: String) -> Set<String>? {
        catalogActionFamilies.first { family in
            family.contains(where: { catalogSearchTokenMatches($0, needle) })
        }
    }

    /// Keep close alternatives while omitting weak incidental matches when a
    /// better answer exists. Shared by the core result and app-owned merge.
    /// This filters search presentation only, never catalog availability.
    public static func catalogSearchIsShortlisted(score: Int, bestScore: Int) -> Bool {
        score > 0 && score * 4 >= bestScore * 3
    }

    /// One tool's relevance to a query. Scaled by 100 so a description's
    /// per-token weight stays an integer.
    ///
    /// Within lexical matches, names outweigh description mentions; subject
    /// coverage and purpose-action alignment then rank the whole intent.
    /// Description hits are weighted per token (Agent, 2026-09-13: "correct a
    /// memory" ranked `memory_moments_pending` over `rewrite_memory`). A long
    /// description that says "memory" three times among seventy words is not
    /// more about memory than a short one that says it once, and the flat
    /// per-needle credit said it was.
    public static func catalogSearchScore(
        name: String,
        description: String,
        groups: [String],
        needles: [String],
        query: String? = nil
    ) -> Int {
        let lowerName = name.lowercased()
        // A verbatim canonical identifier is selection evidence, not another
        // descriptive keyword. Preserve underscores/hyphens/internal dots so natural words
        // and longer identifiers cannot accidentally name this tool. Scope and
        // availability filtering happen before scoring, never through it.
        if let query {
            let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
            let identifiers = query.lowercased().components(separatedBy: identifierCharacters.inverted)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            if identifiers.contains(lowerName) { return 1_000_000 }
        }
        let nameTokens = catalogSearchTokens(name)
        let descriptionTokens = catalogSearchTokens(description)
        let groupTokens = catalogSearchTokens(groups.joined(separator: " "))
        // Tool descriptions often mention other operations in cautions or
        // recovery advice. The opening purpose sentence says what THIS tool
        // does; later text can supply subject evidence, not its action bonus.
        let purpose = description.components(separatedBy: ". ").first ?? description
        let purposeTokens = catalogSearchTokens(purpose)
        let subjects = needles.filter { catalogActionFamily(for: $0) == nil }
        let subjectHits = subjects.filter { subject in
            (nameTokens + descriptionTokens).contains { catalogSearchTokenMatches($0, subject) }
        }.count
        let purposeSubjectHits = subjects.filter { subject in
            (nameTokens + purposeTokens).contains { catalogSearchTokenMatches($0, subject) }
        }.count
        // A matching verb alone is not evidence of the requested subject:
        // searching Slack does not make it a match for searching local files.
        guard subjects.isEmpty || subjectHits > 0 else { return 0 }
        var hasPurposeAction = false
        var total = 0
        // Agent on the glass, 2026-09-13: "correct a memory" went from 19
        // matches to 66. A group name is a NEIGHBOURHOOD, not a hit — every
        // tool shelved beside a memory tool scored 100 and became a "match".
        // So group credit still ORDERS the results, but it can never make a
        // tool a match on its own: that takes the tool's own name, its own
        // description, or the verb it performs.
        var groupCredit = 0
        var matched = false
        for needle in needles {
            if nameTokens.contains(where: { catalogSearchTokenMatches($0, needle) }) {
                total += 400
                matched = true
            } else if lowerName.contains(needle) {
                total += 200
                matched = true
            }
            let hits = descriptionTokens.filter { catalogSearchTokenMatches($0, needle) }.count
            if hits > 0 {
                total += min(400, max(1, 2_000 * hits / max(descriptionTokens.count, 1)))
                matched = true
            }
            if groupTokens.contains(where: { catalogSearchTokenMatches($0, needle) }) {
                groupCredit += 100
            }
            // DOING the thing asked for beats sharing a noun with it. Both
            // weights sit above the 400 a plain name-token hit earns, so
            // `rewrite_memory` ("Replace one memory's text") clears
            // `list_memories` on "correct a memory" even though neither
            // description contains the word the query used.
            if let family = catalogActionFamily(for: needle) {
                // Stem-matched, like everything else here: a description that
                // says "Updates the memory" carries the same verb as one that
                // says "update", and exact equality would miss it.
                func saysIt(_ tokens: [String]) -> Bool {
                    tokens.contains { token in
                        family.contains { catalogSearchTokenMatches(token, $0) }
                    }
                }
                let inName = saysIt(nameTokens)
                let inDescription = saysIt(purposeTokens)
                hasPurposeAction = hasPurposeAction || inName || inDescription
                if inName {
                    total += 500
                    matched = true
                } else if inDescription {
                    total += 450
                    matched = true
                }
            }
        }
        guard matched else { return 0 }
        // Matching the requested operation and subject outranks tools that
        // only mention the subject. Keep subject-only matches as fallbacks:
        // adjacent capabilities can still be useful for a multi-step task.
        // A capability's own purpose is stronger evidence than a filename or
        // directory mentioned in its output/recovery instructions. Keep those
        // later mentions as lower-ranked fallback evidence, not equal intent.
        let subjectCoverage = subjects.isEmpty ? 0
            : (5_000 * purposeSubjectHits + 1_000 * subjectHits) / subjects.count
        // Reserve the upper tier for exact identifiers, irrespective of the
        // amount of surrounding descriptive language in an unusual query.
        return min(100_000, total + groupCredit + subjectCoverage + (hasPurposeAction ? 2_000 : 0))
    }
}
