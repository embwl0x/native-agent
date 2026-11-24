import SenseCore
import Foundation
import MindCore
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import DeskCore
// Blueprint: | `InlineInteractionPersistence.swift` | Checked same-row persistence and originating envelopes |
extension InlineInteractionCoordinator {
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
    public func originEnvelope(
        of id: String, sessionID: String) async throws -> TurnEnvelope? {
        let read = try await checkedRows(sessionID)
        return try await Task.detached(priority: .userInitiated) { () throws -> TurnEnvelope? in
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
        }.value
    }
    func require(
        id: String, sessionID: String) async throws -> InlineInteraction {
        guard let found = try await interaction(id: id, sessionID: sessionID)
        else { throw ResolveError.notFound }
        return found
    }
    func checkRevision(
        _ interaction: InlineInteraction, _ expected: Int?
    ) throws {
        guard let expected else { return }
        guard expected == interaction.revision else {
            throw ResolveError.staleRevision(expected: expected, actual: interaction.revision)
        }
    }
    /// Compare-and-swap every post-claim step so stale process state cannot overwrite reclamation, Stop or supersession.
    func persistTransition(
        _ interaction: InlineInteraction,
        from predecessor: InlineInteraction.Continuation.ResumeState,
        sessionID: String) async throws {
        let expectedRevision = interaction.revision
        try await persist(
            interaction, sessionID: sessionID,
            expecting: { current in
                current.revision == expectedRevision
                    && current.continuation?.state == predecessor
            }
        )
    }
    /// Compare revision and predecessor under the write lock so a losing writer cannot resurrect settled work.
    func persist(
        _ interaction: InlineInteraction,
        sessionID: String,
        ifRevision expected: Int? = nil,
        decision: Owed.Phase? = nil,
        expecting: (@Sendable (InlineInteraction) -> Bool)? = nil
    ) async throws {
        try await settle { @MainActor [self] in
            do {
                try await SwiftNativeChatOrchestrationClient.persistInlineInteraction(
                    interaction, at: Self.path(sessionID, dataRoot), ifRevision: expected,
                    expecting: expecting)
                // The saved answer settles before publication or continuation, even if delivery never filed its experience.
                if let decision {
                    await recordDecision(interaction, phase: decision, sessionID: sessionID).value
                }
                await ApprovalChatCards.publishInteractionChange(id: interaction.id, sessionID: sessionID, dataRoot: dataRoot)
                // Notify the open conversation after transcript and mirror publication.
                InlineInteractionDelivery.notify(sessionID: sessionID, dataRoot: dataRoot)
                ChatTurnCompleted.post(sessionID: sessionID)
                return Result<Void, Error>.success(())
            } catch { return .failure(error) }
        }.get()
    }
    @discardableResult
    func recordDecision(_ interaction: InlineInteraction, phase: Owed.Phase, sessionID: String, born: Bool = true) -> Task<Void, Never> {
        Owed.record(dataRoot, id: "interaction:" + interaction.id, kind: .decision, key: "decide", to: "person",
            phase: phase, evidence: [.init(source: "chat/messages/" + sessionID, id: interaction.id)], born: born)
    }
    /// Reconcile an existing debt from the saved decision alone, never from a live projection or a missing card.
    func reconcileDecision(_ saved: InlineInteraction, sessionID: String) {
        let phase: Owed.Phase
        switch saved.state {
        case .settled: phase = .accepted
        case .declined, .superseded: phase = .letGo(.cancelled)
        default: return
        }
        recordDecision(saved, phase: phase, sessionID: sessionID, born: false)
    }
    public nonisolated static func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        SwiftNativeChatOrchestrationClient.inlineInteractionReceiptEnvelope(interaction)
    }
}
