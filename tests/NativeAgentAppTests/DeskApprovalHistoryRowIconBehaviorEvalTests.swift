import Foundation
import ApprovalInbox
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Desk approval history row icon behavior", .serialized)
struct DeskApprovalHistoryRowIconBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-approval-history-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stageApproval(
        _ inbox: SwiftNativeApprovalInbox,
        title: String
    ) async throws -> String {
        try await inbox.create(.object([
            "title": .string(title),
            "action": .string("desk_note"),
            "risk": .string("confirm"),
            "reason": .string("Desk history icon evaluation"),
            "payload": .object([:]),
        ])).id
    }

    // app.desk / desk.approvals.historyRowIcon
    @Test("durable approval decisions retain their distinct Desk history icons after a fresh client read")
    func persistedTerminalDecisionsProjectToDistinctIcons() async throws {
        let root = try temporaryRoot("terminal")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)

        let approvedID = try await stageApproval(inbox, title: "Approved Desk change")
        _ = try await inbox.resolve(approvedID, decision: .approved, decidedBy: "eval")
        let deniedID = try await stageApproval(inbox, title: "Denied Desk change")
        _ = try await inbox.resolve(deniedID, decision: .denied, decidedBy: "eval")
        let canceledID = try await stageApproval(inbox, title: "Canceled Desk change")
        _ = try await inbox.resolve(canceledID, decision: .canceled, decidedBy: "eval")

        let rows = try await NativeClient(baseURL: "", dataRootOverride: root).getApprovals()
        let approved = try #require(rows.first { $0.id == approvedID })
        let denied = try #require(rows.first { $0.id == deniedID })
        let canceled = try #require(rows.first { $0.id == canceledID })

        #expect(ApprovalHistoryRowPresentation.icon(for: approved) == .init(
            systemName: "checkmark.circle.fill", tone: .success))
        #expect(ApprovalHistoryRowPresentation.icon(for: denied) == .init(
            systemName: "xmark.circle.fill", tone: .denial))
        #expect(ApprovalHistoryRowPresentation.icon(for: canceled) == .init(
            systemName: "minus.circle.fill", tone: .neutral))
    }

    // app.desk / desk.approvals.historyRowIcon
    @Test("missing or malformed decision evidence is visibly uncertain rather than a false denial")
    func incompleteAndMalformedDecisionsDoNotRenderAsCrosses() {
        let resolvedWithoutDecision = ApprovalRequest(
            id: "resolved-without-decision",
            title: "Incomplete history",
            action: "desk_note",
            risk: "confirm",
            status: "resolved"
        )
        let malformedDecision = ApprovalRequest(
            id: "malformed-decision",
            title: "Malformed history",
            action: "desk_note",
            risk: "confirm",
            status: "resolved",
            decision: "maybe"
        )
        let unknownStatus = ApprovalRequest(
            id: "unknown-status",
            title: "Unknown history",
            action: "desk_note",
            risk: "confirm",
            status: "remote_pending"
        )

        #expect(ApprovalHistoryRowPresentation.icon(for: resolvedWithoutDecision) == .init(
            systemName: "exclamationmark.triangle.fill", tone: .warning))
        #expect(ApprovalHistoryRowPresentation.icon(for: malformedDecision) == .init(
            systemName: "exclamationmark.triangle.fill", tone: .warning))
        #expect(ApprovalHistoryRowPresentation.icon(for: unknownStatus) == .init(
            systemName: "questionmark.circle.fill", tone: .warning))
    }
}
