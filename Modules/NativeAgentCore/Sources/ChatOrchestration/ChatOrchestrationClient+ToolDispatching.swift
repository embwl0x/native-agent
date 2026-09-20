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
    /// them. The bridge /claude/tool path uses the shared factory without
    /// tracing and does not traverse this — chat rows
    /// only, no double-logging.
    func makeTracedGatedDispatcher(
        fileAccess: String,
        verifiedSessionId: String?
    ) -> any ToolDispatchClient {
        makeGatedToolDispatchClient(
            tools: tools,
            fileAccess: fileAccess,
            approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            dataRoot: dataRoot,
            trust: trust,
            verifiedSessionId: verifiedSessionId,
            tracePeerTurn: true,
            allowsFirstConversationExemption: true
        )
    }
}
