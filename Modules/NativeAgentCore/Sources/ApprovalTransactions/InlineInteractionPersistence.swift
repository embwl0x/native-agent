import AuthoredCapabilities
import Experiences
import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import ProviderRouting
import TrustCenter
import ToolRegistry
import MacControl
import Transcripts
import Studio
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import DreamREMCycle
import Dispatcher
import Browser
import NotificationInbox
// Blueprint: | `InlineInteractionPersistence.swift` | Checked same-row persistence and originating envelopes |
extension InlineInteractionResolver {
    // Replace under the transcript lock while preserving row identity and kind so settled cards remain compact in scrollback.
    nonisolated static func path(_ sessionID: String, _ dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent(
                "\(NativeAgentChatSessionID.normalizedPathComponent(sessionID) ?? sessionID).jsonl"
            )
    }
    /// Read provenance from the interaction's own preserved row so no second envelope can drift; gates still decide authority.
    public static func originEnvelope(
        of id: String, sessionID: String, dataRoot: URL
    ) async throws -> TurnEnvelope? {
        let read = try await checkedRows(sessionID, dataRoot)
        for row in read.rows.reversed() {
            guard case .object(let object) = row,
                  case .object(let metadata)? = object["metadata"],
                  metadata["kind"] == .string(InlineInteractionWire.transcriptKind),
                  case .object(let raw)? = metadata[InlineInteractionWire.metadataKey],
                  raw["id"] == .string(id)
            else { continue }
            _ = try SwiftNativeChatOrchestrationClient.checkedInlineInteraction(in: row, lifeID: read.lifeID)
            return TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
        }
        return nil
    }
    static func require(
        id: String, sessionID: String, dataRoot: URL
    ) async throws -> InlineInteraction {
        guard let found = try await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot)
        else { throw ResolveError.notFound }
        return found
    }
    static func checkRevision(
        _ interaction: InlineInteraction, _ expected: Int?
    ) throws {
        guard let expected else { return }
        guard expected == interaction.revision else {
            throw ResolveError.staleRevision(expected: expected, actual: interaction.revision)
        }
    }
    /// Compare-and-swap every post-claim step so stale process state cannot overwrite reclamation, Stop or supersession.
    static func persistTransition(
        _ interaction: InlineInteraction,
        from predecessor: InlineInteraction.Continuation.ResumeState,
        sessionID: String,
        dataRoot: URL
    ) async throws {
        let expectedRevision = interaction.revision
        try await persist(
            interaction, sessionID: sessionID, dataRoot: dataRoot,
            expecting: { current in
                current.revision == expectedRevision
                    && current.continuation?.state == predecessor
            }
        )
    }
    /// Compare revision and predecessor under the write lock so a losing writer cannot resurrect settled work.
    static func persist(
        _ interaction: InlineInteraction,
        sessionID: String,
        ifRevision expected: Int? = nil,
        decision: Owed.Phase? = nil,
        dataRoot: URL,
        expecting: (@Sendable (InlineInteraction) -> Bool)? = nil
    ) async throws {
        try await settle { @MainActor in
            do {
                try await SwiftNativeChatOrchestrationClient.persistInlineInteraction(
                    interaction, at: path(sessionID, dataRoot), ifRevision: expected,
                    expecting: expecting)
                // The saved answer settles before publication or continuation, even if delivery never filed its experience.
                if let decision {
                    await recordDecision(interaction, phase: decision, sessionID: sessionID, dataRoot: dataRoot).value
                }
                await ApprovalChatCards.publishInteractionChange(id: interaction.id, sessionID: sessionID, dataRoot: dataRoot)
                // Notify the open conversation after transcript and mirror publication.
                NotificationCenter.default.post(name: InlineInteractionWire.changedNotification, object: sessionID)
                NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                return Result<Void, Error>.success(())
            } catch { return .failure(error) }
        }.get()
    }
    @discardableResult
    static func recordDecision(_ interaction: InlineInteraction, phase: Owed.Phase, sessionID: String,
                               dataRoot: URL, born: Bool = true) -> Task<Void, Never> {
        Owed.record(dataRoot, id: "interaction:" + interaction.id, kind: .decision, key: "decide", to: "person",
            phase: phase, evidence: [.init(source: "chat/messages/" + sessionID, id: interaction.id)], born: born)
    }
    /// Reconcile an existing debt from the saved decision alone, never from a live projection or a missing card.
    static func reconcileDecision(_ saved: InlineInteraction, sessionID: String, dataRoot: URL) {
        let phase: Owed.Phase
        switch saved.state {
        case .settled: phase = .accepted
        case .declined, .superseded: phase = .letGo(.cancelled)
        default: return
        }
        recordDecision(saved, phase: phase, sessionID: sessionID, dataRoot: dataRoot, born: false)
    }
    public nonisolated static func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        SwiftNativeChatOrchestrationClient.inlineInteractionReceiptEnvelope(interaction)
    }
}
