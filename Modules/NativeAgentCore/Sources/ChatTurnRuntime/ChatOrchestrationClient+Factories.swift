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
import ChatToolRuntime
// Blueprint: | `ChatOrchestrationClient+Factories.swift` | `makeChatOrchestrationClient`; `makeGatedToolDispatchClient`; Shared canonical gated construction |

// MARK: - Factory

/// Routing and credentials use `providersRoot`; all other state uses `dataRoot` to preserve isolation.
/// Credential writes refresh tokens only. Nil overrides use canonical routing paths and adapter credential selection.
/// The engine and client share the injected clock.
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

/// Non-chat surfaces use the same gated chain so they cannot bypass Trust or persona guards.
/// Invalid file modes refuse; `none` blocks pathful reads and inferred file opens without imposing a general write block.
/// A missing approval filer fails closed. The exact data root owns Trust, peer naming, approvals, security and traces.
/// Verified session identity attributes origin; approved replay satisfies only its matching confirmation, never hard gates.
public func makeGatedToolDispatchClient(
    tools: any ToolDispatchClient,
    fileAccess: String = "read_only",
    approvalFiler: (any ApprovalFiler)? = nil,
    approvalTimeoutSeconds: Double = 30,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    verifiedSessionId: String? = nil,
    approvedReplay: ApprovedChatToolReplay? = nil,
    tracePeerTurn: Bool = false,
    work: ChatTurnWork = .init()
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
        // The peer directory supplies display names only, never authority.
        peerDirectoryDataRoot: dataRoot,
        fileAccess: fileAccess, work: work
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
    // Expansion owns outer practice feedback; nested calls re-enter below it.
    return ExpansionDispatcher(inner: canonical, dataRoot: dataRoot, session: verifiedSessionId, work: work)
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
