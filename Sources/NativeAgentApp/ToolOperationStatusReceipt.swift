import SwiftUI
import AppKit
import ChatToolRuntime
import ToolRegistry
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter

// Blueprint: | `ToolOperationStatusReceipt.swift` | Bounded AppModel operation feedback; repeated results retain independent receipt identities |
/// Keep independent receipts outside global status so identical failures and unmounted tabs retain every outcome.
struct ToolOperationStatusReceipt: Identifiable, Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable {
        case succeeded
        case failed
    }
    let id: UUID
    let message: String
    let outcome: Outcome
    init(message: String, outcome: Outcome) {
        self.id = UUID()
        self.message = message
        self.outcome = outcome
    }
}
enum ToolsStatusFeed {
    static let maximumRetainedReceipts = 8
    static func appending(
        message: String,
        outcome: ToolOperationStatusReceipt.Outcome,
        to existing: [ToolOperationStatusReceipt]
    ) -> [ToolOperationStatusReceipt] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        let next = ToolOperationStatusReceipt(message: trimmed, outcome: outcome)
        return Array(([next] + existing).prefix(maximumRetainedReceipts))
    }
}
extension AppModel {
    /// Record each mutation regardless of mounting; statusText equality must not determine receipt identity.
    @MainActor
    func recordToolOperationStatus(
        _ message: String,
        outcome: ToolOperationStatusReceipt.Outcome,
        cause: Error? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        statusText = trimmed
        statusCause = cause?.localizedDescription
        toolOperationStatusReceipts = ToolsStatusFeed.appending(
            message: trimmed,
            outcome: outcome,
            to: toolOperationStatusReceipts
        )
    }
}
