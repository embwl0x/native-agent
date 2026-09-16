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
            injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier(dataRoot: dataRoot),
            externalToolIsEffect: peerExternalToolEffectResolver(dataRoot: dataRoot),
            // The ONLY chain offered the first-conversation exemption: this is
            // the Mac chat turn the opener runs on. The token itself is bound
            // to a session id and spent on first use, so later turns on this
            // same chain match nothing. See FirstConversationPersonaExemption.
            firstConversationDataRoot: dataRoot,
            // Display only: turns the peer's id into the name on her card.
            peerDirectoryDataRoot: dataRoot
        )
        // 2026-09-06: dotted aliases are canonicalized outside every gate —
        // see CanonicalToolNameDispatcher.
        // PeerDataTaintDispatcher sits under the tracer (so a refusal is still
        // traced) and over the gates (so a peer's words cannot reach the gate
        // machinery at all). See PeerDataTaint.
        return CanonicalToolNameDispatcher(
            inner: ChatToolDispatchTracer(
                inner: PeerDataTaintDispatcher(
                    inner: gated,
                    // The person's own per-peer grant — read here so an
                    // elevated peer's reply does not fence the turn.
                    peerStore: AgentPeerStore(dataRoot: dataRoot)
                ),
                dataRoot: dataRoot
            )
        )
    }
}
