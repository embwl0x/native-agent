import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Test doubles

actor _MockHTTPClient: HTTPClient {
    struct Call: Equatable {
        let urlString: String
        let body: Data
    }
    private(set) var calls: [Call] = []
    private var responses: [(status: Int, data: Data)] = []
    private var failure: Error? = nil

    func queue(status: Int, data: Data) {
        responses.append((status, data))
    }
    func queueJSON(status: Int, _ obj: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        responses.append((status, data))
    }
    func queueFailure(_ err: Error) { failure = err }

    func postJSON(url: URL, body: Data, timeout: TimeInterval) async throws -> (status: Int, data: Data) {
        calls.append(.init(urlString: url.absoluteString, body: body))
        if let failure { throw failure }
        if responses.isEmpty {
            return (200, Data("{}".utf8))
        }
        return responses.removeFirst()
    }
}

actor _MockNotificationCenter: NotificationCenterAdapter {
    struct Call: Equatable {
        let title: String
        let message: String
        let soundName: String?
    }
    private(set) var calls: [Call] = []
    private var shouldThrow: Error? = nil
    func setShouldThrow(_ err: Error?) { shouldThrow = err }
    func postNotification(title: String, message: String, soundName: String?) async throws {
        calls.append(.init(title: title, message: message, soundName: soundName))
        if let shouldThrow { throw shouldThrow }
    }
}

final class _MockAppleScriptAdapter: AppleScriptAdapter, @unchecked Sendable {
    var lastScript: String = ""
    var result: String = "hello"
    var shouldThrow: Error? = nil
    func run(script: String) throws -> String {
        lastScript = script
        if let shouldThrow { throw shouldThrow }
        return result
    }
}

actor _MockProcessAdapter: ProcessAdapter {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let timeoutSeconds: Int
    }
    private(set) var calls: [Call] = []
    private var responses: [ProcessRunResult] = []
    func queue(_ r: ProcessRunResult) { responses.append(r) }
    func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessRunResult {
        calls.append(.init(executable: executable, arguments: arguments, timeoutSeconds: timeoutSeconds))
        if responses.isEmpty {
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        }
        return responses.removeFirst()
    }
}

actor _MockAppControlAdapter: AppControlAdapter, AppStateVerificationAdapter {
    enum Call: Equatable {
        case focus(String)
        case quit(String)
    }
    private(set) var calls: [Call] = []
    var focusResult = AppControlRunResult(
        requestedName: "Safari",
        matchedName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        processIdentifier: 123,
        launched: false,
        activated: true,
        terminated: false
    )
    var quitResult = AppControlRunResult(
        requestedName: "Safari",
        matchedName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        processIdentifier: 123,
        launched: false,
        activated: false,
        terminated: true
    )
    var shouldThrow: Error? = nil
    private var frontmost = true

    func configureFocus(result: AppControlRunResult, frontmost: Bool) {
        focusResult = result
        self.frontmost = frontmost
    }

    func focusApp(named name: String) async throws -> AppControlRunResult {
        calls.append(.focus(name))
        if let shouldThrow { throw shouldThrow }
        return focusResult
    }

    func quitApp(named name: String) async throws -> AppControlRunResult {
        calls.append(.quit(name))
        if let shouldThrow { throw shouldThrow }
        return quitResult
    }

    func isFrontmostApplication(matching name: String) async -> Bool {
        frontmost && name == focusResult.requestedName
    }

    func isApplicationRunning(matching name: String) async -> Bool {
        name != quitResult.requestedName
    }
}

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

// _MockFileManagerAdapter: simple in-memory FS. Class so it can be mutated
// in-place behind the protocol; @unchecked Sendable because tests run
// serially.
final class _MockFileManagerAdapter: FileManagerAdapter, FileStateVerificationAdapter, @unchecked Sendable {
    var files: [String: Data] = [:]
    var directories: [String: [String]] = [:]
    var trashed: [String] = []
    var throwOnRead: Error? = nil
    var throwOnWrite: Error? = nil
    var throwOnMove: Error? = nil
    var throwOnTrash: Error? = nil

    func readData(at url: URL, maxBytes: Int) throws -> Data {
        if let e = throwOnRead { throw e }
        let data = files[url.path] ?? Data()
        if data.count > maxBytes { return data.prefix(maxBytes) }
        return data
    }
    func writeData(_ data: Data, to url: URL, append: Bool) throws {
        if let e = throwOnWrite { throw e }
        if append, let existing = files[url.path] {
            files[url.path] = existing + data
        } else {
            files[url.path] = data
        }
    }
    func listDirectory(at url: URL) throws -> [URL] {
        let names = directories[url.path] ?? []
        return names.map { url.appendingPathComponent($0) }
    }
    func moveItem(from src: URL, to dst: URL) throws {
        if let e = throwOnMove { throw e }
        if let data = files.removeValue(forKey: src.path) {
            files[dst.path] = data
        } else {
            throw NSError(domain: "mock", code: 2, userInfo: [NSLocalizedDescriptionKey: "src missing"])
        }
    }
    func trashItem(at url: URL) throws {
        if let e = throwOnTrash { throw e }
        if files[url.path] != nil {
            files.removeValue(forKey: url.path)
            trashed.append(url.path)
        } else {
            throw NSError(domain: "mock", code: 3, userInfo: [NSLocalizedDescriptionKey: "missing"])
        }
    }
    func itemExists(at url: URL) -> Bool {
        files[url.path] != nil || directories[url.path] != nil
    }
}

// MARK: - Factory routing

@Test func factoryReturnsSwiftNative() {
    let client = makeMacControl()
    #expect(client is SwiftNativeMacControl)
}

// MARK: - Sub-action inventory invariants

@Test func actionPartitionIsExhaustive() {
    // Every documented action appears in exactly one bucket.
    let overlap = macControlNativePortedActions.intersection(macControlUnsupportedActions)
    #expect(overlap.isEmpty, "actions in both buckets: \(overlap)")
    let union = macControlNativePortedActions.union(macControlUnsupportedActions)
    #expect(union == macControlAllActions)
}

@Test func actionInventoryCoversKnownDaemonRoutes() {
    // Pin the set of sub-paths the daemon exposes (the retired daemon
    // :53537–53747). If a daemon route is added, this assertion fires so
    // the Swift dispatch table can be updated in lock-step.
    let known: Set<String> = [
        "notify", "applescript", "jxa", "shortcut", "shortcut/run",
        "focus_app", "quit_app", "keystroke", "click", "system",
        "file/read", "file/write", "file/list", "file/move", "file/trash",
        "spotlight", "shell", "self_test",
    ]
    #expect(macControlAllActions == known, "drift vs daemon routes: missing=\(known.subtracting(macControlAllActions)) extra=\(macControlAllActions.subtracting(known))")
}

// MARK: - Unknown action

@Test func dispatchUnknownActionThrows() async throws {
    let client = SwiftNativeMacControl(http: _MockHTTPClient())
    do {
        _ = try await client.dispatch(action: "bogus", body: [:])
        Issue.record("expected unknownAction")
    } catch MacControlError.unknownAction(let a) {
        #expect(a == "bogus")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func dispatchTrimsLeadingTrailingSlashes() async throws {
    // Callers occasionally pass `/notify` or `notify/`; normalize before
    // dispatch so the inventory check doesn't false-positive.
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc
    )
    let r = try await client.dispatch(action: "/notify/", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.action == "notify")
    #expect(r.viaSwift == true)
    let calls = await mc.calls
    #expect(calls.count == 1)
}

// MARK: - notify (NATIVE)

@Test func notifyHappyPath() async throws {
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("NativeAgent"),
        "message": .string("Hello"),
        "sound": .string("Ping"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(r.action == "notify")
    let calls = await mc.calls
    #expect(calls.count == 1)
    #expect(calls.first?.title == "NativeAgent")
    #expect(calls.first?.message == "Hello")
    #expect(calls.first?.soundName == "Ping")
}

@Test func notifyMissingBothFieldsThrows() async throws {
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: _MockNotificationCenter()
    )
    do {
        _ = try await client.dispatch(action: "notify", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func notifyAdapterFailureSurfacedAsError() async throws {
    let mc = _MockNotificationCenter()
    await mc.setShouldThrow(NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "denied"]))
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("x"), "message": .string("y"),
    ])
    #expect(r.ok == false)
    #expect(r.error?.contains("notify failed") == true)
}

// MARK: - file ops (NATIVE)

@Test func fileReadHappyPath() async throws {
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/hello.txt"] = Data("hello world".utf8)
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        fileManagerAdapter: fm
    )
    let r = try await client.dispatch(action: "file/read", body: [
        "path": .string("/tmp/swiftmc/hello.txt"),
    ])
    #expect(r.ok == true)
    if case .object(let obj) = r.output, case .string(let s) = obj["content"] ?? .null {
        #expect(s == "hello world")
    } else {
        Issue.record("missing content field")
    }
}

@Test func fileReadRespectsMaxBytes() async throws {
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/big.txt"] = Data(String(repeating: "A", count: 5000).utf8)
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        fileManagerAdapter: fm
    )
    let r = try await client.dispatch(action: "file/read", body: [
        "path": .string("/tmp/swiftmc/big.txt"),
        "max_bytes": .int(100),
    ])
    if case .object(let obj) = r.output, case .string(let s) = obj["content"] ?? .null {
        #expect(s.count == 100)
    } else {
        Issue.record("missing content field")
    }
}

@Test func fileReadMissingPathThrows() async throws {
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), fileManagerAdapter: _MockFileManagerAdapter())
    do {
        _ = try await client.dispatch(action: "file/read", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField(let f) {
        #expect(f == "path")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func fileWriteRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    let r = try await client.dispatch(action: "file/write", body: [
        "path": .string("/tmp/swiftmc/out.txt"),
        "content": .string("roundtrip"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.ok == true)
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/out.txt"] == Data("roundtrip".utf8))
}

@Test func fileWriteAppendRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/log.txt"] = Data("a".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    _ = try await client.dispatch(action: "file/write", body: [
        "path": .string("/tmp/swiftmc/log.txt"),
        "content": .string("b"),
        "append": .bool(true),
    ])
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/log.txt"] == Data("ab".utf8))
}

@Test func fileListReturnsBasenames() async throws {
    let fm = _MockFileManagerAdapter()
    fm.directories["/tmp/swiftmc/dir"] = ["a.txt", "b.txt", "c.txt"]
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), fileManagerAdapter: fm)
    let r = try await client.dispatch(action: "file/list", body: [
        "path": .string("/tmp/swiftmc/dir"),
    ])
    if case .object(let obj) = r.output,
       case .array(let entries) = obj["entries"] ?? .null {
        let names = entries.compactMap { (v: JSONValue) -> String? in
            if case .string(let s) = v { return s }; return nil
        }
        #expect(names == ["a.txt", "b.txt", "c.txt"])
    } else {
        Issue.record("missing entries field")
    }
}

@Test func fileMoveRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/a.txt"] = Data("X".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    _ = try await client.dispatch(action: "file/move", body: [
        "src": .string("/tmp/swiftmc/a.txt"),
        "dst": .string("/tmp/swiftmc/b.txt"),
    ])
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/a.txt"] == nil)
    #expect(fm.files["/tmp/swiftmc/b.txt"] == Data("X".utf8))
}

@Test func fileTrashRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/trash.txt"] = Data("X".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    let r = try await client.dispatch(action: "file/trash", body: [
        "path": .string("/tmp/swiftmc/trash.txt"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(fm.files["/tmp/swiftmc/trash.txt"] == nil)
    #expect(fm.trashed == ["/tmp/swiftmc/trash.txt"])
    let calls = await http.calls
    #expect(calls.isEmpty)
}

// MARK: - Sensitive-path fence

@Test func sensitivePathFenceBlocksKeychain() async throws {
    let fm = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/read", body: [
            "path": .string("~/Library/Keychains/login.keychain-db"),
        ])
        Issue.record("expected sensitivePathDenied")
    } catch MacControlError.sensitivePathDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    // Critical: confirm the file system was never touched (the gate
    // ran BEFORE the FileManager call).
    #expect(fm.files.isEmpty)
}

@Test func fileWriteRejectsSensitivePathInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/write", body: [
            "path": .string("/tmp/swiftmc/trust_policy.json"),
            "content": .string("{}"),
        ])
        Issue.record("expected sensitivePathDenied")
    } catch MacControlError.sensitivePathDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/trust_policy.json"] == nil)
}

@Test func fileWriteRejectsProtectedSystemPathInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/write", body: [
            "path": .string("/etc/hosts"),
            "content": .string("127.0.0.1 example.local"),
        ])
        Issue.record("expected protected path denial")
    } catch MacControlError.sensitivePathDenied(let reason) {
        #expect(reason.contains("protected_system_path_denied"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/private/etc/hosts"] == nil)
}

@Test func fileMoveRejectsSensitiveDestInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/innocent.txt"] = Data("X".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/move", body: [
            "src": .string("/tmp/swiftmc/innocent.txt"),
            "dst": .string("~/.ssh/authorized_keys"),
        ])
        Issue.record("expected sensitivePathDenied")
    } catch MacControlError.sensitivePathDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/innocent.txt"] == Data("X".utf8))
}

// MARK: - Shell whitelist

@Test func whitelistAllowsEcho() {
    #expect(MacControlShellWhitelist.validate("echo hi") == nil)
}

@Test func whitelistRejectsRm() {
    let r = MacControlShellWhitelist.validate("rm -rf /tmp/everything")
    #expect(r != nil)
    #expect(r?.contains("not whitelisted") == true)
}

@Test func whitelistRejectsMetacharChain() {
    let r = MacControlShellWhitelist.validate("echo hi; rm -rf /")
    #expect(r?.contains("metacharacter") == true)
}

@Test func whitelistRejectsBackticks() {
    #expect(MacControlShellWhitelist.validate("echo `whoami`") != nil)
}

@Test func whitelistRejectsPipe() {
    #expect(MacControlShellWhitelist.validate("echo a | cat") != nil)
}

@Test func whitelistRejectsEmptyCommand() {
    let r = MacControlShellWhitelist.validate("   ")
    #expect(r?.contains("empty") == true)
}

@Test func whitelistRejectsAbsolutePath() {
    // Even though basename `date` IS whitelisted, an absolute path
    // bypasses NAME control — attacker could drop /tmp/date executable.
    let r = MacControlShellWhitelist.validate("/tmp/date now")
    #expect(r != nil)
    #expect(r?.contains("path not allowed") == true)
}

@Test func whitelistRejectsRelativePath() {
    // `./date` would resolve to attacker-controlled cwd.
    let r = MacControlShellWhitelist.validate("./date")
    #expect(r != nil)
    #expect(r?.contains("relative path") == true)
}

// MARK: - Shell dispatch

@Test func shellDispatchRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let proc = _MockProcessAdapter()
    await proc.queue(ProcessRunResult(exitCode: 0, stdout: "hi\n", stderr: ""))
    let client = SwiftNativeMacControl(http: http, processAdapter: proc)
    let r = try await client.dispatch(action: "shell", body: [
        "command": .string("echo hi"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.ok == true)
    let calls = await http.calls
    #expect(calls.isEmpty)
    let procCalls = await proc.calls
    #expect(procCalls.count == 1)
    #expect(procCalls.first?.executable == "/bin/sh")
}

@Test func shellDispatchRejectedCommandThrowsBeforeProcess() async throws {
    let http = _MockHTTPClient()
    let proc = _MockProcessAdapter()
    let client = SwiftNativeMacControl(http: http, processAdapter: proc)
    do {
        _ = try await client.dispatch(action: "shell", body: [
            "command": .string("rm -rf /"),
        ])
        Issue.record("expected shellNotWhitelisted")
    } catch MacControlError.shellNotWhitelisted {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
    let procCalls = await proc.calls
    #expect(procCalls.isEmpty)
}

// MARK: - applescript adapter (direct)

@Test func appleScriptAdapterReturnsResult() throws {
    let scr = _MockAppleScriptAdapter()
    scr.result = "hello"
    let out = try scr.run(script: "return \"hello\"")
    #expect(out == "hello")
    #expect(scr.lastScript == "return \"hello\"")
}

@Test func appleScriptAdapterPropagatesError() {
    let scr = _MockAppleScriptAdapter()
    scr.shouldThrow = MacControlError.applescriptFailed("syntax")
    do {
        _ = try scr.run(script: "garbage")
        Issue.record("expected throw")
    } catch MacControlError.applescriptFailed(let m) {
        #expect(m == "syntax")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func fileMoveRejectsProtectedSystemDestInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/innocent.txt"] = Data("X".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/move", body: [
            "src": .string("/tmp/swiftmc/innocent.txt"),
            "dst": .string("/Applications/NativeAgent.app/Contents/Info.plist"),
        ])
        Issue.record("expected protected path denial")
    } catch MacControlError.sensitivePathDenied(let reason) {
        #expect(reason.contains("protected_system_path_denied"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
}

@Test func appleScriptHandlerRejectsEmptyScript() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    do {
        _ = try await client.dispatch(action: "applescript", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField(let field) {
        #expect(field == "script")
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
}

// MARK: - applescript dispatch

@Test func applescriptDispatchInvokesAdapter() async throws {
    let http = _MockHTTPClient()
    let scr = _MockAppleScriptAdapter()
    let client = SwiftNativeMacControl(
        http: http,
        appleScriptAdapter: scr
    )
    let r = try await client.dispatch(action: "applescript", body: [
        "script": .string("return \"hello\""),
    ])
    #expect(r.viaSwift == true)
    #expect(scr.lastScript == "return \"hello\"")
    let calls = await http.calls
    #expect(calls.isEmpty)
}

@Test func applescriptFailureSurfacesAsError() async throws {
    let http = _MockHTTPClient()
    let scr = _MockAppleScriptAdapter()
    scr.shouldThrow = MacControlError.applescriptFailed("syntax")
    let client = SwiftNativeMacControl(http: http, appleScriptAdapter: scr)
    let r = try await client.dispatch(action: "applescript", body: [
        "script": .string("garbage"),
    ])
    #expect(r.ok == false)
    #expect(r.error?.contains("syntax") == true)
    #expect(r.viaSwift == true)
    #expect(await http.calls.isEmpty)
}

@Test func applescriptMissingScriptThrows() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    do {
        _ = try await client.dispatch(action: "applescript", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField(let field) {
        #expect(field == "script")
    } catch {
        Issue.record("wrong error: \(error)")
    }
    #expect(await http.calls.isEmpty)
}

// MARK: - app control

@Test func focusAppRunsInSwiftWithoutHTTP() async throws {
    let http = _MockHTTPClient()
    let apps = _MockAppControlAdapter()
    let client = SwiftNativeMacControl(http: http, appControlAdapter: apps)
    let r = try await client.dispatch(action: "focus_app", body: [
        "app": .string("Safari"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(r.action == "focus_app")
    #expect(await http.calls.isEmpty)
    #expect(await apps.calls == [.focus("Safari")])
    guard case .object(let obj) = r.output else {
        Issue.record("expected app-control output object")
        return
    }
    #expect(obj["status"] == .string("focused"))
    #expect(obj["bundle_identifier"] == .string("com.apple.Safari"))
    #expect(obj["activated"] == .bool(true))
}

@Test func focusAppUsesObservedFrontmostStateWhenActivationRequestReturnsFalse() async throws {
    let apps = _MockAppControlAdapter()
    await apps.configureFocus(result: AppControlRunResult(
        requestedName: "Safari",
        matchedName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        processIdentifier: 123,
        launched: false,
        activated: false,
        activationRequestAccepted: false,
        activationFallbackAttempted: true,
        activationFallbackSucceeded: true,
        terminated: false
    ), frontmost: true)
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), appControlAdapter: apps)

    let result = try await client.dispatch(action: "focus_app", body: ["app": .string("Safari")])

    #expect(result.ok)
    #expect(result.error == nil)
    guard case .object(let output) = result.output else {
        Issue.record("expected app-control output object")
        return
    }
    #expect(output["status"] == .string("focused"))
    #expect(output["activated"] == .bool(true))
    #expect(output["verified"] == .bool(true))
    #expect(output["activation_request_accepted"] == .bool(false))
    #expect(output["activation_fallback_succeeded"] == .bool(true))
}

@Test func focusAppFailsHonestlyWhenActivationRequestReturnsFalseAndTargetNeverBecomesFrontmost() async throws {
    let apps = _MockAppControlAdapter()
    await apps.configureFocus(result: AppControlRunResult(
        requestedName: "Safari",
        matchedName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        processIdentifier: 123,
        launched: false,
        activated: false,
        activationRequestAccepted: false,
        activationFallbackAttempted: true,
        activationFallbackSucceeded: true,
        activationFailureReason: "NSRunningApplication.activate returned false; NSWorkspace.openApplication fallback completed; target was not observed frontmost within 1.5 seconds",
        terminated: false
    ), frontmost: false)
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), appControlAdapter: apps)

    let result = try await client.dispatch(action: "focus_app", body: ["app": .string("Safari")])

    #expect(result.ok == false)
    #expect(result.error?.contains("NSRunningApplication.activate returned false") == true)
    #expect(result.error?.contains("fallback completed") == true)
    #expect(result.error?.contains("not observed frontmost") == true)
    guard case .object(let output) = result.output else {
        Issue.record("expected app-control output object")
        return
    }
    #expect(output["status"] == .string("focus_failed"))
    #expect(output["activated"] == .bool(false))
    #expect(output["verified"] == .bool(false))
    #expect(output["failure_reason"] == .string(result.error!))
}

@Test func quitAppRunsInSwiftWithoutHTTP() async throws {
    let http = _MockHTTPClient()
    let apps = _MockAppControlAdapter()
    let client = SwiftNativeMacControl(http: http, appControlAdapter: apps)
    let r = try await client.dispatch(action: "quit_app", body: [
        "name": .string("Safari"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(r.action == "quit_app")
    #expect(await http.calls.isEmpty)
    #expect(await apps.calls == [.quit("Safari")])
    guard case .object(let obj) = r.output else {
        Issue.record("expected app-control output object")
        return
    }
    #expect(obj["status"] == .string("quit_requested"))
    #expect(obj["terminated"] == .bool(true))
}

@Test func appControlMissingAppThrows() async throws {
    let apps = _MockAppControlAdapter()
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), appControlAdapter: apps)
    do {
        _ = try await client.dispatch(action: "focus_app", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField(let field) {
        #expect(field == "app")
    } catch {
        Issue.record("wrong error: \(error)")
    }
    #expect(await apps.calls.isEmpty)
}

// MARK: - Sensitive-path symlink follow

@Test func sensitivePathFenceFollowsSymlinkTarget() throws {
    // Create a symlink under /tmp that points at ~/.ssh — the raw symlink
    // path is benign-looking but the resolved target is fenced.
    let fm = FileManager.default
    let linkPath = "/tmp/swiftmc_link_\(UUID().uuidString)"
    let target = ((NSHomeDirectory() as NSString).expandingTildeInPath as NSString)
        .appendingPathComponent(".ssh")
    do {
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
    } catch {
        // Some sandboxes block symlink creation under /tmp — skip gracefully.
        return
    }
    defer { try? fm.removeItem(atPath: linkPath) }
    let r = MacControlSensitivePathFence.reason(forPath: linkPath)
    #expect(r != nil, "symlink target should be fenced")
}

// MARK: - Sensitive-path daemon data roots

@Test func sensitivePathFenceBlocksDaemonOAuthDir() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "~/Library/Application Support/NativeAgent/oauth/google.json"
    )
    #expect(r != nil)
}

@Test func sensitivePathFenceBlocksDaemonTrustDir() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "~/Library/Application Support/NativeAgent/trust/policy.json"
    )
    #expect(r != nil)
}

@Test func sensitivePathFenceBlocksDaemonSecretsDir() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "~/Library/Application Support/NativeAgent/secrets/api.key"
    )
    #expect(r != nil)
}

@Test func sensitivePathFenceBlocksLocalBridgeDiscoveryCredentials() {
    #expect(MacControlSensitivePathFence.reason(
        forPath: "~/.config/claude-bridge/bridge.json"
    ) != nil)
    #expect(MacControlSensitivePathFence.reason(
        forPath: "/Users/example/Projects/NativeAgent/data/browser_ipc.json"
    ) != nil)
}

// R2-2: data root may live outside AppSupport — repo `/data/<segment>/`,
// or the Swift-native `NATIVE_AGENT_DATA_ROOT`-relocated `<root>/<segment>/`.
// Match by path-component boundary, NOT substring.

@Test func sensitivePathFenceBlocksRepoDataOAuthDir() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "/Users/example/Projects/NativeAgent/data/oauth_tokens/google.json"
    )
    #expect(r != nil, "repo-relative /data/oauth_tokens/* must be fenced")
}

@Test func sensitivePathFenceAllowsNonDataBoundary() {
    // Substring `data` inside `notdata` must NOT trigger — only a true
    // `/data/` path-component boundary should.
    let r = MacControlSensitivePathFence.reason(forPath: "/tmp/notdata/oauth/x.json")
    #expect(r == nil, "substring-only match must not fence")
}

@Test func sensitivePathFenceBlocksRepoDataNextgenRemote() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "/Users/example/Projects/NativeAgent/data/nextgen/remote/session.json"
    )
    #expect(r != nil)
}

// gpt-5.5 review LOW/MED follow-up (2026-06-06): `NATIVE_AGENT_DATA` is the
// legacy daemon data-root env var. The Swift port no longer reads it as a
// config source, but the sensitive-path fence MUST still cover whatever it
// points at — otherwise a stale launchctl plist can be used to pivot
// read/write tools at the daemon-era root and bypass the explicit
// AppSupport coverage. Coverage gap surfaced by the post-fix build runner:
// the previous tests only proved the fence still passes when the env var
// is unset; this test proves the new candidate ALSO denies when it IS set.
//
// Uses a UUID-stamped path so concurrent tests in this suite can't
// accidentally collide with the legacy prefix. The defer block preserves
// any pre-existing `NATIVE_AGENT_DATA` (gpt-5.5 review-2 #5): a developer
// running tests with the env var already set would otherwise see their
// shell-level export clobbered, surprising the next test run.
@Test func sensitivePathFenceBlocksLegacyDaemonDataRootWhenEnvSet() {
    let legacyRoot = "/tmp/legacy-daemon-root-test-\(UUID().uuidString)"
    let prior = getenv("NATIVE_AGENT_DATA").map { String(cString: $0) }
    setenv("NATIVE_AGENT_DATA", legacyRoot, 1)
    defer {
        if let prior {
            setenv("NATIVE_AGENT_DATA", prior, 1)
        } else {
            unsetenv("NATIVE_AGENT_DATA")
        }
    }

    // Path under the legacy root's oauth dir — should be denied.
    let denied = MacControlSensitivePathFence.reason(
        forPath: "\(legacyRoot)/oauth_tokens/google.json"
    )
    #expect(denied != nil, "legacy daemon data root must be fenced when env var is set")

    // Substring-only match below the legacy prefix must NOT trigger — segment
    // boundary discipline is still in effect.
    let benign = MacControlSensitivePathFence.reason(
        forPath: "\(legacyRoot)-not-daemon/oauth_tokens/google.json"
    )
    #expect(benign == nil, "segment-only prefix discipline must hold")
}

// MARK: - spotlight

@Test func spotlightParsesMdfindOutput() async throws {
    let proc = _MockProcessAdapter()
    await proc.queue(ProcessRunResult(
        exitCode: 0,
        stdout: "/Users/test/a.pdf\n/Users/test/b.pdf\n/Users/test/c.pdf\n",
        stderr: ""
    ))
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), processAdapter: proc)
    let r = try await client.dispatch(action: "spotlight", body: [
        "query": .string("invoice"),
        "limit": .int(2),
    ])
    #expect(r.ok == true)
    if case .object(let obj) = r.output,
       case .array(let arr) = obj["results"] ?? .null {
        #expect(arr.count == 2)
    } else {
        Issue.record("missing results")
    }
    let calls = await proc.calls
    #expect(calls.first?.executable == "/usr/bin/mdfind")
    #expect(calls.first?.arguments == ["invoice"])
}

@Test func spotlightAcceptsQAlias() async throws {
    let proc = _MockProcessAdapter()
    await proc.queue(ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), processAdapter: proc)
    let r = try await client.dispatch(action: "spotlight", body: [
        "q": .string("legacy"),
    ])
    #expect(r.ok == true)
    let calls = await proc.calls
    #expect(calls.first?.arguments == ["legacy"])
}

@Test func spotlightMissingQueryThrows() async throws {
    let proc = _MockProcessAdapter()
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), processAdapter: proc)
    do {
        _ = try await client.dispatch(action: "spotlight", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - Unsupported Swift actions

@Test func unsupportedActionReturnsSwift501() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    let r = try await client.dispatch(action: "shortcut", body: [
        "name": .string("MyShortcut"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.ok == false)
    #expect(r.httpStatus == 501)
    #expect(r.error?.contains("unsupported_mac_control_action") == true)
    let calls = await http.calls
    #expect(calls.isEmpty)
}

@Test func unsupportedShortcutRunAliasReturnsSwift501() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    let r = try await client.dispatch(action: "shortcut/run", body: ["name": .string("Z")])
    #expect(r.httpStatus == 501)
    let calls = await http.calls
    #expect(calls.isEmpty)
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: with NO policyProvider — the direct-library-caller escape
/// hatch that skips the policy gates — injection still failed closed on the
/// approval attestation (403 / `approval_not_granted` / status "blocked"). The
/// point was that injection did not inherit the hatch.
/// NEW CONTRACT: the attestation self-mints, so on the no-policyProvider path
/// there is nothing left to fail closed on and the keystroke executes locally.
/// Still true and still pinned: it runs IN-PROCESS — no HTTP call is made, so
/// the direct-library path never reaches out over the wire.
@Test func unattestedKeystrokeExecutesLocallyWithNoPolicyProvider() async throws {
    let http = _MockHTTPClient()
    let sink = _InertEventSink()
    let client = SwiftNativeMacControl(http: http, eventSink: sink)
    let r = try await client.dispatch(action: "keystroke", body: [
        "text": .string("hi"),
    ])
    #expect(r.error?.hasPrefix("approval_not_granted") != true,
            "the approval tier is retired: \(r.error ?? "nil")")
    #expect(r.httpStatus != 403)
    if case .object(let obj) = r.output,
       case .string(let s) = obj["status"] ?? .null {
        #expect(s != "blocked", "no approval tier remains to block on")
    } else {
        Issue.record("missing status field")
    }
    #expect(await http.calls.isEmpty, "the direct-library path stays in-process")
}

@Test func unattestedClickExecutesLocallyWithNoPolicyProvider() async throws {
    let http = _MockHTTPClient()
    let sink = _InertEventSink()
    let client = SwiftNativeMacControl(http: http, eventSink: sink)
    let r = try await client.dispatch(action: "click", body: [:])
    #expect(r.error?.hasPrefix("approval_not_granted") != true)
    #expect(r.httpStatus != 403)
    #expect(r.viaSwift == true)
    #expect(await http.calls.isEmpty, "the direct-library path stays in-process")
}

@Test func unsupportedActionSurfacesHttpStatusHint() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    let r = try await client.dispatch(action: "shortcut", body: ["name": .string("X")])
    #expect(r.httpStatus == 501)
    #expect(r.viaSwift == true)
}

@Test func nativeResultHasNilHttpStatus() async throws {
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == nil, "native in-process result has no upstream status")
}

@Test func unsupportedActionNeverPostsHTTP() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    _ = try await client.dispatch(action: "keystroke", body: ["text": .string("hi")])
    let calls = await http.calls
    #expect(calls.isEmpty)
}

@Test func unsupportedJxaDoesNotUseTransport() async throws {
    let http = _MockHTTPClient()
    await http.queueFailure(NSError(domain: "test", code: -1009, userInfo: nil))
    let client = SwiftNativeMacControl(http: http)
    let r = try await client.dispatch(action: "jxa", body: ["script": .string("x")])
    #expect(r.httpStatus == 501)
    #expect(await http.calls.isEmpty)
}

@Test func unknownActionThrowsWithoutHttp() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    do {
        _ = try await client.dispatch(action: "bogus", body: [:])
        Issue.record("expected unknownAction")
    } catch MacControlError.unknownAction(let action) {
        #expect(action == "bogus")
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty, "must not even attempt HTTP for unknown action")
}

// MARK: - Gate pre-flight (wave 30 W01)

/// Test policy provider: returns a fixed policy (or nil to simulate
/// unresolved policy → fail-open).
struct _StubPolicyProvider: MacControlPolicyProvider {
    let policy: MacControlPolicy?
    func currentPolicy() async -> MacControlPolicy? { policy }
}

/// A permissive base policy: master on, remote-ios on, every category on,
/// no trust policy (file policy short-circuits to allow). Tests flip
/// individual fields off.
private func _permissiveMacPolicy() -> MacControlPolicy {
    MacControlPolicy(
        enabled: true,
        remoteFromIOSAllowed: true,
        requireAppBridgeForTCC: false,
        categoryAllowed: [
            "applescript_allowed": true, "jxa_allowed": true,
            "shortcuts_allowed": true, "accessibility_allowed": true,
            "system_control_allowed": true, "file_ops_allowed": true,
            "shell_allowed": true, "notifications_allowed": true,
            "spotlight_allowed": true,
        ],
        trustPolicy: nil,
        workspaceRoots: []
    )
}

@Test func preflightMasterGateOffShortCircuitsBeforeProxy() async throws {
    // shell is Swift-native; with master gate OFF the pre-flight must refuse
    // IN-PROCESS (viaSwift:true, 403) WITHOUT any HTTP call.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.ok == false)
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(r.error == "mac_control_disabled: master gate off")
    let calls = await http.calls
    #expect(calls.isEmpty, "refused request must NOT round-trip to the daemon")
}

@Test func preflightPerCategoryOffRefusesWithDaemonParityString() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.categoryAllowed["shell_allowed"] = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.error == "category_disabled: shell_allowed is off")
    #expect(r.httpStatus == 403)
    let calls = await http.calls
    #expect(calls.isEmpty)
}

/// Pins the refusal RESULT.OUTPUT contract that NativeClient.synthesizeNativeReceipt
/// (Sources/NativeAgentApp/NativeClient.swift, W31 W05) reads to build an honest
/// `blocked:true / block_reason / status:"blocked"` receipt instead of the wave-30
/// W01 synthesized 200/blocked=false. If a future refactor of `refusalResult` drops
/// `block_reason` / `blocked_by` from the output object, the NativeClient receipt
/// silently regresses to blocked=false — this test fails first.
@Test func preflightRefusalOutputCarriesBlockReasonContractForNativeClient() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.ok == false)
    #expect(r.httpStatus == 403)
    // The NativeClient reads block_reason / blocked_by / status out of result.output.
    guard case .object(let out) = r.output else {
        Issue.record("refusal result.output must be a JSON object the NativeClient can read")
        return
    }
    #expect(out["status"] == .string("blocked"))
    #expect(out["blocked_by"] == .string("swift_gate_preflight"))
    // block_reason must be non-empty and match the gate reason verbatim (daemon parity).
    guard case .string(let reason)? = out["block_reason"] else {
        Issue.record("refusal result.output must carry a string block_reason")
        return
    }
    #expect(!reason.isEmpty)
    #expect(reason == r.error, "block_reason must mirror the gate reason the daemon's _blocked_receipt logs")
}

@Test func preflightRemoteIosOffRefusesOnlyForIosTrigger() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.remoteFromIOSAllowed = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    // ios trigger → refused.
    let r = try await client.dispatch(action: "shortcut", body: [
        "name": .string("X"), "trigger": .string("ios"),
    ])
    #expect(r.error == "remote_ios_disabled: remote_from_ios_allowed is off")
    #expect(await http.calls.isEmpty)
}

@Test func preflightUserTriggerNotGatedByRemoteIos() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.remoteFromIOSAllowed = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    // user trigger (default) → remote gate does not apply, then shortcut
    // fails closed because it is not implemented in Swift yet.
    let r = try await client.dispatch(action: "shortcut", body: ["name": .string("X")])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 501)
    #expect(await http.calls.isEmpty)
}

@Test func preflightAllowsProceedToNativeAction() async throws {
    // notify is NATIVE; a permissive policy must let it run in-process.
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc,
        policyProvider: _StubPolicyProvider(policy: _permissiveMacPolicy())
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(await mc.calls.count == 1)
}

@Test func preflightNilProviderIsTransparent() async throws {
    // No provider (test-only direct handler mode) → shell can execute in-process.
    let http = _MockHTTPClient()
    let proc = _MockProcessAdapter()
    await proc.queue(ProcessRunResult(exitCode: 0, stdout: "hi\n", stderr: ""))
    let client = SwiftNativeMacControl(http: http, processAdapter: proc)  // no provider
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.viaSwift == true)
    #expect(await http.calls.isEmpty)
    #expect(await proc.calls.count == 1)
}

@Test func preflightUnresolvedPolicyFailsClosedInSwift() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: nil)
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(r.error == "mac_control_policy_unavailable: Swift trust policy could not be resolved")
    #expect(await http.calls.isEmpty)
}

@Test func preflightUnresolvedPolicyBlocksNativeActionBeforeSideEffect() async throws {
    let http = _MockHTTPClient()
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: http,
        notificationCenterAdapter: mc,
        policyProvider: _StubPolicyProvider(policy: nil)
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(await http.calls.isEmpty)
    #expect(await mc.calls.isEmpty, "in-process notification must NOT have fired ungated")
}

@Test func preflightNoProviderStillRunsNativeInProcess() async throws {
    // Contrast with above: NO provider configured (the default) keeps wave-29
    // behavior — notify runs in-process (no policy expectation on that path).
    let http = _MockHTTPClient()
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: http,
        notificationCenterAdapter: mc
    )  // no provider
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.viaSwift == true)
    #expect(await mc.calls.count == 1)
    #expect(await http.calls.isEmpty)
}

@Test func preflightSelfTestUnsupportedWithoutDaemon() async throws {
    // self_test has no single pre-flight category and no Swift executor yet.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "self_test", body: [:])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 501)
    #expect(await http.calls.isEmpty)
}

@Test func preflightFilePolicyDeniesOutsideWorkspace() async throws {
    // file/write is Swift-native. With a trust policy that denies outside
    // workspaces and no full-mac window, an outside path must refuse with the
    // verbatim W4 file-policy string BEFORE the write.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(
        outsideWorkspaceDefault: "deny",
        permissionLevel: "balanced",
        fullMacExpiresAt: "",
        fullMacNeverExpires: false,
        fullMacConfirmedAt: "",
        fullMacMaxDurationHours: 4
    )
    pol.workspaceRoots = ["/tmp/allowed_ws"]
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "file/write", body: [
        "path": .string("/tmp/outside/file.txt"),
        "content": .string("x"),
    ])
    #expect(r.ok == false)
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(r.error?.hasPrefix("file_policy_denied:") == true)
    #expect(r.error?.contains("outside configured workspaces") == true)
    #expect(await http.calls.isEmpty)
}

@Test func preflightFilePolicyAllowsInsideWorkspace() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "deny")
    pol.workspaceRoots = ["/tmp/allowed_ws"]
    let client = SwiftNativeMacControl(
        http: http,
        fileManagerAdapter: fm,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "file/write", body: [
        "path": .string("/tmp/allowed_ws/file.txt"),
        "content": .string("x"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.ok == true)
    #expect(fm.files["/tmp/allowed_ws/file.txt"] == Data("x".utf8))
    #expect(await http.calls.isEmpty)
}

@Test func preflightFullMacBlocksTrashWithoutDeveloperModeEvenWithStaleDestructiveFlag() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/trash.txt"] = Data("X".utf8)
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(
        outsideWorkspaceDefault: "allow",
        permissionLevel: "full_mac_os",
        fullMacNeverExpires: true,
        developerMode: false,
        allowDestructiveActions: true
    )
    let client = SwiftNativeMacControl(
        http: http,
        fileManagerAdapter: fm,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "file/trash", body: [
        "path": .string("/tmp/swiftmc/trash.txt"),
    ])
    #expect(r.ok == false)
    #expect(r.httpStatus == 403)
    #expect(r.error == "developer_mode_required: file/trash requires Developer Mode")
    #expect(fm.files["/tmp/swiftmc/trash.txt"] != nil)
    #expect(fm.trashed.isEmpty)
    #expect(await http.calls.isEmpty)
}

@Test func preflightDeveloperModeAllowsTrash() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/trash.txt"] = Data("X".utf8)
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(
        outsideWorkspaceDefault: "allow",
        permissionLevel: "full_mac_os",
        fullMacNeverExpires: true,
        developerMode: true,
        allowDestructiveActions: false
    )
    let client = SwiftNativeMacControl(
        http: http,
        fileManagerAdapter: fm,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "file/trash", body: [
        "path": .string("/tmp/swiftmc/trash.txt"),
    ])
    #expect(r.ok == true)
    #expect(r.httpStatus == nil)
    #expect(fm.files["/tmp/swiftmc/trash.txt"] == nil)
    #expect(fm.trashed == ["/tmp/swiftmc/trash.txt"])
    #expect(await http.calls.isEmpty)
}

@Test func preflightSensitivePathSkipsFilePolicyRefusal() async throws {
    // A sensitive path that is ALSO outside-workspace must NOT surface the
    // file-policy string from the pre-flight — the pre-flight skips it so the
    // authoritative sensitive reason from the native write fence wins. The
    // request therefore reaches the Swift file handler, whose sensitive fence
    // raises the sensitive-path error.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "deny")
    pol.workspaceRoots = ["/tmp/allowed_ws"]
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    do {
        _ = try await client.dispatch(action: "file/write", body: [
            "path": .string("/tmp/outside/trust_policy.json"),
            "content": .string("x"),
        ])
        Issue.record("expected sensitivePathDenied")
    } catch MacControlError.sensitivePathDenied(let reason) {
        #expect(reason.contains("trust_policy.json"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    #expect(await http.calls.isEmpty)
}

@Test func preflightCategoryMapMatchesDaemon() {
    // Pin every dispatch action → gate category against the verified daemon
    // _gate(...) calls. self_test maps to nil (multi-category sweep).
    #expect(macControlGateCategory(forAction: "applescript") == "applescript")
    #expect(macControlGateCategory(forAction: "jxa") == "jxa")
    #expect(macControlGateCategory(forAction: "shortcut") == "shortcuts")
    #expect(macControlGateCategory(forAction: "shortcut/run") == "shortcuts")
    #expect(macControlGateCategory(forAction: "focus_app") == "accessibility")
    #expect(macControlGateCategory(forAction: "quit_app") == "accessibility")
    #expect(macControlGateCategory(forAction: "keystroke") == "accessibility")
    #expect(macControlGateCategory(forAction: "click") == "accessibility")
    #expect(macControlGateCategory(forAction: "system") == "system")
    #expect(macControlGateCategory(forAction: "file/read") == "file_ops")
    #expect(macControlGateCategory(forAction: "file/write") == "file_ops")
    #expect(macControlGateCategory(forAction: "file/list") == "file_ops")
    #expect(macControlGateCategory(forAction: "file/move") == "file_ops")
    #expect(macControlGateCategory(forAction: "file/trash") == "file_ops")
    #expect(macControlGateCategory(forAction: "notify") == "notifications")
    #expect(macControlGateCategory(forAction: "shell") == "shell")
    #expect(macControlGateCategory(forAction: "spotlight") == "spotlight")
    #expect(macControlGateCategory(forAction: "self_test") == nil)
}

@Test func preflightFilePolicyPathKeysMatchDaemon() {
    #expect(macControlFilePolicyPathKeys(forAction: "file/read") == ["path"])
    #expect(macControlFilePolicyPathKeys(forAction: "file/write") == ["path"])
    #expect(macControlFilePolicyPathKeys(forAction: "file/list") == ["path"])
    #expect(macControlFilePolicyPathKeys(forAction: "file/trash") == ["path"])
    #expect(macControlFilePolicyPathKeys(forAction: "file/move") == ["src", "dst"])
    #expect(macControlFilePolicyPathKeys(forAction: "notify") == [])
}

// MARK: - Misc

@Test func resultJSONRoundTrip() {
    let r = MacControlResult(
        ok: true,
        action: "notify",
        output: .object(["title": .string("x")]),
        error: nil,
        durationMs: 42,
        viaSwift: true
    )
    let json = r.toJSON()
    if case .object(let obj) = json {
        if case .bool(let b) = obj["ok"] { #expect(b == true) } else { Issue.record("ok") }
        if case .string(let a) = obj["action"] { #expect(a == "notify") } else { Issue.record("action") }
        if case .bool(let v) = obj["viaSwift"] { #expect(v == true) } else { Issue.record("viaSwift") }
    } else {
        Issue.record("not an object")
    }
}

// MARK: - Blocked-receipt audit append (wave 32 W03 — CUTOVER §6.55 prereq #4)

/// Make a fresh temp audit-file path inside a unique dir; caller cleans up.
private func _makeTempAuditPath() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl_audit_test_\(UUID().uuidString)", isDirectory: true)
    return dir.appendingPathComponent("mac_control_audit.jsonl")
}

/// Read all JSONL rows from an audit file as parsed objects, simulating the
/// daemon's `_load_audit` (json.loads per line). Returns [] if absent.
private func _readAuditRows(_ path: URL) -> [[String: JSONValue]] {
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line -> [String: JSONValue]? in
        guard let parsed = try? JSONValue.parse(Data(line.utf8)),
              case .object(let obj) = parsed else { return nil }
        return obj
    }
}

@Test func gateRefusalEmitsAuditRowWhenAuditPathSet() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false  // master gate off → refuse
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    let r = try await client.dispatch(action: "shell", body: [
        "command": .string("echo hi"), "trigger": .string("user"),
    ])
    #expect(r.ok == false)
    #expect(r.httpStatus == 403)
    // No HTTP round-trip — refusal is in-process.
    let calls = await http.calls
    #expect(calls.isEmpty)

    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1, "exactly one blocked-receipt row must be appended")
    guard let row = rows.first else { return }
    // _blocked_receipt → make_receipt(blocked=True, block_reason=…) parity shape.
    #expect(row["blocked"] == .bool(true))
    #expect(row["block_reason"] == .string("mac_control_disabled: master gate off"))
    #expect(row["method"] == .string("run_shell"))      // daemon method name for shell
    #expect(row["category"] == .string("shell"))
    #expect(row["trigger"] == .string("user"))
    #expect(row["trigger_source"] == .string("user"))
    #expect(row["args_hash"] == .string("sha256:none"))
    #expect(row["approved"] == .null)
    #expect(row["exit_code"] == .int(0))
    #expect(row["stdout"] == .string(""))
    #expect(row["stderr"] == .string(""))
    #expect(row["duration_ms"] == .int(0))
    // approval_required: approvalRequiredFor is nil → daemon defaults shell to
    // ["shell"] ⇒ true.
    #expect(row["approval_required"] == .bool(true))
    // wave-33 W02: byte-equivalence requires NO extra keys the daemon never
    // writes. The wave-32 `logged_by` marker is gone; the row carries exactly
    // make_receipt's 15 fields.
    #expect(row["logged_by"] == nil)
    #expect(row.count == 15)
    // id + executed_at present and non-empty.
    if case .string(let id)? = row["id"] { #expect(!id.isEmpty) } else { Issue.record("missing id") }
    if case .string(let ts)? = row["executed_at"] { #expect(ts.contains("T")) } else { Issue.record("missing executed_at") }
}

@Test func gateRefusalDoesNotWriteAuditWhenPathNil() async throws {
    // No auditAppendPath → no Swift-side write (wave-31 behavior preserved).
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false
    let probe = _makeTempAuditPath()  // path we ASSERT stays absent
    defer { try? FileManager.default.removeItem(at: probe.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
        // auditAppendPath omitted → nil
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.ok == false)
    #expect(r.httpStatus == 403)
    #expect(!FileManager.default.fileExists(atPath: probe.path),
            "no audit file may be created when auditAppendPath is nil")
}

@Test func fileOpsFilePolicyRefusalEmitsFileOpsAuditRow() async throws {
    // A file-policy refusal (workspace fence) must also log, with the file_ops
    // category + the mapped daemon method name for the action.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    // Constrain the workspace so an out-of-workspace path is refused by the
    // file-policy layer (NOT the sensitive fence — use a benign /tmp path).
    // trustPolicy non-nil + outsideWorkspaceDefault="deny" + full-mac inactive
    // (empty expiry) makes fileReason refuse a path outside workspaceRoots.
    pol.trustPolicy = MacControlTrustPolicy(
        outsideWorkspaceDefault: "deny",
        fullMacExpiresAt: "",
        fullMacNeverExpires: false
    )
    pol.workspaceRoots = ["/some/workspace/only"]
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    let r = try await client.dispatch(action: "file/read", body: [
        "path": .string("/tmp/outside_workspace_file.txt"),
        "trigger": .string("user"),
    ])
    // Only assert the audit row IF the file-policy layer actually refused
    // (guards against a permissive default in the gate that would let it pass).
    let rows = _readAuditRows(auditPath)
    if r.httpStatus == 403 {
        #expect(rows.count == 1)
        guard let row = rows.first else { return }
        #expect(row["blocked"] == .bool(true))
        #expect(row["category"] == .string("file_ops"))
        #expect(row["method"] == .string("read_file"))
        // approvalRequiredFor is nil on this policy → daemon default for a
        // non-shell category is [] → approval_required false.
        #expect(row["approval_required"] == .bool(false))
        if case .string(let br)? = row["block_reason"] { #expect(!br.isEmpty) } else { Issue.record("block_reason") }
    } else {
        // If the gate allowed it, there must be NO audit row (we only log refusals).
        #expect(rows.isEmpty)
    }
}

@Test func auditApprovalRequiredReflectsLivePolicyList() async throws {
    // Daemon-parity finding (W03 gpt-5.5 review #1): approval_required must
    // reflect the LIVE approval_required_for list, not a hardcoded default.
    // When the list is PRESENT, it overrides the shell special-case: a list
    // that EXCLUDES "shell" makes a shell refusal record approval_required=false.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false // master gate off → refuse (category still = shell)
    pol.approvalRequiredFor = ["file_ops"] // shell deliberately NOT in the list
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1)
    // List present + shell absent from it → false (NOT the ["shell"] default).
    #expect(rows.first?["approval_required"] == .bool(false))
    #expect(rows.first?["category"] == .string("shell"))
}

@Test func auditApprovalRequiredDefaultPolicyMatchesDaemon() async throws {
    // W03 re-review finding #1: MacControlPolicy.default carries
    // DEFAULT_MAC_CONTROL_POLICY["approval_required_for"], so a default-policy
    // file_ops refusal logs approval_required=true (daemon parity), not the
    // nil-branch false. Use .default with file_ops disabled-by-default → refuse.
    let http = _MockHTTPClient()
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }
    // .default has enabled=false (master gate off) → any action refuses.
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: .default),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "file/read", body: ["path": .string("/tmp/x")])
    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1)
    #expect(rows.first?["category"] == .string("file_ops"))
    #expect(rows.first?["approval_required"] == .bool(true),
            "default policy includes file_ops in approval_required_for")
}

@Test func auditSystemMethodNameResolvesConcreteSubMethod() async throws {
    // W03 re-review finding #2: /v1/mac_control/system fans out to concrete
    // daemon methods (set_volume etc) chosen by body["action"]. The audit row's
    // `method` must record the concrete name, not the generic "system".
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.categoryAllowed["system_control_allowed"] = false // system refused
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "system", body: [
        "action": .string("set_volume"), "value": .int(50),
    ])
    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1)
    #expect(rows.first?["category"] == .string("system"))
    #expect(rows.first?["method"] == .string("set_volume"),
            "system refusal must record the concrete daemon method, not \"system\"")
}

@Test func auditRowIsValidJSONLParseable() async throws {
    // The daemon's audit reader does json.loads per line; assert the Swift row
    // round-trips cleanly (no trailing comma, valid JSON object, newline-terminated).
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.categoryAllowed["notifications_allowed"] = false
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "notify", body: [
        "title": .string("x"), "message": .string("y"),
    ])
    let raw = try Data(contentsOf: auditPath)
    let text = String(data: raw, encoding: .utf8) ?? ""
    #expect(text.hasSuffix("\n"), "JSONL row must be newline-terminated")
    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1)
    #expect(rows.first?["method"] == .string("post_notification"))
    #expect(rows.first?["category"] == .string("notifications"))
    // notifications is NOT in the default approval_required_for list.
    #expect(rows.first?["approval_required"] == .bool(false))
}

// MARK: - Native audit byte contract

@Test func auditRowMatchesNativeBlockedReceiptByteContract() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false  // master gate off → refuse
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "shell", body: [
        "command": .string("echo hi"), "trigger": .string("user"),
    ])

    // Raw bytes Swift wrote (strip the trailing newline; compare the JSON body).
    let rawData = try Data(contentsOf: auditPath)
    var swiftLine = String(data: rawData, encoding: .utf8) ?? ""
    #expect(swiftLine.hasSuffix("\n"))
    if swiftLine.hasSuffix("\n") { swiftLine.removeLast() }

    // Dynamic fields still have strict byte shapes:
    //   • id          — lowercase UUID.
    //   • executed_at — `...+00:00` offset with optional 6-digit microseconds.
    let rows0 = _readAuditRows(auditPath)
    guard let row0 = rows0.first else { Issue.record("no audit row"); return }
    guard case .string(let id)? = row0["id"] else {
        Issue.record("missing id")
        return
    }
    do {
        #expect(id == id.lowercased(), "id must be a LOWERCASE uuid (Python parity), got: \(id)")
        #expect(id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                         options: .regularExpression) != nil,
                "id must match lowercase-hex UUID shape, got: \(id)")
    }
    guard case .string(let ts)? = row0["executed_at"] else {
        Issue.record("missing executed_at")
        return
    }
    do {
        // Fraction is optional: whole-second instants omit it, otherwise it is
        // exactly 6 digits.
        #expect(ts.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?\+00:00$"#,
                         options: .regularExpression) != nil,
                "executed_at must be YYYY-MM-DDTHH:MM:SS[.ffffff]+00:00, got: \(ts)")
    }

    let expectedLine = try JSONValue.serializeOrderedObjectPython([
        ("id", .string(id)),
        ("method", .string("run_shell")),
        ("category", .string("shell")),
        ("args_hash", .string("sha256:none")),
        ("trigger", .string("user")),
        ("trigger_source", .string("user")),
        ("approval_required", .bool(true)),
        ("approved", .null),
        ("exit_code", .int(0)),
        ("stdout", .string("")),
        ("stderr", .string("")),
        ("duration_ms", .int(0)),
        ("executed_at", .string(ts)),
        ("blocked", .bool(true)),
        ("block_reason", .string("mac_control_disabled: master gate off")),
    ])

    #expect(swiftLine == expectedLine,
            "Swift audit line must match the native ordered blocked-receipt contract.\nSWIFT  : \(swiftLine)\nEXPECTED: \(expectedLine)")
}

@Test func executedAtFormatMatchesNativeIsoformatContractAcrossEdgeCases() async throws {
    let fixtures: [(epoch: Double, expected: String)] = [
        (1_780_000_447.123456, "2026-05-28T20:34:07.123456+00:00"),
        (1_780_000_447.0, "2026-05-28T20:34:07+00:00"),
        (1_780_000_447.1234566, "2026-05-28T20:34:07.123456+00:00"),
        (1_780_000_447.9999996, "2026-05-28T20:34:07.999999+00:00"),
    ]
    for fixture in fixtures {
        let epoch = fixture.epoch
        let fixed = Date(timeIntervalSince1970: epoch)
        let http = _MockHTTPClient()
        var pol = _permissiveMacPolicy()
        pol.enabled = false
        let auditPath = _makeTempAuditPath()
        defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }
        let client = SwiftNativeMacControl(
            http: http,
            now: { fixed },
            policyProvider: _StubPolicyProvider(policy: pol),
            auditAppendPath: auditPath
        )
        _ = try await client.dispatch(action: "shell", body: ["command": .string("x")])
        let rows = _readAuditRows(auditPath)
        guard case .string(let swiftTs)? = rows.first?["executed_at"] else {
            Issue.record("missing executed_at for epoch \(epoch)"); continue
        }
        #expect(swiftTs == fixture.expected,
                "executed_at byte mismatch for epoch \(epoch).\nSWIFT  : \(swiftTs)\nEXPECTED: \(fixture.expected)")
    }
}

/// Unit-level pin of the ordered serializer itself: keys emit in the GIVEN
/// order (NOT sorted), and non-ASCII + control chars escape through the native
/// canonical audit serializer.
@Test func serializeOrderedObjectKeepsNativeAuditByteContract() async throws {
    // Deliberately NOT alphabetical, with a non-ASCII value and an escape char,
    // so a sort-keys or ensure_ascii regression would diverge.
    let pairs: [(String, JSONValue)] = [
        ("z_first", .string("café\n\"q\"")),   // é (U+00E9) + newline + quote
        ("a_last", .int(7)),
        ("mid", .bool(false)),
        ("nullable", .null),
        ("emoji", .string("🚀")),               // surrogate-pair path
    ]
    let swift = try JSONValue.serializeOrderedObjectPython(pairs)
    let expected = #"{"z_first": "caf\u00e9\n\"q\"", "a_last": 7, "mid": false, "nullable": null, "emoji": "\ud83d\ude80"}"#
    #expect(swift == expected,
            "ordered serializer must match the native audit byte contract.\nSWIFT  : \(swift)\nEXPECTED: \(expected)")
}

// MARK: - Accessibility read gate: Full Mac window is required on the bridge path
// (gpt-5.5 BLOCKING, 2026-08-12). The model-tool path gates AX reads on
// accessibilityReadAllowed = fullMacActive && accessibility_allowed. The
// HTTP/iOS-remote bridge dispatches straight through SwiftNativeMacControl,
// whose gate only checked master/category — so these pin that the SAME Full
// Mac predicate refuses in-process when the trust window is absent or expired.

private func _fullMacActiveTrust() -> MacControlTrustPolicy {
    // outside=="allow" satisfies the permission gate; never-expires satisfies
    // the window — fullMacActive is unconditionally true.
    MacControlTrustPolicy(
        outsideWorkspaceDefault: "allow",
        permissionLevel: "full_mac_os",
        fullMacNeverExpires: true
    )
}

@Test func axReadRefusesWhenFullMacWindowInactive() async throws {
    // accessibility category ON, but NO trust policy → Full Mac not active.
    // The category gate alone would pass; the new predicate must refuse.
    let http = _MockHTTPClient()
    let pol = _permissiveMacPolicy()  // trustPolicy: nil
    let client = SwiftNativeMacControl(http: http, policyProvider: _StubPolicyProvider(policy: pol))
    let r = try await client.dispatch(action: "ax_tree", body: [:])
    #expect(r.ok == false)
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(r.error == "full_mac_inactive: ax_tree requires an active Full Mac trust window")
    let calls = await http.calls
    #expect(calls.isEmpty, "a refused AX read must never round-trip to the daemon")
}

@Test func axReadPassesGateWhenFullMacActive() async throws {
    // Same category ON, but WITH an active Full Mac window → the gate no longer
    // refuses. It reaches the reader (untrusted in CI → ok:true, trusted:false),
    // which is a DIFFERENT outcome than the 403 refusal above — proving the
    // predicate is what changed, not a blanket allow/deny.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    let client = SwiftNativeMacControl(http: http, policyProvider: _StubPolicyProvider(policy: pol))
    let r = try await client.dispatch(action: "ax_status", body: [:])
    #expect(r.ok == true, "gate must pass; ax_status answers trusted:false honestly, not a 403")
    #expect(r.httpStatus != 403)
}

// MARK: - W2/W3 injection: the THREE gates, one test each
//
// Every injection action must clear ALL THREE of:
//   (a) the accessibility CATEGORY (master gate + per-category),
//   (b) an ACTIVE Full Mac trust window,
//   (c) the APPROVAL tier — a live, body-bound, single-use
//       `MacInjectionCapability` presented through `dispatchApprovedInjection`.
// Each gate gets its own test, and each test flips exactly ONE input away from
// a known-passing fixture so a pass cannot come from the wrong reason.

private let _injectionActions = ["keystroke", "click", "scroll", "ax_act"]

private func _injectionBody(_ action: String) -> [String: JSONValue] {
    switch action {
    case "keystroke": return ["text": .string("hi")]
    case "click": return ["x": .int(10), "y": .int(20)]
    case "scroll": return ["dy": .int(-3)]
    default: return ["path": .array([.int(0)])]
    }
}

extension SwiftNativeMacControl {
    /// Test-only stand-in for what `AutonomyGatedDispatcher.runInner` does after
    /// a resolved approval: mint a capability bound to this exact action+body
    /// and present it on the privileged entry point. Handler-behaviour tests
    /// use this so they stay about handler behaviour; the gate tests below call
    /// the raw entry points deliberately.
    func injectApproved(
        action: String,
        body: [String: JSONValue],
        approvalID: String = "test-approval-\(UUID().uuidString)"
    ) async throws -> MacControlResult {
        guard let capability = MacInjectionCapability.mint(
            approvalID: approvalID,
            action: action,
            body: body
        ) else {
            Issue.record("could not mint an injection capability for \(action)")
            return MacControlResult(ok: false, action: action, output: .null, error: "mint_failed", durationMs: 0, viaSwift: true)
        }
        return try await dispatchApprovedInjection(
            action: action,
            body: body,
            capability: capability
        )
    }
}

/// Full Mac ACTIVE + accessibility category ON + attested: the fixture every
/// gate test below flips one field of.
/// Swallows every synthesized event so a test can never move the real cursor or
/// type into the real frontmost app.
///
/// HERMETICITY (2026-08-13): this became load-bearing with the YOLO cutover.
/// While the injection entry points refused without a capability, these tests
/// never reached a sink. They self-mint now, so a test host whose responsible
/// process holds the Accessibility TCC grant WOULD post real events through the
/// default `defaultMacEventSink()`. Every client built here injects this sink.
private final class _InertEventSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _mouse = 0
    private var _keys = 0
    var isAvailable: Bool { true }
    var mouseCount: Int { lock.lock(); defer { lock.unlock() }; return _mouse }
    var keyCount: Int { lock.lock(); defer { lock.unlock() }; return _keys }
    func post(key: MacKeyEvent) { lock.lock(); _keys += 1; lock.unlock() }
    func post(mouse: MacMouseEvent) { lock.lock(); _mouse += 1; lock.unlock() }
    func post(scroll: MacScrollEvent) { lock.lock(); _mouse += 1; lock.unlock() }
}

private func _injectionReadyClient(
    _ http: _MockHTTPClient,
    sink: any MacEventSink = _InertEventSink()
) -> SwiftNativeMacControl {
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    return SwiftNativeMacControl(
        http: http,
        eventSink: sink,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
}

@Test func injectionRefusedWhenFullMacWindowInactive() async throws {
    // GATE (b). Category ON, attestation PRESENT — only the Full Mac window
    // is missing (trustPolicy nil ⇒ never confirmed).
    for action in _injectionActions {
        let http = _MockHTTPClient()
        let client = SwiftNativeMacControl(
            http: http,
            policyProvider: _StubPolicyProvider(policy: _permissiveMacPolicy())
        )
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.ok == false, "\(action)")
        #expect(r.httpStatus == 403, "\(action)")
        #expect(r.error == "full_mac_inactive: \(action) requires an active Full Mac trust window", "\(action)")
        #expect(await http.calls.isEmpty, "a refused injection must never round-trip anywhere")
    }
}

@Test func injectionRefusedWhenAccessibilityCategoryOff() async throws {
    // GATE (a). Full Mac ACTIVE, attestation PRESENT — only the category flips.
    for action in _injectionActions {
        var pol = _permissiveMacPolicy()
        pol.trustPolicy = _fullMacActiveTrust()
        pol.categoryAllowed["accessibility_allowed"] = false
        let client = SwiftNativeMacControl(
            http: _MockHTTPClient(),
            policyProvider: _StubPolicyProvider(policy: pol)
        )
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.ok == false, "\(action)")
        #expect(r.httpStatus == 403, "\(action)")
        #expect(r.error?.isEmpty == false, "\(action) must carry the category refusal reason")
        #expect(r.error?.contains("full_mac_inactive") == false,
                "\(action) must refuse for the CATEGORY, not fall through to the window check")
    }
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT (GATE (c)): with Full Mac ACTIVE and the category ON, the only
/// thing missing was a capability — and the public `dispatch` has no parameter
/// that could carry one, so it 403'd with `approval_not_granted`. That gate
/// closed the HTTP / iOS-remote bridge, the app's direct MacControl callers and
/// any raw SwiftToolDispatcher.
/// NEW CONTRACT: `dispatchCore` self-mints, so gate (c) no longer exists.
/// Gates (a) master-enabled and (b) the Full Mac window remain, and their
/// dedicated rows above/below are what still prove the entry point is gated.
@Test func publicDispatchEntryPointSelfMintsAndClearsTheApprovalTier() async throws {
    for action in _injectionActions {
        let http = _MockHTTPClient()
        let client = _injectionReadyClient(http)
        let r = try await client.dispatch(action: action, body: _injectionBody(action))
        #expect(r.error != "approval_not_granted: \(action) requires an approved injection request",
                "\(action): the approval tier is retired")
        // Past the retired tier it may still stop at the macOS TCC grant, which
        // is a DIFFERENT, non-403 outcome.
        if r.httpStatus == 403 {
            Issue.record("\(action) must no longer 403 on the approval tier: \(r.error ?? "nil")")
        }
    }
}

@Test func injectionRefusedWhenTheMasterGateIsOff() async throws {
    // Defense in depth: master `enabled:false` refuses before the category is
    // even consulted, exactly as it does for every other Mac Control action.
    for action in _injectionActions {
        var pol = _permissiveMacPolicy()
        pol.trustPolicy = _fullMacActiveTrust()
        pol.enabled = false
        let client = SwiftNativeMacControl(
            http: _MockHTTPClient(),
            policyProvider: _StubPolicyProvider(policy: pol)
        )
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.ok == false && r.httpStatus == 403, "\(action)")
    }
}

@Test func injectionPassesAllThreeGatesAndReachesTheHandler() async throws {
    // The positive control that gives the three refusals above their teeth: the
    // SAME fixture with nothing flipped must NOT 403 — it must reach the
    // injection preconditions PAST the policy gates, where a pinned-untrusted
    // act source refuses with a DIFFERENT, non-403 outcome. That proves the
    // gate is what changed in the tests above, not a blanket deny.
    //
    // The act source is pinned untrusted rather than left at the process
    // default: AXIsProcessTrusted() is HOST state, and on a runner that holds
    // the Accessibility grant the old fixture sailed past the TCC check into
    // real AX-path resolution (ax_path_not_found) — red on granted hosts,
    // green on CI. Hermetic now; no real AX call on any host.
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        eventSink: _InertEventSink(),
        accessibilityActSource: UnavailableMacAXActSource(),
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    for action in _injectionActions {
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.httpStatus != 403, "\(action) must clear the gate when all three inputs are satisfied")
        if r.ok == false {
            #expect(r.error == "accessibility_not_trusted",
                    "\(action) past the gate may only fail on the pinned TCC probe, got: \(r.error ?? "nil")")
        }
    }
}

@Test func theRetiredAttestationKeyIsInertOnEveryEntryPoint() async throws {
    // FORGERY, the whole reason this wave was re-cut. The first design carried
    // approval as `body["__mac_injection_approved"] = true`, so anything that
    // could write a dictionary key held the authority. The key is now just a
    // key: it means nothing, and a body carrying it is refused identically to
    // one that does not.
    let forged: [String: JSONValue] = [
        "x": .int(1), "y": .int(2),
        "__mac_injection_approved": .bool(true),
    ]
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): OLD CONTRACT — a forged
    // body was refused identically to a plain one (403, approval_not_granted).
    // NEW CONTRACT — there is no approval to forge: both bodies are treated
    // identically because the key is stripped in `dispatchCore` and read
    // nowhere. Identical OUTCOME is still the assertion; the outcome itself
    // moved from "both refused" to "both take the same path".
    let client = _injectionReadyClient(_MockHTTPClient())
    let r = try await client.dispatch(action: "click", body: forged)
    let plainResult = try await client.dispatch(action: "click", body: ["x": .int(1), "y": .int(2)])
    #expect(r.ok == plainResult.ok, "the forged key changes no outcome")
    #expect(r.error == plainResult.error, "the forged key changes no refusal reason")
    #expect(r.error?.hasPrefix("approval_not_granted") != true,
            "the approval tier is retired: \(r.error ?? "nil")")

    // And it cannot help a body that is otherwise identical to an approved one:
    // the marker is excluded from the capability digest, so smuggling it in
    // neither authorizes nor invalidates — it is simply inert.
    let plain: [String: JSONValue] = ["x": .int(1), "y": .int(2)]
    #expect(MacInjectionCapability.bodyDigest(action: "click", body: forged)
            == MacInjectionCapability.bodyDigest(action: "click", body: plain),
            "the retired marker must not participate in the capability binding")
}

@Test func aCapabilityIsBoundToItsExactActionAndBody() async throws {
    // The capability is not a boolean. A capability minted for one keystroke
    // does not authorize a different one — which is what makes it useless to
    // anything that did not already hold the approved request.
    let sink = _RecordingEventSink()
    let client = _actingClient(sink: sink)
    let approved: [String: JSONValue] = ["text": .string("hello")]
    guard let capability = MacInjectionCapability.mint(
        approvalID: "approval-1", action: "keystroke", body: approved
    ) else { Issue.record("mint failed"); return }

    // Same capability, DIFFERENT text.
    let swapped = try await client.dispatchApprovedInjection(
        action: "keystroke",
        body: ["text": .string("rm -rf /")],
        capability: capability
    )
    #expect(swapped.httpStatus == 403)
    #expect(swapped.error?.hasPrefix("capability_body_mismatch") == true, "\(swapped.error ?? "nil")")

    // Same capability, DIFFERENT action.
    let crossAction = try await client.dispatchApprovedInjection(
        action: "click",
        body: ["x": .int(1), "y": .int(2)],
        capability: capability
    )
    #expect(crossAction.httpStatus == 403)
    #expect(crossAction.error?.hasPrefix("capability_action_mismatch") == true, "\(crossAction.error ?? "nil")")
    #expect(sink.keys.isEmpty && sink.mouse.isEmpty, "no refused call may emit an event")

    // The matching call still works — the refusals above are about the BINDING,
    // not a blanket deny.
    let honored = try await client.dispatchApprovedInjection(
        action: "keystroke", body: approved, capability: capability
    )
    #expect(honored.ok, "\(honored.error ?? "")")
    #expect(sink.keys.count == 10, "5 characters × down/up")
}

@Test func aCapabilityIsSingleUseAndExpires() async throws {
    let sink = _RecordingEventSink()
    let client = _actingClient(sink: sink)
    let body: [String: JSONValue] = ["x": .int(3), "y": .int(4)]
    guard let capability = MacInjectionCapability.mint(
        approvalID: "approval-2", action: "click", body: body
    ) else { Issue.record("mint failed"); return }

    let first = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(first.ok, "\(first.error ?? "")")

    // REPLAY. One approval buys one injection; a captured capability is spent.
    let second = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(second.httpStatus == 403)
    #expect(second.error?.hasPrefix("capability_already_used") == true, "\(second.error ?? "nil")")
    #expect(sink.mouse.count == 3, "only the FIRST call may have emitted events")

    // TTL: a capability minted in the past authorizes nothing even unspent.
    guard let stale = MacInjectionCapability.mint(
        approvalID: "approval-3",
        action: "click",
        body: body,
        now: Date().addingTimeInterval(-(MacInjectionCapability.defaultTTLSeconds + 60))
    ) else { Issue.record("mint failed"); return }
    let expired = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: stale
    )
    #expect(expired.httpStatus == 403)
    #expect(expired.error?.hasPrefix("capability_expired") == true, "\(expired.error ?? "nil")")
}

@Test func aCapabilityCannotBeMintedWithoutAnApproval() {
    // An empty approval id is exactly "nobody said yes". There is no other
    // constructor: `MacInjectionCapability`'s memberwise init is private, so a
    // caller cannot write one as a literal.
    #expect(MacInjectionCapability.mint(approvalID: "", action: "keystroke", body: [:]) == nil)
    #expect(MacInjectionCapability.mint(approvalID: "   ", action: "keystroke", body: [:]) == nil)
    // ...and it cannot be minted for a NON-injection action, so it can never
    // become a general-purpose MacControl override.
    #expect(MacInjectionCapability.mint(approvalID: "a", action: "focus_app", body: [:]) == nil)
    #expect(MacInjectionCapability.mint(approvalID: "a", action: "shell", body: [:]) == nil)
}

@Test func injectionActRequiresTheACTSourceTrustNotTheReadSource() async throws {
    // SHOULD-FIX 5. The precondition used to be
    // `actSource.isTrusted() || accessibilitySource.isTrusted()`, so a trusted
    // READ seam satisfied an ACT precondition. Read trust is not act authority.
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        accessibilitySource: _TrustedReadOnlyAXSource(),   // READ seam IS trusted
        eventSink: sink,
        accessibilityActSource: _FakeAXActSource(root: nil, trusted: false),  // ACT seam NOT trusted
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    for action in _injectionActions {
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.ok == false, "\(action) must refuse when the ACT source is untrusted")
        #expect(r.error == "accessibility_not_trusted", "\(action): \(r.error ?? "nil")")
    }
    #expect(sink.keys.isEmpty && sink.mouse.isEmpty && sink.scrolls.isEmpty,
            "an untrusted act source must emit NOTHING")
}

@Test func axActRefusesANonIntegralPathIndex() async throws {
    // SHOULD-FIX 6. `1.9` used to truncate to 1 and act on a DIFFERENT element
    // than the caller named — a silent wrong-target click.
    let target = _FakeAXActNode(role: "AXButton", title: "Send",
                                frame: MacAXFrame(x: 1, y: 1, w: 2, h: 2), actions: ["AXPress"])
    let other = _FakeAXActNode(role: "AXButton", title: "Delete",
                               frame: MacAXFrame(x: 9, y: 9, w: 2, h: 2), actions: ["AXPress"])
    let root = _FakeAXActNode(role: "AXWindow", children: [target, other])
    let sink = _RecordingEventSink()
    for bad in [JSONValue.double(1.9), .double(0.5), .double(-0.0001), .double(1e30)] {
        let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
            action: "ax_act",
            body: ["path": .array([bad])]
        )
        #expect(!r.ok && r.httpStatus == 400, "\(bad) must be refused, not truncated")
        #expect(r.error?.contains("non-negative integers") == true, "\(bad): \(r.error ?? "nil")")
    }
    #expect(target.performed.isEmpty && other.performed.isEmpty,
            "no malformed index may reach an element")
    // Positive control: an INTEGRAL double is still a valid index.
    let ok = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: ["path": .array([.double(1.0)])]
    )
    #expect(ok.ok, "\(ok.error ?? "")")
    #expect(other.performed == ["AXPress"], "1.0 must mean index 1, the element the caller named")
}

@Test func accessibilityReadsAreUnaffectedByTheInjectionApprovalTier() async throws {
    // Regression fence: the W1 read tier must NOT have acquired an approval
    // requirement. An unattested read still passes the gate.
    let client = _injectionReadyClient(_MockHTTPClient())
    for action in ["ax_status", "ax_tree", "ax_find"] {
        let body: [String: JSONValue] = action == "ax_find" ? ["role": .string("AXButton")] : [:]
        let r = try await client.dispatch(action: action, body: body)
        #expect(r.httpStatus != 403, "\(action) is read tier — it must not need an approval attestation")
    }
}

// MARK: - W2 handler behaviour through the real dispatch path

private func _actingClient(
    sink: _RecordingEventSink,
    actRoot: _FakeAXActNode? = nil
) -> SwiftNativeMacControl {
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    return SwiftNativeMacControl(
        http: _MockHTTPClient(),
        eventSink: sink,
        accessibilityActSource: _FakeAXActSource(root: actRoot, trusted: true),
        policyProvider: _StubPolicyProvider(policy: pol)
    )
}

@Test func keystrokeDispatchEmitsTypingAndChordEventsInOrder() async throws {
    let sink = _RecordingEventSink()
    let client = _actingClient(sink: sink)
    let r = try await client.injectApproved(
        action: "keystroke",
        body: ([
            "text": .string("hi"),
            "keys": .string("cmd+s"),
        ])
    )
    #expect(r.ok, "\(r.error ?? "")")
    // 2 characters × down/up, then the chord's down/up.
    #expect(sink.keys.count == 6)
    #expect(sink.keys.prefix(4).compactMap(\.unicodeText) == ["h", "h", "i", "i"])
    #expect(sink.keys[4].keyCode == 1 && sink.keys[4].modifiers == .command)
    #expect(sink.keys[5].down == false && sink.keys[5].modifiers == .command)
    guard case .object(let out) = r.output else { Issue.record("no output object"); return }
    // The typed CHARACTERS are never echoed back — only the count.
    #expect(out["text_characters"] == .int(2))
    #expect(out["verified"] == .bool(false), "emitting events is not observing an effect")
    let serialized = String(data: try r.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!serialized.contains("\"hi\""), "keystroke payloads carry secrets — never echo the text")
}

@Test func keystrokeRejectsMalformedSyntaxWithoutEmittingAnything() async throws {
    let sink = _RecordingEventSink()
    let client = _actingClient(sink: sink)
    let r = try await client.injectApproved(
        action: "keystroke",
        body: (["keys": .string("cmd+shift+")])
    )
    #expect(!r.ok)
    #expect(r.httpStatus == 400)
    #expect(r.error?.hasPrefix("invalid_keystroke_syntax") == true, "\(r.error ?? "nil")")
    #expect(sink.keys.isEmpty, "a half-understood chord spec must emit NOTHING")
}

@Test func keystrokeRequiresTextOrKeys() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "keystroke",
        body: ([:])
    )
    #expect(!r.ok && r.httpStatus == 400)
    #expect(sink.keys.isEmpty)
}

@Test func clickDispatchEmitsMoveDownUp() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "click",
        body: (["x": .int(120), "y": .int(340)])
    )
    #expect(r.ok, "\(r.error ?? "")")
    #expect(sink.mouse.map(\.phase) == [.move, .down, .up])
    #expect(sink.mouse.allSatisfy { $0.x == 120 && $0.y == 340 })
}

@Test func clickDispatchSupportsDoubleRightAndDrag() async throws {
    let double = _RecordingEventSink()
    _ = try await _actingClient(sink: double).injectApproved(
        action: "click",
        body: ([
            "x": .int(1), "y": .int(2), "double": .bool(true),
        ])
    )
    #expect(double.mouse.filter { $0.phase == .down }.map(\.clickCount) == [1, 2])

    let right = _RecordingEventSink()
    _ = try await _actingClient(sink: right).injectApproved(
        action: "click",
        body: ([
            "x": .int(1), "y": .int(2), "button": .string("right"),
        ])
    )
    #expect(right.mouse.filter { $0.phase != .move }.allSatisfy { $0.button == .right })

    let drag = _RecordingEventSink()
    let r = try await _actingClient(sink: drag).injectApproved(
        action: "click",
        body: ([
            "from": .object(["x": .int(5), "y": .int(6)]),
            "to": .object(["x": .int(70), "y": .int(80)]),
            "duration_ms": .int(80),
        ])
    )
    #expect(r.ok)
    #expect(drag.mouse.prefix(2).map(\.phase) == [.move, .down])
    #expect(drag.mouse.dropFirst(2).dropLast().allSatisfy { $0.phase == .drag })
    #expect(drag.mouse.last?.phase == .up)
    #expect(drag.mouse.count == 8) // move + down + five 16ms drag steps + up
    #expect(drag.mouse.last?.x == 70 && drag.mouse.last?.y == 80)
}

@Test func clickRequiresCoordinates() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "click",
        body: (["button": .string("left")])
    )
    #expect(!r.ok && r.httpStatus == 400)
    #expect(sink.mouse.isEmpty)
}

@Test func scrollDispatchEmitsAWheelEventAndClampsRunawayDeltas() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "scroll",
        body: ([
            "dy": .int(999_999), "x": .int(400), "y": .int(300), "units": .string("pixel"),
        ])
    )
    #expect(r.ok, "\(r.error ?? "")")
    #expect(sink.mouse.map(\.phase) == [.move], "an x/y scroll moves the pointer over the target view first")
    #expect(sink.scrolls.count == 1)
    #expect(sink.scrolls[0].deltaY == 10_000, "runaway deltas are clamped")
    #expect(sink.scrolls[0].unit == .pixel)
}

@Test func scrollRefusesAZeroDelta() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "scroll",
        body: (["dx": .int(0), "dy": .int(0)])
    )
    #expect(!r.ok && r.httpStatus == 400)
    #expect(sink.scrolls.isEmpty)
}

@Test func axActDispatchPressesAndReturnsPostState() async throws {
    let button = _FakeAXActNode(
        role: "AXButton", title: "Send",
        frame: MacAXFrame(x: 600, y: 500, w: 100, h: 40),
        actions: ["AXPress"]
    )
    let root = _FakeAXActNode(role: "AXWindow", title: "Compose", children: [button])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: (["path": .array([.int(0)])])
    )
    #expect(r.ok, "\(r.error ?? "")")
    guard case .object(let out) = r.output else { Issue.record("no output"); return }
    #expect(out["method"] == .string("ax_action"))
    #expect(out["requested_action"] == .string("AXPress"))
    #expect(button.performed == ["AXPress"])
    #expect(sink.mouse.isEmpty, "the semantic path must not synthesize a click")
    guard case .object(let post)? = out["post_state"] else { Issue.record("no post_state"); return }
    #expect(post["value"] == .string("pressed"), "the post-state read must be surfaced to the caller")
}

@Test func axActDispatchFallsBackToACentreClick() async throws {
    let image = _FakeAXActNode(
        role: "AXImage", title: "Logo",
        frame: MacAXFrame(x: 20, y: 20, w: 60, h: 60), actions: []
    )
    let root = _FakeAXActNode(role: "AXWindow", children: [image])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: (["path": .array([.int(0)])])
    )
    #expect(r.ok)
    guard case .object(let out) = r.output else { Issue.record("no output"); return }
    #expect(out["method"] == .string("cgevent_click_fallback"))
    #expect(out["fallback_reason"] == .string("element_does_not_advertise_AXPress"))
    #expect(sink.mouse.map(\.phase) == [.move, .down, .up])
    #expect(sink.mouse.allSatisfy { $0.x == 50 && $0.y == 50 })
}

@Test func axActRejectsAMalformedPath() async throws {
    let root = _FakeAXActNode(role: "AXWindow", children: [])
    let sink = _RecordingEventSink()
    for bad in [
        JSONValue.array([.string("0")]),
        .array([.int(-1)]),
        .string("0"),
    ] {
        let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
            action: "ax_act",
            body: (["path": bad])
        )
        #expect(!r.ok && r.httpStatus == 400, "\(bad)")
    }
    #expect(sink.mouse.isEmpty)
}

@Test func axActReports404WhenThePathDoesNotResolve() async throws {
    let root = _FakeAXActNode(role: "AXWindow", children: [])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: (["path": .array([.int(7)])])
    )
    #expect(!r.ok)
    #expect(r.httpStatus == 404)
    #expect(r.error == "ax_path_not_found")
    #expect(sink.mouse.isEmpty)
}

@Test func injectionRefusesWithoutTheMacOSAccessibilityGrant() async throws {
    // The policy gate is not the system grant. Without the TCC grant CGEventPost
    // is swallowed by the window server, so reporting "typed" would be a lie.
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        accessibilitySource: _UntrustedAXSource(),
        eventSink: sink,
        accessibilityActSource: _FakeAXActSource(root: nil, trusted: false),
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    for action in _injectionActions {
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(!r.ok, "\(action)")
        #expect(r.error == "accessibility_not_trusted", "\(action): \(r.error ?? "nil")")
    }
    #expect(sink.keys.isEmpty && sink.mouse.isEmpty && sink.scrolls.isEmpty)
}

/// Read source that reports no TCC grant, so the grant precondition can be
/// exercised independently of the host machine's real TCC state.
private struct _UntrustedAXSource: MacAXElementSource {
    func isTrusted() -> Bool { false }
    func frontmostApp() -> MacAXAppInfo? { nil }
    func frontmostWindowRoot() -> MacAXElementRef? { nil }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { nil }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] { [] }
}

/// READ source that reports a live TCC grant. Its whole job is to prove the act
/// precondition does NOT accept it in place of the act source's own trust
/// (SHOULD-FIX 5).
private struct _TrustedReadOnlyAXSource: MacAXElementSource {
    func isTrusted() -> Bool { true }
    func frontmostApp() -> MacAXAppInfo? { nil }
    func frontmostWindowRoot() -> MacAXElementRef? { nil }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { nil }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] { [] }
}

// MARK: - W2/W3-FIX-R2 3: a written ax_act value never comes back out

@Test func axActValueIsRedactedOutOfTheResultAndThePostState() async throws {
    // BLOCKING R2-3. `ax_act(value:)` writes a string into a field — which can
    // be a password or a 2FA code — and this handler then RE-READS the field
    // and returns both `element` and `post_state`. That put the secret into the
    // tool result, and from there into the turn trace, the operation store, the
    // chat transcript, and the approval record's resultPreview (which syncs to
    // iOS/Telegram). The argument redaction did nothing about the RETURN trip.
    let secret = "hunter2"
    let field = _FakeAXActNode(
        role: "AXTextField", title: "Password",
        frame: MacAXFrame(x: 10, y: 10, w: 200, h: 24),
        actions: [], settable: true
    )
    let root = _FakeAXActNode(role: "AXWindow", title: "Login", children: [field])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: ["path": .array([.int(0)]), "action": .string("AXSetValue"),
               "value": .string(secret)]
    )
    #expect(r.ok, "\(r.error ?? "")")
    // The WRITE still happened — this is redaction of the echo, not of the act.
    #expect(field.value == secret, "the value must actually be written")

    let serialized = String(
        data: try r.output.serializedData(pretty: false), encoding: .utf8
    ) ?? ""
    #expect(!serialized.contains(secret),
            "no part of an ax_act result may echo the written value: \(serialized)")
    #expect(serialized.contains("\"value_redacted\": true"))

    guard case .object(let out) = r.output else { Issue.record("no output"); return }
    guard case .object(let post)? = out["post_state"] else { Issue.record("no post_state"); return }
    guard case .object(let postValue)? = post["value"] else {
        Issue.record("post_state.value must be the redaction envelope, got \(post["value"] ?? .null)")
        return
    }
    // Auditable, not readable: count + digest, the same shape the redacted
    // ARGUMENT carries, so a reviewer can still confirm what landed is what was
    // approved.
    #expect(postValue["redacted"] == .bool(true))
    #expect(postValue["character_count"] == .int(7))
    #expect(postValue["sha256"] == .string(MacInjectionArgRedaction.sha256(secret) ?? ""))
}

@Test func axActWithNoValueStillReturnsThePlainPostState() async throws {
    // TEETH for the test above: the redaction is scoped to a value-CARRYING
    // call. A press keeps its readable post-state, so a blanket "null out
    // post_state.value" implementation fails here.
    let button = _FakeAXActNode(
        role: "AXButton", title: "Send",
        frame: MacAXFrame(x: 600, y: 500, w: 100, h: 40), actions: ["AXPress"]
    )
    let root = _FakeAXActNode(role: "AXWindow", children: [button])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act", body: ["path": .array([.int(0)])]
    )
    #expect(r.ok)
    guard case .object(let out) = r.output else { Issue.record("no output"); return }
    #expect(out["value_redacted"] == .bool(false))
    guard case .object(let post)? = out["post_state"] else { Issue.record("no post_state"); return }
    #expect(post["value"] == .string("pressed"),
            "a press must still surface its readable post-state")
}

@Test func injectionResultRedactorCoversEveryValueBearingShape() {
    // The downstream preview boundaries (turn trace, approval resultPreview)
    // apply this independently of the MacControl handler, so a future result
    // shape that reintroduces the field cannot leak through them.
    let raw = JSONValue.object([
        "element": .object(["role": .string("AXTextField"), "value": .string("hunter2")]),
        "post_state": .object(["value": .string("hunter2")]),
        "nested": .array([.object(["text": .string("hunter2")])]),
        "role": .string("AXTextField"),
    ])
    let redacted = MacInjectionResultRedaction.redacted(tool: "mac_ax_act", result: raw)
    let serialized = String(data: (try? redacted.serializedData(pretty: false)) ?? Data(), encoding: .utf8) ?? ""
    #expect(!serialized.contains("hunter2"), "\(serialized)")
    #expect(serialized.contains("\"character_count\": 7"))
    #expect(serialized.contains("AXTextField"), "non-secret fields survive")

    // Idempotent, and a non-injection tool is untouched.
    #expect(MacInjectionResultRedaction.redacted(tool: "mac_ax_act", result: redacted) == redacted)
    #expect(MacInjectionResultRedaction.redacted(tool: "read_file", result: raw) == raw)
}
