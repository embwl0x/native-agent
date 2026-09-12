import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter

private struct AlternateRootUnavailableChatLLMClient: LLMClient, StreamingLLMClient {
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

    func stream(
        prompt: String,
        system: String?,
        model: String?
    ) -> AsyncThrowingStream<String, Error> {
        let error = unavailable()
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
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
/// its ActiveToolsStore and TurnTraceBus; this factory deliberately reuses
/// those exact instances rather than pretending `dataRoot` can rewrite an
/// already-assembled engine. Missing deps → fall through to the no-arg form
/// which constructs sensible defaults.
public func makeChatOrchestrationClient(
    engine: SwiftNativeTurnEngine?,
    llm: (any LLMClient)?,
    tools: (any ToolDispatchClient)?,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    streamingLLM: (any StreamingLLMClient)? = nil,
    approvalFiler: (any ApprovalFiler)? = nil,
    cognitiveObserver: (any CognitiveEventObserving)? = nil,
    cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil
) -> any ChatOrchestrationClient {
    if let engine, let llm, let tools {
        return SwiftNativeChatOrchestrationClient(
            engine: engine, tools: tools, llm: llm,
            streamingLLM: streamingLLM,
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
    // 2026-09-06: forward the engine's retry wait seam for factory fixtures.
    providerRecoverySleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
    /// Per-surface tool-loop budget override forwarded to
    /// `ToolLoopBudget.resolve(surface:requested:)` (clamped to hardCap).
    /// nil = the surface's default. The bridge profile passes 180: the loop
    /// runs under surface "chat" (the model pick must keep following the
    /// chat picker — 2026-06-13), so a surface-keyed budget can never reach
    /// it (proven live 2026-08-27: Agent exhausted at 60 with the
    /// "claude-bridge" budget case shipped but unreachable).
    toolLoopMaxIterations: Int? = nil,
    turnWallClockSeconds: TimeInterval? = nil,
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
    clock: @escaping @Sendable () -> Date = { Date() },
    // Factory seam for a controlled credential-root probe. Production takes
    // nil and constructs CodexAdapter directly; tests can observe the exact
    // child-process environment without launching a real Codex child.
    codexAdapterFactory: (@Sendable ([String: String]?) -> any LLMAdapter)? = nil
) -> SwiftNativeChatOrchestrationClient {
    makeDefaultChatOrchestrationClient(
        tools: tools,
        approvalFiler: approvalFiler,
        providerRecoverySleep: providerRecoverySleep,
        toolLoopMaxIterations: toolLoopMaxIterations,
        turnWallClockSeconds: turnWallClockSeconds,
        dataRoot: dataRoot,
        providersRoot: providersRoot,
        activeProviderPathOverride: activeProviderPathOverride,
        surfacesPathOverride: surfacesPathOverride,
        cognitiveObserver: cognitiveObserver,
        cognitiveContextProvider: cognitiveContextProvider,
        providerLifecycleObserver: providerLifecycleObserver,
        contextFlow: contextFlow,
        memoryAtomTranslator: memoryAtomTranslator,
        clock: clock,
        codexAdapterFactory: codexAdapterFactory
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
            allowProcessGlobalTools: dataRoot == PersistenceCore.defaultDataRoot(),
            enforceLazyToolLoading: true
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
/// constructs per-turn (fileAccess gate → autonomy gate → real tools), for
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
///   TrustCenter. Callers that already inject `trust` may leave it at default.
/// - `trust`: optional AutonomyResolver override; defaults to a
///   `SwiftNativeTrustCenter` on `dataRoot`.
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
    trust: (any AutonomyResolver)? = nil,
    verifiedSessionId: String? = nil,
    approvedReplay: ApprovedChatToolReplay? = nil,
    injectionApprovalVerifier: (any InjectionApprovalVerifying)? = nil,
    approvedReplayVerifier: (any ApprovedReplayVerifying)? = nil
) -> any ToolDispatchClient {
    let resolvedTrust: any AutonomyResolver = trust ?? SwiftNativeTrustCenter(dataRoot: dataRoot)
    let gate = AutonomyGate(trust: resolvedTrust, approvalFiler: approvalFiler)
    let fileAccessGated = FileAccessGatedDispatcher(inner: tools, fileAccess: fileAccess)
    // 2026-09-06: canonicalize the dotted alias OUTSIDE the gates, so the
    // fileAccess blocklist and the Trust Center both judge the name that will
    // actually execute (`save.skill` used to reach `save_skill` un-gated).
    return CanonicalToolNameDispatcher(inner: AutonomyGatedDispatcher(
        inner: fileAccessGated,
        gate: gate,
        approvalFiler: approvalFiler,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: dataRoot),
        hasFiler: approvalFiler != nil,
        approvalTimeoutSeconds: approvalTimeoutSeconds,
        verifiedSessionId: verifiedSessionId,
        approvedReplay: approvedReplay,
        // W2/W3-FIX-R2 1 — every chain this factory builds can CHECK an
        // injection approval id against the canonical inbox on the same data
        // root. Callers may override for a hermetic inbox; nobody has to
        // remember to pass one for production to be safe.
        injectionApprovalVerifier: injectionApprovalVerifier
            ?? ApprovalInboxInjectionApprovalVerifier(dataRoot: dataRoot),
        // 2026-09-06 — and every NON-injection replay is checked against the
        // same inbox: the record must exist, be approved for this tool and
        // body, have been spent by the executor just now, and it is good for
        // exactly one dispatch.
        approvedReplayVerifier: approvedReplayVerifier
            ?? ApprovalInboxApprovedReplayVerifier(dataRoot: dataRoot)
    ))
}

private func makeDefaultChatOrchestrationClient(
    tools: any ToolDispatchClient,
    approvalFiler: (any ApprovalFiler)?,
    providerRecoverySleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
    toolLoopMaxIterations: Int? = nil,
    turnWallClockSeconds: TimeInterval? = nil,
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
    /// ActiveToolsStore, telemetry — stays on `dataRoot`, so a disposable
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
    clock: @escaping @Sendable () -> Date = { Date() },
    // Kept at the production assembly boundary: a test observes the exact
    // environment handed to the real Codex adapter, rather than reconstructing
    // the expected dictionary beside the factory.
    codexAdapterFactory: (@Sendable ([String: String]?) -> any LLMAdapter)? = nil
) -> SwiftNativeChatOrchestrationClient {
    // W-J hermeticity seam: a single dataRoot threads to every source-bound
    // singleton the factory constructs (persona/router/trust/adapters/engine/
    // client). Default = PersistenceCore.defaultDataRoot() so production
    // callers get the identical wiring they had before; the factory smoke
    // test passes a temp dir and stops leaking digest/active_tools/activity/
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
    let usesCanonicalBody = credentialRoot != nil
        || dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    let llm: any LLMClient & StreamingLLMClient
    if usesCanonicalBody {
        let telemetryRoot: URL? = credentialRoot == nil ? nil : dataRoot
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
        let codexEnvironment: [String: String]? = {
            if let root = credentialRoot {
                return CodexAdapter.augmentedProcessEnvironment().merging([
                    "CODEX_HOME": root.appendingPathComponent("codex_home", isDirectory: true).path,
                    "NATIVE_AGENT_DATA_ROOT": root.path,
                ]) { _, bound in bound }
            }
            let resolved = OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: dataRoot)
            guard OpenAIOAuthDirectAdapter.hasUsableTokens(at: resolved) else { return nil }
            return CodexAdapter.augmentedProcessEnvironment().merging([
                "CODEX_HOME": resolved.deletingLastPathComponent().path,
            ]) { _, bound in bound }
        }()
        llm = SwiftNativeLLMClient(
            router: router,
            // Codex child processes read CODEX_HOME / NATIVE_AGENT_DATA_ROOT; bind
            // both to the credential root so a secondary runtime never reads (or
            // refreshes) the operator's personal ~/.codex. (gpt-5.5 BLOCKING.)
            codex: codexAdapterFactory?(codexEnvironment)
                ?? CodexAdapter(processEnvironmentOverride: codexEnvironment),
            anthropic: AnthropicAdapter(
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openAI: OpenAIAdapter(
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(
                authPathOverride: credentialRoot.map {
                    OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: $0, allowSharedFallbacks: false, defaultRoot: $0)
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(
                authPathOverride: credentialRoot.map {
                    $0.appendingPathComponent("providers", isDirectory: true)
                        .appendingPathComponent("anthropic_oauth_direct.json")
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            xaiOAuthDirect: XAIOAuthDirectAdapter(
                tokenPathOverride: credentialRoot.map {
                    XAIOAuthDirectAdapter.tokenPath(dataRoot: $0)
                },
                telemetryDataRootOverride: telemetryRoot
            ),
            moonshot: MoonshotAdapter(
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            kimiCode: AnthropicAdapter.kimiCode(
                dataRootOverride: credentialRoot,
                telemetryDataRootOverride: telemetryRoot
            ),
            openRouter: OpenRouterAdapter(dataRootOverride: credentialRoot),
            lifecycleObserver: providerLifecycleObserver,
            moonshotCatalogDataRoot: credentialRoot ?? PersistenceCore.defaultDataRoot()
        )
    } else {
        // None of the default adapters has a complete credential-root seam.
        // Construct none of them: an injected secondary/test body must never
        // consume User's API keys, OAuth state, Codex home, or provider traces.
        llm = AlternateRootUnavailableChatLLMClient()
    }
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
    // Both the turn engine and the text-compatibility client expose a
    // promotion hook. They must share the same root decision or one path can
    // still write an alternate-root turn into the live singleton.
    let promoter = makeChatMemoryPromoter(dataRoot: dataRoot)
    let activeToolsStore: ActiveToolsStore =
        (tools as? any ActiveToolsStoreProviding)?.activeToolsStore
        ?? (dataRoot == PersistenceCore.defaultDataRoot()
            ? .shared
            : ActiveToolsStore(dataRoot: dataRoot))
    let turnTraceBus = makeChatTurnTraceBus(dataRoot: dataRoot)
    // remPinsDataRoot wired so REM-approved persona drift pins reach the
    // system prompt — without it, REMPinsReader.read is never called and the
    // approval pipeline's output dead-ends in <dataRoot>/rem_pins.json.
    let engine = SwiftNativeTurnEngine(
        persona: persona,
        memory: recaller,
        router: router,
        trust: trust,
        llm: llm,
        tools: tools,
        providerRecoverySleep: providerRecoverySleep,
        clock: clock,
        remPinsDataRoot: dataRoot,
        memoryPromoter: promoter,
        activeToolsStore: activeToolsStore,
        turnTraceBus: turnTraceBus,
        contextFlow: contextFlow,
        cognitiveContextProvider: cognitiveContextProvider,
        memoryAtomTranslator: memoryAtomTranslator
    )
    return SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        // SwiftNativeLLMClient now conforms to StreamingLLMClient (Wave 4 gap
        // close, 2026-05-31). Streaming routes by model-prefix to the same
        // three adapters as complete(): Anthropic + OpenAI stream via SSE;
        // codex degrades to single-chunk via the LLMAdapter default stream().
        streamingLLM: llm,
        dataRoot: dataRoot,
        activeToolsStore: activeToolsStore,
        turnTraceBus: turnTraceBus,
        trust: trust,
        approvalFiler: approvalFiler,
        toolLoopMaxIterations: toolLoopMaxIterations,
        turnWallClockSeconds: turnWallClockSeconds,
        // AdaptiveMemoryPromoter.shared is rooted in the production MemoryV2
        // singleton.  An alternate-root client must never feed a synthetic
        // turn back into that live process-wide owner.
        promoter: promoter,
        cognitiveObserver: cognitiveObserver,
        cognitiveContextProvider: cognitiveContextProvider,
        providerLifecycleObserverInstalled: providerLifecycleObserver != nil
    )
}

// MARK: - MemoryRecalling adapter over SwiftNativeMemoryV2.shared

/// Bridges SwiftNativeMemoryV2.shared (MemoryV2 module) into the
/// ChatOrchestration-module `MemoryRecalling` protocol.
private struct SwiftNativeMemoryV2RecallingAdapter: MemoryRecalling {
    let memory: SwiftNativeMemoryV2

    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] {
        let inner = SwiftNativeMemoryV2Recaller(memory: memory)
        return try await inner.recall(query, k: k)
    }

    func recall(
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
    func recordServedContextHits(ids: [String]) async {
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
func makeChatMemoryRecaller(dataRoot: URL) -> any MemoryRecalling {
    SwiftNativeMemoryV2RecallingAdapter(
        memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
    )
}

func makeChatMemoryPromoter(dataRoot: URL) -> (any MemoryPromoting)? {
    SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot)
        ? AdaptiveMemoryPromoterAdapter()
        : nil
}

func makeChatTurnTraceBus(dataRoot: URL) -> TurnTraceBus {
    dataRoot == PersistenceCore.defaultDataRoot()
        ? .shared
        : TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: dataRoot))
}

// MARK: - MemoryPromoting adapter over AdaptiveMemoryPromoter.shared

/// Bridges AdaptiveMemoryPromoter.shared into the chat client's
/// MemoryPromoting hook. The shared promoter is auto-configured at app
/// launch with SwiftNativeMemoryV2.shared as its backing store.
private struct AdaptiveMemoryPromoterAdapter: MemoryPromotionTelemetryReporting, MomentReviewQueueReporting {
    /// The per-turn "moments waiting" nudge asks its promoter for a count and
    /// stays silent when the promoter cannot answer. This adapter is the one
    /// production injects (not `SharedAdaptiveMemoryPromoter`), so without
    /// this conformance the nudge never rendered live (2026-09-02).
    func pendingMomentCount() async -> Int {
        await AdaptiveMemoryPromoter.shared.pendingMomentCount()
    }

    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {
        _ = await observeTurnWithTelemetry(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId
        )
    }

    func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        sessionId: String
    ) async -> MemoryPromotionTelemetry {
        await observeTurnWithTelemetry(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            toolEvidence: [],
            sessionId: sessionId
        )
    }

    /// Sweep item 35: this is the PRODUCTION seat of the promoter. Without the
    /// evidence overload here, the projection would be computed every turn and
    /// dropped by the protocol's default — a wired-looking dead nerve.
    func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String
    ) async -> MemoryPromotionTelemetry {
        await observeTurnWithTelemetry(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            toolEvidence: toolEvidence,
            sessionId: sessionId,
            surface: "chat"
        )
    }

    /// THE SURFACE OVERLOAD, seated in production (Astra comb 3, lane2 finding
    /// 4, 2026-09-12). Without it the protocol's default dropped `surface` on
    /// the floor exactly as it once dropped evidence, so every moment staged
    /// from Telegram recorded `metadata.surface = "chat"` — proposal
    /// `D6A7E552-1D5C-414E-B278-4CD5D5D58A87`, staged 21:53:07 from a Telegram
    /// turn, is the live row. "The night we shipped it over Telegram" is part
    /// of the moment; a wired-looking dead nerve is not.
    func observeTurnWithTelemetry(
        userMessage: String,
        assistantMessage: String,
        toolEvidence: [String],
        sessionId: String,
        surface: String
    ) async -> MemoryPromotionTelemetry {
        let observation = await AdaptiveMemoryPromoter.shared.observeTurnWithReport(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            toolEvidence: toolEvidence,
            sessionId: sessionId,
            surface: surface
        )
        let staged = observation.proposals
        // Sweep item 38, the procedural lane: the SAME evidence, read for a
        // different question. The promoter above asks "did this turn state a
        // durable fact"; this asks "has she now done this exact thing enough
        // times that it is craft". It fires on the repetition landing, never
        // on a schedule, and mints at most one approval card — nothing it does
        // reaches a prompt. It runs in the same post-reply side channel as the
        // promoter above (the reply is already sent), and swallows its own
        // failures for the same reason: a ledger write is never worth a turn.
        await ProceduralLane.shared.observeTurn(
            userMessage: userMessage,
            toolEvidence: toolEvidence,
            sessionId: sessionId
        )
        var telemetry = MemoryPromotionTelemetry(
            stagedProposalCount: staged.count,
            semanticStatus: observation.extraction.semanticStatus,
            semanticCandidateCount: observation.extraction.semanticCandidateCount,
            candidateCount: observation.extraction.candidates.count
                + observation.toolEvidenceCandidateCount
        )
        telemetry.momentOutcome = observation.momentOutcome
        return telemetry
    }
}
