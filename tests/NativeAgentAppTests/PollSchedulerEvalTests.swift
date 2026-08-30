import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
private final class PollSchedulerTestClock {
    private(set) var value: Date

    init(_ value: Date = Date(timeIntervalSinceReferenceDate: 10_000)) {
        self.value = value
    }

    func now() -> Date { value }

    func advance(by interval: TimeInterval) {
        value = value.addingTimeInterval(interval)
    }
}

@MainActor
private final class PollSchedulerPauseState {
    var streaming = false
    var appIsActive = true
}

private actor PollSchedulerTestSleeper {
    private var nextID = 0
    private var delays: [TimeInterval] = []
    private var order: [Int] = []
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancellations = 0

    func sleep(for delay: TimeInterval) async throws {
        let id = nextID
        nextID += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cancellations += 1
                    continuation.resume(throwing: CancellationError())
                    return
                }
                delays.append(delay)
                order.append(id)
                continuations[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func resumeNext() -> Bool {
        guard !order.isEmpty else { return false }
        let id = order.removeFirst()
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(returning: ())
        return true
    }

    func delaySnapshot() -> [TimeInterval] { delays }
    func pendingCount() -> Int { continuations.count }
    func cancellationCount() -> Int { cancellations }

    private func cancel(_ id: Int) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        cancellations += 1
        continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private func pollSchedulerEventually(
    _ description: String,
    condition: @escaping @MainActor () async -> Bool
) async {
    for _ in 0..<20_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("PollScheduler did not reach expected state: \(description)")
}

@MainActor
private func makePollScheduler(
    clock: PollSchedulerTestClock,
    sleeper: PollSchedulerTestSleeper,
    pause: PollSchedulerPauseState = PollSchedulerPauseState()
) -> PollScheduler {
    PollScheduler(
        now: clock.now,
        sleep: { delay in try await sleeper.sleep(for: delay) },
        isStreaming: { _ in pause.streaming },
        isAppActive: { pause.appIsActive }
    )
}

@MainActor
@Suite("app.background · poll scheduler", .serialized)
struct PollSchedulerEvalTests {
    @Test("registration waits one full interval, fires once when due, and unregister cancels idle work")
    func registrationDueFireAndUnregisterLifecycle() async {
        let clock = PollSchedulerTestClock()
        let sleeper = PollSchedulerTestSleeper()
        let scheduler = makePollScheduler(clock: clock, sleeper: sleeper)
        var fireCount = 0

        scheduler.register(.init(
            id: "primary",
            interval: 10,
            pauseWhenStreaming: false,
            pauseWhenUnfocused: false
        )) {
            fireCount += 1
        }

        await pollSchedulerEventually("initial full-interval sleep") {
            await sleeper.delaySnapshot().count == 1
        }
        #expect(fireCount == 0, "registration must seed lastTick instead of firing immediately")
        #expect(await sleeper.delaySnapshot() == [10])

        clock.advance(by: 9)
        #expect(await sleeper.resumeNext())
        await pollSchedulerEventually("one-second remainder after an early wake") {
            await sleeper.delaySnapshot().count == 2
        }
        #expect(fireCount == 0)
        #expect(await sleeper.delaySnapshot() == [10, 1])

        clock.advance(by: 1)
        #expect(await sleeper.resumeNext())
        await pollSchedulerEventually("one due fire and the next full interval") {
            let delayCount = await sleeper.delaySnapshot().count
            return fireCount == 1 && delayCount == 3
        }
        #expect(await sleeper.delaySnapshot() == [10, 1, 10])

        #expect(await sleeper.resumeNext())
        await pollSchedulerEventually("no double fire without elapsed time") {
            await sleeper.delaySnapshot().count == 4
        }
        #expect(fireCount == 1)
        #expect(await sleeper.delaySnapshot().last == 10)

        scheduler.unregister("primary")
        await pollSchedulerEventually("unregister cancellation") {
            await sleeper.cancellationCount() == 1
        }
        #expect(await sleeper.pendingCount() == 0)
        clock.advance(by: 100)
        #expect(!(await sleeper.resumeNext()))
        await Task.yield()
        #expect(fireCount == 1, "an unregistered job must never fire again")
    }

    @Test("streaming and focus pauses defer due work to the five-second recheck")
    func pausedDueJobsRecheckAndResumeInOrder() async {
        let clock = PollSchedulerTestClock()
        let sleeper = PollSchedulerTestSleeper()
        let pause = PollSchedulerPauseState()
        pause.streaming = true
        pause.appIsActive = false
        let scheduler = makePollScheduler(clock: clock, sleeper: sleeper, pause: pause)
        var events: [String] = []

        scheduler.register(.init(
            id: "streaming",
            interval: 10,
            pauseWhenStreaming: true,
            pauseWhenUnfocused: false
        )) {
            events.append("streaming")
        }
        scheduler.register(.init(
            id: "focus",
            interval: 10,
            pauseWhenStreaming: false,
            pauseWhenUnfocused: true
        )) {
            events.append("focus")
        }

        await pollSchedulerEventually("paused jobs' initial interval") {
            await sleeper.delaySnapshot().count == 1
        }
        #expect(await sleeper.delaySnapshot() == [10])

        clock.advance(by: 10)
        #expect(await sleeper.resumeNext())
        await pollSchedulerEventually("paused due-job recheck") {
            await sleeper.delaySnapshot().count == 2
        }
        #expect(events.isEmpty)
        #expect(await sleeper.delaySnapshot().last == 5)

        pause.streaming = false
        #expect(await sleeper.resumeNext())
        await pollSchedulerEventually("streaming job resumes while focus job stays paused") {
            let delayCount = await sleeper.delaySnapshot().count
            return events == ["streaming"] && delayCount == 3
        }
        #expect(await sleeper.delaySnapshot().last == 5)

        pause.appIsActive = true
        #expect(await sleeper.resumeNext())
        await pollSchedulerEventually("focus job resumes") {
            let delayCount = await sleeper.delaySnapshot().count
            return events == ["streaming", "focus"] && delayCount == 4
        }
        #expect(await sleeper.delaySnapshot().last == 10)

        scheduler.unregister("streaming")
        scheduler.unregister("focus")
        await pollSchedulerEventually("final idle cancellation") {
            await sleeper.pendingCount() == 0
        }
    }

    @Test("sleep delay is clamped to the documented half-second and two-minute bounds")
    func sleepBounds() async {
        let shortClock = PollSchedulerTestClock()
        let shortSleeper = PollSchedulerTestSleeper()
        let shortScheduler = makePollScheduler(clock: shortClock, sleeper: shortSleeper)
        shortScheduler.register(.init(
            id: "short",
            interval: 0.1,
            pauseWhenStreaming: false,
            pauseWhenUnfocused: false
        )) {}
        await pollSchedulerEventually("minimum bounded delay") {
            await shortSleeper.delaySnapshot().count == 1
        }
        #expect(await shortSleeper.delaySnapshot() == [0.5])
        shortScheduler.unregister("short")

        let longClock = PollSchedulerTestClock()
        let longSleeper = PollSchedulerTestSleeper()
        let longScheduler = makePollScheduler(clock: longClock, sleeper: longSleeper)
        longScheduler.register(.init(
            id: "long",
            interval: 1_000,
            pauseWhenStreaming: false,
            pauseWhenUnfocused: false
        )) {}
        await pollSchedulerEventually("maximum bounded delay") {
            await longSleeper.delaySnapshot().count == 1
        }
        #expect(await longSleeper.delaySnapshot() == [120])
        longScheduler.unregister("long")
    }

    @Test("duplicate registration replaces the handler, restarts once, and keeps the new interval")
    func duplicateIDReplacement() async {
        let clock = PollSchedulerTestClock()
        let sleeper = PollSchedulerTestSleeper()
        let scheduler = makePollScheduler(clock: clock, sleeper: sleeper)
        var events: [String] = []

        scheduler.register(.init(
            id: "same-id",
            interval: 10,
            pauseWhenStreaming: false,
            pauseWhenUnfocused: false
        )) {
            events.append("old")
        }
        await pollSchedulerEventually("original registration sleep") {
            await sleeper.delaySnapshot().count == 1
        }

        scheduler.register(.init(
            id: "same-id",
            interval: 20,
            pauseWhenStreaming: false,
            pauseWhenUnfocused: false
        )) {
            events.append("new")
        }
        await pollSchedulerEventually("replacement cancels old sleep and uses new interval") {
            let cancellationCount = await sleeper.cancellationCount()
            let delayCount = await sleeper.delaySnapshot().count
            return cancellationCount == 1 && delayCount == 2
        }
        #expect(await sleeper.delaySnapshot() == [10, 20])

        clock.advance(by: 20)
        #expect(await sleeper.resumeNext())
        await pollSchedulerEventually("replacement handler fires") {
            let delayCount = await sleeper.delaySnapshot().count
            return events == ["new"] && delayCount == 3
        }
        #expect(await sleeper.delaySnapshot().last == 20)

        scheduler.unregister("same-id")
        await pollSchedulerEventually("replacement idle work is cancelled") {
            await sleeper.cancellationCount() == 2
        }
        #expect(events == ["new"])
    }
}
