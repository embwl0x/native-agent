import Foundation
import Testing

@testable import ApprovalInbox
@testable import NativeAgentApp
@testable import NativeAgentShared
@testable import PersistenceCore

// EVAL FENCE: app.desk / desk.approvals.decisionToastKind
@MainActor
@Suite("Desk approval decision toast kind")
struct DeskApprovalDecisionToastKindEvalTests {
    @Test("durably approved and denied decisions use distinct, truthful toast kinds")
    func durableDecisionDeterminesToastKind() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)

        let approvedID = try await stageApproval(in: inbox, title: "Approve a Desk update")
        let approved = try await inbox.resolve(
            approvedID,
            decision: .approved,
            decidedBy: "eval"
        )
        let deniedID = try await stageApproval(in: inbox, title: "Deny a Desk update")
        let denied = try await inbox.resolve(
            deniedID,
            decision: .denied,
            decidedBy: "eval"
        )

        let toasts = SystemToastCenter()
        let approvedToast = ApprovalDecisionToastPresentation.toast(
            for: request(from: approved),
            requestedID: approved.id
        )
        ApprovalDecisionToastPresentation.publish(approvedToast, to: toasts)
        #expect(toasts.queue.last?.kind == .success)
        #expect(toasts.queue.last?.text == "Approval recorded as approved")

        let deniedToast = ApprovalDecisionToastPresentation.toast(
            for: request(from: denied),
            requestedID: denied.id
        )
        ApprovalDecisionToastPresentation.publish(deniedToast, to: toasts)
        #expect(toasts.queue.last?.kind == .info)
        #expect(toasts.queue.last?.text == "Approval recorded as denied")
        toasts.dismissAll()
    }

    @Test("mismatched, pending, and unavailable responses cannot claim approval success")
    func incompleteOrUnavailableDecisionUsesErrorToast() {
        let pending = ApprovalRequest(
            id: "approval-pending",
            title: "Pending",
            action: "desk_note",
            risk: "confirm",
            status: "pending",
            decision: "approved"
        )
        let mismatch = ApprovalDecisionToastPresentation.toast(
            for: pending,
            requestedID: "another-approval"
        )
        let incomplete = ApprovalDecisionToastPresentation.toast(
            for: pending,
            requestedID: pending.id
        )
        let unavailable = ApprovalDecisionToastPresentation.unavailable(
            NSError(domain: "DeskApprovalEval", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "approval inbox unavailable",
            ])
        )

        #expect(mismatch.kind == .error)
        #expect(incomplete.kind == .error)
        #expect(unavailable.kind == .error)
        #expect(!unavailable.text.isEmpty)
    }

    private func stageApproval(
        in inbox: SwiftNativeApprovalInbox,
        title: String
    ) async throws -> String {
        try await inbox.create(.object([
            "title": .string(title),
            "action": .string("desk_note"),
            "risk": .string("confirm"),
            "reason": .string("Desk approval toast evaluation"),
            "payload": .object([:]),
        ])).id
    }

    private func request(from record: ApprovalRecord) -> ApprovalRequest {
        ApprovalRequest(
            id: record.id,
            title: record.title,
            action: record.action,
            risk: record.risk,
            reason: record.reason,
            status: record.status,
            createdAt: record.createdAt,
            resolvedAt: record.resolvedAt,
            decision: record.decision
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-approval-toast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
