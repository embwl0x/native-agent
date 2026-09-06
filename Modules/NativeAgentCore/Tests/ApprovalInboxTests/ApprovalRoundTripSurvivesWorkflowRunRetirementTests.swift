import Testing
import Foundation
@testable import ApprovalInbox
import NativeAgentCore
import PersistenceCore

/// 2026-09-01: User authorized retiring the workflow RUN engine. The approvals
/// half shares the `workflows/` directory with the retired engine
/// (`workflows/approvals/requests.json` next to the frozen `workflows/runs.jsonl`)
/// but is a different owner and is written every day. This suite is the
/// severance proof: an approval request still round-trips end to end —
/// created, listed, read back by id, resolved, and re-read from the bytes on
/// disk — with no workflow run, run state, or run ledger anywhere in the path.
@Suite("Approvals survive the workflow run-engine retirement")
struct ApprovalRoundTripSurvivesWorkflowRunRetirementTests {
    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("approvals-after-workflow-retirement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("an approval request round-trips through requests.json with no run engine present")
    func approvalRequestRoundTripsAfterRunEngineRemoval() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)

        let created = try await inbox.create(.object([
            "title": .string("Send the weekly digest"),
            "action": .string("connector.send"),
            "risk": .string("medium"),
            "reason": .string("External send requires review."),
            "payload": .object(["channel": .string("email")]),
        ]))
        #expect(created.status == "pending")
        #expect(created.decision == nil)

        // The store writes the canonical path the Mac UI and the iOS
        // projection both watch. It must exist and hold the new row.
        let path = await inbox.approvalsPath
        #expect(path == root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json"))
        #expect(FileManager.default.fileExists(atPath: path.path))

        let pending = try await inbox.list(filter: ApprovalFilter(status: "pending", action: nil))
        #expect(pending.map(\.id) == [created.id])

        let fetched = try await inbox.get(created.id)
        #expect(fetched.title == "Send the weekly digest")
        #expect(fetched.payload == .object(["channel": .string("email")]))

        let resolved = try await inbox.resolve(
            created.id,
            decision: .approved,
            provenance: .local(decidedBy: "user")
        )
        #expect(resolved.status == "resolved")
        #expect(resolved.decision == "approved")
        #expect(resolved.resolvedAt != nil)

        // Re-read from disk through a fresh store: the decision must be
        // durable, not just returned.
        let reread = try await SwiftNativeApprovalInbox(root: root).get(created.id)
        #expect(reread.decision == "approved")
        #expect(reread.status == "resolved")
        #expect(try await SwiftNativeApprovalInbox(root: root)
            .list(filter: ApprovalFilter(status: "pending", action: nil)).isEmpty)

        // Severance: the approvals path never touches the retired run engine's
        // stores. Neither is created by an approval round-trip.
        let workflows = root.appendingPathComponent("workflows", isDirectory: true)
        #expect(!FileManager.default.fileExists(
            atPath: workflows.appendingPathComponent("runs.jsonl").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: workflows.appendingPathComponent("run_state", isDirectory: true).path
        ))
    }
}
