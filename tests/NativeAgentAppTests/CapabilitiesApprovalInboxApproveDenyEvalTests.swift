import ApprovalInbox
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.approvalInboxApproveDeny
@MainActor
@Suite("Capabilities approval inbox approve and deny", .serialized)
struct CapabilitiesApprovalInboxApproveDenyEvalTests {
    @Test("approval action owner durably approves and denies distinct requests with visible receipts")
    func approvalActionOwnerResolvesTheCanonicalInbox() async throws {
        let root = try temporaryRoot("actions")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approveRecord = try await stage(inbox: inbox, title: "Approve fixture")
        let denyRecord = try await stage(inbox: inbox, title: "Deny fixture")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.approvals = try await app.getApprovals()

        let approve = try #require(app.approvals.first { $0.id == approveRecord.id })
        await app.resolveCapabilitiesApprovalInbox(approve, decision: "approved")
        guard case .applied(let applied)? = app.capabilitiesApprovalInboxOutcome else {
            Issue.record("the Capabilities approval action did not produce an applied receipt")
            return
        }
        #expect(applied.id == approveRecord.id)
        #expect(app.capabilitiesApprovalInboxOutcome?.visibleMessage == "Approval recorded as approved.")
        #expect(CapabilitiesApprovalInboxPresentation.outcomeTone(.applied(applied)) == "success")
        let approved = try await inbox.get(approveRecord.id)
        #expect(approved.decision == "approved")

        app.approvals = try await app.getApprovals()
        let deny = try #require(app.approvals.first { $0.id == denyRecord.id })
        await app.resolveCapabilitiesApprovalInbox(deny, decision: "denied")
        guard case .applied(let deniedReceipt)? = app.capabilitiesApprovalInboxOutcome else {
            Issue.record("the Capabilities denial action did not produce an applied receipt")
            return
        }
        #expect(deniedReceipt.id == denyRecord.id)
        #expect(app.capabilitiesApprovalInboxOutcome?.visibleMessage == "Approval recorded as denied.")
        #expect(CapabilitiesApprovalInboxPresentation.outcomeTone(.applied(deniedReceipt)) == "warning")
        let denied = try await inbox.get(denyRecord.id)
        #expect(denied.decision == "denied")
    }

    @Test("empty, stale, unavailable, and refused action states do not look like an approved effect")
    func adverseStatesStayExplicit() async throws {
        let clean = AppModel.PanelRefreshStatus(lastAttemptAt: Date(), lastSuccessAt: Date(), failedEndpoints: [])
        let failed = AppModel.PanelRefreshStatus(lastAttemptAt: Date(), lastSuccessAt: nil, failedEndpoints: ["approvals"])
        #expect(CapabilitiesApprovalInboxPresentation.readState(approvalCount: 0, refresh: nil) == .loading)
        #expect(CapabilitiesApprovalInboxPresentation.readState(approvalCount: 0, refresh: clean) == .empty)
        #expect(CapabilitiesApprovalInboxPresentation.readState(approvalCount: 1, refresh: failed) == .stale)
        #expect(CapabilitiesApprovalInboxPresentation.readState(approvalCount: 0, refresh: failed) == .unavailable)

        let refused = ApprovalRequest(
            id: "refused",
            title: "Refused",
            action: "fixture.action",
            risk: "confirm",
            status: "resolved",
            decision: "denied"
        )
        let outcome = CapabilitiesApprovalInboxResolution.applied(refused)
        #expect(outcome.visibleMessage == "Approval recorded as denied.")
        #expect(CapabilitiesApprovalInboxPresentation.outcomeTone(outcome) == "warning")

        let unavailableRoot = try temporaryRoot("unavailable")
        defer { try? FileManager.default.removeItem(at: unavailableRoot) }
        let unavailableInbox = SwiftNativeApprovalInbox(root: unavailableRoot)
        let pending = try await stage(inbox: unavailableInbox, title: "Unavailable fixture")
        let unavailableApp = AppModel(dataRootOverride: unavailableRoot, startBackgroundTasks: false)
        unavailableApp.approvals = try await unavailableApp.getApprovals()
        enum UnavailableError: Error { case store }
        unavailableApp.approvalResolverOverride = { _, _ in throw UnavailableError.store }
        let request = try #require(unavailableApp.approvals.first { $0.id == pending.id })
        await unavailableApp.resolveCapabilitiesApprovalInbox(request, decision: "approved")
        guard case .unavailable(let detail)? = unavailableApp.capabilitiesApprovalInboxOutcome else {
            Issue.record("an unavailable approval owner did not retain an unavailable receipt")
            return
        }
        #expect(!detail.isEmpty)
        #expect(unavailableApp.statusText.hasPrefix("Approval update failed:"))
        let stillPending = try await unavailableInbox.get(pending.id)
        #expect(stillPending.status == "pending")
        #expect(stillPending.decision == nil)

        unavailableApp.recordPanelRefresh(.capabilities, failedEndpoints: ["approvals"])
        #expect(CapabilitiesApprovalInboxPresentation.readState(
            approvalCount: 0,
            refresh: unavailableApp.panelRefreshStatus[.capabilities]
        ) == .unavailable)
    }

    private func stage(inbox: SwiftNativeApprovalInbox, title: String) async throws -> ApprovalRecord {
        try await inbox.create(.object([
            "title": .string(title),
            "action": .string("fixture.approval.action"),
            "risk": .string("confirm"),
            "reason": .string("Exercise the Capabilities approval action owner."),
            "payload": .object([:]),
        ]))
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capabilities-approval-inbox-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
