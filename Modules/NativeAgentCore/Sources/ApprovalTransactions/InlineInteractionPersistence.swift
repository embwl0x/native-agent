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
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
// Blueprint: | `InlineInteractionPersistence.swift` | Checked same-row persistence and originating envelopes |
extension InlineInteractionResolver {
    //
    // Same-row replacement, keyed by the interaction id, under the
    // transcript's own lock — the locked receipt replacement the approval
    // executor uses. The row keeps its id, createdAt, source and envelope, and
    // keeps `kind: inline_interaction` FOREVER: a settled card stays a compact
    // card in scrollback ("GitHub connected"), it does not decay into a
    // generic tool receipt.
    nonisolated static func path(_ sessionID: String, _ dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent(
                "\(NativeAgentChatSessionID.normalizedPathComponent(sessionID) ?? sessionID).jsonl"
            )
    }
    /// The envelope of the turn that raised this card.
    ///
    /// Read from the SAME row the interaction lives on — `metadata.envelope` is
    /// written there by the one writer that stamps the card
    /// (`ChatOrchestrationClient+MessagePersistence`), at the same moment, and
    /// the resolver's own locked rewrite preserves it. So it is the originating
    /// envelope by construction, with no second copy to drift.
    ///
    /// Provenance only: it says WHO and WHERE, and the gate still re-decides.
    public static func originEnvelope(
        of id: String, sessionID: String, dataRoot: URL
    ) async -> TurnEnvelope? {
        guard let read = try? await checkedRows(sessionID, dataRoot) else { return nil }
        for row in read.rows.reversed() {
            guard SwiftNativeChatOrchestrationClient.inlineInteraction(in: row, lifeID: read.lifeID)?.id == id,
                  case .object(let object) = row,
                  case .object(let metadata)? = object["metadata"]
            else { continue }
            return TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
        }
        return nil
    }
    static func require(
        id: String, sessionID: String, dataRoot: URL
    ) async throws -> InlineInteraction {
        guard let found = await interaction(id: id, sessionID: sessionID, dataRoot: dataRoot)
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
    /// A POST-CLAIM continuation transition, written only over the exact
    /// predecessor this caller is carrying on from.
    ///
    /// Everything after the claim used to write unconditionally, so a row that
    /// had moved on disk — reclaimed by a relaunch, invalidated by Stop,
    /// superseded by a newer identical ask — was overwritten by whatever this
    /// process still held in memory, and a card could read `resumed` for a turn
    /// nobody started. The claim itself is CAS'd; so is every step after it.
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
    /// `ifRevision` is the revision the caller READ before deciding on this
    /// transition; `expecting` is a predicate evaluated on the row as it exists
    /// INSIDE the lock. Both make the write a compare-and-swap: the compare
    /// happens against what is actually persisted, and a loser is told the
    /// card moved instead of resurrecting what another writer settled.
    static func persist(
        _ interaction: InlineInteraction,
        sessionID: String,
        ifRevision expected: Int? = nil,
        dataRoot: URL,
        expecting: (@Sendable (InlineInteraction) -> Bool)? = nil
    ) async throws {
        try await settle { @MainActor in
            do {
                try await SwiftNativeChatOrchestrationClient.persistInlineInteraction(
                    interaction, at: path(sessionID, dataRoot), ifRevision: expected,
                    expecting: expecting)
                await ApprovalChatCards.publishInteractionChange(id: interaction.id, sessionID: sessionID, dataRoot: dataRoot)
                // Notify the open conversation after transcript and mirror publication.
                NotificationCenter.default.post(name: InlineInteractionWire.changedNotification, object: sessionID)
                NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                return Result<Void, Error>.success(())
            } catch { return .failure(error) }
        }.get()
    }
    public nonisolated static func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        SwiftNativeChatOrchestrationClient.inlineInteractionReceiptEnvelope(interaction)
    }
}
