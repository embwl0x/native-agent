import Foundation
import Testing
@testable import NativeAgentApp

private final class FirstRunGreetingCapture: @unchecked Sendable {
    var providerReady = true
    var acceptance: AppModel.ChatTurnAcceptance = .accepted(sessionId: "first-run-session")
    var sendCount = 0
    var observedDurableClaim = false
    var lastKickoff = ""
    var lastSessionID = ""
    var hidUserBubble = false
}

@MainActor
@Suite("First-run greeting durable behavior", .serialized)
struct FirstRunGreetingBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-run-greeting-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func appModel(root: URL, capture: FirstRunGreetingCapture) -> AppModel {
        let model = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
        model.firstRunGreetingPublicReleaseOverride = true
        model.activeChatSessionId = "first-run-session"
        model.firstRunGreetingProviderReadyOverride = {
            capture.providerReady
        }
        model.firstRunGreetingSendOverride = { kickoff, sessionID, hideUserBubble in
            capture.sendCount += 1
            capture.lastKickoff = kickoff
            capture.lastSessionID = sessionID
            capture.hidUserBubble = hideUserBubble
            let pending = root.appendingPathComponent(".needs_welcome")
            let inFlight = root.appendingPathComponent(".needs_welcome.inflight")
            capture.observedDurableClaim = !FileManager.default.fileExists(atPath: pending.path)
                && FileManager.default.fileExists(atPath: inFlight.path)
            return capture.acceptance
        }
        return model
    }

    // app.chat / loop.chat.firstRunGreeting
    @Test("accepted delivery is claimed before the hidden handoff and never repeats after restart")
    func acceptedGreetingIsExactlyOnceAcrossRestart() async throws {
        let root = try temporaryRoot("accepted")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FirstRunGreetingCapture()
        let model = appModel(root: root, capture: capture)

        model.markFirstRunWelcomePending()
        await model.maybeSendFirstRunGreeting()

        let pending = root.appendingPathComponent(".needs_welcome")
        let inFlight = root.appendingPathComponent(".needs_welcome.inflight")
        #expect(capture.sendCount == 1)
        #expect(capture.observedDurableClaim)
        #expect(capture.hidUserBubble)
        #expect(capture.lastSessionID == "first-run-session")
        #expect(capture.lastKickoff.contains("ONLY if you genuinely know it"))
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        #expect(!FileManager.default.fileExists(atPath: inFlight.path))

        let relaunchedCapture = FirstRunGreetingCapture()
        let relaunched = appModel(root: root, capture: relaunchedCapture)
        await relaunched.maybeSendFirstRunGreeting()
        #expect(relaunchedCapture.sendCount == 0)
    }

    // app.chat / loop.chat.firstRunGreeting
    @Test("unavailable providers defer and rejected handoffs restore the pending marker")
    func adverseProviderAndRejectedHandoffRemainRetryable() async throws {
        let root = try temporaryRoot("retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FirstRunGreetingCapture()
        let model = appModel(root: root, capture: capture)
        let pending = root.appendingPathComponent(".needs_welcome")
        let inFlight = root.appendingPathComponent(".needs_welcome.inflight")

        model.markFirstRunWelcomePending()
        capture.providerReady = false
        await model.maybeSendFirstRunGreeting()
        #expect(capture.sendCount == 0)
        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(!FileManager.default.fileExists(atPath: inFlight.path))

        capture.providerReady = true
        capture.acceptance = .rejected(message: "chat is unavailable")
        await model.maybeSendFirstRunGreeting()
        #expect(capture.sendCount == 1)
        #expect(capture.observedDurableClaim)
        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(!FileManager.default.fileExists(atPath: inFlight.path))

        capture.acceptance = .accepted(sessionId: "first-run-session")
        await model.maybeSendFirstRunGreeting()
        #expect(capture.sendCount == 2)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        #expect(!FileManager.default.fileExists(atPath: inFlight.path))
    }

    // app.chat / loop.chat.firstRunGreeting
    @Test("a restart with an in-flight marker suppresses a duplicate hidden greeting")
    func unknownOutcomeOnRestartIsNotRetried() async throws {
        let root = try temporaryRoot("unknown-outcome")
        defer { try? FileManager.default.removeItem(at: root) }
        let inFlight = root.appendingPathComponent(".needs_welcome.inflight")
        try Data("claimed-before-send\n".utf8).write(to: inFlight, options: [.atomic])

        let capture = FirstRunGreetingCapture()
        let relaunched = appModel(root: root, capture: capture)
        await relaunched.maybeSendFirstRunGreeting()

        #expect(capture.sendCount == 0)
        #expect(FileManager.default.fileExists(atPath: inFlight.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".needs_welcome").path))
    }
}
