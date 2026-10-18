import Foundation
import ApprovalInbox
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import ToolRegistry


/// One provider assembly for resident turns and background body work. Routing,
/// credentials, account catalogs and adapter transports have exactly one owner.
public func makeResidentProviderLLMClient(
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    providersRoot: URL? = nil,
    router suppliedRouter: (any ProviderRoutingProtocol)? = nil,
    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    streamGuard: ProviderStreamGuardConfig = .fromEnvironment()
) -> any LLMClient {
    let credentialRoot = providersRoot?.standardizedFileURL
    let router = suppliedRouter ?? SwiftNativeProviderRouting(dataRoot: credentialRoot ?? dataRoot)
    let usesCanonicalBody = credentialRoot != nil
        || dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    let llm: any LLMClient
    if usesCanonicalBody {
        let telemetryRoot: URL? = credentialRoot == nil ? nil : dataRoot
        let stallSession = streamGuard.wallTimeout == 0 ? ProviderStreamGuard.stallOnlySession : nil
        // User, 2026-09-06: readiness ("codex is signed in") is decided from the
        // app's OWN credential resolution
        // (`OpenAIOAuthDirectAdapter.preferredAuthPath`), but the child got no
        // CODEX_HOME unless a `credentialRoot` was injected — so on the default
        // root the CLI went and used whatever `~/.codex` or ambient CODEX_HOME
        // it found, which is a different account from the one the badge
        // validated (and the one the app deliberately gates behind CLI-adoption
        // consent). Whenever the app has resolved a usable credential, the
        // child is pointed at exactly that location.
        // The merge sits on `augmentedProcessEnvironment` because an injected
        // environment REPLACES the adapter's PATH repair, and a GUI-launched
        // app's PATH cannot find `codex`.
        // The child runs on the app credential's access-only copy
        // (`codexChildHome`), never the app's own file; an adopted ~/.codex is
        // the CLI's own and stays as it is.
        let codexEnvironment: [String: String]? = {
            if let root = credentialRoot {
                return CodexAdapter.augmentedProcessEnvironment().merging([
                    "CODEX_HOME": OpenAIOAuthDirectAdapter.codexChildHome(dataRoot: root).path,
                    "NATIVE_AGENT_DATA_ROOT": root.path,
                ]) { _, bound in bound }
            }
            let resolved = OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: dataRoot)
            guard OpenAIOAuthDirectAdapter.hasUsableTokens(at: resolved) else { return nil }
            return CodexAdapter.augmentedProcessEnvironment().merging([
                "CODEX_HOME": (OpenAIOAuthDirectAdapter.codexChildHome(mirroring: resolved)
                    ?? resolved.deletingLastPathComponent()).path,
            ]) { _, bound in bound }
        }()
        llm = SwiftNativeLLMClient(
            router: router,
            // Codex child processes read CODEX_HOME / NATIVE_AGENT_DATA_ROOT; bind
            // both to the credential root so a secondary runtime never reads (or
            // refreshes) the operator's personal ~/.codex. (gpt-5.5 BLOCKING.)
            codex: CodexAdapter(processEnvironmentOverride: codexEnvironment),
            anthropic: AnthropicAdapter(
                session: stallSession ?? .shared,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openAI: OpenAIAdapter(
                session: stallSession ?? .shared,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(
                session: stallSession ?? OpenAIOAuthDirectAdapter.productionSession,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(
                session: stallSession ?? AnthropicOAuthDirectAdapter.productionSession,
                authPathOverride: credentialRoot.map {
                    $0.appendingPathComponent("providers", isDirectory: true)
                        .appendingPathComponent("anthropic_oauth_direct.json")
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            xaiOAuthDirect: XAIOAuthDirectAdapter(
                session: stallSession ?? .shared,
                tokenPathOverride: credentialRoot.map {
                    XAIOAuthDirectAdapter.tokenPath(dataRoot: $0)
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            moonshot: MoonshotAdapter(
                session: stallSession ?? .shared,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            kimiCode: AnthropicAdapter.kimiCode(
                session: stallSession ?? .shared,
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openRouter: OpenRouterAdapter(session: stallSession ?? .shared, dataRootOverride: credentialRoot),
            streamGuardConfig: streamGuard,
            lifecycleObserver: lifecycleObserver,
            moonshotCatalogDataRoot: credentialRoot ?? PersistenceCore.defaultDataRoot()
        )
    } else {
        // None of the default adapters has a complete credential-root seam.
        // Construct none of them: an injected secondary/test body must never
        // consume User's API keys, OAuth state, Codex home, or provider traces.
        llm = AlternateRootUnavailableChatLLMClient()
    }
    return llm
}

private struct AlternateRootUnavailableChatLLMClient: LLMClient {
    private func unavailable() -> NSError {
        NSError(
            domain: "ChatOrchestration",
            code: 503,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "default provider adapters are unavailable for an alternate data root",
            ]
        )
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw unavailable()
    }
}
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
import Context

// MARK: - Factory

/// Injection-style factory: when the caller has assembled a SwiftNativeTurnEngine
/// + llm + tools, build the SwiftNative impl directly. The prebuilt engine owns
/// its TurnTraceBus; this factory deliberately reuses that exact instance rather than pretending `dataRoot` can rewrite an
/// already-assembled engine. Missing deps → fall through to the no-arg form
/// which constructs sensible defaults.
public func makeChatOrchestrationClient(
    engine: SwiftNativeTurnEngine?,
    llm: (any LLMClient)?,
    tools: (any ToolDispatchClient)?,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    approvalFiler: (any ApprovalFiler)? = nil,
    cognitiveObserver: (any CognitiveEventObserving)? = nil,
    cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil
) -> any ChatOrchestrationClient {
    if let engine, let llm, let tools {
        return SwiftNativeChatOrchestrationClient(
            engine: engine, tools: tools, llm: llm,
            history: SessionHistoryReader(dataRoot: dataRoot),
            dataRoot: dataRoot,
            trust: SwiftNativeTrustCenter(dataRoot: dataRoot),
            approvalFiler: approvalFiler,
            cognitiveObserver: cognitiveObserver,
            cognitiveContextProvider: cognitiveContextProvider
        )
    }
    return makeChatOrchestrationClient(
        dataRoot: dataRoot,
        cognitiveObserver: cognitiveObserver,
        cognitiveContextProvider: cognitiveContextProvider,
        contextFlow: contextFlow
    )
}

/// Convenience overload for app shells that need to add app-owned tools while
/// reusing the production persona/router/trust/LLM/memory wiring.
public func makeChatOrchestrationClient(
    tools: any ToolDispatchClient,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    continuationCapabilityProfile: String? = nil,
    /// OPTIONAL CREDENTIAL/ROUTING ROOT — token-refresh writes allowed there, nothing else (nil = today's behaviour,
    /// byte for byte). See `makeDefaultChatOrchestrationClient`.
    providersRoot: URL? = nil,
    /// Optional ACTIVE-PROVIDER map path for the router (a bench A/B seam: a
    /// CLONE-side copy of active.json with one surface repointed). The router
    /// treats the path as its real map — reads AND any router-side writes/
    /// transactions target that file and its directory — which is exactly why
    /// the bench hands it a clone path, never the live file. nil = the provider
    /// root's own active.json.
    activeProviderPathOverride: URL? = nil,
    /// Same seam for the surface→model pin map (surfaces.json). nil = the provider root's own.
    surfacesPathOverride: URL? = nil,
    approvalFiler: (any ApprovalFiler)? = nil,
    cognitiveObserver: (any CognitiveEventObserving)? = nil,
    cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
    providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil,
    memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)? = nil,
    clock: @escaping @Sendable () -> Date = { Date() }
) -> SwiftNativeChatOrchestrationClient {
    makeDefaultChatOrchestrationClient(
        tools: tools,
        approvalFiler: approvalFiler,
        continuationCapabilityProfile: continuationCapabilityProfile,
        dataRoot: dataRoot,
        providersRoot: providersRoot,
        activeProviderPathOverride: activeProviderPathOverride,
        surfacesPathOverride: surfacesPathOverride,
        cognitiveObserver: cognitiveObserver,
        cognitiveContextProvider: cognitiveContextProvider,
        providerLifecycleObserver: providerLifecycleObserver,
        contextFlow: contextFlow,
        memoryAtomTranslator: memoryAtomTranslator,
        clock: clock
    )
}

/// No-arg form — auto-constructs sensible SwiftNative defaults
/// (persona/router/trust on `PersistenceCore.defaultDataRoot()`, the real
/// SwiftNativeLLMClient with the provider adapters, and the minimal
/// SwiftToolDispatcher).
public func makeChatOrchestrationClient(
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    cognitiveObserver: (any CognitiveEventObserving)? = nil,
    cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
    providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil
) -> any ChatOrchestrationClient {
    makeDefaultChatOrchestrationClient(
        tools: SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: dataRoot == PersistenceCore.defaultDataRoot()
        ),
        approvalFiler: nil,
        dataRoot: dataRoot,
        cognitiveObserver: cognitiveObserver,
        cognitiveContextProvider: cognitiveContextProvider,
        providerLifecycleObserver: providerLifecycleObserver,
        contextFlow: contextFlow
    )
}

/// Build the same gated tool dispatch chain that `SwiftNativeChatOrchestrationClient.chat`
/// constructs per-turn (canonical name → optional trace/peer taint → autonomy
/// → file access → real tools), for
/// use by non-chat surfaces (e.g. ClaudeBridge HTTP /claude/tool) that
/// would otherwise bypass Trust Center deny/confirm decisions and persona
/// write-guards.
///
/// - `fileAccess`: same values as `ChatOrchestrationClient.chat(..., fileAccess:)`
///   — `"workspace"|"auto"|"full"` = allow, `"read_only"` = block writes,
///   `"none"|"off"|"disabled"` = block all FS/shell tools by name prefix.
///   2026-07-21: empty/unknown values FAIL CLOSED (no longer permissive).
/// - `approvalFiler`: pass nil to make CONFIRM-tier tools fail closed (no
///   human-in-the-loop). Pass a wired filer to allow async approvals.
/// - `dataRoot`: exact root used when this factory constructs its default
///   TrustCenter, peer naming, approval inbox, security and trace stores.
/// - `verifiedSessionId`: optional session id used by SecurityCenter for
///   origin attribution; pass nil for stateless callers.
/// - `approvedReplay`: exact approval evidence for a resolved chat-tool replay.
///   It satisfies only a matching persona confirmation; hard gates still run.
public func makeGatedToolDispatchClient(
    tools: any ToolDispatchClient,
    fileAccess: String = "read_only",
    approvalFiler: (any ApprovalFiler)? = nil,
    approvalTimeoutSeconds: Double = 30,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    verifiedSessionId: String? = nil,
    approvedReplay: ApprovedChatToolReplay? = nil,
    approvedReplayVerifier: (any ApprovedReplayVerifying)? = nil,
    tracePeerTurn: Bool = false,
    allowsFirstConversationExemption: Bool = false
) -> any ToolDispatchClient {
    let gate = AutonomyGate(approvalFiler: approvalFiler)
    let fileAccessGated = FileAccessGatedDispatcher(inner: tools, fileAccess: fileAccess)
    // 2026-09-06: canonicalize the dotted alias OUTSIDE the gates, so the
    // fileAccess blocklist and the Trust Center both judge the name that will
    // actually execute (`save.skill` used to reach `save_skill` un-gated).
    var dispatcher: any ToolDispatchClient = AutonomyGatedDispatcher(
        inner: fileAccessGated,
        gate: gate,
        approvalFiler: approvalFiler,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: dataRoot),
        approvalTimeoutSeconds: approvalTimeoutSeconds,
        verifiedSessionId: verifiedSessionId,
        approvedReplay: approvedReplay,
        injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier(dataRoot: dataRoot),
        // 2026-09-06 — and every NON-injection replay is checked against the
        // same inbox: the record must exist, be approved for this tool and
        // body, have been spent by the executor just now, and it is good for
        // exactly one dispatch.
        approvedReplayVerifier: approvedReplayVerifier
            ?? ApprovalInboxApprovedReplayVerifier(dataRoot: dataRoot, canonicalTool: CanonicalToolNameDispatcher.canonical),
        // Peer turns expose the external MCP namespace like any other tool
        // (User, 2026-09-15: whole Agent), so the gate needs to know which of
        // those tools ACT. The registry already stamps a per-tool risk class
        // and `riskRequiresApproval` is exactly the read/effect split — a
        // server that ships no metadata resolves to
        // `approval_gated_missing_tool_risk`, which requires approval. So an
        // unclassified external tool asks rather than runs.
        externalToolIsEffect: peerExternalToolEffectResolver(dataRoot: dataRoot),
        // The ONLY chain offered the first-conversation exemption: this is
        // the Mac chat turn the opener runs on. The token itself is bound
        // to a session id and spent on first use, so later turns on this
        // same chain match nothing. See FirstConversationPersonaExemption.
        firstConversationDataRoot: allowsFirstConversationExemption ? dataRoot : nil,
        // The peer directory supplies display names only, never authority.
        peerDirectoryDataRoot: dataRoot,
        fileAccess: fileAccess
    )
    // Provenance policy also binds approved replays and carried work, even
    // when those dispatch chains do not record a chat trace.
    dispatcher = PeerDataTaintDispatcher(
        inner: dispatcher, peerStore: AgentPeerStore(dataRoot: dataRoot), dataRoot: dataRoot
    )
    if tracePeerTurn { dispatcher = ChatToolDispatchTracer(inner: dispatcher, dataRoot: dataRoot) }
    // 2026-09-18: every surface resolves saved peer names from this same root.
    return CanonicalToolNameDispatcher(inner: dispatcher, peerDataRoot: dataRoot,
        builtInLanes: tools as? any BuiltInAgentLaneProviding, conversationScope: verifiedSessionId)
}

/// The same registry evidence must reach peer effect gates on every turn chain.
func peerExternalToolEffectResolver(dataRoot: URL) -> @Sendable (String) -> Bool {
    { name in
        let lowered = name.lowercased()
        if !lowered.hasPrefix("mcp__") {
            guard !SwiftToolDispatcher.reservedBuiltInNames.contains(name) else { return false }
            return AppActionBinding.action(input: ["action": .string(ToolNameAliases.authoredAction(lowered))])?.read != true
        }
        guard let descriptor = MCPToolBridge.listMCPTools(dataRoot: dataRoot)
            .first(where: { $0.bridgedName.lowercased() == lowered })
        else { return true }
        return MCPToolBridge.riskRequiresApproval(descriptor.effectiveRiskClass)
    }
}

private func makeDefaultChatOrchestrationClient(
    tools: any ToolDispatchClient,
    approvalFiler: (any ApprovalFiler)?,
    continuationCapabilityProfile: String? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    /// OPTIONAL CREDENTIAL/ROUTING ROOT. Reads credentials + routing there; the ONLY
    /// writes that may land there are the adapters' own token refreshes.
    ///
    /// nil (every production and existing test caller) → behaviour is byte
    /// identical to before this parameter existed.
    ///
    /// Non-nil → the provider lane alone is repointed at this root: the
    /// router reads `providers/surfaces.json` / `providers/active.json` /
    /// registry / catalog from there, and the REAL adapters resolve their
    /// credentials there (API keys, OAuth token files, the Codex auth.json).
    /// Everything else — persona, memory, trust, history, traces, REM pins,
    /// telemetry — stays on `dataRoot`, so a disposable
    /// clone can make a real provider call without the tokens leaving the
    /// live store; the only writes that land there are token refreshes. This is the
    /// personality range bench's Layer 2 seam (docs/build_plans/
    /// personality-range-bench.md, decision (a)).
    providersRoot: URL? = nil,
    /// Optional ACTIVE-PROVIDER map path for the router (a bench A/B seam: a
    /// CLONE-side copy of active.json with one surface repointed). The router
    /// treats the path as its real map — reads AND any router-side writes/
    /// transactions target that file and its directory — which is exactly why
    /// the bench hands it a clone path, never the live file. nil = the provider
    /// root's own active.json.
    activeProviderPathOverride: URL? = nil,
    /// Same seam for the surface→model pin map (surfaces.json). nil = the provider root's own.
    surfacesPathOverride: URL? = nil,
    cognitiveObserver: (any CognitiveEventObserving)? = nil,
    cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
    providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil,
    memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)? = nil,
    // Injectable so replay tooling (turn-replay bench) can pin assembly to a
    // fixture's capture instant; production callers take the Date() default.
    clock: @escaping @Sendable () -> Date = { Date() }
) -> SwiftNativeChatOrchestrationClient {
    // W-J hermeticity seam: a single dataRoot threads to every source-bound
    // singleton the factory constructs (persona/router/trust/adapters/engine/
    // client). Default = PersistenceCore.defaultDataRoot() so production
    // callers get the identical wiring they had before; the factory smoke
    // test passes a temp dir and stops leaking digest/activity/
    // traces into the live data root.
    let persona = dataRoot.standardizedFileURL
        == PersistenceCore.defaultDataRoot().standardizedFileURL
        ? SwiftNativePersonaEngine(dataRoot: dataRoot)
        : SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
    // The provider lane's root: `providersRoot` when injected, otherwise
    // `dataRoot` exactly as before.
    let credentialRoot = providersRoot?.standardizedFileURL
    let routerRoot = credentialRoot ?? dataRoot
    let router = SwiftNativeProviderRouting(
        dataRoot: routerRoot,
        surfacesPathOverride: surfacesPathOverride ?? routerRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("surfaces.json"),
        activeProviderPathOverride: activeProviderPathOverride ?? routerRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("active.json")
    )
    let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
    // Wave 27 OpenAIOAuthDirectAdapter must be wired here too — without it,
    // gpt-* models in OAuth mode (the user's production setup: no OPENAI_API_KEY,
    // ChatGPT JWT in data/codex_home/auth.json::tokens.access_token) silently
    // throw .notConfigured(provider: "openai") and the Mac UI shows nothing.
    // SwiftNativeLLMClient routes gpt-* to OAuth-direct when the adapter is
    // installed and SURFACES its errors (no silent api-key swap, per 9358710c
    // strict routing); the api-key path is used only when the adapter is nil.
    //
    // Wave 28 AnthropicOAuthDirectAdapter (2026-06-01): same shape for the
    // claude-* / anthropic/* prefix. the user's environment has NO
    // ANTHROPIC_API_KEY — only the OAuth setup_token in
    // data/providers/anthropic_oauth_direct.json. Without this wire, every
    // chat turn against a claude model fails .notConfigured(provider:
    // "anthropic") and the Mac UI shows a silent no-reply.
    // A non-nil telemetry override flips LLMCallTraceRecorder to SYNCHRONOUS
    // test-mode writes — never hand it to production (gpt-5.5 review catch).
    // Only a non-default root (hermetic tests) gets the override.
    //
    // An injected `providersRoot` is the SECOND way to be real-adapter
    // eligible: the caller has named exactly which root the credentials come
    // from, so the "an alternate root has no credential seam" reason to
    // install the throwing client no longer holds. Each adapter is then given
    // that root for credential resolution, while its TELEMETRY root stays on
    // `dataRoot` — reads from the named credential root, writes into the
    // caller's own (disposable) body.
    let llm = makeResidentProviderLLMClient(dataRoot: dataRoot, providersRoot: providersRoot,
        router: router, lifecycleObserver: providerLifecycleObserver)
    // Swift-native cutover/fix-memory-wiring: route recall through SwiftNativeMemoryV2.shared
    // (SQLite-backed MemoryStorage) instead of the legacy JSONL store. Same
    // SQLite db the rest of MemoryV2 — UserMDGenerator, consolidation, proposal
    // accept/reject — writes through. The shared instance uses the managed
    // embedding provider: CoreML MiniLM when the bundled mlpackage loads,
    // fail-closed (embed() throws) otherwise unless the user opted into mock
    // via config or NATIVE_AGENT_EMBEDDING_MOCK=1. The previous comment about
    // a silent MockEmbeddingProvider fallback is stale — that path was removed
    // by the fail-closed cutover.
    let recaller = makeChatMemoryRecaller(dataRoot: dataRoot)
    // Alternate-root turns never feed the live memory singleton.
    let promoter = makeChatMemoryPromoter(dataRoot: dataRoot)
    let turnTraceBus = makeChatTurnTraceBus(dataRoot: dataRoot)
    // remPinsDataRoot wired so REM-approved persona drift pins reach the
    // system prompt — without it, REMPinsReader.read is never called and the
    // approval pipeline's output dead-ends in <dataRoot>/rem_pins.json.
    let engine = SwiftNativeTurnEngine(
        persona: persona,
        memory: recaller,
        router: router,
        trust: trust,
        tools: tools,
        clock: clock,
        remPinsDataRoot: dataRoot,
        memoryPromoter: promoter,
        turnTraceBus: turnTraceBus,
        contextFlow: contextFlow,
        cognitiveContextProvider: cognitiveContextProvider,
        memoryAtomTranslator: memoryAtomTranslator
    )
    return SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: dataRoot),
        dataRoot: dataRoot,
        turnTraceBus: turnTraceBus,
        trust: trust,
        approvalFiler: approvalFiler,
        continuationCapabilityProfile: continuationCapabilityProfile,
        cognitiveObserver: cognitiveObserver,
        cognitiveContextProvider: cognitiveContextProvider,
        providerLifecycleObserverInstalled: providerLifecycleObserver != nil
    )
}

// MARK: - Memory recall adapter

/// Disclosure-aware recall and served-hit credit against the same memory owner.
public struct SwiftNativeMemoryV2RecallingAdapter: Sendable {
    private let memory: SwiftNativeMemoryV2

    public init(memory: SwiftNativeMemoryV2) {
        self.memory = memory
    }

    public func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit] {
        let inner = SwiftNativeMemoryV2Recaller(memory: memory)
        return try await inner.recall(
            query,
            k: k,
            persona: persona,
            surface: surface
        )
    }

    /// Fluid-context serve bump (task #42): same use_count/last_used_at write
    /// the legacy recall lane fires, reached from the packet-served path.
    /// Errors are logged, never thrown — a dropped bump self-heals on any
    /// later serve, matching the recall lane's proportionate response.
    public func recordServedContextHits(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            try await memory.recordRecallHits(ids: ids)
        } catch {
            FileHandle.standardError.write(
                Data("MemoryV2: context-serve bump failed for \(ids.count) ids: \(error)\n".utf8)
            )
        }
    }
}

/// Construct the memory read owner for one chat factory root.
///
/// Production deliberately reuses the configured singleton (Spotlight/KG
/// hooks and the app's embedding runtime). Alternate/test roots get a private
/// SQLite-backed actor and managed embedder rooted at the exact injected URL.
/// Opening that store may fail; the unwired actor preserves MemoryV2's existing
/// fail-closed behavior instead of falling back to the live singleton.
func makeChatMemoryRecaller(dataRoot: URL) -> SwiftNativeMemoryV2RecallingAdapter {
    SwiftNativeMemoryV2RecallingAdapter(
        memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
    )
}

func makeChatMemoryPromoter(dataRoot: URL) -> SharedAdaptiveMemoryPromoter? {
    SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot)
        ? SharedAdaptiveMemoryPromoter()
        : nil
}

func makeChatTurnTraceBus(dataRoot: URL) -> TurnTraceBus {
    dataRoot == PersistenceCore.defaultDataRoot()
        ? .shared
        : TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: dataRoot))
}
