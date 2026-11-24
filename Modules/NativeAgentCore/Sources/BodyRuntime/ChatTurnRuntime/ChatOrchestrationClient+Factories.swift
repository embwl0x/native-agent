import Foundation
import MindCore
import MacNerves
import NativeAgentCore
import PersistenceCore
import SenseCore
import DeskCore
import ProviderRouting

// Blueprint: | `ChatOrchestrationClient+Factories.swift` | `makeChatOrchestrationClient`; `makeGatedToolDispatchClient`; Shared canonical gated construction |

// MARK: - Factory

/// Routing and credentials use `providersRoot`; all other state uses `dataRoot` to preserve isolation.
/// Credential writes refresh tokens only. Nil overrides use canonical routing paths and adapter credential selection.
/// The engine and client share the injected clock.
public func makeChatOrchestrationClient(
    tools: any ToolDispatchClient,
    jobStore: AgentJobStore,
    bodyField: BodyField?,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    sessionDelivery: SessionTurnDelivery.Resolver?,
    pages: PartFaces?,
    liveTurns: ChatLiveTap?,
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
        pages: pages,
        jobStore: jobStore, bodyField: bodyField,
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
        sessionDelivery: sessionDelivery,
        liveTurns: liveTurns,
        turnTraceBus: turnTraceBus,
        approvalFiler: approvalFiler,
        continuationCapabilityProfile: continuationCapabilityProfile,
        cognitiveRuntime: cognitiveRuntime,
        providerLifecycleObserverInstalled: providerLifecycleObserver != nil,
        clock: clock
    )
}

/// Non-chat surfaces use the same gated chain so they cannot bypass Trust or persona guards.
/// Invalid file modes refuse; `none` blocks pathful reads and inferred file opens without imposing a general write block.
/// A missing approval filer fails closed. The exact data root owns Trust, peer naming, approvals, security and traces.
/// Verified session identity attributes origin; approved replay satisfies only its matching confirmation, never hard gates.
public func makeGatedToolDispatchClient(
    tools: any ToolDispatchClient,
    jobStore: AgentJobStore,
    fileAccess: String = "read_only",
    approvalFiler: (any ApprovalFiler)? = nil,
    approvalTimeoutSeconds: Double = 30,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    verifiedSessionId: String? = nil,
    approvedReplay: ApprovedChatToolReplay? = nil,
    tracePeerTurn: Bool = false,
    conversation: AgentConversationContext? = nil,
    work: ChatTurnWork = .init()
) -> DoorPipeline {
    let policy = DoorPolicy(fileAccess: fileAccess, approvalFiler: approvalFiler, approvalTimeoutSeconds: approvalTimeoutSeconds,
        verifiedSessionId: verifiedSessionId, approvedReplay: approvedReplay, traceOnlyAbilities: !tracePeerTurn, work: work,
        surfaceProfile: conversation.map(DoorPolicy.SurfaceProfile.contact) ?? .ordinary, includeAppOwnedTools: tools.includeAppOwnedTools)
    return DoorPipeline(policy: policy, endpoint: tools, jobStore: jobStore, securityCenter: SwiftNativeSecurityCenter(dataRoot: dataRoot),
        gate: AutonomyGate(approvalFiler: approvalFiler), injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier(dataRoot: dataRoot),
        approvedReplayVerifier: ApprovalInboxApprovedReplayVerifier(inbox: SwiftNativeApprovalInbox(root: dataRoot), canonicalTool: ToolNameAliases.canonical))
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
