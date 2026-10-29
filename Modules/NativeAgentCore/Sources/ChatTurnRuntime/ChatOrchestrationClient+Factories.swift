import Foundation
import ApprovalInbox
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import ToolRegistry


import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
import Context
// Blueprint: | `ChatOrchestrationClient+Factories.swift` | `makeChatOrchestrationClient`, `makeGatedToolDispatchClient` (outermost node `ExpansionDispatcher`), the factory shares its injected clock with engine and chat client; uses ProviderRouting’s canonical provider assembly; stall-only calls share a transport without a resource wall; `SwiftNativeMemoryV2Recaller`: disclosure-aware recall and served-hit credit |

// MARK: - Factory

/// Convenience overload for app shells that need to add app-owned tools while
/// reusing the production persona/router/trust/LLM/memory wiring.
/// `providersRoot` selects routing and credentials; credential writes are token refreshes only.
/// Without it, routing uses `dataRoot` and adapters retain their default credential selection.
/// Routing overrides are read/write targets, including transactions in their directories;
/// nil uses `providers/active.json` and `providers/surfaces.json` under the routing root.
/// All other state stays on `dataRoot`; nondefault roots isolate persona and memory owners.
/// The injected `clock` is shared by the engine and client; its default is `Date()`.
public func makeChatOrchestrationClient(
    tools: any ToolDispatchClient,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    continuationCapabilityProfile: String? = nil,
    providersRoot: URL? = nil,
    activeProviderPathOverride: URL? = nil,
    surfacesPathOverride: URL? = nil,
    approvalFiler: (any ApprovalFiler)? = nil,
    cognitiveRuntime: (any CognitiveRuntimeProviding)? = nil,
    providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil,
    memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)? = nil,
    clock: @escaping @Sendable () -> Date = { Date() }
) -> SwiftNativeChatOrchestrationClient {
    let persona = dataRoot.standardizedFileURL
        == PersistenceCore.defaultDataRoot().standardizedFileURL
        ? SwiftNativePersonaEngine(dataRoot: dataRoot)
        : SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
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
    let llm = makeResidentProviderLLMClient(dataRoot: dataRoot, providersRoot: providersRoot,
        router: router, lifecycleObserver: providerLifecycleObserver)
    let recaller = makeChatMemoryRecaller(dataRoot: dataRoot)
    // Alternate-root turns never feed the live memory singleton.
    let promoter = makeChatMemoryPromoter(dataRoot: dataRoot)
    let turnTraceBus = makeChatTurnTraceBus(dataRoot: dataRoot)
    // REM-approved persona drift pins from `dataRoot` reach the system prompt.
    let engine = SwiftNativeTurnEngine(
        persona: persona,
        memory: recaller,
        router: router,
        tools: tools,
        clock: clock,
        remPinsDataRoot: dataRoot,
        memoryPromoter: promoter,
        turnTraceBus: turnTraceBus,
        contextFlow: contextFlow,
        cognitiveRuntime: cognitiveRuntime,
        memoryAtomTranslator: memoryAtomTranslator
    )
    return SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: tools,
        llm: llm,
        history: SessionHistoryReader(dataRoot: dataRoot),
        dataRoot: dataRoot,
        turnTraceBus: turnTraceBus,
        approvalFiler: approvalFiler,
        continuationCapabilityProfile: continuationCapabilityProfile,
        cognitiveRuntime: cognitiveRuntime,
        providerLifecycleObserverInstalled: providerLifecycleObserver != nil,
        clock: clock
    )
}

/// No-arg form — auto-constructs sensible SwiftNative defaults
/// (persona/router/trust on `PersistenceCore.defaultDataRoot()`, the real
/// SwiftNativeLLMClient with the provider adapters, and the minimal
/// SwiftToolDispatcher).
public func makeChatOrchestrationClient(
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    cognitiveRuntime: (any CognitiveRuntimeProviding)? = nil,
    providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
    contextFlow: (any ContextTurnPreparing)? = nil
) -> SwiftNativeChatOrchestrationClient {
    makeChatOrchestrationClient(
        tools: SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: dataRoot == PersistenceCore.defaultDataRoot()
        ),
        dataRoot: dataRoot,
        cognitiveRuntime: cognitiveRuntime,
        providerLifecycleObserver: providerLifecycleObserver,
        contextFlow: contextFlow
    )
}

/// Build the same gated tool dispatch chain that `SwiftNativeChatOrchestrationClient.chat`
/// constructs per-turn (expansion → canonical name → optional trace/peer taint → autonomy
/// → file access → real tools), for
/// use by non-chat surfaces (e.g. ClaudeBridge HTTP /claude/tool) that
/// would otherwise bypass Trust Center deny/confirm decisions and persona
/// write-guards.
///
/// - `fileAccess`: same values as `ChatOrchestrationClient.chat(..., fileAccess:)`
///   — invalid modes are refused; `none` refuses pathful `read` and prevents
///   downstream screen reads from opening inferred files. The mode travels
///   downstream; this wrapper does not impose a general read-only write block.
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
    tracePeerTurn: Bool = false,
    allowsFirstConversationExemption: Bool = false
) -> any ToolDispatchClient {
    let gate = AutonomyGate(approvalFiler: approvalFiler)
    let fileAccessGated = FileAccessGatedDispatcher(inner: tools, fileAccess: fileAccess)
    // Canonicalize aliases outside the gates so file access and Trust judge the name that executes.
    var dispatcher: any ToolDispatchClient = AutonomyGatedDispatcher(
        inner: fileAccessGated,
        gate: gate,
        approvalFiler: approvalFiler,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: dataRoot),
        approvalTimeoutSeconds: approvalTimeoutSeconds,
        verifiedSessionId: verifiedSessionId,
        approvedReplay: approvedReplay,
        injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier(dataRoot: dataRoot),
        // Non-injection replays require a matching inbox approval just spent by the executor, valid for one dispatch.
        approvedReplayVerifier: ApprovalInboxApprovedReplayVerifier(dataRoot: dataRoot, canonicalTool: CanonicalToolNameDispatcher.canonical),
        // The ONLY chain offered the first-conversation exemption: this is
        // the Mac chat turn the opener runs on. The token itself is bound
        // to a session id and spent on first use, so later turns on this
        // same chain match nothing. See FirstConversationPersonaProgression.
        firstConversationDataRoot: allowsFirstConversationExemption ? dataRoot : nil,
        // The peer directory supplies display names only, never authority.
        peerDirectoryDataRoot: dataRoot,
        fileAccess: fileAccess
    )
    // Provenance policy also binds approved replays and carried work, even
    // when those dispatch chains do not record a chat trace.
    dispatcher = PeerDataTaintDispatcher(
        inner: dispatcher, peerStore: AgentPeerStore(dataRoot: dataRoot)
    )
    if tracePeerTurn { dispatcher = ChatToolDispatchTracer(inner: dispatcher, dataRoot: dataRoot) }
    // Every surface resolves saved peer names from this same root.
    let canonical = CanonicalToolNameDispatcher(inner: dispatcher, peerDataRoot: dataRoot,
        conversationScope: verifiedSessionId)
    // Outermost: a mind's call returns carrying what its own practice looks
    // at next (`Expansion`); calls made inside a call re-enter below it.
    return ExpansionDispatcher(inner: canonical, dataRoot: dataRoot, session: verifiedSessionId)
}

/// Recall uses the root's canonical SQLite owner and managed embedder; unavailable stores remain fail-closed.
func makeChatMemoryRecaller(dataRoot: URL) -> SwiftNativeMemoryV2Recaller {
    SwiftNativeMemoryV2Recaller(
        memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
    )
}

func makeChatMemoryPromoter(dataRoot: URL) -> AdaptiveMemoryPromoter? {
    SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot)
        ? .shared
        : nil
}

func makeChatTurnTraceBus(dataRoot: URL) -> TurnTraceBus {
    dataRoot == PersistenceCore.defaultDataRoot()
        ? .shared
        : TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: dataRoot))
}
