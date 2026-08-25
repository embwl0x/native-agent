import CognitiveSubstrate
import Foundation
import Observation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / loop.activityCognitionSubscription
@MainActor
@Suite("Activity cognition subscription", .serialized)
struct ActivityCognitionSubscriptionEvalTests {
    private final class SubscriptionChangeContinuation: @unchecked Sendable {
        let continuation: CheckedContinuation<Void, Never>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            continuation.resume()
        }
    }

    @Test("the mounted subscription receives real cognition revisions once, serially, and stops cleanly")
    func activityProjectionTracksRuntimeChangesWithoutLeakingAfterStop() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        // Bootstrap before mounting. The runtime emits its bootstrap revision
        // during this call; starting the subscription afterward makes its
        // first observed revision the deliberate test mutation below.
        await runtime.bootstrap()
        let subscription = ActivityCognitionSubscription(runtime: runtime)

        subscription.start()
        subscription.start() // mounted lifecycle is idempotent
        await waitForSubscription(subscription) {
            $0.state == .active && $0.refreshCount == 1
        }

        await runtime.publishRuntimeChange(reason: "activity-subscription-eval")
        await waitForSubscription(subscription) {
            $0.lastRevision == 2 && $0.refreshCount == 2
        }
        #expect(subscription.peakConcurrentRefreshes == 1)

        for index in 2...32 {
            await runtime.publishRuntimeChange(reason: "activity-subscription-burst-\(index)")
        }
        await waitForSubscription(subscription) { $0.lastRevision == 33 }
        #expect(subscription.peakConcurrentRefreshes == 1)

        let repeated = NativeCognitionRuntimeChange(
            revision: 33,
            occurredAt: Date(),
            reason: "same-revision"
        )
        #expect(!ActivityCognitionSubscription.shouldRefresh(for: repeated, after: subscription.lastRevision))

        let refreshesBeforeStop = subscription.refreshCount
        subscription.stop()
        #expect(subscription.state == .stopped)
        await runtime.publishRuntimeChange(reason: "after-stop")
        // One scheduler turn lets a cancelled stream consumer observe the
        // emitted revision; this is a cancellation boundary, not polling.
        await Task.yield()
        #expect(subscription.refreshCount == refreshesBeforeStop)
    }

    @Test("disabled cognition is unavailable rather than a quiet zero-proposal subscription")
    func disabledRuntimeHasAnExplicitUnavailableState() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = CognitiveConfiguration.allPhasesEnabled
        configuration.enabled = false
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        let subscription = ActivityCognitionSubscription(runtime: runtime)

        subscription.start()
        await waitForSubscription(subscription) {
            $0.state == .unavailable("Cognition proposals are unavailable while cognition is off.")
        }
        #expect(subscription.pending.count == 0)
        subscription.stop()
    }

    private func waitForSubscription(
        _ subscription: ActivityCognitionSubscription,
        until condition: @escaping @MainActor (ActivityCognitionSubscription) -> Bool
    ) async {
        while !condition(subscription) {
            await nextSubscriptionChange(subscription)
        }
    }

    private func nextSubscriptionChange(_ subscription: ActivityCognitionSubscription) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let signal = SubscriptionChangeContinuation(continuation)
            withObservationTracking {
                _ = subscription.state
                _ = subscription.lastRevision
                _ = subscription.refreshCount
            } onChange: {
                signal.resume()
            }
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-cognition-subscription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
