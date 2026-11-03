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
    /// A mounted conversation reads the store when the store publishes (its file changed). No turn asks for this read:
    /// the live turn is drawn over the saved rows, and settles into them as the store takes them.
    @MainActor
    public func readMountedTranscript(sessionId: String, failure: (Error) -> Void) async {
        guard !sessionId.isEmpty else { return }
        do { try await transcripts.refreshMessages(sessionId: sessionId) } catch { failure(error) }
    }
}
extension NativeAgentEngine {
    @MainActor
    public func observeSessionMessages(_ sessionID: String, finished: (Error?) -> Void) async {
        let events = FileChangeEvents(paths: [dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")], emitInitial: true)
        await withTaskCancellationHandler {
            for await _ in events.stream {
                guard !Task.isCancelled else { break }
                var failure: Error?
                await readMountedTranscript(sessionId: sessionID, failure: { failure = $0 })
                finished(failure)
            }
        } onCancel: { events.cancel() }
    }
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
