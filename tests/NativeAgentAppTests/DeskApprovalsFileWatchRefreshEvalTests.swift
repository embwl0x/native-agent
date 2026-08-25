import ApprovalInbox
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.approvals.fileWatchRefresh
//
// Runs the mounted Desk observation lifecycle against the same canonical
// ApprovalInbox writer used by non-Desk surfaces. A resolution performed after
// the panel's initial read must update its already-mounted projection.

@Test @MainActor
func deskApprovalsFileWatchRefreshesTheMountedCanonicalInbox() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("desk-approvals-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let inbox = SwiftNativeApprovalInbox(root: root)
    let created = try await inbox.create(.object([
        "title": .string("Approve mounted Desk action"),
        "action": .string("desk.eval.action"),
        "risk": .string("confirm"),
        "reason": .string("exercise the canonical live approval feed"),
        "payload": .object([:]),
    ]))
    let client = NativeClient(baseURL: "", dataRootOverride: root)
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)

    let watchedPath = await client.approvalRequestsPath()
    let canonicalPath = await inbox.approvalsPath
    #expect(watchedPath == canonicalPath)

    var readFailure: String?
    let observation = Task { @MainActor in
        await ApprovalRequestsLiveRefresh.observe(client: client) {
            do {
                model.approvals = try await model.getApprovals()
            } catch {
                readFailure = error.localizedDescription
            }
        }
    }
    defer { observation.cancel() }

    let initialDeadline = Date().addingTimeInterval(3)
    while Date() < initialDeadline {
        if model.approvals.first(where: { $0.id == created.id })?.status == "pending" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.approvals.first(where: { $0.id == created.id })?.status == "pending")
    #expect(readFailure == nil)

    _ = try await inbox.resolve(created.id, decision: .denied, decidedBy: "external-surface")

    let resolutionDeadline = Date().addingTimeInterval(3)
    while Date() < resolutionDeadline {
        let record = model.approvals.first(where: { $0.id == created.id })
        if record?.status == "resolved", record?.decision == "denied" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let resolved = model.approvals.first(where: { $0.id == created.id })
    #expect(resolved?.status == "resolved")
    #expect(resolved?.decision == "denied")
    #expect(readFailure == nil)
}
