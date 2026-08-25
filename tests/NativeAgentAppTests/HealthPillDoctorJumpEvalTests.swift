import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.doctorJumpFromHealthPill
@MainActor
@Suite("Health pill Doctor jump", .serialized)
struct HealthPillDoctorJumpEvalTests {
    @Test("a mounted scene receives the exact Doctor diagnostics destination")
    func mountedJumpIsDeliveredWithoutClaimingRenderCompletion() {
        let calls = Counter()
        let coordinator = makeCoordinator(calls: calls)
        var destinations: [NativeAgentNavigationDestination] = []
        _ = coordinator.mountMainScene { destinations.append($0) }

        let receipt = HealthPillDoctorJump.request(using: coordinator)

        #expect(receipt == .deliveredToMountedScene)
        #expect(destinations == [.sidebar(.diagnostics)])
        #expect(calls.values == [1, 1])
        #expect(HealthPillDoctorJump.help(for: receipt) == "Doctor navigation was delivered to the app window.")
    }

    @Test("a windowless jump remains queued until a scene can accept it")
    func windowlessJumpIsQueuedAndLaterDelivered() {
        let calls = Counter()
        let coordinator = makeCoordinator(calls: calls)

        let receipt = HealthPillDoctorJump.request(using: coordinator)
        #expect(receipt == .queuedForMainScene)
        #expect(calls.values == [1, 1])
        #expect(HealthPillDoctorJump.help(for: receipt) == "Doctor navigation is queued until the main window is ready.")

        var destinations: [NativeAgentNavigationDestination] = []
        _ = coordinator.mountMainScene { destinations.append($0) }
        #expect(destinations == [.sidebar(.diagnostics)])
    }

    private func makeCoordinator(calls: Counter) -> NativeAgentAppCoordinator {
        NativeAgentAppCoordinator(
            notificationCenter: NotificationCenter(),
            windowActions: .init(
                activateApplication: { calls.increment(index: 0) },
                openMainWindow: { calls.increment(index: 1) }
            )
        )
    }
}

@MainActor
private final class Counter {
    private(set) var values = [0, 0]

    func increment(index: Int) {
        values[index] += 1
    }
}
