// U5 W-D "comms resilience" tests: poll backoff (virtual time, no real
// sleeps) + errors.jsonl rotation (dedup_shadow recipe) + setMyCommands
// retry gating.

import Testing
import Foundation
@testable import TelegramBot
import NativeAgentCore
import NativeAgentTestSupport
import PersistenceCore

// MARK: - Helpers (private per-file copies, same precedent as CompletenessTests)

/// Lock-protected virtual clock — backoff tests run on virtual time only.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
        self._now = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}

/// Togglable failure switch + request counter for the mock transport.
private final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _failing: Bool
    private var _count = 0

    init(failing: Bool = true) { self._failing = failing }

    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failing }
        set { lock.lock(); defer { lock.unlock() }; _failing = newValue }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _count += 1
    }
}

// Isolated stub subclass (own handler slot) — see ConfigurableURLProtocolStub.
private final class BackoffMockURLProtocol: ConfigurableURLProtocolStub {}

private func backoffMockSession(
    _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    BackoffMockURLProtocol.makeSession(handler: handler)
}

private func okResponse(_ url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private func mkRoot(_ tag: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tg_backoff_\(tag)_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("telegram", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private func readRows(_ url: URL) -> [JSONValue] {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
        try? JSONValue.parse(Data(String($0).utf8))
    }
}

// MARK: - TelegramExponentialBackoff unit tests (virtual time)

@Test func backoff_curve_doubles_from_1s_to_60s_cap_with_unit_jitter() async {
    let clock = VirtualClock()
    let backoff = TelegramExponentialBackoff(now: { clock.now }, random: { _ in 1.0 })
    var delays: [TimeInterval] = []
    for _ in 0..<8 {
        delays.append(await backoff.recordFailure())
    }
    #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60])
    #expect(await backoff.failureCount() == 8)
}

@Test func backoff_success_resets_curve_and_window() async {
    let clock = VirtualClock()
    let backoff = TelegramExponentialBackoff(now: { clock.now }, random: { _ in 1.0 })
    _ = await backoff.recordFailure() // 1
    _ = await backoff.recordFailure() // 2
    _ = await backoff.recordFailure() // 4
    #expect(await backoff.failureCount() == 3)
    #expect(await backoff.shouldAttempt() == false)

    await backoff.recordSuccess()
    #expect(await backoff.failureCount() == 0)
    #expect(await backoff.currentDeadline() == nil)
    // No window open — attempt allowed immediately, no clock advance.
    #expect(await backoff.shouldAttempt())
    // Curve restarted from the base, not from where it left off.
    #expect(await backoff.recordFailure() == 1)
}

@Test func backoff_gates_attempts_until_deadline_passes() async {
    let clock = VirtualClock()
    let backoff = TelegramExponentialBackoff(now: { clock.now }, random: { _ in 1.0 })
    #expect(await backoff.shouldAttempt()) // never failed → allowed

    _ = await backoff.recordFailure() // arms a 1s window
    #expect(await backoff.shouldAttempt() == false)
    clock.advance(0.5)
    #expect(await backoff.shouldAttempt() == false)
    clock.advance(0.6) // 1.1s ≥ 1s deadline
    #expect(await backoff.shouldAttempt())
}

@Test func backoff_jitter_scales_delay_and_cap_is_hard_ceiling() async {
    let clock = VirtualClock()
    // Pin jitter to the top of the range (1.2).
    let backoff = TelegramExponentialBackoff(
        now: { clock.now },
        random: { range in range.upperBound }
    )
    // First failure: raw 1s × 1.2 jitter.
    #expect(await backoff.recordFailure() == 1.2)
    // Drive to the cap: raw clamps to 60 BEFORE jitter, and the jittered
    // value re-clamps to 60 — the documented cap is a hard ceiling.
    var last: TimeInterval = 0
    for _ in 0..<10 {
        last = await backoff.recordFailure()
    }
    #expect(last == 60)
}

// MARK: - Poll-loop integration (failure gating + recovery, virtual time)

@Suite(.serialized)
struct TelegramBackoffPollLoopTests {

    @Test func pollLoop_transient_failures_back_off_and_reset_on_success() async throws {
        let root = try mkRoot("poll")
        defer { try? FileManager.default.removeItem(at: root) }
        let offsetURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let errorsURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("errors.jsonl")

        let sw = FailSwitch(failing: true)
        let session = backoffMockSession { req in
            sw.increment()
            if sw.failing { throw URLError(.notConnectedToInternet) }
            return (okResponse(req.url!), Data(#"{"ok":true,"result":[]}"#.utf8))
        }
        let clock = VirtualClock()
        let pollBackoff = TelegramExponentialBackoff(now: { clock.now }, random: { _ in 1.0 })
        let loop = TelegramPollLoop(
            interval: 60,
            token: "TKN123",
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offsetURL,
            sendMessage: { _, _, _ in },
            pollBackoff: pollBackoff
        )

        // Attempt #1 fails → 1s window armed, one error row recorded.
        guard case .failed(let pollError) = await loop.tickOutcome() else {
            Issue.record("expected typed Telegram poll failure")
            return
        }
        #expect(pollError.contains("Telegram long poll"))
        #expect(pollError.contains("unavailable"))
        #expect(sw.count == 1)
        #expect(readRows(errorsURL).count == 1)

        // Window open → tick is a no-op: NO transport hit, NO new error row.
        // The skip must be HEALTH-NEUTRAL — reported as an ordinary skip it
        // reset the scheduler's consecutive-failure streak between every real
        // failure, so the failure-streak push could never fire during an
        // outage (audit 2026-08-02).
        let backoffSkip = await loop.tickOutcome()
        #expect(backoffSkip == .backingOff(reason: "Telegram poll backoff active"))
        #expect(backoffSkip.isHealthNeutralSkip)
        await loop.tick()
        #expect(sw.count == 1)
        #expect(readRows(errorsURL).count == 1)

        // Past the 1s deadline → attempt #2 fails → 2s window armed.
        clock.advance(1.5)
        await loop.tick()
        #expect(sw.count == 2)
        #expect(readRows(errorsURL).count == 2)

        // Only 1s of the 2s window elapsed → still gated.
        clock.advance(1.0)
        await loop.tick()
        #expect(sw.count == 2)

        // Network back + window elapsed → attempt #3 succeeds → reset.
        sw.failing = false
        clock.advance(1.5)
        await loop.tick()
        #expect(sw.count == 3)
        #expect(await pollBackoff.failureCount() == 0)

        // No window → next tick polls immediately (back to normal cadence).
        await loop.tick()
        #expect(sw.count == 4)
        #expect(readRows(errorsURL).count == 2)

        // Observability: state.json reflects the reset.
        let state = await SwiftNativePersistenceCore().readJSON(
            root.appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("state.json"),
            defaultValue: .object([:])
        )
        guard case .object(let obj) = state else {
            Issue.record("expected state object"); return
        }
        #expect(obj["pollBackoffFailures"] == .int(0))
    }

    @Test func pollLoop_failed_command_menu_sync_stops_retrying_every_tick() async throws {
        let root = try mkRoot("menu")
        defer { try? FileManager.default.removeItem(at: root) }
        let offsetURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let session = backoffMockSession { req in
            (okResponse(req.url!), Data(#"{"ok":true,"result":[]}"#.utf8))
        }

        actor SyncGate {
            var attempts = 0
            var failing = true
            func attempt() throws -> TelegramCommandMenuStatus {
                attempts += 1
                if failing { throw TelegramBotError.underlying("setMyCommands status 502") }
                return TelegramCommandMenuStatus(
                    commandCount: TelegramCommandRegistry.commands.count,
                    registryVersion: TelegramCommandRegistry.version,
                    syncedAt: "2026-06-11T00:00:00Z"
                )
            }
            func recover() { failing = false }
            func count() -> Int { attempts }
        }
        let gate = SyncGate()

        let clock = VirtualClock()
        let menuBackoff = TelegramExponentialBackoff(
            baseDelay: 5, maxDelay: 300,
            now: { clock.now }, random: { _ in 1.0 }
        )
        let loop = TelegramPollLoop(
            interval: 60,
            token: "TKN123",
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offsetURL,
            sendMessage: { _, _, _ in },
            syncCommandMenu: { _, _ in try await gate.attempt() },
            commandMenuBackoff: menuBackoff
        )

        // Attempt #1 fails → 5s window. Subsequent ticks must NOT re-attempt.
        await loop.tick()
        await loop.tick()
        await loop.tick()
        #expect(await gate.count() == 1)

        // Past the 5s deadline → attempt #2 (fails → 10s window).
        clock.advance(5.5)
        await loop.tick()
        #expect(await gate.count() == 2)

        // Recovery: after the 10s window, attempt #3 succeeds and marks the
        // menu synced — later ticks skip the sync via the synced-state guard.
        await gate.recover()
        clock.advance(10.5)
        await loop.tick()
        #expect(await gate.count() == 3)
        await loop.tick()
        #expect(await gate.count() == 3)
    }
}

// MARK: - errors.jsonl rotation (dedup_shadow recipe)

@Test func telegramErrorLog_rotates_at_cap_to_single_backup() async throws {
    let root = try mkRoot("rotate")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root
        .appendingPathComponent("telegram", isDirectory: true)
        .appendingPathComponent("errors.jsonl")
    let backup = url.appendingPathExtension("1")

    // Cap of 1 byte → every append after the first sees a full live file.
    await TelegramErrorLog.append(.object(["n": .int(1)]), to: url, rotateAtBytes: 1)
    #expect(readRows(url) == [.object(["n": .int(1)])])
    #expect(!FileManager.default.fileExists(atPath: backup.path))

    await TelegramErrorLog.append(.object(["n": .int(2)]), to: url, rotateAtBytes: 1)
    #expect(readRows(url) == [.object(["n": .int(2)])])
    #expect(readRows(backup) == [.object(["n": .int(1)])])

    // Third append REPLACES the backup (single-.1 pattern, worst case 2×cap).
    await TelegramErrorLog.append(.object(["n": .int(3)]), to: url, rotateAtBytes: 1)
    #expect(readRows(url) == [.object(["n": .int(3)])])
    #expect(readRows(backup) == [.object(["n": .int(2)])])
}

@Test func telegramErrorLog_below_cap_appends_without_rotation() async throws {
    let root = try mkRoot("nocap")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root
        .appendingPathComponent("telegram", isDirectory: true)
        .appendingPathComponent("errors.jsonl")

    for i in 1...3 {
        await TelegramErrorLog.append(.object(["n": .int(Int64(i))]), to: url, rotateAtBytes: 10_000)
    }
    #expect(readRows(url).count == 3)
    #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
}

@Test func clearLogs_removes_errors_log_and_its_rotation_backup() async throws {
    let root = try mkRoot("clear")
    defer { try? FileManager.default.removeItem(at: root) }
    let teleDir = root.appendingPathComponent("telegram", isDirectory: true)
    let live = teleDir.appendingPathComponent("errors.jsonl")
    let backup = live.appendingPathExtension("1")
    try Data("{\"n\":1}\n".utf8).write(to: live)
    try Data("{\"n\":0}\n".utf8).write(to: backup)

    try await SwiftNativeTelegramBot(dataRoot: root).clearLogs()

    #expect(!FileManager.default.fileExists(atPath: live.path))
    #expect(!FileManager.default.fileExists(atPath: backup.path))
}
