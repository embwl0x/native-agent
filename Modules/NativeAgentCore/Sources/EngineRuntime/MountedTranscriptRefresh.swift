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
// Blueprint: | `MountedTranscriptRefresh.swift` | Mounted and detached chat refresh/observation through the engine shared transcript owner |
extension NativeAgentEngine {
    /// Re-read a mounted transcript after a turn to replace optimistic rows
    /// with persisted ones. Local turns already land their disk snapshot and
    /// set `messagesAlreadyRefreshed`; remote turns keep the full refresh.
    @MainActor
    @discardableResult
    public func refreshChatMessagesAfterTurn(
        sessionId: String, messagesAlreadyRefreshed: Bool,
        isMounted: () -> Bool, failure: (Error) -> Void
    ) async -> Bool {
        guard !sessionId.isEmpty, isMounted() else { return false }
        if !messagesAlreadyRefreshed {
            do {
                guard try await transcripts.refreshMessages(sessionId: sessionId) else { return false }
            } catch {
                failure(error)
                return false
            }
        }
        return isMounted()
    }
    /// Refresh a visible detached transcript after a turn completed on another
    /// surface, independently of the main selection.
    @MainActor
    public func refreshDetachedChatMessagesAfterTurn(
        sessionId: String, messagesAlreadyRefreshed: Bool,
        isDetached: () -> Bool, finished: ([String]) -> Void
    ) async {
        if await refreshChatMessagesAfterTurn(
            sessionId: sessionId, messagesAlreadyRefreshed: messagesAlreadyRefreshed,
            isMounted: isDetached, failure: { _ in finished(["messages"]) }
        ) {
            finished([])
        }
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
                await refreshChatMessagesAfterTurn(sessionId: sessionID, messagesAlreadyRefreshed: false,
                    isMounted: { true }, failure: { failure = $0 })
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
