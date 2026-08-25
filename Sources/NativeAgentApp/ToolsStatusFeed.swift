import Foundation

/// A result from a tool mutation that the Tools surface must keep visible.
/// This is intentionally separate from the app-wide one-line `statusText`:
/// repeated failures are separate observations even when their wording is
/// identical, and an unmounted tab must not drop a result.
struct ToolOperationStatusReceipt: Identifiable, Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable {
        case succeeded
        case failed

        var badgeStatus: String {
            switch self {
            case .succeeded: return "ok"
            case .failed: return "error"
            }
        }

        var systemImage: String {
            switch self {
            case .succeeded: return "checkmark.circle"
            case .failed: return "exclamationmark.triangle"
            }
        }
    }

    let id: UUID
    let message: String
    let outcome: Outcome
    let recordedAt: Date

    init(message: String, outcome: Outcome, recordedAt: Date = Date()) {
        self.id = UUID()
        self.message = message
        self.outcome = outcome
        self.recordedAt = recordedAt
    }
}

enum ToolsStatusFeed {
    static let maximumRetainedReceipts = 8

    static func appending(
        message: String,
        outcome: ToolOperationStatusReceipt.Outcome,
        to existing: [ToolOperationStatusReceipt],
        now: Date = Date()
    ) -> [ToolOperationStatusReceipt] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        let next = ToolOperationStatusReceipt(message: trimmed, outcome: outcome, recordedAt: now)
        return Array(([next] + existing).prefix(maximumRetainedReceipts))
    }
}

extension AppModel {
    /// Records every completed/failed Tools mutation independently of whether
    /// the Tools tab is mounted. Keep `statusText` for existing global status
    /// consumers, but never use its equality as the receipt identity.
    @MainActor
    func recordToolOperationStatus(
        _ message: String,
        outcome: ToolOperationStatusReceipt.Outcome
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        statusText = trimmed
        toolOperationStatusReceipts = ToolsStatusFeed.appending(
            message: trimmed,
            outcome: outcome,
            to: toolOperationStatusReceipts
        )
    }
}
