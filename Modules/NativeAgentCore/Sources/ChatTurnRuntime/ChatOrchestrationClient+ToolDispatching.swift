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
    /// Build each chat dispatch chain here so its tracer sees provenance, autonomy and file-gate refusals once.
    /// Expansion and canonical naming wrap the tracer; the loop records offered-contract refusals.
    /// Direct bridge tools use the shared untraced factory because they create no chat rows.
    func makeTracedGatedDispatcher(
        fileAccess: String,
        verifiedSessionId: String?, work: ChatTurnWork
    ) -> any ToolDispatchClient {
        makeGatedToolDispatchClient(
            tools: tools,
            fileAccess: fileAccess,
            approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            dataRoot: dataRoot,
            verifiedSessionId: verifiedSessionId,
            tracePeerTurn: true, work: work
        )
    }
}
