import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import Cognition

// FIX: per-element wrapper used by NativeClient.getList for lossy array decode.
// Captures the decode result of a single array element so a malformed element
// is dropped (and logged) instead of throwing the whole array.

extension NativeClient {
    func _swiftDispatch(
        tool: String,
        input: [String: Any],
        sessionId: String?
    ) async throws -> DispatchResult {
        let raw = try JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed])
        let parsed = try JSONValue.parse(raw)
        guard case .object(let obj) = parsed else {
            var body: [String: Any] = [
                "tool": tool, "input": input, "surface": "chat", "dry_run": false,
            ]
            if let sid = sessionId { body["session_id"] = sid }
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            return try await _dispatchMissingNativeHandler(bodyData: bodyData)
        }
        // Build the Swift-native dispatcher registry. Unknown tools fail closed
        // inside SwiftNativeDispatcher with `native_handler_missing`; there is no
        // daemon or HTTP fallback.
        var flipHandlers: [String: ConnectorActionHandler] = [:]
        var flipSideEffecting: Set<String> = []
        var flipTrivialVerify: Set<String> = []
        // The action flips (persona_read, workspace_list, time_now,
        // persona_list_skills, read_file, file_excerpt, system_info) were once
        // each gated behind their own rollout flag. All seven shipped ON and the
        // flags were retired, so the registries now merge unconditionally. The
        // merge is a union: every registry is disjoint from the others, so
        // ordering is immaterial and nothing clobbers. `system_info` consumes no
        // file_access sandbox state (no path input, no allowedRoots check),
        // unlike the read_file / file_excerpt flips.
        func mergeFlipRegistry(_ reg: LocalConnectorActions) {
            for name in reg.toolNames {
                flipHandlers[name] = { input, ctx in reg.run(name, input: input, ctx: ctx) ?? .null }
                if reg.isSideEffecting(name) { flipSideEffecting.insert(name) }
                if reg.isTrivialVerify(name) { flipTrivialVerify.insert(name) }
            }
        }
        mergeFlipRegistry(LocalConnectorActions.personaReadOnly)
        mergeFlipRegistry(LocalConnectorActions.workspaceListReadOnly)
        mergeFlipRegistry(LocalConnectorActions.timeNowReadOnly)
        mergeFlipRegistry(LocalConnectorActions.personaListSkillsReadOnly)
        mergeFlipRegistry(LocalConnectorActions.readFileReadOnly)
        mergeFlipRegistry(LocalConnectorActions.fileExcerptReadOnly)
        mergeFlipRegistry(LocalConnectorActions.systemInfoReadOnly)
        let localActions: LocalConnectorActions? = flipHandlers.isEmpty
            ? nil
            : LocalConnectorActions(
                handlers: flipHandlers,
                sideEffecting: flipSideEffecting,
                trivialVerify: flipTrivialVerify)
        let dispatcher = makeDispatcher(localActions: localActions)
        // WAVE 41 W02 (§6.220-rd2 #2) — SECURITY WIRING fix for the read_file /
        // file_excerpt flips. The prior `DispatchContext.defaultForSurface("chat")`
        // shipped an EMPTY `repoRoot` and EMPTY `extra`, so when either flip was ON
        // `FileSystemActions.allowedRoots(ctx)` returned `[]` and the sandbox guard
        // (`!allowed.isEmpty && !isWithinRoots(...)` in FileSystemActions.readFile /
        // .fileExcerpt) was BYPASSED — an absolute path like `/etc/passwd` resolved,
        // skipped the empty-allowed-roots check, fell outside the data root so the
        // sensitive-path block didn't fire, and was READ. The seam was thus a
        // sandbox-escape the instant either flag flipped ON.
        //
        // The sandbox-engaging context uses a validated repo root and a READ-ONLY
        // `file_access` envelope so read tools never run against an empty or
        // overbroad allowed-root set.
        //
        // WAVE 42 W01 (§6.260) — REOPEN of §6.240-rd2 #1. The §6.220-rd2 #2 fix
        // computed the sandbox need as FLAG-SET-scoped (ON if EITHER file flag was
        // ON) and applied the resulting `ctx` to WHATEVER `tool` this call
        // dispatched. So a `persona_read` / `workspace_list` / `time_now` /
        // `persona_list_skills` / `system_info` dispatch got the sandbox-engaging
        // context whenever a file flag was ON — flipping the non-file actions'
        // persona root from `defaultPersonaRoot()` (`<repo>/persona`) to the
        // `<dataRoot>/memory` legacy fallback (they derive persona root from
        // `_na_data_root` only in test mode), a behavior change. The canonical
        // path below scopes the sandbox context to read_file/file_excerpt;
        // every other action keeps the normal chat context.
        // Scope: built ONLY for the file-system flips. The already-LIVE persona_read /
        // workspace_list / time_now / persona_list_skills flips resolve their own
        // roots (persona/workspace) independently of `repoRoot`/`file_access` and
        // derive persona root from `_na_data_root` ONLY in test mode — so threading a
        // prod `_na_data_root` here would flip their persona root from
        // `defaultPersonaRoot()` (stamped `<repo>/persona`) to the `<dataRoot>/memory`
        // legacy fallback, a behavior change. Those flips keep `defaultForSurface`;
        // ONLY read_file/file_excerpt get the sandbox-engaging context.
        let needsFileSandbox = (tool == "read_file")
            || (tool == "file_excerpt")
        let ctx: DispatchContext
        if needsFileSandbox {
            let dataRoot = PersistenceCore.defaultDataRoot()
            // WAVE 42 W02 (§6.260 — closes §6.240 round-2 reopen #2) — TIGHTEN the
            // sandbox repo root. The prior code used `dataRoot.deletingLastPath-
            // Component()` (the data root's PARENT) directly. That is correct ONLY
            // when the data root is `<repo>/data` (dev walkup / stamped-bundle
            // install — both have a VALIDATED repo as the parent). But
            // `defaultDataRoot`'s step-4 fallback returns `~/Library/Application
            // Support/NativeAgent` BARE (no `/data` suffix), whose parent is
            // `~/Library/Application Support` — the ENTIRE Application Support tree.
            // With the read sandbox engaged that parent became the sole allowed
            // root, so a read of any path under another app's Application Support
            // dir resolved INSIDE the sandbox (gpt-5.5 W02 FAIL). The env-var
            // data-root branch has the same exposure for an arbitrary parent.
            //
            // `resolveSandboxRepoRoot` returns a repo root only when the data
            // root's parent carries all required repo markers. On nil we refuse
            // locally; there is no HTTP recovery path.
            guard let repoRootURL = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot) else {
                var body: [String: Any] = [
                    "tool": tool, "input": input, "surface": "chat", "dry_run": false,
                ]
                if let sid = sessionId { body["session_id"] = sid }
                let bodyData = try JSONSerialization.data(withJSONObject: body)
                return try await _dispatchMissingNativeHandler(bodyData: bodyData)
            }
            let repoRoot = repoRootURL.path
            var extra: [String: JSONValue] = [
                "file_access": .object([
                    "mode": .string("read_only"),
                    "sandbox": .string("read_only"),
                ]),
            ]
            // Thread the data root so `isSensitiveDataPath` blocks OAuth tokens /
            // pairing secrets / provider credentials even though they live UNDER the
            // repo root (which would otherwise be an allowed root). Empty-string
            // guarded — `fromDispatch` treats "" as falsy (Python `_resolve_na_data_root`).
            let dataRootPath = dataRoot.path
            if !dataRootPath.isEmpty {
                extra["_na_data_root"] = .string(dataRootPath)
            }
            ctx = DispatchContext(
                repoRoot: repoRoot,
                cwd: repoRoot,
                surface: "chat",
                sessionId: sessionId ?? "",
                persona: "",
                activeProvider: "",
                extra: extra
            )
        } else {
            ctx = DispatchContext.defaultForSurface("chat", sessionId: sessionId ?? "")
        }
        let result: Dispatcher.DispatchResult
        do {
            result = try await dispatcher.dispatch(tool: tool, input: obj, ctx: ctx, dryRun: false)
        } catch let err as DispatcherError {
            throw NSError(domain: "NativeAgentDispatcher", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: err.localizedDescription])
        }
        // WAVE 36 W11 — preserve the native handler's `output` payload (e.g.
        // persona_read's `content` / `path` / `size_bytes`) instead of dropping
        // it to nil. The HTTP `_dispatchRaw` path decodes the daemon receipt's
        // `output` into DispatchOutput.rawString; the in-process seam must mirror
        // that so receipt-rendering consumers see parity. Serialize the module
        // JSONValue compactly (matches the HTTP-path object shape).
        let mappedOutput: DispatchOutput? = result.output.map { mo in
            DispatchOutput(rawString: (try? mo.value.serialize(pretty: false)) ?? "{}")
        }
        return DispatchResult(
            ok: result.ok,
            tool: result.tool,
            status: result.status,
            output: mappedOutput,
            error: result.error.map { e in DispatchResult.DispatchToolError(code: e.code, message: e.message, tool: e.tool, recoverable: e.recoverable) },
            executed: result.executed,
            verifyPassed: result.verifyPassed,
            durationUs: result.durationUs,
            durationMs: result.durationMs,
            effectiveAutonomy: result.effectiveAutonomy,
            autonomySource: result.autonomySource,
            providerMatch: result.providerMatch,
            traceEventId: result.traceEventId,
            runId: result.runId,
            startedAt: result.startedAt
        )
    }

    func swiftListMCPConsents() async throws -> [MCPConsentRecord] {
        let disp = mcpDispatcherForClientRoot()
        let items = try await disp.listConsents()
        return items.map(NativeClient._mapMCPConsent)
    }

    static func _mapMCPConsent(_ value: MCPConsent) -> MCPConsentRecord {
        MCPUIActions.mapConsent(value)
    }

    func swiftGrantMCPConsent(serverId: String, toolName: String, risk: String?) async throws -> MCPConsentRecord {
        try await MCPUIActions.grantConsent(
            serverId: serverId, toolName: toolName, risk: risk,
            dispatcher: mcpDispatcherForClientRoot(),
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    /// MCP consent is durable execution authority. Reads and mutations must
    /// share the NativeClient's resolved root so an injected surface cannot
    /// display one ledger while changing another.
    func mcpDispatcherForClientRoot() -> SwiftNativeMCPDispatcher {
        SwiftNativeMCPDispatcher(
            root: dataRootOverride ?? SwiftNativeMCPDispatcher.defaultDataRoot()
        )
    }

    // MARK: - Training / Promotion / Evals read-side helpers
    //
    // Each reads the SAME data files the daemon reads (co-located on the Mac)
    // and re-decodes the pass-through JSONValue into the identical UI model the
    // HTTP path decodes.
    //
    // wave 32 W05: the daemon's _training_allowed()/_promotion_allowed() 403 trust
    // gates ARE now mirrored. Each training/promotion routed helper consults the
    // Swift gate (SwiftNativeSelfImprovement.trainingAllowed / promotionAllowed,
    // which read the live <root>/trust/policy.json) and, when the gate is CLOSED,
    // throws the IDENTICAL 403 NSError the daemon's HTTP validate() would have
    // produced — so a flag-ON caller sees the same 403 as the HTTP path, not a
    // silently-allowed read. /v1/evals/runs is NOT gated (the retired daemon
    // serves it unconditionally), so swiftGetEvals has no gate, preserving daemon
    // parity.
    // Each helper constructs the actor directly (the read methods live on the
    // concrete SwiftNativeSelfImprovement, not the protocol).

    static func _trainingPromotionActor(dataRoot: URL? = nil) -> SwiftNativeSelfImprovement {
        // dataRoot defaults to defaultDataRoot(), which reads the live process
        // environment exactly as the daemon's _resolve_data_root() does, so the
        // Swift reader is co-located with the daemon's files on the Mac.
        if let dataRoot {
            return SwiftNativeSelfImprovement(dataRoot: dataRoot)
        }
        return SwiftNativeSelfImprovement()
    }

    /// The 403 NSError the daemon's HTTP path produces on a closed gate. The
    /// daemon sends `_send_json_status(403, {"error": "forbidden", "detail": …})`
    ///, and NativeClient.validate() rethrows
    /// any non-2xx as `NSError(domain:"NativeAgent", code:status,
    /// userInfo:[NSLocalizedDescriptionKey: <raw body string>])`. We reproduce
    /// that exact shape so flag-ON callers get byte-identical 403 behavior.
    static func _trustForbidden(detail: String) -> NSError {
        // json.dumps preserves insertion order: {"error": "forbidden", "detail": "…"}.
        let body = "{\"error\": \"forbidden\", \"detail\": \"\(detail)\"}"
        return NSError(
            domain: "NativeAgent",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: body]
        )
    }

    func swiftGetTrainingRuns() async throws -> [TrainingRunSummary] {
        let actor = NativeClient._trainingPromotionActor(dataRoot: dataRootOverride)
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        let raw = try await actor.listTrainingRunsLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([TrainingRunSummary].self, from: data)
    }

    func swiftGetTrainingProposals() async throws -> [TrainingProposalSummary] {
        let actor = NativeClient._trainingPromotionActor(dataRoot: dataRootOverride)
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        let raw = try await actor.listTrainingProposalsLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([TrainingProposalSummary].self, from: data)
    }

    func swiftGetPromotionCandidates() async throws -> [PromotionCandidateSummary] {
        let actor = NativeClient._trainingPromotionActor(dataRoot: dataRootOverride)
        guard await actor.promotionAllowed() else {
            throw NativeClient._trustForbidden(detail: "promotionPolicy.enabled not set in trust policy")
        }
        let raw = try await actor.listPromotionCandidatesLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([PromotionCandidateSummary].self, from: data)
    }

    func swiftGetPromotionPending() async throws -> [PromotionCandidateSummary] {
        let actor = NativeClient._trainingPromotionActor(dataRoot: dataRootOverride)
        guard await actor.promotionAllowed() else {
            throw NativeClient._trustForbidden(detail: "promotionPolicy.enabled not set in trust policy")
        }
        let raw = try await actor.listPromotionPendingLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([PromotionCandidateSummary].self, from: data)
    }

    func swiftGetEvals() async throws -> [EvalRun] {
        let raw = try await NativeClient._trainingPromotionActor(dataRoot: dataRootOverride).listEvalsLocal()
        let data = try raw.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode([EvalRun].self, from: data)
    }

    func swiftImprovementGauntlet() async throws -> ImprovementGauntletStatus {
        try await RuntimeReadProjection.swiftImprovementGauntlet(dataRoot: dataRootOverride)
    }

    // MARK: - Training-proposal mutation routes (gate: .selfImprovement)
    // wave 33 W10. Mirrors the wave-32 W05 read-side gate posture: consult
    // trainingAllowed() and throw the identical 403 NSError before mutating, so
    // a flag-ON Swift write is under the SAME _training_allowed() leash the HTTP
    // path enforces.

    /// Keep the legacy dictionary result at the action boundary without a JSON round-trip.
    static func _jsonValueToDictionary(_ value: JSONValue) throws -> [String: Any] {
        guard case .object(let row) = value else {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "swift training-proposal result was not an object"]
            )
        }
        return MCPInputSchemaForm.toFoundationDict(row)
    }

    /// Returns the approve result dict. With `route_through_promotion` enabled,
    /// the actor stages a Swift-native promotion candidate instead of applying
    /// the personality-doc write immediately.
    func swiftApproveTrainingProposal(id: String) async throws -> [String: Any] {
        let actor = NativeClient._trainingPromotionActor(dataRoot: dataRootOverride)
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        let raw = try await actor.approveTrainingProposalLocal(proposalId: id)
        return try NativeClient._jsonValueToDictionary(raw)
    }

    func swiftRejectTrainingProposal(id: String, reason: String) async throws -> [String: Any] {
        let actor = NativeClient._trainingPromotionActor(dataRoot: dataRootOverride)
        guard await actor.trainingAllowed() else {
            throw NativeClient._trustForbidden(detail: "autonomous_training not enabled in trust policy")
        }
        let raw = try await actor.rejectTrainingProposalLocal(proposalId: id, reason: reason)
        return try NativeClient._jsonValueToDictionary(raw)
    }

    // MARK: - ToolExecution / ToolRegistry mutation routes
    // (gates: .toolRegistry — promote/quarantine share the same flag because
    // both write the same registry.json and either path may end up modifying
    // active/, quarantine/, or proposals/. Keeping them co-flagged avoids
    // half-flips where promote routes via Swift but the next quarantine on
    // the same registry returns to HTTP and loses Swift's mutations.)

    /// Promote a proposal via SwiftNativeToolExecution. The returned
    /// ProposalRecord's JSON carries the registry record's typed slots
    /// (id/name/status/createdAt) plus every extras key the promote engine
    /// merges in, so it reads as the promoted `ToolRecord`.
    func swiftPromoteTool(id: String, allowRisky: Bool) async throws -> ToolRecord {
        let exec = SwiftNativeToolExecution(
            root: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let proposal = try await exec.promote(id: id, allowRisky: allowRisky).toJSON()
        if let field = ToolRecord.stringFieldProblem(in: proposal) {
            throw ToolRegistryError.registryUnreadable(reason: "promoted tool \(id) has no valid \(field)")
        }
        guard let record = ToolRecord(json: proposal) else {
            throw ToolRegistryError.registryUnreadable(reason: "promoted tool \(id) has no registry record")
        }
        try ToolsFacade.checkAuthored(record)
        return record
    }

    /// Quarantine a tool via SwiftNativeToolRegistry.
    func swiftQuarantineTool(
        id: String,
        reason: String
    ) async throws -> ToolRecord {
        // Keep the app action coordinator on the same injectable canonical
        // root as its readers.  Production has no override; hermetic app
        // integration tests exercise this exact route without touching live
        // tool authority.
        let reg = SwiftNativeToolRegistry(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
        let record = try await reg.quarantine(id: id, reason: reason)
        try ToolsFacade.checkAuthored(record)
        return record
    }

    // MARK: - MCPDispatcher listServers (gate: .mcpDispatcher)

    /// Adapt Core MCPServer → app MCPServerRecord by JSON round-trip via
    /// MCPServer.toJSON() (presence-preserving). Every typed field the app
    /// struct exposes (id/name/transport/endpoint/command/status/healthStatus/
    /// toolCount/resourceCount/riskClass/updatedAt) is populated by Core's
    /// listServers (defaults merged in — nativeagent-internal + searxng-local).
    func swiftListMCPServers() async throws -> [MCPServerRecord] {
        let disp = makeMCPDispatcher()
        let servers = try await disp.listServers()
        return try servers.map { server in
            let data = try server.toJSON().serializedData(pretty: false)
            return try JSONDecoder.nativeAgent.decode(MCPServerRecord.self, from: data)
        }
    }

    /// Live MCP tool list for a server — backed by SwiftNativeMCPDispatcher's
    /// `listToolsLive` (spawns the stdio child via the shared pool on demand,
    /// caches results for 60s mirroring the daemon's cache stamp).
    func swiftListMCPToolsLive(

        serverId: String
    ) async throws -> MCPToolsResponse {
        let disp = mcpDispatcherForClientRoot()
        let raw = try await disp.listToolsLive(forServer: serverId)
        var tools: [MCPToolRecord] = []
        for entry in raw {
            guard case .object(let obj) = entry else { continue }
            guard case .string(let name) = obj["name"] ?? .null else { continue }
            var desc: String? = nil
            if case .string(let s) = obj["description"] ?? .null { desc = s }
            // gpt-5.5 review: must thread inputSchema through the live path,
            // otherwise the new MCPInputSchemaForm always falls back to the raw
            // JSON editor for swift-native-served tools — feature is broken on
            // day one. The HTTP/Codable decode path gets inputSchema for free
            // via JSONDecoder.nativeAgent + default Codable derivation.
            var schema: JSONValue? = nil
            if let s = obj["inputSchema"], case .object = s { schema = s }
            tools.append(MCPToolRecord(name: name, description: desc, inputSchema: schema))
        }
        return MCPToolsResponse(serverId: serverId, tools: tools, createdAt: nil)
    }

    /// Live MCP resource list for a server — same caching contract as
    /// `swiftListMCPToolsLive`.
    func swiftListMCPResourcesLive(

        serverId: String
    ) async throws -> MCPResourcesResponse {
        let disp = mcpDispatcherForClientRoot()
        let raw = try await disp.listResourcesLive(forServer: serverId)
        var resources: [MCPResourceRecord] = []
        for entry in raw {
            guard case .object(let obj) = entry else { continue }
            guard case .string(let uri) = obj["uri"] ?? .null else { continue }
            var name: String? = nil
            if case .string(let s) = obj["name"] ?? .null { name = s }
            var mime: String? = nil
            if case .string(let s) = obj["mimeType"] ?? .null { mime = s }
            resources.append(MCPResourceRecord(uri: uri, name: name, mimeType: mime))
        }
        return MCPResourcesResponse(serverId: serverId, resources: resources, createdAt: nil)
    }

    // MARK: - Research routes (gate: .research)

    /// SearXNG autodetect — in-process Swift mirror of
    /// `Daemon.autodetect_searxng()`. Scans common ports + docker, persists
    /// `searxng_base_url` to `<dataRoot>/research/config.json` via
    /// PersistenceCore, returns the same {found, baseURL, source, error}
    /// shape the daemon returned. (Daemon-config path was retired
    /// 2026-06-06 — Swift now owns research config in its own file.)
    func swiftAutodetectSearXNG() async throws -> DetectSearXNGResponse {
        let client = makeResearchClient(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let result = try await client.autodetectSearXNG()
        return DetectSearXNGResponse(
            found: result.found,
            baseURL: result.baseURL,
            source: result.source,
            error: result.error
        )
    }

    /// Research search — in-process Swift mirror of `Daemon.search(query)`.
    /// Hits the configured SearXNG /search endpoint, writes a receipt JSON
    /// to `data/research/<id>.json`, returns the same per-result
    /// {title, url, snippet, source} shape the daemon returns.
    func swiftResearchSearch(query: String) async throws -> [ResearchSearchResult] {
        let client = makeResearchClient(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        return try await client.search(query: query).results
    }

    /// Research lab run — in-process Swift mirror of
    /// `Daemon.run_research_lab(body)`. Passes maxResults=5 to match the
    /// daemon caller's body. (Gate: .research.)
    func swiftRunResearchLab(objective: String) async throws -> ResearchLabRun {
        try await makeResearchClient(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        ).runResearchLab(objective: objective, maxResults: 5)
    }

    // MARK: - PersonaEngine routes (gate: .personaEngine)

    /// Build the app's `PersonalityProfile` from `PersonaCompiler.compileProfile()`
    /// which mirrors the daemon's `personality()` (default-seeded normalization
    /// of `<dataRoot>/memory/profile.json`). Every field the HTTP `/v1/personality`
    /// response carries is populated — Core's CompiledPersonalityProfile and
    /// the shared PersonalityProfile struct share the same field set 1:1.
    func swiftPersonality() async throws -> PersonalityProfile {
        let compiled = await PersonaCompiler().compileProfile(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        // Shared with the wave-33 W06 write-gate result mapping so the read and
        // write paths can't drift on the CompiledPersonalityProfile → app shape.
        return Self.adaptCompiledProfile(compiled)
    }

    /// Build the personality growth summary by compiling the chat-surface
    /// packet for fingerprint+activeKind and providing a feedback-memory count
    /// via SwiftNativeMemoryV2.listMemory(kind:nil) filtered by the
    /// `persona-feedback` tag (mirrors daemon's persona-feedback memory query).
    func swiftPersonalityGrowth() async throws -> PersonalityGrowthSummary {
        try await RuntimeReadProjection.swiftPersonalityGrowth {
            await NativeAgentEngine.liveCognition.substrate.growthWeekLines()
        }
    }

    // MARK: - CompiledPersonality route (gate: .personaEngine)

    /// Build the `/v1/personality/compiled` response in Swift by calling
    /// `PersonaCompiler.compiledPacket(surface:)`, which mirrors the
    /// daemon's `compiled_personality_packet` (the retired daemon
    /// L35508-35553) and the route envelope at L51635-51638. The wire
    /// shape `{surface, fingerprint, compiled}` is byte-equivalent: the
    /// `fingerprint` hashes the FULL UNSLICED docs + full profile via the
    /// same canonical-JSON serializer the daemon uses, and `compiled` is
    /// rendered as `json.dumps(packet, indent=2)` (ensure_ascii=True,
    /// insertion-order keys) so the Personality tab text matches byte-
    /// for-byte.
    func swiftCompiledPersonality(surface: String) async throws -> CompiledPersonality {
        let compiler: PersonaCompiler
        if let dataRootOverride {
            compiler = PersonaCompiler(
                engine: SwiftNativePersonaEngine.isolated(dataRoot: dataRootOverride)
            )
        } else {
            compiler = PersonaCompiler()
        }
        let wire = try await compiler.compiledPacket(surface: surface)
        return CompiledPersonality(
            surface: wire.surface,
            fingerprint: wire.fingerprint,
            compiled: wire.compiled
        )
    }

    // MARK: - PersonalityDocs route (gate: .personaEngine)

    /// Field-for-field map from Core's `PersonaDocSpec` (wire-shape DTO
    /// produced by `SwiftNativePersonaEngine.listPersonaDocSpecs()`) to the
    /// app-side `NativeAgentShared.PersonalityDoc`. Core owns the listing
    /// + mapping logic; this adapter only crosses the module boundary.
    func swiftPersonalityDocs() async throws -> PersonalityDocsResponse {
        let engine: SwiftNativePersonaEngine = dataRootOverride.map(SwiftNativePersonaEngine.isolated(dataRoot:))
            ?? SwiftNativePersonaEngine()
        let listing = try await engine.listPersonaDocSpecs()
        let docs: [PersonalityDoc] = listing.docs.map { spec in
            PersonalityDoc(
                id: spec.id,
                title: spec.title,
                filename: spec.filename,
                path: spec.path,
                content: spec.content,
                updatedAt: spec.updatedAt
            )
        }
        return PersonalityDocsResponse(docs: docs, updatedAt: listing.updatedAt)
    }

    // MARK: - TriggerScheduler routes (gate: .triggerScheduler)
    //
    // SUBSYSTEM #17 cluster C3 (2026-05-31). Covers list / enable / disable
    // / configure for BOTH schedules (proactive inbox + executions). fire_now is
    // native for supported inbox/execution cases and fails closed otherwise.

    /// Adapt Core TriggerConfig → app-side InboxTriggerConfig by JSON
    /// round-trip. Core writes the same daemon-byte shape, so InboxTriggerConfig's
    /// tolerant decoder handles the mixed-typed `config` dict unchanged.
    func swiftListInboxTriggers() async throws -> [InboxTriggerConfig] {
        let client = makeTriggerScheduler()
        let configs = try await client.listInboxTriggers()
        return try configs.map { cfg in
            let data = try cfg.toJSON().serializedData(pretty: false)
            return try JSONDecoder.nativeAgent.decode(InboxTriggerConfig.self, from: data)
        }
    }

    /// Adapt Core TriggerConfig → app-side TriggerRecord (Workshop executions schedule).
    /// TriggerRecord has typed (objective/title/trust_required) fields that
    /// live in extras on the Core side; round-trip via JSON preserves them.
    func swiftListWorkshopTriggers() async throws -> [TriggerRecord] {
        let client = makeTriggerScheduler()
        let configs = try await client.listWorkshopTriggers()
        return try configs.map { cfg in
            let data = try cfg.toJSON().serializedData(pretty: false)
            return try JSONDecoder.nativeAgent.decode(TriggerRecord.self, from: data)
        }
    }

    /// Flip enabled bit on an inbox trigger via the SwiftNative actor.
    /// HTTP-equivalent throws on not_found; mirror that so the UI behavior
    /// is unchanged.
    func swiftInboxTriggerEnable(

        name: String,
        enabled: Bool
    ) async throws {
        let client = makeTriggerScheduler()
        let status: TriggerStatus = try await (
            enabled
                ? client.enableInboxTrigger(name: name)
                : client.disableInboxTrigger(name: name)
        )
        if status.status == "not_found" {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "trigger not found: \(name)"]
            )
        }
    }

    /// SwiftNative configure path for inbox triggers. Translates the app-side
    /// dict (which can contain arrays / strings / ints / bools) into a
    /// JSONValue.object and hands it to the actor, which merges shallow into
    /// the existing per-trigger config dict (matches daemon
    /// proactive_triggers.update_config semantics).
    func swiftInboxTriggerConfigure(

        name: String,
        body: [String: Any]
    ) async throws {
        let client = makeTriggerScheduler()
        // Re-serialize to JSON then parse into our JSONValue so any nested
        // arrays/dicts/numbers come out exactly the way the daemon would
        // have parsed them on the HTTP path. Avoids hand-walking [String: Any].
        let data = try JSONSerialization.data(withJSONObject: body)
        let jv = try JSONValue.parse(data)
        let status = try await client.configureInboxTrigger(name: name, config: jv)
        if status.status == "not_found" {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "trigger not found: \(name)"]
            )
        }
    }

    /// Workshop-side enable/disable. Map TriggerStatus → WorkshopActionResult
    /// (status only — there is no mission_id for a config flip).
    func swiftWorkshopTriggerEnable(

        name: String,
        enabled: Bool
    ) async throws -> WorkshopActionResult {
        let client = makeTriggerScheduler()
        let status: TriggerStatus = try await (
            enabled
                ? client.enableWorkshopTrigger(name: name)
                : client.disableWorkshopTrigger(name: name)
        )
        if status.status == "not_found" {
            throw NSError(
                domain: "NativeAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "trigger not found: \(name)"]
            )
        }
        return WorkshopActionResult(
            executionId: nil,
            status: status.status,
            title: nil,
            plan_steps: nil,
            id: nil
        )
    }
}
