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
    /// Build each chat dispatch chain here so its tracer sees admitted provenance and autonomy once.
    /// Request ceilings precede expansion; the loop records calls refused before the inner tracer as well as offered-contract refusals.
    /// Direct bridge tools use the shared untraced factory because they create no chat rows.
    func makeTracedGatedDispatcher(
        fileAccess: String,
        verifiedSessionId: String?, work: ChatTurnWork
    ) -> any ExpansionToolDispatchClient {
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
