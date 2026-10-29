import AgentWorkspace
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TurnTrace
import PersonaEngine
import MemoryV2
import ProviderRouting
import DreamREMCycle
import MacControl
import Context
import CognitiveSubstrate
import Transcripts
// Blueprint: | `ChatOrchestration+TurnEngine.swift` | SwiftNativeTurnEngine actor dependencies and retained task lifetimes |
public actor SwiftNativeTurnEngine {
    internal let persona: SwiftNativePersonaEngine
    let memory: SwiftNativeMemoryV2Recaller?
    let router: SwiftNativeProviderRouting
    internal let tools: any ToolDispatchClient
    let clock: @Sendable () -> Date
    let memoryPromoter: AdaptiveMemoryPromoter?
    let turnTraceBus: TurnTraceBus
    internal let contextFlow: (any ContextTurnPreparing)?
    /// Optional runtime data root; nil omits REM-approved persona pins.
    let remPinsDataRoot: URL?
    /// Bounded, read-only attention source for ContextTurnRequest; nil supplies no signals.
    internal let cognitiveRuntime: (any CognitiveRuntimeProviding)?
    /// App-owned memory-record → atom mapping keeps projection owner strings out of core.
    /// Nil drops memory-keyed activation while terms and intent still flow.
    internal let memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)?
    /// Upper bound on the attention-signal read. A slow substrate must never
    /// stall the turn: on expiry we proceed with no signals and flag the trace.
    internal static let attentionSignalsTimeoutNanos: UInt64 = 250_000_000
    internal static let queryEmbeddingWaitNanos: UInt64 = 500_000_000

    var deferredMemoryPromotion: Task<Void, Never>?
    var deferredMemoryPromotionID: UUID?
    var afterReplyFlights: [UUID: Task<Void, Never>] = [:]

    public init(
        persona: SwiftNativePersonaEngine,
        memory: SwiftNativeMemoryV2Recaller?,
        router: SwiftNativeProviderRouting,
        tools: any ToolDispatchClient,
        clock: @escaping @Sendable () -> Date = { Date() },
        remPinsDataRoot: URL? = nil,
        memoryPromoter: AdaptiveMemoryPromoter? = .shared,
        turnTraceBus: TurnTraceBus = .shared,
        contextFlow: (any ContextTurnPreparing)? = nil,
        cognitiveRuntime: (any CognitiveRuntimeProviding)? = nil,
        memoryAtomTranslator: (@Sendable (String) -> ContextAtomID?)? = nil
    ) {
        self.persona = persona
        self.memory = memory
        self.router = router
        self.tools = tools
        self.clock = clock
        self.memoryPromoter = memoryPromoter
        self.turnTraceBus = turnTraceBus
        self.remPinsDataRoot = remPinsDataRoot
        self.contextFlow = contextFlow
        self.cognitiveRuntime = cognitiveRuntime
        self.memoryAtomTranslator = memoryAtomTranslator
    }
    func readTurnQuietHours() -> TurnQuietHoursWindow? {
        remPinsDataRoot.flatMap { TurnQuietHoursWindow.read(dataRoot: $0) }
    }
}
