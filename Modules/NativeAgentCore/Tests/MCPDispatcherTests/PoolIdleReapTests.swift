import Testing
import Foundation
@testable import MCPDispatcher

// R17: idle-reap for pooled stdio MCP children. Before this, a spawned child
// lived until spec removal or app quit — one exploratory MCP call cost a
// resident subprocess forever. The current implementation owns one exact
// deadline rather than periodically polling a quarter of the idle window.
@Suite(.serialized)
struct PoolIdleReapTests {

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            value = value.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private func makeDeadlinePool(clock: TestClock) -> MCPSubprocessPool {
        MCPSubprocessPool(
            reapNow: { clock.now() },
            // Tests deliver captured generations explicitly. The parked sleep
            // must still be cancellation-aware so reschedules leave no tasks.
            reapSleepUntil: { _ in
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        )
    }

    private func expectDate(_ actual: Date?, equals expected: Date) {
        #expect(actual != nil)
        if let actual {
            #expect(abs(actual.timeIntervalSince(expected)) < 0.001)
        }
    }

    private func makeHelperScript() throws -> URL {
        // Minimal MCP-speaking helper: replies to initialize and then blocks
        // reading stdin. Mirrors MCPSubprocessClientTests' writeMCPHelper but
        // trimmed to what reap needs (a live child that idles).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoolIdleReap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("helper.sh")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*([^,}]+).*/\\1/')
          case "$line" in
            *'"method":"initialize"'*|*'"method": "initialize"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"capabilities":{}}}\\n' "$id"
              ;;
            *'"method":"tools/list"'*|*'"method": "tools/list"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\\n' "$id"
              ;;
            *)
              printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id"
              ;;
          esac
        done
        """
        try Data(script.utf8).write(to: path)
        return path
    }

    @Test func idleChildIsReapedAndRespawnsOnNextGet() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let pool = MCPSubprocessPool()
        await pool.updateSpecs([
            .init(serverId: "idle-reap-srv", command: "/bin/sh \(script.path)")
        ])
        let proc = try await pool.get(serverId: "idle-reap-srv")
        #expect(await proc.isRunning)
        #expect(await pool._reapLoopArmed())

        // Deterministic pass: pretend idleTimeout has elapsed.
        await pool._setIdleTimeout(60)
        let farFuture = Date().addingTimeInterval(3600)
        let reaped = await pool.reapIdle(now: farFuture)
        #expect(reaped == ["idle-reap-srv"])
        #expect(await !proc.isRunning)

        // Spec survives — next get() cold-respawns without crash backoff.
        let respawned = try await pool.get(serverId: "idle-reap-srv")
        #expect(await respawned.isRunning)
        #expect(respawned !== proc)
        await pool.stopAll()
    }

    @Test func recentlyUsedChildIsNotReaped() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let pool = MCPSubprocessPool()
        await pool.updateSpecs([
            .init(serverId: "warm-srv", command: "/bin/sh \(script.path)")
        ])
        let proc = try await pool.get(serverId: "warm-srv")
        await pool._setIdleTimeout(3600)
        // Now is real time; the child was just started — nowhere near idle.
        let reaped = await pool.reapIdle()
        #expect(reaped.isEmpty)
        #expect(await proc.isRunning)
        await pool.stopAll()
    }

    @Test func zeroTimeoutDisablesReaping() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let pool = MCPSubprocessPool()
        await pool._setIdleTimeout(0)
        await pool.updateSpecs([
            .init(serverId: "no-reap-srv", command: "/bin/sh \(script.path)")
        ])
        let proc = try await pool.get(serverId: "no-reap-srv")
        let reaped = await pool.reapIdle(now: Date().addingTimeInterval(86_400))
        #expect(reaped.isEmpty)
        #expect(await proc.isRunning)
        // Disabled reaping never arms the loop.
        #expect(await !pool._reapLoopArmed())
        await pool.stopAll()
    }

    @Test func stopAllDisarmsReapLoop() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let pool = MCPSubprocessPool()
        await pool.updateSpecs([
            .init(serverId: "disarm-srv", command: "/bin/sh \(script.path)")
        ])
        _ = try await pool.get(serverId: "disarm-srv")
        #expect(await pool._reapLoopArmed())
        await pool.stopAll()
        #expect(await !pool._reapLoopArmed())
    }

    @Test func exactDeadlineDoesNotReapEarlyAndReapsWhenDue() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let clock = TestClock(Date().addingTimeInterval(5))
        let pool = makeDeadlinePool(clock: clock)
        await pool._setIdleTimeout(60)
        await pool.updateSpecs([.init(serverId: "exact-srv", command: "/bin/sh \(script.path)")])
        let proc = try await pool.get(serverId: "exact-srv")
        expectDate(await pool._scheduledReapDeadline(), equals: clock.now().addingTimeInterval(60))

        let earlyGeneration = await pool._reapScheduleGeneration()
        clock.advance(59)
        await pool._fireReapDeadlineForTests(generation: earlyGeneration, now: clock.now())
        #expect(await proc.isRunning)
        expectDate(await pool._scheduledReapDeadline(), equals: clock.now().addingTimeInterval(1))

        let dueGeneration = await pool._reapScheduleGeneration()
        clock.advance(1)
        await pool._fireReapDeadlineForTests(generation: dueGeneration, now: clock.now())
        #expect(await !proc.isRunning)
        #expect(await !pool._reapLoopArmed())
        await pool.stopAll()
    }

    @Test func checkoutPushesDeadlineAndStaleTaskCannotReap() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let clock = TestClock(Date().addingTimeInterval(5))
        let pool = makeDeadlinePool(clock: clock)
        await pool._setIdleTimeout(60)
        await pool.updateSpecs([.init(serverId: "checkout-srv", command: "/bin/sh \(script.path)")])
        let proc = try await pool.get(serverId: "checkout-srv")
        let oldGeneration = await pool._reapScheduleGeneration()
        let oldDeadline = await pool._scheduledReapDeadline()

        clock.advance(30)
        let checkedOut = try await pool.get(serverId: "checkout-srv")
        #expect(checkedOut === proc)
        let pushedDeadline = clock.now().addingTimeInterval(60)
        expectDate(await pool._scheduledReapDeadline(), equals: pushedDeadline)

        // A cancelled task from the pre-checkout generation may still resume.
        // Its generation cannot touch the currently pooled process or schedule.
        await pool._fireReapDeadlineForTests(
            generation: oldGeneration,
            now: oldDeadline ?? clock.now()
        )
        #expect(await proc.isRunning)
        expectDate(await pool._scheduledReapDeadline(), equals: pushedDeadline)

        let currentGeneration = await pool._reapScheduleGeneration()
        clock.advance(60)
        await pool._fireReapDeadlineForTests(generation: currentGeneration, now: clock.now())
        #expect(await !proc.isRunning)
        await pool.stopAll()
    }

    @Test func multipleChildrenReapAtTheirOwnDeadlinesAndRearm() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let clock = TestClock(Date().addingTimeInterval(5))
        let pool = makeDeadlinePool(clock: clock)
        await pool._setIdleTimeout(60)
        await pool.updateSpecs([
            .init(serverId: "first-srv", command: "/bin/sh \(script.path)"),
            .init(serverId: "second-srv", command: "/bin/sh \(script.path)"),
        ])
        let first = try await pool.get(serverId: "first-srv")
        let firstDeadline = clock.now().addingTimeInterval(60)
        clock.advance(10)
        let second = try await pool.get(serverId: "second-srv")
        let secondDeadline = clock.now().addingTimeInterval(60)
        expectDate(await pool._scheduledReapDeadline(), equals: firstDeadline)

        let firstGeneration = await pool._reapScheduleGeneration()
        clock.advance(50)
        await pool._fireReapDeadlineForTests(generation: firstGeneration, now: clock.now())
        #expect(await !first.isRunning)
        #expect(await second.isRunning)
        expectDate(await pool._scheduledReapDeadline(), equals: secondDeadline)

        let secondGeneration = await pool._reapScheduleGeneration()
        clock.advance(10)
        await pool._fireReapDeadlineForTests(generation: secondGeneration, now: clock.now())
        #expect(await !second.isRunning)
        #expect(await !pool._reapLoopArmed())
        await pool.stopAll()
    }

    @Test func staleDeadlineCannotReapReplacementProcess() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let clock = TestClock(Date().addingTimeInterval(5))
        let pool = makeDeadlinePool(clock: clock)
        await pool._setIdleTimeout(60)
        await pool.updateSpecs([.init(serverId: "replace-srv", command: "/bin/sh \(script.path)")])
        let original = try await pool.get(serverId: "replace-srv")
        let staleGeneration = await pool._reapScheduleGeneration()

        await pool.updateSpecs([
            .init(serverId: "replace-srv", command: "/bin/sh \(script.path) --replacement")
        ])
        #expect(await !original.isRunning)
        clock.advance(10)
        let replacement = try await pool.get(serverId: "replace-srv")
        let replacementDeadline = clock.now().addingTimeInterval(60)

        clock.advance(50)
        await pool._fireReapDeadlineForTests(generation: staleGeneration, now: clock.now())
        #expect(await replacement.isRunning)
        expectDate(await pool._scheduledReapDeadline(), equals: replacementDeadline)
        await pool.stopAll()
    }

    @Test func stopAllInvalidatesCapturedDeadline() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let clock = TestClock(Date().addingTimeInterval(5))
        let pool = makeDeadlinePool(clock: clock)
        await pool._setIdleTimeout(60)
        await pool.updateSpecs([.init(serverId: "stop-all-srv", command: "/bin/sh \(script.path)")])
        _ = try await pool.get(serverId: "stop-all-srv")
        let staleGeneration = await pool._reapScheduleGeneration()
        await pool.stopAll()
        #expect(await !pool._reapLoopArmed())
        #expect(await pool._scheduledReapDeadline() == nil)
        clock.advance(60)
        await pool._fireReapDeadlineForTests(generation: staleGeneration, now: clock.now())
        #expect(await !pool._reapLoopArmed())
    }

    @Test func timeoutChangeReschedulesAndZeroDisarms() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let clock = TestClock(Date().addingTimeInterval(5))
        let pool = makeDeadlinePool(clock: clock)
        await pool._setIdleTimeout(60)
        await pool.updateSpecs([.init(serverId: "reschedule-srv", command: "/bin/sh \(script.path)")])
        let proc = try await pool.get(serverId: "reschedule-srv")
        let anchor = clock.now()
        expectDate(await pool._scheduledReapDeadline(), equals: anchor.addingTimeInterval(60))

        await pool._setIdleTimeout(120)
        expectDate(await pool._scheduledReapDeadline(), equals: anchor.addingTimeInterval(120))
        #expect(await pool._reapLoopArmed())

        await pool._setIdleTimeout(0)
        #expect(await !pool._reapLoopArmed())
        #expect(await pool._scheduledReapDeadline() == nil)
        clock.advance(10_000)
        let reaped = await pool.reapIdle(now: clock.now())
        #expect(reaped.isEmpty)
        #expect(await proc.isRunning)
        await pool.stopAll()
    }

    @Test func emptyPoolNeverArmsDeadline() async {
        let clock = TestClock(Date())
        let pool = makeDeadlinePool(clock: clock)
        await pool._setIdleTimeout(60)
        await pool.updateSpecs([])
        #expect(await !pool._reapLoopArmed())
        #expect(await pool._scheduledReapDeadline() == nil)
    }

    @Test func nonfiniteAndNegativeTimeoutsFailClosed() async {
        let clock = TestClock(Date())
        let pool = makeDeadlinePool(clock: clock)

        await pool._setIdleTimeout(.infinity)
        #expect(await pool.idleTimeout == 0)
        #expect(await !pool._reapLoopArmed())

        await pool._setIdleTimeout(.nan)
        #expect(await pool.idleTimeout == 0)

        await pool._setIdleTimeout(-10)
        #expect(await pool.idleTimeout == 0)

        await pool._setIdleTimeout(100 * 24 * 60 * 60)
        #expect(await pool.idleTimeout == 7 * 24 * 60 * 60)
    }

    @Test func runningChildRevalidatesIdentityAfterActorHop() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let pool = MCPSubprocessPool()
        let originalSpec = MCPSubprocessPool.Spec(
            serverId: "post-await-live",
            command: "/bin/sh \(script.path)"
        )
        let replacementSpec = MCPSubprocessPool.Spec(
            serverId: "post-await-live",
            command: "/bin/sh \(script.path) --replacement"
        )
        await pool.updateSpecs([originalSpec])
        let original = try await pool.get(serverId: originalSpec.serverId)
        await pool._setGetPostAwaitHook {
            await pool._setGetPostAwaitHook(nil)
            await pool.updateSpecs([replacementSpec])
        }

        let returned = try await pool.get(serverId: originalSpec.serverId)
        #expect(returned !== original)
        #expect(await returned.isRunning)
        #expect(await !original.isRunning)
        await pool.stopAll()
    }

    @Test func deadChildCannotRecordCrashAgainstConcurrentReplacement() async throws {
        let script = try makeHelperScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let pool = MCPSubprocessPool()
        let originalSpec = MCPSubprocessPool.Spec(
            serverId: "post-await-dead",
            command: "/bin/sh \(script.path)"
        )
        let replacementSpec = MCPSubprocessPool.Spec(
            serverId: "post-await-dead",
            command: "/bin/sh \(script.path) --replacement"
        )
        let neverStarted = try MCPSubprocess.fromServerCommand(
            serverId: originalSpec.serverId,
            command: originalSpec.command
        )
        await pool._injectProcess(neverStarted, spec: originalSpec)
        await pool._setGetPostAwaitHook {
            await pool._setGetPostAwaitHook(nil)
            await pool.updateSpecs([replacementSpec])
        }

        let returned = try await pool.get(serverId: originalSpec.serverId)
        #expect(returned !== neverStarted)
        #expect(await returned.isRunning)
        #expect(await pool._crashInfo(for: originalSpec.serverId) == nil)
        await pool.stopAll()
    }
}
