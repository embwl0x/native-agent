import AppToolRuntime
import Transcripts
import ApprovalTransactions
import Foundation
import Observation
import ChatTurnRuntime
import AgentWorkspace
import ChatSessionWork
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Cognition
import StandingBots
import MemoryV2
import AuthoredCapabilities
import AttentionRouting
import TurnTrace
import Privacy
import MacControl
import Darwin
import ChatTurnContracts
import ChatToolParsing
// Blueprint: | `MountedTranscriptRefresh.swift` | Mounted conversations read the store when it publishes; no turn refreshes a view |
extension NativeAgentEngine {
    /// Read on store publication, never a turn request; live rows overlay saved rows until the store accepts them.
    @MainActor
    public func readMountedTranscript(sessionId: String, failure: (Error) -> Void) async {
        guard !sessionId.isEmpty else { return }
        do { try await transcripts.refreshMessages(sessionId: sessionId) } catch { failure(error) }
    }
}
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
