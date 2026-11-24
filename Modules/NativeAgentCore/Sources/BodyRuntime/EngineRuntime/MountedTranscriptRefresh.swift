import SenseCore
import Foundation
import Observation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import MindCore
import MacNerves
import Darwin
// Blueprint: | `MountedTranscriptRefresh.swift` | Mounted conversations read the store when it publishes; no turn refreshes a view |
extension NativeAgentEngine {
    @MainActor
    public func loadDetachedSessionMessages(
        _ sessionId: String, finished: ([String]) -> Void
    ) async {
        guard !sessionId.isEmpty else { return }
        do {
            if try await transcripts.refreshMessages(sessionId: sessionId) { finished([]) }
        } catch { finished(["messages"]) }
    }
}
