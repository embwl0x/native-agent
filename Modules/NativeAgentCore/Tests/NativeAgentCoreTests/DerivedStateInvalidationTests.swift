@testable import NativeAgentCore
import Foundation
import Testing

private actor RecordingDerivedStateSink: DerivedStateInvalidationSink {
    private(set) var batches: [[DerivedSourceChange]] = []
    private(set) var cancellationStates: [Bool] = []

    func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        batches.append(changes)
        cancellationStates.append(Task.isCancelled)
    }

    func recorded() -> [[DerivedSourceChange]] { batches }
    func recordedCancellationStates() -> [Bool] { cancellationStates }
}

private final class FlushAdmissionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int?
    private var waiter: CheckedContinuation<Int, Never>?

    func signal(_ count: Int) {
        let continuation = lock.withLock {
            self.count = count
            let result = waiter
            waiter = nil
            return result
        }
        continuation?.resume(returning: count)
    }

    func value() async -> Int {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let count {
                lock.unlock()
                continuation.resume(returning: count)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

private actor BlockingDerivedStateSink: DerivedStateInvalidationSink {
    private var entered: Set<String> = []
    private var completed: Set<String> = []
    private var arrivals: [String: CheckedContinuation<Void, Never>] = [:]
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var cancellationStates: [Bool] = []

    func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        guard let id = changes.first?.stableID else { return }
        cancellationStates.append(Task.isCancelled)
        entered.insert(id)
        arrivals.removeValue(forKey: id)?.resume()
        await withCheckedContinuation { releases[id] = $0 }
        cancellationStates.append(Task.isCancelled)
        completed.insert(id)
    }

    func waitUntilEntered(_ id: String) async {
        if entered.contains(id) { return }
        await withCheckedContinuation { arrivals[id] = $0 }
    }

    func release(_ id: String) { releases.removeValue(forKey: id)?.resume() }
    func didComplete(_ id: String) -> Bool { completed.contains(id) }
}

private func invalidationChange(_ id: String) -> DerivedSourceChange {
    DerivedSourceChange(namespace: "memory-v2", stableID: id, operation: .removed, reason: "correction fixture")
}

@Test
func derivedStateFlushJoinsActiveDeliveryAndConcurrentFlushes() async {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 0)
    let sink = BlockingDerivedStateSink()
    await center.install(sink)
    await center.publish(invalidationChange("old-fact"))
    // The timer has already drained pending; the sink has not yet published.
    await sink.waitUntilEntered("old-fact")
    let firstAdmission = FlushAdmissionLatch()
    let secondAdmission = FlushAdmissionLatch()
    let first = Task {
        await center.flush(onAdmission: firstAdmission.signal)
        return await sink.didComplete("old-fact")
    }
    let second = Task {
        await center.flush(onAdmission: secondAdmission.signal)
        return await sink.didComplete("old-fact")
    }
    #expect(await firstAdmission.value() == 1)
    #expect(await secondAdmission.value() == 1)
    #expect(await sink.didComplete("old-fact") == false)
    first.cancel()
    await sink.release("old-fact")
    #expect(await first.value)
    #expect(await second.value)
    #expect(await sink.cancellationStates == [false, false])

    // Completion removes tracking without requiring a later drain to clean it.
    let emptyAdmission = FlushAdmissionLatch()
    await center.flush(onAdmission: emptyAdmission.signal)
    #expect(await emptyAdmission.value() == 0)
}

@Test
func derivedStateFlushDoesNotJoinLaterPublishedDelivery() async {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 0)
    let sink = BlockingDerivedStateSink()
    await center.install(sink)
    await center.publish(invalidationChange("first"))
    await sink.waitUntilEntered("first")
    let admission = FlushAdmissionLatch()
    let flush = Task { await center.flush(onAdmission: admission.signal) }
    #expect(await admission.value() == 1)

    await center.publish(invalidationChange("later"))
    await sink.waitUntilEntered("later")
    await sink.release("first")
    await flush.value
    #expect(await sink.didComplete("later") == false)
    let laterAdmission = FlushAdmissionLatch()
    let laterFlush = Task { await center.flush(onAdmission: laterAdmission.signal) }
    #expect(await laterAdmission.value() == 1)
    await sink.release("later")
    await laterFlush.value
}

@Test
func derivedStateNewInstallationDoesNotAwaitDetachedOldSink() async {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 0)
    let oldSink = BlockingDerivedStateSink()
    await center.install(oldSink)
    await center.publish(invalidationChange("old"))
    await oldSink.waitUntilEntered("old")
    let oldAdmission = FlushAdmissionLatch()
    let oldFlush = Task { await center.flush(onAdmission: oldAdmission.signal) }
    #expect(await oldAdmission.value() == 1)
    await center.install(nil)

    let newSink = BlockingDerivedStateSink()
    await center.install(newSink)
    await center.publish(invalidationChange("new"))
    await newSink.waitUntilEntered("new")
    let newAdmission = FlushAdmissionLatch()
    let newFlush = Task { await center.flush(onAdmission: newAdmission.signal) }
    #expect(await newAdmission.value() == 1)
    await newSink.release("new")
    await newFlush.value
    #expect(await oldSink.didComplete("old") == false)
    await oldSink.release("old")
    await oldFlush.value
    #expect(await oldSink.cancellationStates == [false, false])
}

@Test
func derivedStateCanceledFlushCallerDoesNotCancelPendingSinkDelivery() async {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 60_000_000_000)
    let sink = BlockingDerivedStateSink()
    await center.install(sink)
    await center.publish(invalidationChange("pending"))
    let admission = FlushAdmissionLatch()
    let flush = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await center.flush(onAdmission: admission.signal)
    }
    #expect(await admission.value() == 1)
    await sink.waitUntilEntered("pending")
    await sink.release("pending")
    await flush.value
    #expect(await sink.cancellationStates == [false, false])
}

@Test
func derivedStateInvalidationSingleChangeUsesBatchContract() async {
    let sink = RecordingDerivedStateSink()
    let change = DerivedSourceChange(
        namespace: " persona ",
        stableID: " SOUL.md ",
        operation: .changed,
        reason: " save "
    )

    await sink.sourceDidChange(change)

    let batches = await sink.recorded()
    #expect(batches == [[change]])
    #expect(change.namespace == "persona")
    #expect(change.stableID == "SOUL.md")
    #expect(change.reason == "save")
}

@Test
func derivedStateInvalidationCenterForwardsOnlyWhileInstalled() async {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 0)
    let sink = RecordingDerivedStateSink()
    let change = DerivedSourceChange(
        namespace: "memory-v2",
        stableID: "memory-1",
        operation: .changed,
        reason: "test"
    )

    await center.publish(change)
    await center.install(sink)
    await center.publish(change)
    await center.flush()
    await center.install(nil)
    await center.publish(change)

    #expect(await sink.recorded() == [[change]])
}

@Test
func derivedStateInvalidationCenterCoalescesLatestChangePerCanonicalSource() async {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 1_000_000_000)
    let sink = RecordingDerivedStateSink()
    await center.install(sink)
    await center.publish(DerivedSourceChange(
        namespace: "memory-v2",
        stableID: "memory-1",
        operation: .changed,
        reason: "first"
    ))
    let latest = DerivedSourceChange(
        namespace: "memory-v2",
        stableID: "memory-1",
        operation: .removed,
        reason: "latest"
    )
    await center.publish(latest)
    await center.flush()

    #expect(await sink.recorded() == [[latest]])
}

@Test
func derivedStateInvalidationCoalescingPreservesDistinctDatabaseRoots() async {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 60_000_000_000)
    let sink = RecordingDerivedStateSink()
    await center.install(sink)
    let live = DerivedSourceChange(
        namespace: "memory-v2", stableID: "same-backed-up-row", operation: .changed,
        canonicalLocator: "/fixture/live/memory/memory.sqlite", reason: "live write"
    )
    let candidate = DerivedSourceChange(
        namespace: "memory-v2", stableID: "same-backed-up-row", operation: .removed,
        canonicalLocator: "/fixture/live/memory/consolidation/candidates/run/memory/memory.sqlite",
        reason: "candidate-only consolidation"
    )
    await center.publish(live)
    await center.publish(candidate)
    await center.flush()

    let batches = await sink.recorded()
    #expect(batches.count == 1)
    #expect(Set(batches.flatMap { $0 }) == [live, candidate])
    await center.install(nil)
}

@Test
func derivedStateInvalidationAutomaticDeliveryDoesNotCancelItsSink() async throws {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 5_000_000)
    let sink = RecordingDerivedStateSink()
    let change = DerivedSourceChange(
        namespace: "persona",
        stableID: "VOICE.md",
        operation: .changed,
        reason: "automatic delivery"
    )
    await center.install(sink)
    await center.publish(change)

    // 10s, not 1s: this polls, so a passing run pays only the actual delivery
    // latency — but the 1s ceiling starved under full-suite parallel load and
    // flaked the canonical gate twice on 2026-07-20/21 (passes instantly solo).
    let deadline = ContinuousClock.now + .seconds(10)
    while await sink.recorded().isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(await sink.recorded() == [[change]])
    #expect(await sink.recordedCancellationStates() == [false])
}

@Test
func derivedStateInvalidationUninstallInvalidatesOlderScheduledDelivery() async throws {
    let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 20_000_000)
    let sink = RecordingDerivedStateSink()
    let old = DerivedSourceChange(
        namespace: "memory-v2",
        stableID: "old",
        operation: .changed,
        reason: "before uninstall"
    )
    let new = DerivedSourceChange(
        namespace: "memory-v2",
        stableID: "new",
        operation: .changed,
        reason: "after reinstall"
    )

    await center.install(sink)
    await center.publish(old)
    await center.install(nil)
    await center.install(sink)
    await center.publish(new)

    // 10s, not 1s: this polls, so a passing run pays only the actual delivery
    // latency — but the 1s ceiling starved under full-suite parallel load and
    // flaked the canonical gate twice on 2026-07-20/21 (passes instantly solo).
    let deadline = ContinuousClock.now + .seconds(10)
    while await sink.recorded().isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await sink.recorded() == [[new]])
    #expect(await sink.recordedCancellationStates() == [false])
}
