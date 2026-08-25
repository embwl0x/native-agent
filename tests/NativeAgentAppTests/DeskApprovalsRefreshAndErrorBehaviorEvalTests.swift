import ApprovalInbox
import Foundation
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Desk approvals refresh and error behavior", .serialized)
struct DeskApprovalsRefreshAndErrorBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-approvals-refresh-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func readerFailure(_ detail: String) -> NSError {
        NSError(domain: "DeskApprovalRefreshEval", code: 1, userInfo: [
            NSLocalizedDescriptionKey: detail,
        ])
    }

    // app.desk / desk.approvals.refreshAndError
    @Test("a durable approval refresh replaces the rendered state and clears an earlier failure")
    @MainActor func successfulRefreshUsesTheCanonicalApprovalReader() async throws {
        let root = try temporaryRoot("success")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let created = try await inbox.create(.object([
            "title": .string("Refresh canonical approval"),
            "action": .string("desk_note"),
            "risk": .string("confirm"),
            "reason": .string("Exercise the mounted reader"),
            "payload": .object([:]),
        ]))
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let state = ApprovalLoadState()

        let initiallyFailed = await state.reload { throw Self.readerFailure("temporary outage") }
        #expect(!initiallyFailed)
        #expect(state.errorText?.contains("Approvals couldn't load.") == true)

        let refreshed = await state.reload { try await client.getApprovals() }
        #expect(refreshed)
        #expect(state.approvals.map(\.id) == [created.id])
        #expect(state.approvals.first?.status == "pending")
        #expect(state.errorText == nil)
    }

    // app.desk / desk.approvals.refreshAndError
    @Test("a failed refresh retains prior approvals and labels them as last-known")
    @MainActor func failedRefreshDoesNotTurnLastGoodApprovalsIntoAQuietEmptyState() async throws {
        let root = try temporaryRoot("retained")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let created = try await inbox.create(.object([
            "title": .string("Retain last good approval"),
            "action": .string("desk_note"),
            "risk": .string("confirm"),
            "reason": .string("Exercise retained data"),
            "payload": .object([:]),
        ]))
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let state = ApprovalLoadState()
        #expect(await state.reload { try await client.getApprovals() })
        let lastGood = state.approvals

        let refreshed = await state.reload { throw Self.readerFailure("approval store is unreadable") }
        #expect(!refreshed)
        #expect(state.approvals == lastGood)
        #expect(state.approvals.map(\.id) == [created.id])
        #expect(state.errorText == "Approvals couldn't refresh — showing 1 previously loaded approval. approval store is unreadable")
    }

    // app.desk / desk.approvals.refreshAndError
    @Test("a cold refresh failure is explicit and cannot claim no approvals need action")
    @MainActor func coldFailureHasNoFalseQuietState() async {
        let state = ApprovalLoadState()
        let refreshed = await state.reload { throw Self.readerFailure("approval store unavailable") }

        #expect(!refreshed)
        #expect(state.approvals.isEmpty)
        #expect(state.errorText == "Approvals couldn't load. approval store unavailable")
    }
}
