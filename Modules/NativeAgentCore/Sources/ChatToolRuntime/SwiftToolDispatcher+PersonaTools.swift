import Foundation
import ToolRegistry
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

// MARK: - Persona and runtime introspection tools

extension SwiftToolDispatcher {
    func impl_get_persona_doc(input: [String: JSONValue]) async throws -> JSONValue {
        // 2026-09-22: persona_read/write/append take `kind`; accept it here too.
        let doc = try requireString(input, input["doc"] == nil && input["kind"] != nil ? "kind" : "doc")
        // Reject path-traversal characters.
        if doc.contains("/") || doc.contains("..") || doc.hasPrefix(".") {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: invalid persona doc name '\(doc)'"
            )
        }
        let docName = doc.hasSuffix(".md") ? doc : "\(doc).md"
        // CANONICAL persona doc path = <personaRoot>/<doc>.md.
        // PersonaRootResolver.resolve() is the single source of truth for
        // where the canonical persona docs live (mirrors PersonaCompiler's
        // `readDoc(root:, id:)` at line 306 of PersonaEngine+Compiler.swift —
        // PersonaCompiler treats this exact path as the authoritative doc.)
        // The per-persona subdir <root>/<name>/<doc>.md is an OVERRIDE for
        // multi-persona setups, NOT a fallback — exposing it via this tool
        // would conflate "read THE doc" with "read someone's customization
        // of the doc" and turn callers into path-fiddlers. If a future
        // multi-persona override surface is needed, that's its own tool
        // (get_persona_override or similar).
        let personaRoot = personaRootForTools()
        let rootPath = personaRoot.resolvingSymlinksInPath().path
        let url = personaRoot
            .appendingPathComponent(docName)
            .resolvingSymlinksInPath()
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: persona path escapes personaRoot ('\(docName)')"
            )
        }
        guard let bytes = try? Data(contentsOf: url),
              let text = String(data: bytes, encoding: .utf8) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: persona doc not found at '\(url.path)'"
            )
        }
        if bytes.count > Self.maxFileBytes {
            let head = bytes.prefix(Self.maxFileBytes)
            let headText = String(data: head, encoding: .utf8) ?? text
            return .string(headText + "\n... [truncated, \(bytes.count) bytes total]")
        }
        return .string(text)
    }

    func impl_persona_read(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = canonicalPersonaKind(try requireString(input, "kind"))
        let allowedKinds: Set<String> = ["soul", "user", "voice", "growth", "agents", "skill"]
        guard allowedKinds.contains(kind) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher persona_read kind must be one of: \(allowedKinds.sorted().joined(separator: ", "))"
            )
        }
        let skillName = optionalString(input, "skill_name")
        if kind == "skill" && skillName == nil {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher persona_read requires skill_name when kind=skill"
            )
        }
        if let skillName, !validatePersonaSkillName(skillName) {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher persona_read invalid skill_name '\(skillName)'"
            )
        }
        guard let target = try personaToolPath(kind: kind, skillName: skillName) else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher persona_read could not resolve persona path")
        }
        guard let bytes = try? Data(contentsOf: target),
              let content = String(data: bytes, encoding: .utf8) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher persona_read doc not found at '\(target.path)'"
            )
        }
        return .object([
            "ok": .bool(true),
            "status": .string("ok"),
            "kind": .string(kind),
            "path": .string(target.path),
            "content": .string(content),
            "size_bytes": .int(Int64(bytes.count)),
        ])
    }

    func impl_persona_write(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try requireString(input, "kind")
        let content = try requireString(input, "content")
        let engine = SwiftNativePersonaEngine(root: personaRootForTools(), dataRoot: dataRoot)
        do {
            let result = try await engine.personaWrite(
                kind: kind,
                content: content,
                skillName: optionalString(input, "skill_name")
            )
            return personaWriteResultJSON(result)
        } catch {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher persona_write failed: \(error.localizedDescription)"
            )
        }
    }

    func impl_persona_append_section(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try requireString(input, "kind")
        let title = try requireString(input, "title")
        let content = try requireString(input, "content")
        let engine = SwiftNativePersonaEngine(root: personaRootForTools(), dataRoot: dataRoot)
        do {
            let result = try await engine.personaAppendSection(
                kind: kind,
                title: title,
                content: content
            )
            return personaWriteResultJSON(result)
        } catch {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher persona_append_section failed: \(error.localizedDescription)"
            )
        }
    }

    func impl_agent_introspect(input: [String: JSONValue], invokedAs: String) async throws -> JSONValue {
        let sessionId = Self.extractSessionId(from: input)
        let fullDetail = (jsonString(input["detail"]) ?? "compact")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "full"
        let pid = ProcessInfo.processInfo.processIdentifier
        let provider = await Self.providerStamp(dataRoot: dataRoot)
        let runtimeInstanceID = "swift-native-\(pid)"
        var response: [String: JSONValue] = [
            "status": .string("ok"),
            "detail": .string(fullDetail ? "full" : "compact"),
            "invoked_as": .string(invokedAs),
            "runtime": .string("swift-native"),
            "python_daemon": .string("retired"),
            "provider": provider,
            "dispatch": .object([
                "provider_tools_field": .bool(true),
                "tool_loop": .string("SwiftNativeTurnEngine.executeTurnWithToolLoop"),
                "dispatcher": .string("SwiftToolDispatcher"),
            ]),
            "runtime_instance_id": .string(runtimeInstanceID),
            "process_id": .int(Int64(pid)),
            "tool_state": .string("app is your one tool; app {find} finds an action by what you want done. Request detail=full for diagnostic roots, MCP names, and outcome population health"),
        ]
        if !sessionId.isEmpty {
            // session_id stays as a compatibility alias, but now names the
            // same authoritative conversation scope used by traces,
            // scratchpads, and lazy tool activation. The process-scoped
            // identity is separate above and must never masquerade as chat.
            response["conversation_session_id"] = .string(sessionId)
            response["session_id"] = .string(sessionId)
        }
        guard fullDetail else { return .object(response) }

        let availableTools = Set(try await modelVisibleToolNames())
        let mcpTools = modelVisibleMCPToolNames().sorted()
        let modelVisibleAvailableTools = Self.modelVisibleCatalogToolNames(availableTools)
        let activeTools = Self.alwaysOnCoreNames
            .union(LLMCallContext.turnActiveTools ?? [])
            .intersection(modelVisibleAvailableTools)
            .sorted()
        let personaRoot = personaRootForTools()
        let trustedRoots = await trustedWorkspaceRoots()
        let outcomeDimensionHealth: JSONValue
        do {
            let audit = try await OutcomeDimensionStatePopulationReader(
                dataRoot: dataRoot,
                since: Calendar.current.date(byAdding: .day, value: -7, to: Date())
            ).read()
            outcomeDimensionHealth = audit.jsonValue
        } catch {
            outcomeDimensionHealth = .object([
                "status": .string("unavailable"),
                "absent_is_zero": .bool(false),
                "error_class": .string(String(describing: type(of: error))),
            ])
        }
        response["outcome_dimension_health"] = outcomeDimensionHealth
        response["data_root"] = .string(dataRoot.path)
        response["persona_root"] = .string(personaRoot.path)
        response["read_root"] = .string(rootForRead.path)
        response["trusted_workspace_roots"] = .array(trustedRoots.map { .string($0.path) })
        response["active_tools"] = .array(activeTools.map { .string($0) })
        response["active_tool_count"] = .int(Int64(activeTools.count))
        response["available_tool_count"] = .int(Int64(modelVisibleAvailableTools.count))
        response["tool_count_semantics"] = .object([
            "active_tool_count": .string("Tools advertised to the model this turn: always-on core + turn-scoped, intersected with the model-visible catalog."),
            "available_tool_count": .string("Every model-visible tool in the catalog, loaded or not."),
            "mcp_tool_count": .string("External MCP servers' tools, each an app action mcp.<server>.<tool> (not in active_tool_count)."),
        ])
        response["discovery"] = .string("every capability is an app action: app {} is home and the pages, app {find} finds an action")
        response["mcp_tool_count"] = .int(Int64(mcpTools.count))
        response["mcp_tools"] = .array(mcpTools.map { .string(ToolNameAliases.appAction($0) ?? $0) })
        response["compatibility"] = .object([
            "daemon_introspect": .string("alias_for_agent_introspect"),
            "recall_search": .string("alias_for_recall_memory"),
        ])
        response["build"] = Self.buildStamp(identity: .current, pid: pid)
        return .object(response)
    }

    /// Which binary is answering this turn. Full detail only — the compact
    /// payload stays free of build mass on ordinary turns.
    ///
    /// Reads `NativeAgentBuildIdentity`, the SAME type the local bridge's
    /// `buildIdentity` payload reports, so an in-turn answer and an
    /// out-of-band bridge read can never name different binaries.
    /// `exactSourceRevision` is null on a dirty or unstamped build: absence is
    /// the honest answer, never a bare `sourceRevision` promoted to proof.
    static func buildStamp(identity: NativeAgentBuildIdentity, pid: Int32) -> JSONValue {
        .object([
            "version": .string(identity.version),
            "exactSourceRevision": identity.exactSourceRevision.map(JSONValue.string) ?? .null,
            "sourceDirty": .bool(identity.sourceDirty),
            "pid": .int(Int64(pid)),
        ])
    }

    /// The provider+model actually generating the current turn (live), or the
    /// surface's configured model when introspect runs outside a turn. Answers
    /// Agent's "which model is running me right now" — the live turn model can
    /// differ from the configured one on a per-turn override. `source` tells the
    /// agent which it got: live_turn / configured / unresolved.
    static func providerStamp(dataRoot: URL) async -> JSONValue {
        let router = SwiftNativeProviderRouting(
            dataRoot: dataRoot,
            surfacesPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("active.json")
        )
        if let turn = ChatTurnRuntimeContext.current,
           !turn.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Report the exact transport admitted with this turn. Model-family
            // inference cannot distinguish API-key, OAuth-direct, Codex, or an
            // OpenRouter route serving the same upstream model.
            let snapshot = try? await router.checkedRoutingSnapshot()
            let surfaceActiveProvider = snapshot.flatMap {
                ProviderRoutingSurfaceLookup.value($0.activeProviders, turn.surface)
            }
            return .object([
                "name": .string(
                    turn.providerID
                        ?? router.inferProviderForModel(turn.model)
                        ?? surfaceActiveProvider
                        ?? "unknown"
                ),
                "model": .string(turn.model),
                "surface": .string(turn.surface),
                "surface_active_provider": surfaceActiveProvider.map { JSONValue.string($0) } ?? .null,
                "source": .string("live_turn"),
            ])
        }
        // Outside a turn there is no turn model in play; report the chat-surface
        // configured model as the best available answer.
        if let snapshot = try? await router.checkedRoutingSnapshot(),
           let pref = ProviderRoutingSurfaceLookup.value(snapshot.preferences, "chat")
                ?? snapshot.preferences["chat"],
           !pref.model.isEmpty {
            let surfaceActiveProvider = ProviderRoutingSurfaceLookup.value(
                snapshot.activeProviders,
                "chat"
            )
            return .object([
                "name": .string(surfaceActiveProvider ?? router.inferProviderForModel(pref.model) ?? "unknown"),
                "model": .string(pref.model),
                "surface": .string("chat"),
                "surface_active_provider": surfaceActiveProvider.map { JSONValue.string($0) } ?? .null,
                "source": .string("configured"),
            ])
        }
        return .object([
            "name": .string("unknown"),
            "model": .null,
            "source": .string("unresolved"),
        ])
    }
}
