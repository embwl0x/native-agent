import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `ChatOrchestrationClient+ToolDispatching.swift` | `SwiftNativeChatOrchestrationClient`: `makeTracedGatedDispatcher` |

extension SwiftNativeChatOrchestrationClient {
    /// CHOKE POINT for chat tool dispatch. Every chat turn must build its
    /// per-turn dispatcher here, so the
    /// ChatToolDispatchTracer sees dispatches and refusals from the inner
    /// provenance, autonomy and file gates. Expansion and canonical naming
    /// wrap the tracer; undispatched offered-contract refusals are recorded
    /// by the loop. The bridge /claude/tool path uses the shared factory without
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
            verifiedSessionId: verifiedSessionId,
            tracePeerTurn: true
        )
    }
}
