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

// MARK: - Persona and runtime introspection tools

extension SwiftToolDispatcher {
    func impl_get_persona_doc(input: [String: JSONValue]) async throws -> JSONValue {
        let doc = try requireString(input, "doc")
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
        guard let target = personaToolPath(kind: kind, skillName: skillName) else {
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
        let availableTools = Set(await modelVisibleToolNames())
        let mcpTools = modelVisibleMCPToolNames().sorted()
        let sessionId = Self.extractSessionId(from: input)
        let sessionTools: Set<String> = sessionId.isEmpty
            ? []
            : await activeToolsStore.load(sessionId: sessionId).activeTools
        let activeTools = Self.alwaysOnCoreNames
            .union(sessionTools)
            .union(LLMCallContext.turnActiveTools ?? [])
            .union(mcpTools)
            .intersection(availableTools)
            .sorted()
        let personaRoot = personaRootForTools()
        let trustedRoots = await trustedWorkspaceRoots()
        let pid = ProcessInfo.processInfo.processIdentifier
        let provider = await Self.providerStamp(dataRoot: dataRoot)
        return .object([
            "status": .string("ok"),
            "invoked_as": .string(invokedAs),
            "runtime": .string("swift-native"),
            "python_daemon": .string("retired"),
            "provider": provider,
            "dispatch": .object([
                "provider_tools_field": .bool(true),
                "tool_loop": .string("SwiftNativeTurnEngine.executeTurnWithToolLoop"),
                "dispatcher": .string("SwiftToolDispatcher"),
            ]),
            "session_id": .string("swift-native-\(pid)"),
            "process_id": .int(Int64(pid)),
            "data_root": .string(dataRoot.path),
            "persona_root": .string(personaRoot.path),
            "read_root": .string(rootForRead.path),
            "trusted_workspace_roots": .array(trustedRoots.map { .string($0.path) }),
            "active_tools": .array(activeTools.map { .string($0) }),
            "active_tool_count": .int(Int64(activeTools.count)),
            "available_tool_count": .int(Int64(availableTools.count)),
            "lazy_loading": .string("available tools omitted; use tool_catalog to discover and tool_load to activate"),
            "mcp_tool_count": .int(Int64(mcpTools.count)),
            "mcp_tools": .array(mcpTools.map { .string($0) }),
            "compatibility": .object([
                "daemon_introspect": .string("alias_for_agent_introspect"),
                "recall_search": .string("alias_for_recall_memory"),
            ]),
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
            // Report a SELF-CONSISTENT pair: the live turn model and the provider
            // inferred from that SAME model. Do NOT cross it with active.json's
            // provider — under a mixed config (surface requests model X but the
            // active provider serves model Y) that produces a contradictory stamp
            // like {model: gpt-5.5, name: anthropic_oauth_direct}. The active
            // provider is reported separately as `surface_active_provider` so the
            // agent can SEE a config divergence rather than be lied to.
            let surfaceActiveProvider = await router.activeProvidersForSurfaces()[turn.surface]
            return .object([
                "name": .string(router.inferProviderForModel(turn.model) ?? surfaceActiveProvider ?? "unknown"),
                "model": .string(turn.model),
                "surface": .string(turn.surface),
                "surface_active_provider": surfaceActiveProvider.map { JSONValue.string($0) } ?? .null,
                "source": .string("live_turn"),
            ])
        }
        // Outside a turn there is no turn model in play; report the chat-surface
        // configured model as the best available answer.
        if let pref = try? await router.modelForSurface("chat"), !pref.model.isEmpty {
            let surfaceActiveProvider = await router.activeProvidersForSurfaces()["chat"]
            return .object([
                "name": .string(router.inferProviderForModel(pref.model) ?? surfaceActiveProvider ?? "unknown"),
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
