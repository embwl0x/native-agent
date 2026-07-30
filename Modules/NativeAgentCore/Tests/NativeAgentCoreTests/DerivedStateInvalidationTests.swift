import NativeAgentCore
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
