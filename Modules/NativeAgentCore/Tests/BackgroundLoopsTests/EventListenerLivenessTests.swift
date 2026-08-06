import Testing
import Foundation
@testable import BackgroundLoops

// Sweep R4 item 3. An event-driven loop's listener task consumed its stream
// with `for await` and, when that stream ENDED (watcher invalidated, upstream
// continuation finished), simply returned. Nothing recorded the exit, nothing
// restarted it, and `status()` kept reporting the loop as running — so a purely
// event-driven loop went permanently blind while health said it was fine.

/// A source whose first `endingStreams` streams finish immediately and whose
/// next stream stays open, so the test proves BOTH the restart-with-backoff and
/// the recovery instead of spinning forever.
private final class EndingEventSource: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    private var held: [AsyncStream<Void>.Continuation] = []
    private let endingStreams: Int

    init(endingStreams: Int) { self.endingStreams = endingStreams }

    var streamsMade: Int { lock.lock(); defer { lock.unlock() }; return made }

    func makeStream() -> AsyncStream<Void> {
        lock.lock()
        made += 1
        let index = made
        lock.unlock()
        return AsyncStream<Void> { continuation in
            if index <= endingStreams {
                continuation.finish()
            } else {
                lock.lock()
                held.append(continuation)
                lock.unlock()
            }
        }
    }

    func emit() {
        lock.lock()
        let continuations = held
        lock.unlock()
        for continuation in continuations { continuation.yield(()) }
    }
}

private struct EndingPhysiologyLoop: EventDeadlineLoopRunner {
    let loopId = "ending_listener"
    let interval: TimeInterval = 86_400
    let eventCoalescingDelay: TimeInterval = 0
    let source: EndingEventSource

    func tickOutcome() async -> LoopTickOutcome { .completed(result: nil) }
    func physiologyEvents() -> AsyncStream<Void> { source.makeStream() }
    func nextMeaningfulDeadline(after now: Date) async -> Date? { nil }
}

/// Bounded wait: fail loudly rather than hang if the condition never holds.
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("Event listener liveness")
struct EventListenerLivenessTests {

    @Test("a listener whose stream ends is recorded, restarted with backoff, and visible in status()")
    func endedListenerIsRecordedRestartedAndVisible() async {
        let source = EndingEventSource(endingStreams: 1)
        let manager = BackgroundLoopsManager()
        // Compressed backoff: the SHAPE (bounded delay, then rebuild) is what
        // matters; production keeps 1s/5s/30s.
        await manager._testSetEventListenerBackoff([0.05, 0.05, 0.05])
        await manager.start(loops: [EndingPhysiologyLoop(source: source)])
        defer { Task { await manager.stop() } }

        // 1. The end is RECORDED — this is the fact that did not exist before.
        let recorded = await waitUntil {
            await manager._testEventListenerHealth(loopId: "ending_listener")?.lastEndedAt != nil
        }
        #expect(recorded, "the listener's stream ended and nothing recorded it")

        // 2. status() reports the gap even though the loop is still "running".
        let duringGap = await manager.status().first { $0.name == "ending_listener" }
        let listener = try? #require(duringGap?.eventListener)
        #expect(duringGap?.running == true)
        #expect(listener?.consecutiveEnds ?? 0 >= 1)
        #expect(listener?.lastError?.contains("event stream ended") == true)

        // 3. It is REBUILT after the backoff — a second stream is requested.
        await manager._testAwaitListenerRestart(loopId: "ending_listener")
        let restarted = await waitUntil { source.streamsMade >= 2 }
        #expect(restarted, "the listener was never rebuilt after its stream ended")
        let afterRestart = await manager._testEventListenerHealth(loopId: "ending_listener")
        #expect(afterRestart?.restartCount ?? 0 >= 1)

        // 4. A delivered event proves the replacement works and clears the gap.
        let live = await waitUntil { await manager._testEventListenerHealth(loopId: "ending_listener")?.active == true }
        #expect(live)
        source.emit()
        let cleared = await waitUntil {
            await manager._testEventListenerHealth(loopId: "ending_listener")?.consecutiveEnds == 0
        }
        #expect(cleared, "a delivered event must clear the consecutive-end count")
    }

    @Test("repeated stream ends climb instead of spinning, and never tighten the restart delay")
    func repeatedEndsClimbAndStayBounded() async {
        let source = EndingEventSource(endingStreams: 3)
        let manager = BackgroundLoopsManager()
        await manager._testSetEventListenerBackoff([0.02, 0.04, 0.06])
        await manager.start(loops: [EndingPhysiologyLoop(source: source)])
        defer { Task { await manager.stop() } }

        let climbed = await waitUntil {
            (await manager._testEventListenerHealth(loopId: "ending_listener")?.consecutiveEnds ?? 0) >= 3
        }
        #expect(climbed, "three consecutive stream ends must be counted, not collapsed")

        // The backoff is bounded by the schedule's last entry: with 3 ends the
        // manager is at the ceiling, and the stream count is bounded by the
        // number of ends + the surviving one — no tight respawn loop.
        #expect(source.streamsMade <= 6)
    }

    @Test("a loop with no event lane reports no listener at all")
    func nonEventLoopHasNoListenerRecord() async {
        struct PlainLoop: LoopRunner {
            let loopId = "plain"
            let interval: TimeInterval = 86_400
            func tickOutcome() async -> LoopTickOutcome { .completed(result: nil) }
        }
        let manager = BackgroundLoopsManager()
        await manager.start(loops: [PlainLoop()])
        defer { Task { await manager.stop() } }
        let status = await manager.status().first { $0.name == "plain" }
        #expect(status?.eventListener == nil, "no event lane is not the same as a dead listener")
    }
}
