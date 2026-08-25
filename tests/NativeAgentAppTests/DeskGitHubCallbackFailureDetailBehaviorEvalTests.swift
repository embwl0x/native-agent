import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Desk GitHub callback failure detail behavior", .serialized)
struct DeskGitHubCallbackFailureDetailBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-github-callback-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func observation() -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets",
            number: 42,
            kind: .pullRequest,
            title: "Show callback detail in Desk",
            isOpen: true,
            observedVersion: "callback-detail-observed",
            actionableEventVersion: "callback-detail-event",
            signals: [.reviewComment],
            headSHA: "abc123",
            waitingKind: .review
        )
    }

    private func persistedCallback(
        root: URL,
        status: String,
        errorMessage: String? = nil,
        noWorkObserved: Bool? = nil
    ) async throws -> GitHubCommandItem {
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation())
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        return try #require(try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: status,
            summary: "Callback for Desk presentation evaluation.",
            errorMessage: errorMessage,
            noWorkObserved: noWorkObserved
        ).first)
    }

    // app.desk / desk.github.callbackFailureDetail
    @Test("a persisted uppercase callback failure retains provider detail and resend safety in Desk")
    func persistedFailureDetailSurvivesTheDeskProjection() async throws {
        let root = try temporaryRoot("failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await persistedCallback(
            root: root,
            status: "FAILED",
            errorMessage: "OpenAI is experiencing high demand (503)",
            noWorkObserved: true
        )

        let detail = try #require(DeskGitHubCallbackFailurePresentation.detail(for: item))
        #expect(detail.message == "OpenAI is experiencing high demand (503)")
        #expect(detail.noWorkObserved == true)
    }

    // app.desk / desk.github.callbackFailureDetail
    @Test("a no-final-reply callback with no provider text stays visible with a truthful fallback")
    func missingFailureTextDoesNotDisappear() async throws {
        let root = try temporaryRoot("missing-detail")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await persistedCallback(root: root, status: "completed_without_reply")

        let detail = try #require(DeskGitHubCallbackFailurePresentation.detail(for: item))
        #expect(detail.message == "Codex callback ended without a final result.")
        #expect(detail.noWorkObserved == nil)
    }

    // app.desk / desk.github.callbackFailureDetail
    @Test("malformed callback status with adverse evidence is visible, while a healthy callback does not manufacture a failure")
    func malformedAndHealthyCallbackStatesStayDistinct() async throws {
        let malformedRoot = try temporaryRoot("malformed")
        defer { try? FileManager.default.removeItem(at: malformedRoot) }
        let malformed = try await persistedCallback(
            root: malformedRoot,
            status: "   ",
            noWorkObserved: false
        )
        let malformedDetail = try #require(DeskGitHubCallbackFailurePresentation.detail(for: malformed))
        #expect(malformedDetail.message == "Codex callback returned no usable status without an error detail.")
        #expect(malformedDetail.noWorkObserved == false)

        let healthyRoot = try temporaryRoot("healthy")
        defer { try? FileManager.default.removeItem(at: healthyRoot) }
        let healthy = try await persistedCallback(root: healthyRoot, status: "completed")
        #expect(DeskGitHubCallbackFailurePresentation.detail(for: healthy) == nil)
    }
}
