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

    @Test("the initial approval summary cannot claim an empty inbox before a successful read")
    @MainActor func uncheckedAndKnownEmptyAreDifferent() async {
        let state = ApprovalLoadState()
        #expect(!state.hasLoadedSnapshot)
        #expect(state.summaryTitle == "Checking approvals…")
        #expect(await state.reload { [] })
        #expect(state.hasLoadedSnapshot)
        #expect(state.summaryTitle == "No actions need approval")
    }

    @Test("retry keeps its prior failure visible until the replacement read succeeds")
    @MainActor func retryRetainsFailureEvidence() async {
        let state = ApprovalLoadState()
        #expect(await state.reload { [] })
        #expect(!(await state.reload { throw Self.readerFailure("offline") }))
        #expect(state.summaryTitle == "Approval refresh failed")
        var continuation: CheckedContinuation<[ApprovalRequest], Never>?
        let retry = Task { @MainActor in
            await state.reload { await withCheckedContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        #expect(state.isRefreshing)
        #expect(state.refreshErrorText?.contains("offline") == true)
        #expect(state.summaryTitle == "Approval refresh failed")
        state.clearActionError()
        #expect(state.refreshErrorText != nil)
        continuation?.resume(returning: [])
        #expect(await retry.value)
        #expect(!state.isRefreshing)
        #expect(state.refreshErrorText == nil)
    }

    @Test("an older read cannot overwrite a newer unavailable result or clear its warning")
    @MainActor func olderSuccessCannotHideNewerFailure() async {
        let state = ApprovalLoadState()
        var continuation: CheckedContinuation<[ApprovalRequest], Never>?
        let oldRead = Task { @MainActor in
            await state.reload { await withCheckedContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        #expect(!(await state.reload { throw Self.readerFailure("newer failure") }))
        continuation?.resume(returning: [])
        #expect(!(await oldRead.value))
        #expect(!state.hasLoadedSnapshot)
        #expect(state.summaryTitle == "Approval status unavailable")
        #expect(state.refreshErrorText?.contains("newer failure") == true)
    }

    @Test("older failures and canceled reads cannot replace the current successful snapshot")
    @MainActor func outdatedFailureAndCancellationCannotPublish() async {
        let state = ApprovalLoadState()
        var continuation: CheckedContinuation<[ApprovalRequest], any Error>?
        let oldRead = Task { @MainActor in
            await state.reload { try await withCheckedThrowingContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        #expect(await state.reload { [] })
        continuation?.resume(throwing: Self.readerFailure("old failure"))
        #expect(!(await oldRead.value))
        #expect(state.refreshErrorText == nil)

        continuation = nil
        let canceledRead = Task { @MainActor in
            await state.reload { try await withCheckedThrowingContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        canceledRead.cancel()
        continuation?.resume(throwing: CancellationError())
        #expect(!(await canceledRead.value))
        #expect(!state.isRefreshing)
        #expect(state.summaryTitle == "No actions need approval")
        #expect(state.refreshErrorText == nil)
    }
}
