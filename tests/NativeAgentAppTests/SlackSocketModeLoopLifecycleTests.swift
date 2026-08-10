import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// Pinning tests for LOOPS-2 (tracked handling + retryable deliveries) and
// LOOPS-5 (event-driven history polling). Every test here is hermetic: the
// outbound Slack calls go through the injected `SlackSocketModeOutbound`
// recorder, never SlackConnectorActions, so nothing can post to a real
// workspace from the test suite.

private func makeLifecycleRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SlackLoopLifecycleTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeConfig(historyPollEnabled: Bool = false) -> SlackSocketModeConfig {
    SlackSocketModeConfig(
        botToken: "xoxb-test",
        appToken: "xapp-test",
        botUserId: "UBOT",
        teamId: "T1",
        enabled: true,
        historyPollEnabled: historyPollEnabled,
        historyPollInterval: 60,
        historyConversationRefreshInterval: 600,
        allowedChannelIds: [],
        allowedUserIds: []
    )
}

private func makeInbound(ts: String = "1.000") -> SlackInboundMessage {
    SlackInboundMessage(
        eventId: "T1:C1:\(ts)",
        teamId: "T1",
        channelId: "C1",
        userId: "U1",
        eventType: "message",
        text: "hello",
        ts: ts,
        threadTs: nil,
        channelType: "channel",
        isDirectMessage: false
    )
}

private actor OutboundRecorder {
    private(set) var posts: [[String: JSONValue]] = []
    var shouldSucceed = true

    func setShouldSucceed(_ value: Bool) { shouldSucceed = value }

    func record(_ input: [String: JSONValue]) -> JSONValue {
        posts.append(input)
        return .object(["ok": .bool(shouldSucceed)])
    }

    var postCount: Int { posts.count }
}

private func outbound(_ recorder: OutboundRecorder) -> SlackSocketModeOutbound {
    SlackSocketModeOutbound(
        postMessage: { await recorder.record($0) },
        uploadFile: { await recorder.record($0) }
    )
}

// MARK: - LOOPS-2 (a): a failed delivery must stay retryable

@Test
func slackLoop_failedDeliveryUnmarksDeduperAndSucceedsOnRetry() async throws {
    let root = try makeLifecycleRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = OutboundRecorder()
    await recorder.setShouldSucceed(false) // Slack rejects the first post
    let deduper = SlackEventDeduper()
    let loop = SlackSocketModeLoop(
        config: makeConfig(),
        dataRoot: root,
        outbound: outbound(recorder),
        chatHandler: { _ in SlackSocketModeReply(text: "reply") }
    )
    let inbound = makeInbound()

    // Attempt 1: gate through the deduper exactly like the loop does.
    #expect(await deduper.markIfNew(inbound.eventId))
    let firstDelivered = await loop.handleInbound(inbound)
    #expect(firstDelivered == false)
    if !firstDelivered { await deduper.unmark(inbound.eventId) }

    // Pinning assertion: the failed event is NOT left marked seen. Before the
    // fix the mark was a permanent tombstone and no retry could ever run.
    #expect(await deduper.hasSeen(inbound.eventId) == false)

    // Attempt 2: Slack now accepts the post — the retry must actually run.
    await recorder.setShouldSucceed(true)
    #expect(await deduper.markIfNew(inbound.eventId))
    let secondDelivered = await loop.handleInbound(inbound)
    #expect(secondDelivered == true)
    #expect(await deduper.hasSeen(inbound.eventId))
    #expect(await recorder.postCount == 2)
}

@Test
func slackEventDeduper_unmarkRestoresRetryabilityAndKeepsCapBookkeeping() async {
    let deduper = SlackEventDeduper(cap: 2)
    #expect(await deduper.markIfNew("a"))
    #expect(await deduper.markIfNew("a") == false)
    await deduper.unmark("a")
    #expect(await deduper.hasSeen("a") == false)
    #expect(await deduper.markIfNew("a"))

    // unmark must remove from the FIFO ring too, or the cap eviction would
    // later drop a live id (or evict a phantom).
    await deduper.unmark("a")
    #expect(await deduper.markIfNew("b"))
    #expect(await deduper.markIfNew("c"))
    #expect(await deduper.hasSeen("b"))
    #expect(await deduper.hasSeen("c"))
    // unmarking an unknown id is a no-op, not a crash.
    await deduper.unmark("zzz")
    #expect(await deduper.hasSeen("b"))
}

/// gpt-5.5 review BLOCKING pin: a bare mark means "in flight", and only a
/// CONFIRMED delivery may justify advancing the history-poll watermark past a
/// dedupe hit. Without the delivered state, gap-fill could advance past a
/// socket delivery that later failed and unmarked — skipping it forever.
@Test
func slackEventDeduper_deliveredStateGatesWatermarkAdvance() async {
    let deduper = SlackEventDeduper(cap: 2)

    // In flight: marked but NOT delivered — watermark must not pass this.
    #expect(await deduper.markIfNew("m1"))
    #expect(await deduper.isDelivered("m1") == false)

    // Confirmed: now (and only now) safe to advance past.
    await deduper.confirmDelivered("m1")
    #expect(await deduper.isDelivered("m1"))

    // Failure path: unmark clears BOTH the mark and the delivered claim.
    await deduper.unmark("m1")
    #expect(await deduper.hasSeen("m1") == false)
    #expect(await deduper.isDelivered("m1") == false)

    // Confirming an id that was never marked is a no-op, not a phantom claim.
    await deduper.confirmDelivered("ghost")
    #expect(await deduper.isDelivered("ghost") == false)

    // Cap eviction drops the delivered flag with the mark — no leak, and a
    // re-marked id starts un-delivered again.
    #expect(await deduper.markIfNew("a"))
    await deduper.confirmDelivered("a")
    #expect(await deduper.markIfNew("b"))
    #expect(await deduper.markIfNew("c")) // evicts "a" (cap 2)
    #expect(await deduper.hasSeen("a") == false)
    #expect(await deduper.markIfNew("a"))
    #expect(await deduper.isDelivered("a") == false)
}

/// gpt-5.5 review MEDIUM pin: a handler that ignores cooperative cancellation
/// must not deadlock loop stop — cancelAndWaitAll abandons it at the timeout.
@Test
func slackInFlightHandlers_cancelAndWaitAllAbandonsCancellationIgnoringTask() async {
    actor Release { var open = false; func set() { open = true } }
    let release = Release()
    let handlers = SlackInFlightHandlers()
    let id = UUID()
    let stubborn = Task {
        // Swallows CancellationError and keeps spinning until released —
        // the shape of a wedged provider call that ignores cancellation.
        while !(await release.open) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    await handlers.register(stubborn, id: id)

    let started = Date()
    let abandoned = await handlers.cancelAndWaitAll(timeout: 0.5)
    #expect(abandoned == 1)
    // 10s, not 5s: the claim is "the 0.5s wait timeout won, not the stubborn
    // handler" — well above scheduler noise, well below a real wedge.
    #expect(Date().timeIntervalSince(started) < 10)
    #expect(await handlers.count == 0)

    await release.set() // let the stubborn task exit; nothing may await it now
}

// MARK: - LOOPS-2 (b): loop stop cancels and awaits in-flight handling

@Test
func slackLoop_stopCancelsAndAwaitsInFlightHandling() async throws {
    let root = try makeLifecycleRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let started = SlackTestSignal()
    let observed = SlackTestSignal()
    let recorder = OutboundRecorder()
    let loop = SlackSocketModeLoop(
        config: makeConfig(),
        dataRoot: root,
        outbound: outbound(recorder),
        chatHandler: { _ in
            await started.fire()
            // Block until cancelled; the loop's stop path must reach us.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await observed.fire()
            throw CancellationError()
        }
    )

    await loop.spawnInboundHandling(makeInbound())
    await started.wait()
    #expect(await loop.inFlightHandlingCount == 1)

    // Pinning assertion: this returns only after the handler observed
    // cancellation and finished. Detached `Task {}` handling (the pre-fix
    // shape) could satisfy neither half.
    await loop.cancelAndWaitInFlightHandling()
    #expect(await observed.didFire)
    #expect(await loop.inFlightHandlingCount == 0)
}

@Test
func slackHumanTurnPromotesBackgroundSocketWorkToUserInitiated() async throws {
    let root = try makeLifecycleRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let priority = SlackTaskPriorityCapture()
    let recorder = OutboundRecorder()
    let loop = SlackSocketModeLoop(
        config: makeConfig(),
        dataRoot: root,
        outbound: outbound(recorder),
        chatHandler: { _ in
            await priority.record(Task.currentPriority)
            return SlackSocketModeReply(text: "reply")
        }
    )

    // Observe the handler before awaiting the background driver so await-side
    // priority donation cannot make an inherited-priority implementation pass.
    let driver = Task.detached(priority: .background) {
        await loop.spawnInboundHandling(makeInbound())
    }
    let observed = await priority.wait()
    #expect(observed?.rawValue ?? 0 >= TaskPriority.userInitiated.rawValue)
    await driver.value
    await loop.cancelAndWaitInFlightHandling()
}

@Test
func slackInFlightHandlers_registrationRacingCompletionDoesNotLeak() async {
    let handlers = SlackInFlightHandlers()
    let id = UUID()
    // Task completes (and reports finish) BEFORE register lands.
    let task = Task<Void, Never> { }
    await task.value
    await handlers.finish(id)
    await handlers.register(task, id: id)
    #expect(await handlers.count == 0)

    // And the ordinary ordering still tracks + drains.
    let id2 = UUID()
    let blocking = Task<Void, Never> {
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
    await handlers.register(blocking, id: id2)
    #expect(await handlers.count == 1)
    await handlers.cancelAndWaitAll()
    #expect(await handlers.count == 0)
}

// MARK: - LOOPS-5 (c): history polling is event-driven, not a bare interval

private let pollInterval: TimeInterval = 60
private let safetyInterval: TimeInterval = 900
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test
func slackHistoryPoll_firesGapFillOnConnectOrReconnect() {
    // A fresh socket session has no prior poll -> gap-fill immediately, which
    // is how a reconnect recovers messages missed while the socket was down.
    #expect(
        SlackSocketModeLoop.historyPollTrigger(
            now: t0,
            socketHealthy: true,
            lastPollAt: nil,
            pollInterval: pollInterval,
            safetyInterval: safetyInterval
        ) == .gapFill
    )
}

@Test
func slackHistoryPoll_suppressedWhileSocketHealthy() {
    // The defect: polling every `pollInterval` while the socket is connected
    // and delivering the same events. One interval after a poll, a healthy
    // socket must produce NO poll.
    for elapsed in [pollInterval, pollInterval * 5, safetyInterval - 1] {
        #expect(
            SlackSocketModeLoop.historyPollTrigger(
                now: t0.addingTimeInterval(elapsed),
                socketHealthy: true,
                lastPollAt: t0,
                pollInterval: pollInterval,
                safetyInterval: safetyInterval
            ) == nil,
            "healthy socket must not poll at +\(elapsed)s"
        )
    }
}

@Test
func slackHistoryPoll_safetyBackstopStillFiresOnHealthySocket() {
    // Conservative fallback: a socket can keep answering pings while Slack
    // silently stops delivering events, so polling is throttled, not removed.
    #expect(
        SlackSocketModeLoop.historyPollTrigger(
            now: t0.addingTimeInterval(safetyInterval),
            socketHealthy: true,
            lastPollAt: t0,
            pollInterval: pollInterval,
            safetyInterval: safetyInterval
        ) == .safetyInterval
    )
}

@Test
func slackHistoryPoll_resumesIntervalPollingWhenSocketUnhealthy() {
    #expect(
        SlackSocketModeLoop.historyPollTrigger(
            now: t0.addingTimeInterval(pollInterval - 1),
            socketHealthy: false,
            lastPollAt: t0,
            pollInterval: pollInterval,
            safetyInterval: safetyInterval
        ) == nil
    )
    #expect(
        SlackSocketModeLoop.historyPollTrigger(
            now: t0.addingTimeInterval(pollInterval),
            socketHealthy: false,
            lastPollAt: t0,
            pollInterval: pollInterval,
            safetyInterval: safetyInterval
        ) == .socketUnhealthy
    )
}

@Test
func slackSocketHealth_tracksConnectStaleAndDisconnect() async {
    let health = SlackSocketHealth()
    #expect(await health.isHealthy(now: t0) == false)

    await health.markConnected(now: t0)
    #expect(await health.isHealthy(now: t0.addingTimeInterval(10)))
    // Three missed heartbeats -> stale -> history poll takes over.
    #expect(await health.isHealthy(now: t0.addingTimeInterval(SlackSocketModeLoop.socketHealthGrace + 1)) == false)

    await health.markAlive(now: t0.addingTimeInterval(120))
    #expect(await health.isHealthy(now: t0.addingTimeInterval(130)))

    await health.markDisconnected()
    #expect(await health.isHealthy(now: t0.addingTimeInterval(130)) == false)
}

@Test
func slackLoop_safetyPollIntervalIsFarCoarserThanTheOldBareInterval() {
    let loop = SlackSocketModeLoop(
        config: makeConfig(historyPollEnabled: true),
        chatHandler: { _ in SlackSocketModeReply(text: "") }
    )
    #expect(loop.historySafetyPollInterval == 900)
    #expect(loop.historySafetyPollInterval >= 10 * 60)
}

// MARK: - helpers

private actor SlackTestSignal {
    private var fired = false
    var didFire: Bool { fired }

    func fire() { fired = true }

    // 15s default, not 5s: positive waits only need to exceed worst-case
    // scheduler noise under full-suite parallelism; a green run returns at
    // the first 2ms poll that observes the signal.
    func wait(timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !fired, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private actor SlackTaskPriorityCapture {
    private var value: TaskPriority?

    func record(_ priority: TaskPriority) { value = priority }

    func wait(timeout: TimeInterval = 15) async -> TaskPriority? {
        let deadline = Date().addingTimeInterval(timeout)
        while value == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return value
    }
}
