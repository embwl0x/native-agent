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
    approvalFiler: (any ApprovalFiler)? = nil,
    cognitiveObserver: (any CognitiveEventObserving)? = nil,
    cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
    providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil,
    memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)? = nil,
    publicSafeMode: Bool = false
) -> SwiftNativeChatOrchestrationClient {
    makeDefaultChatOrchestrationClient(
        tools: tools,
        approvalFiler: approvalFiler,
        dataRoot: dataRoot,
        cognitiveObserver: cognitiveObserver,
        cognitiveContextProvider: cognitiveContextProvider,
        providerLifecycleObserver: providerLifecycleObserver,
        contextFlow: contextFlow,
        memoryAtomTranslator: memoryAtomTranslator,
        publicSafeMode: publicSafeMode
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
    injectionApprovalVerifier: (any InjectionApprovalVerifying)? = nil
) -> any ToolDispatchClient {
    let resolvedTrust: any AutonomyResolver = trust ?? SwiftNativeTrustCenter(dataRoot: dataRoot)
    let gate = AutonomyGate(trust: resolvedTrust, approvalFiler: approvalFiler)
    let fileAccessGated = FileAccessGatedDispatcher(inner: tools, fileAccess: fileAccess)
    return AutonomyGatedDispatcher(
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
            ?? ApprovalInboxInjectionApprovalVerifier(dataRoot: dataRoot)
    )
}

private func makeDefaultChatOrchestrationClient(
    tools: any ToolDispatchClient,
    approvalFiler: (any ApprovalFiler)?,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    cognitiveObserver: (any CognitiveEventObserving)? = nil,
    cognitiveContextProvider: (any CognitiveContextProviding)? = nil,
    providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil,
    memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)? = nil,
    publicSafeMode: Bool = false
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
    let router = SwiftNativeProviderRouting(
        dataRoot: dataRoot,
        surfacesPathOverride: dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("surfaces.json"),
        activeProviderPathOverride: dataRoot
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
    let usesCanonicalBody = dataRoot.standardizedFileURL
        == PersistenceCore.defaultDataRoot().standardizedFileURL
    let llm: any LLMClient & StreamingLLMClient
    if usesCanonicalBody {
        llm = SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(),
            anthropic: AnthropicAdapter(),
            openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            xaiOAuthDirect: XAIOAuthDirectAdapter(),
            moonshot: MoonshotAdapter(),
            kimiCode: AnthropicAdapter.kimiCode(),
            openRouter: OpenRouterAdapter(),
            lifecycleObserver: providerLifecycleObserver
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
        // AdaptiveMemoryPromoter.shared is rooted in the production MemoryV2
        // singleton.  An alternate-root client must never feed a synthetic
        // turn back into that live process-wide owner.
        promoter: promoter,
        cognitiveObserver: cognitiveObserver,
        cognitiveContextProvider: cognitiveContextProvider,
        providerLifecycleObserverInstalled: providerLifecycleObserver != nil,
        publicSafeMode: publicSafeMode
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
    if dataRoot == PersistenceCore.defaultDataRoot() {
        return SwiftNativeMemoryV2RecallingAdapter(memory: .shared)
    }
    guard let storage = try? MemoryStorage(dataRoot: dataRoot) else {
        return SwiftNativeMemoryV2RecallingAdapter(memory: SwiftNativeMemoryV2())
    }
    let memory = SwiftNativeMemoryV2(
        embedder: ManagedEmbeddingProvider(dataRoot: dataRoot),
        storage: MemoryStorageBridge(storage: storage)
    )
    return SwiftNativeMemoryV2RecallingAdapter(memory: memory)
}

func makeChatMemoryPromoter(dataRoot: URL) -> (any MemoryPromoting)? {
    dataRoot == PersistenceCore.defaultDataRoot()
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
private struct AdaptiveMemoryPromoterAdapter: MemoryPromoting {
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {
        await AdaptiveMemoryPromoter.shared.observeTurn(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId
        )
    }
}
