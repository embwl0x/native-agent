import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftNativeChatOrchestrationClient {
    /// CHOKE POINT for chat tool dispatch. Every chat loop — structured
    /// non-streaming, structured streaming, and the Anthropic text-compat
    /// stream — must build its per-turn dispatcher here, so the
    /// ChatToolDispatchTracer wrapper sees EVERY dispatch exactly once.
    /// The tracer sits OUTERMOST because gate denials throw above the inner
    /// dispatcher; a trace hook inside SwiftToolDispatcher would never see
    /// them. The bridge /claude/tool path builds its own chain
    /// (makeGatedToolDispatchClient) and does not traverse this — chat rows
    /// only, no double-logging.
    func makeTracedGatedDispatcher(
        fileAccess: String,
        verifiedSessionId: String?
    ) -> any ToolDispatchClient {
        let gate = AutonomyGate(trust: trust, approvalFiler: approvalFiler)
        let fileAccessGated = FileAccessGatedDispatcher(inner: tools, fileAccess: fileAccess)
        let gated = AutonomyGatedDispatcher(
            inner: fileAccessGated,
            gate: gate,
            approvalFiler: approvalFiler,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: dataRoot),
            hasFiler: approvalFiler != nil,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            verifiedSessionId: verifiedSessionId,
            // W2/W3-FIX-R2 1 — the per-turn chat chain checks injection
            // approval ids against the canonical inbox on this data root.
            injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier(dataRoot: dataRoot)
        )
        return ChatToolDispatchTracer(inner: gated, dataRoot: dataRoot)
    }
}
