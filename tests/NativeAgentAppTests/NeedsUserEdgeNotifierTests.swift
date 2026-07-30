import Foundation
import Testing
@testable import NativeAgentApp

private enum NeedsUserTestError: Error {
    case deliveryFailed
}

private actor NeedsUserSendRecorder {
    struct Call: Sendable {
        let title: String
        let body: String
        let userInfo: [String: String]
    }

    private var failuresRemaining: Int
    private(set) var calls: [Call] = []

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func send(title: String, body: String, userInfo: [String: String]) throws {
        calls.append(Call(title: title, body: body, userInfo: userInfo))
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NeedsUserTestError.deliveryFailed
        }
    }
}

@Suite("Needs-User notification edge", .serialized)
struct NeedsUserEdgeNotifierTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("needs-user-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func failedDeliveryRetriesAndCommitsOnlyAfterSuccess() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = NeedsUserSendRecorder(failuresRemaining: 1)
        let notifier = NeedsUserEdgeNotifier(dataRoot: root) { title, body, userInfo in
            try await recorder.send(title: title, body: body, userInfo: userInfo)
        }

        await notifier.evaluate(needsUser: false, why: "") // seed baseline
        await notifier.evaluate(needsUser: true, why: "A build needs your decision")
        await notifier.evaluate(needsUser: true, why: "A build needs your decision")
        await notifier.evaluate(needsUser: true, why: "A build needs your decision")

        let calls = await recorder.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.title == "NativeAgent needs you" })
        #expect(calls.allSatisfy { $0.userInfo["kind"] == "agent_needs_user" })
        #expect(calls[0].userInfo["dedupKey"] == calls[1].userInfo["dedupKey"])
    }

    @Test func durableSuccessDoesNotRepingAfterNotifierRestart() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRecorder = NeedsUserSendRecorder()
        let first = NeedsUserEdgeNotifier(dataRoot: root) { title, body, userInfo in
            try await firstRecorder.send(title: title, body: body, userInfo: userInfo)
        }
        await first.evaluate(needsUser: false, why: "")
        await first.evaluate(needsUser: true, why: "Review the approval")
        #expect(await firstRecorder.calls.count == 1)

        let restartedRecorder = NeedsUserSendRecorder()
        let restarted = NeedsUserEdgeNotifier(dataRoot: root) { title, body, userInfo in
            try await restartedRecorder.send(title: title, body: body, userInfo: userInfo)
        }
        await restarted.evaluate(needsUser: true, why: "Review the approval")
        #expect(await restartedRecorder.calls.isEmpty)
    }

    @Test func changedReasonRepingsOnceAndUsesStableDigest() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = NeedsUserSendRecorder()
        let notifier = NeedsUserEdgeNotifier(dataRoot: root) { title, body, userInfo in
            try await recorder.send(title: title, body: body, userInfo: userInfo)
        }

        await notifier.evaluate(needsUser: false, why: "")
        await notifier.evaluate(needsUser: true, why: "First reason")
        await notifier.evaluate(needsUser: true, why: "Second reason")
        await notifier.evaluate(needsUser: true, why: "Second reason")

        let calls = await recorder.calls
        #expect(calls.count == 2)
        #expect(calls[0].userInfo["dedupKey"] == "needs_user+\(NeedsUserEdgeNotifier.stableDigest("First reason"))")
        #expect(calls[1].userInfo["dedupKey"] == "needs_user+\(NeedsUserEdgeNotifier.stableDigest("Second reason"))")
        #expect(calls[0].userInfo["dedupKey"] != calls[1].userInfo["dedupKey"])
    }
}
