import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

private final class _LockedProcessEscalationObservation: @unchecked Sendable {
    struct Value: Sendable {
        var capturedIdentity: ProcessTreeIdentity?
        var cancelledAtNanos: UInt64?
        var childDisappearedAtNanos: UInt64?
        var failure: String?
    }

    private let lock = NSLock()
    private var storage = Value()

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func capture(_ identity: ProcessTreeIdentity) {
        lock.lock()
        storage.capturedIdentity = identity
        lock.unlock()
    }

    func recordCancellation(at nanos: UInt64) {
        lock.lock()
        storage.cancelledAtNanos = nanos
        lock.unlock()
    }

    func recordChildDisappearance(at nanos: UInt64) {
        lock.lock()
        storage.childDisappearedAtNanos = nanos
        lock.unlock()
    }

    func fail(_ message: String) {
        lock.lock()
        storage.failure = message
        lock.unlock()
    }
}

private final class _LockedCancellationAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    @discardableResult
    func invoke() -> Bool {
        lock.lock()
        let action = self.action
        lock.unlock()
        action?()
        return action != nil
    }
}

/// Identity-bound motor observation for the process regression. A zombie has
/// already stopped executing and cannot perform side effects, even though BSD
/// retains its PID/start identity until its parent reaps the exit status.
private func _processIdentityIsRunning(_ identity: ProcessTreeIdentity) -> Bool {
    #if canImport(Darwin)
    var info = proc_bsdinfo()
    let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
    let read = proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, expected)
    guard read == expected,
          Int32(bitPattern: info.pbi_pid) == identity.pid,
          info.pbi_start_tvsec == identity.startSeconds,
          info.pbi_start_tvusec == identity.startMicroseconds else { return false }
    return info.pbi_status != UInt32(SZOMB)
    #else
    _ = identity
    return false
    #endif
}

@Test func systemProcessAdapterCancellationReapsShellProcessGroup() async throws {
    let marker = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl-cancel-\(UUID().uuidString)")
    let ready = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl-cancel-ready-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: ready)
    }
    let adapter = SystemProcessAdapter()
    let task = Task {
        try await adapter.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                // Synchronize cancellation to the child becoming live. A
                // fixed parent-side sleep can be delayed by full-suite load
                // until after the marker has already fired, which tests the
                // scheduler rather than process-group cancellation.
                // Job control places the background child in a different
                // process group, proving the explicit descendant fallback
                // rather than merely the normal killpg fast path.
                "set -m; (trap '' TERM; sleep 1; printf survived > \"$2\") & child=$!; printf ready > \"$1\"; wait \"$child\"",
                "macctl-cancel-test",
                ready.path,
                marker.path,
            ],
            timeoutSeconds: 30
        )
    }

    // Observe readiness and request cancellation from a native QoS thread.
    // The full Core stress gate intentionally saturates Swift's cooperative
    // executor; an async polling task can otherwise resume only after the
    // one-second marker has fired and falsely blame process-tree reaping.
    let canceller = Thread {
        let deadline = DispatchTime.now() + .seconds(5)
        while DispatchTime.now() < deadline, !Thread.current.isCancelled {
            if FileManager.default.fileExists(atPath: ready.path) {
                task.cancel()
                return
            }
            usleep(1_000)
        }
    }
    canceller.qualityOfService = .userInitiated
    canceller.start()
    defer { canceller.cancel() }
    do {
        _ = try await task.value
        Issue.record("parent cancellation must throw instead of returning a process result")
    } catch is CancellationError {
        // Expected: the adapter reaped the child group before surfacing cancel.
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }

    // The child writes its marker at its own t≈2s; a fixed 1.2s wait could end
    // BEFORE that instant under suite load, passing even when the reap failed.
    // Poll past the write window instead: fail fast the moment the marker
    // appears, pass only once the window (2s + load margin) has fully elapsed.
    try await expectMarkerNeverAppears(marker, within: 4.5)
}

@Test func systemProcessAdapterTimeoutUsesNativeDeadlineAndReapsDescendant() async throws {
    let marker = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl-timeout-\(UUID().uuidString)")
    let ready = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl-timeout-ready-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: ready)
    }

    let adapter = SystemProcessAdapter()
    let result = try await adapter.run(
        executable: "/bin/sh",
        arguments: [
            "-c",
            "(sleep 2; printf survived > \"$2\") & child=$!; printf ready > \"$1\"; wait \"$child\"",
            "macctl-timeout-test",
            ready.path,
            marker.path,
        ],
        timeoutSeconds: 1
    )

    #expect(result.timedOut)
    #expect(FileManager.default.fileExists(atPath: ready.path))
    // Same tooth as the cancellation test above: outlast the child's t≈2s
    // write instant (plus load margin) rather than sleeping a fixed 1.2s that
    // can end before a failed reap would have manifested.
    try await expectMarkerNeverAppears(
        marker, within: 4.5,
        "native timeout must fire and reap the tree before its delayed side effect"
    )
}

/// Poll-under-deadline ABSENCE assertion: fails immediately if the marker
/// file ever appears, passes only after the whole window elapses without it.
/// The window must exceed the instant the reaped child WOULD have written.
private func expectMarkerNeverAppears(
    _ marker: URL, within window: TimeInterval, _ comment: Comment? = nil
) async throws {
    let deadline = Date().addingTimeInterval(window)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: marker.path) {
            Issue.record(comment ?? "reaped child's delayed side effect landed anyway")
            return
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

@Test func systemProcessAdapterSharedSeamPreservesDirectoryEnvironmentAndInput() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl-shared-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let adapter = SystemProcessAdapter()
    let result = try await adapter.run(
        executable: "/bin/sh",
        arguments: ["-c", "printf '%s|%s|' \"$PWD\" \"$NATIVE_AGENT_PROCESS_TEST\"; /bin/cat"],
        currentDirectory: root,
        environment: ["NATIVE_AGENT_PROCESS_TEST": "ready"],
        standardInput: Data("payload".utf8),
        // 60s deadline — positive step under suite load (child runs ~0.01s isolated,
        // 7-8s observed under full-suite parallelism); only a true wedge should trip it.
        timeoutSeconds: 60
    )

    #expect(!result.timedOut)
    #expect(result.exitCode == 0)
    #expect(result.stdout.hasSuffix("/\(root.lastPathComponent)|ready|payload"))
    #expect(result.stderr.isEmpty)
}

@Test func systemProcessAdapterSharedSeamDrainsButBoundsBothOutputPipes() async throws {
    let result = try await SystemProcessAdapter().run(
        executable: "/bin/sh",
        arguments: [
            "-c",
            "/usr/bin/yes stdout | /usr/bin/head -c 4096; /usr/bin/yes stderr | /usr/bin/head -c 4096 >&2",
        ],
        currentDirectory: nil,
        environment: nil,
        standardInput: nil,
        // 60s deadline — positive step under suite load (child runs ~0.01s isolated,
        // 7-8s observed under full-suite parallelism); only a true wedge should trip it.
        timeoutSeconds: 60,
        outputByteLimit: 512
    )

    #expect(!result.timedOut)
    #expect(result.exitCode == 0)
    #expect(result.stdout.utf8.count == 512)
    #expect(result.stderr.utf8.count == 512)
    #expect(result.stdoutTruncated)
    #expect(result.stderrTruncated)
}

@Test func systemProcessAdapterCancellationEscalatesActiveTimeoutGraceWindow() async throws {
    let marker = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl-timeout-cancel-\(UUID().uuidString)")
    let ready = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl-timeout-cancel-ready-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: ready)
    }

    let observation = _LockedProcessEscalationObservation()
    let cancellation = _LockedCancellationAction()
    let adapter = SystemProcessAdapter(timeoutSnapshotInstalledObserver: { timeoutTree in
        guard let rootIdentity = timeoutTree.rootIdentity else {
            observation.fail("timeout snapshot did not retain the owned process identity")
            return
        }
        observation.capture(rootIdentity)
        let cancelledAt = DispatchTime.now().uptimeNanoseconds
        observation.recordCancellation(at: cancelledAt)
        guard cancellation.invoke() else {
            observation.fail("task cancellation action was not installed before timeout")
            return
        }
        let disappearanceDeadline = cancelledAt + 1_500_000_000
        while DispatchTime.now().uptimeNanoseconds < disappearanceDeadline {
            if !_processIdentityIsRunning(rootIdentity) {
                observation.recordChildDisappearance(
                    at: DispatchTime.now().uptimeNanoseconds
                )
                return
            }
            usleep(1_000)
        }
        observation.fail("identity-bound owned process remained live for 1.5s after cancellation")
    })
    let task = Task {
        try await adapter.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                // The child ignores TERM in a separate job-control process
                // group. The source-injected observer cancels at the exact edge
                // where timeout ownership and its identity-bound tree snapshot
                // are installed, before any shell timing can affect the race.
                // The delayed marker lands after the asserted 1.5s motor bound
                // but before the old timeout-only two-second grace would end.
                "set -m; (trap '' TERM; sleep 3.7; printf survived > \"$2\") & child=$!; printf ready > \"$1\"; wait \"$child\"",
                "macctl-timeout-cancel-test",
                ready.path,
                marker.path,
            ],
            timeoutSeconds: 2
        )
    }
    cancellation.install { task.cancel() }

    do {
        _ = try await task.value
        Issue.record("cancellation during timeout grace must throw CancellationError")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }

    let observed = observation.value
    #expect(observed.failure == nil, "\(observed.failure ?? "unexpected observer failure")")
    _ = try #require(observed.capturedIdentity)
    let cancellationNanos = try #require(observed.cancelledAtNanos)
    let disappearedNanos = try #require(observed.childDisappearedAtNanos)
    #expect(
        disappearedNanos >= cancellationNanos
            && disappearedNanos - cancellationNanos < 1_500_000_000,
        "identity-bound owned process must stop within 1.5s of explicit cancellation"
    )
    #expect(FileManager.default.fileExists(atPath: ready.path))
    try await Task.sleep(nanoseconds: 2_000_000_000)
    #expect(
        !FileManager.default.fileExists(atPath: marker.path),
        "descendant must not survive cancellation escalation to perform its delayed side effect"
    )
}
