import Foundation
import Testing
@testable import NativeAgentApp

private final class OnboardingCompletionRouteCapture: @unchecked Sendable {
    var sendCount = 0
}

@MainActor
@Suite("app.mac · Onboarding wizard completion route", .serialized)
struct OnboardingWizardCompletionRouteBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-completion-route-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func refreshReceipt() -> AppModel.PanelRefreshStatus {
        AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(),
            lastSuccessAt: Date(),
            failedEndpoints: []
        )
    }

    private func appModel(root: URL, capture: OnboardingCompletionRouteCapture) -> AppModel {
        let model = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
        model.firstRunGreetingPublicReleaseOverride = true
        model.activeChatSessionId = "onboarding-session"
        model.firstRunGreetingProviderReadyOverride = { true }
        model.firstRunGreetingSendOverride = { _, _, _ in
            capture.sendCount += 1
            return .accepted(sessionId: "onboarding-session")
        }
        return model
    }

    @Test("first completion selects and refreshes Chat before writing one greeting; a second route does not duplicate it")
    func completionRoutesOneDurableGreeting() async throws {
        let root = try temporaryRoot("exactly-once")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = OnboardingCompletionRouteCapture()
        let model = appModel(root: root, capture: capture)
        model.markFirstRunWelcomePending()
        var events: [String] = []

        let first = await OnboardingWizardCompletionRoute.complete(
            selectChat: { events.append("select-chat") },
            refreshChat: {
                events.append("refresh-chat")
                return self.refreshReceipt()
            },
            sendGreeting: {
                events.append("send-greeting")
                return await model.maybeSendFirstRunGreeting()
            },
            record: { model.recordOnboardingWizardCompletion($0) }
        )
        let second = await OnboardingWizardCompletionRoute.complete(
            selectChat: { events.append("select-chat-again") },
            refreshChat: {
                events.append("refresh-chat-again")
                return self.refreshReceipt()
            },
            sendGreeting: {
                events.append("send-greeting-again")
                return await model.maybeSendFirstRunGreeting()
            },
            record: { model.recordOnboardingWizardCompletion($0) }
        )

        #expect(events == [
            "select-chat", "refresh-chat", "send-greeting",
            "select-chat-again", "refresh-chat-again", "send-greeting-again"
        ])
        #expect(first.destination == .chat)
        #expect(first.greeting == .delivered(sessionId: "onboarding-session"))
        #expect(second.greeting == .notArmed)
        #expect(capture.sendCount == 1)
        #expect(model.onboardingWizardCompletionReceipt == second)
    }

    @Test("a rejected greeting handoff remains pending and is recorded rather than dismissed as success")
    func rejectedGreetingIsRecordedAsAdverseCompletion() async throws {
        let root = try temporaryRoot("rejected")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = OnboardingCompletionRouteCapture()
        let model = appModel(root: root, capture: capture)
        model.firstRunGreetingSendOverride = { _, _, _ in
            capture.sendCount += 1
            return .rejected(message: "chat is unavailable")
        }
        model.markFirstRunWelcomePending()

        let receipt = await OnboardingWizardCompletionRoute.complete(
            selectChat: {},
            refreshChat: { self.refreshReceipt() },
            sendGreeting: { await model.maybeSendFirstRunGreeting() },
            record: { model.recordOnboardingWizardCompletion($0) }
        )

        #expect(receipt.greeting == .rejected(message: "chat is unavailable"))
        #expect(capture.sendCount == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".needs_welcome").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".needs_welcome.inflight").path))
        #expect(model.onboardingWizardCompletionReceipt == receipt)
        #expect(model.statusText.contains("Chat rejected the first greeting: chat is unavailable"))
    }
}
