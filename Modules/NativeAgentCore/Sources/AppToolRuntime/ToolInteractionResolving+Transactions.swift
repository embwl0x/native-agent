import ApprovalTransactions
import ChatTurnContracts
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ToolInteractionResolving+Transactions.swift` | interaction lookup and transaction resolution |

extension ToolInteractionResolving {
    public func interaction(id: String, sessionID: String, dataRoot: URL) async -> InlineInteraction? {
        await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot)
    }
    public func originEnvelope(of id: String, sessionID: String, dataRoot: URL) async -> TurnEnvelope? {
        await InlineInteractionResolver.originEnvelope(of: id, sessionID: sessionID, dataRoot: dataRoot)
    }
    public func descriptor(for interaction: InlineInteraction, dataRoot: URL) -> InlineInteractionDescriptor {
        InlineInteractionResolver.descriptor(for: interaction, dataRoot: dataRoot)
    }
    public func begin(id: String, sessionID: String, expectedRevision: Int?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.begin(id: id, sessionID: sessionID, expectedRevision: expectedRevision, byAgent: true, dataRoot: dataRoot)
    }
    public func decline(id: String, sessionID: String, expectedRevision: Int?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.decline(id: id, sessionID: sessionID, expectedRevision: expectedRevision, dataRoot: dataRoot)
    }
    public func returnToPending(_ interaction: InlineInteraction, sessionID: String, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.returnToPending(interaction, sessionID: sessionID, dataRoot: dataRoot)
    }
    public func complete(id: String, sessionID: String, selection: String?, scope: InlineInteraction.Scope?, expectedRevision: Int?, attribution: String?, setupError: String?, note: String?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.complete(id: id, sessionID: sessionID, selection: selection, scope: scope, expectedRevision: expectedRevision, attribution: attribution, setupError: setupError, note: note, byAgent: true, dataRoot: dataRoot)
    }
    public func takeContinuationHandBack(id: String) -> String? {
        InlineInteractionResolver.takeContinuationHandBack(id: id)
    }
    public func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        InlineInteractionResolver.receiptEnvelope(interaction)
    }
    public func liveOutcomeSummary(_ interaction: InlineInteraction, dataRoot: URL) async -> String? {
        await InlineInteractionResolver.liveProjection(interaction, dataRoot: dataRoot).state.outcome?.summary
    }
}
