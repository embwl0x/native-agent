import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Adapter protocols (test-injectable)

public protocol NotificationCenterAdapter: Sendable {
    func postNotification(title: String, message: String, soundName: String?) async throws
}

public protocol AppleScriptAdapter: Sendable {
    func run(script: String) async throws -> String
}

public struct ProcessRunResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public protocol ProcessAdapter: Sendable {
    func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessRunResult
}

public struct AppControlRunResult: Sendable, Equatable {
    public let requestedName: String
    public let matchedName: String?
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let launched: Bool
    public let activated: Bool
    public let terminated: Bool
    public let alreadyInDesiredState: Bool

    public init(
        requestedName: String,
        matchedName: String?,
        bundleIdentifier: String?,
        processIdentifier: Int32?,
        launched: Bool,
        activated: Bool,
        terminated: Bool,
        alreadyInDesiredState: Bool = false
    ) {
        self.requestedName = requestedName
        self.matchedName = matchedName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.launched = launched
        self.activated = activated
        self.terminated = terminated
        self.alreadyInDesiredState = alreadyInDesiredState
    }
}

public protocol AppControlAdapter: Sendable {
    func focusApp(named name: String) async throws -> AppControlRunResult
    func quitApp(named name: String) async throws -> AppControlRunResult
}

/// Optional exact postcondition observer for application mutations. The
/// command result alone proves only that AppKit accepted the request; motor
/// verification requires a separate observation of the resulting state.
public protocol AppStateVerificationAdapter: Sendable {
    func isFrontmostApplication(matching name: String) async -> Bool
    func isApplicationRunning(matching name: String) async -> Bool
}

public protocol FileManagerAdapter: Sendable {
    func readData(at url: URL, maxBytes: Int) throws -> Data
    func writeData(_ data: Data, to url: URL, append: Bool) throws
    func listDirectory(at url: URL) throws -> [URL]
    func moveItem(from src: URL, to dst: URL) throws
    func trashItem(at url: URL) throws
}

/// Optional exact postcondition seam for mutation verification. Adapters that
/// cannot observe filesystem state remain valid, and their mutations are
/// honestly reported as unverified.
public protocol FileStateVerificationAdapter: Sendable {
    func itemExists(at url: URL) -> Bool
}

// MARK: - System adapters (production impls)

public final class SystemNotificationCenterAdapter: NotificationCenterAdapter {
    public init() {}
    public func postNotification(title: String, message: String, soundName: String?) async throws {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        // Authorization is the user's responsibility — we don't force a runtime
        // prompt (the prompt belongs in the permissions onboarding flow). But
        // center.add completes with err==nil when unauthorized and silently
        // drops the request, so check settings explicitly: unauthorized must
        // map to ok:false with an actionable reason, not a fabricated success.
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            throw MacControlError.notificationFailed(
                "notifications not authorized (status: \(Self.describe(settings.authorizationStatus))) — enable NativeAgent in System Settings → Notifications"
            )
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        if let s = soundName, !s.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: s))
        } else {
            content.sound = .default
        }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            center.add(req) { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: ()) }
            }
        }
        #else
        throw MacControlError.notificationFailed("UserNotifications unavailable on this platform")
        #endif
    }

    #if canImport(UserNotifications)
    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
    #endif
}

public final class SystemAppleScriptAdapter: AppleScriptAdapter {
    public init() {}
    public func run(script: String) async throws -> String {
        #if canImport(AppKit)
        // NSAppleScript.executeAndReturnError is main-thread-only — hop through
        // @MainActor the same way SystemAppControlAdapter.focusAppOnMain does.
        return try await Self.runOnMain(script: script)
        #else
        throw MacControlError.applescriptFailed("AppKit unavailable on this platform")
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    private static func runOnMain(script: String) throws -> String {
        guard let scr = NSAppleScript(source: script) else {
            throw MacControlError.applescriptFailed("NSAppleScript init failed")
        }
        var errInfo: NSDictionary? = nil
        let descriptor = scr.executeAndReturnError(&errInfo)
        if let errInfo {
            let message = (errInfo[NSAppleScript.errorMessage] as? String)
                ?? "applescript error"
            throw MacControlError.applescriptFailed(message)
        }
        return descriptor.stringValue ?? ""
    }
    #endif
}

public final class SystemProcessAdapter: ProcessAdapter {
    private let timeoutSnapshotInstalledObserver:
        (@Sendable (ProcessTreeSnapshot) -> Void)?

    public init() {
        timeoutSnapshotInstalledObserver = nil
    }

    /// Narrow deterministic test seam. Production uses `init()` and has no
    /// observer. The callback runs on the native deadline owner after timeout
    /// state and its identity-bound process-tree snapshot are installed, but
    /// before the timeout termination worker is launched.
    init(
        timeoutSnapshotInstalledObserver:
            @escaping @Sendable (ProcessTreeSnapshot) -> Void
    ) {
        self.timeoutSnapshotInstalledObserver = timeoutSnapshotInstalledObserver
    }
    private final class _Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private let byteLimit: Int?
        private var data = Data()
        private var droppedBytes = 0

        init(byteLimit: Int?) {
            self.byteLimit = byteLimit.map { max(0, $0) }
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            if let byteLimit {
                let room = max(0, byteLimit - data.count)
                if room > 0 { data.append(chunk.prefix(room)) }
                droppedBytes += max(0, chunk.count - room)
            } else {
                data.append(chunk)
            }
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        var truncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return droppedBytes > 0
        }
    }

    /// Bridges Process.terminationHandler to async/await without blocking a
    /// cooperative executor thread. The child may exit before or after the
    /// continuation is installed, so both paths meet behind this one-shot lock.
    private final class _ProcessCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    /// Owns process-tree termination for timeout and parent Task cancellation.
    /// Timeout gets a cooperative SIGTERM -> SIGKILL window; explicit user
    /// cancellation SIGKILLs immediately so descendants cannot continue side
    /// effects after cancellation has been acknowledged.
    private final class _ProcessTermination: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let onSettled: @Sendable () -> Void
        private let timeoutSnapshotInstalledObserver:
            (@Sendable (ProcessTreeSnapshot) -> Void)?
        private var requested = false
        private var timeoutRequested = false
        private var cancelEscalationRequested = false
        private var activeTerminationTree: ProcessTreeSnapshot?
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private let cancelEscalationSignal = DispatchSemaphore(value: 0)

        init(
            process: Process,
            onSettled: @escaping @Sendable () -> Void,
            timeoutSnapshotInstalledObserver:
                (@Sendable (ProcessTreeSnapshot) -> Void)?
        ) {
            self.process = process
            self.onSettled = onSettled
            self.timeoutSnapshotInstalledObserver = timeoutSnapshotInstalledObserver
        }

        func request(timedOut: Bool) {
            lock.lock()
            if requested {
                // A deadline may already own the graceful TERM window when the
                // parent Task is explicitly cancelled. Cancellation is the
                // stronger motor instruction: wake the existing termination
                // worker so it freezes, rescans, and KILLs the identity-bound
                // tree immediately instead of allowing side effects to continue
                // through the rest of the grace period. The original worker
                // remains the only owner of waitUntilExit/finish.
                let shouldEscalate = !timedOut
                    && timeoutRequested
                    && !finished
                    && !cancelEscalationRequested
                let escalationTree = shouldEscalate ? activeTerminationTree : nil
                if shouldEscalate {
                    cancelEscalationRequested = true
                }
                lock.unlock()
                if shouldEscalate {
                    cancelEscalationSignal.signal()
                    if let escalationTree {
                        // Do the motor stop on the cancellation caller that is
                        // already running. Merely waking the timeout worker can
                        // leave it CPU-starved under machine load. This path
                        // performs signals only; the original worker remains
                        // the sole owner of waitUntilExit and finish/resume.
                        let refreshed = ProcessTreeReaper.snapshot(
                            rootPID: escalationTree.rootPID,
                            retaining: escalationTree
                        )
                        _ = ProcessTreeReaper.quiesceAndKill(refreshed)
                    }
                }
                return
            }
            requested = true
            timeoutRequested = timedOut
            let pid = process.processIdentifier
            let running = process.isRunning
            lock.unlock()
            guard running, pid > 0 else {
                finish()
                return
            }

            // Snapshot descendants before signaling the shell. Once the root
            // exits, a surviving grandchild may be reparented and disappear
            // from a later parent-only traversal.
            let terminationTree = ProcessTreeReaper.snapshot(rootPID: pid)
            lock.lock()
            activeTerminationTree = terminationTree
            let cancellationAlreadyEscalated = cancelEscalationRequested
            lock.unlock()
            if timedOut {
                timeoutSnapshotInstalledObserver?(terminationTree)
            }
            if cancellationAlreadyEscalated {
                let refreshed = ProcessTreeReaper.snapshot(
                    rootPID: terminationTree.rootPID,
                    retaining: terminationTree
                )
                _ = ProcessTreeReaper.quiesceAndKill(refreshed)
            }
            let worker = Thread { [self, process] in
                // User cancellation is not a graceful-shutdown request: it is
                // an instruction that no descendant may continue producing
                // side effects. Freeze the tree before the kill/rescan so a
                // shell cannot fork a job-control child between enumeration
                // and its own death. Timeout retains the cooperative TERM window.
                if !timedOut {
                    let frozenTree = ProcessTreeReaper.quiesceAndKill(terminationTree)
                    if process.isRunning { process.waitUntilExit() }
                    let settledTree = ProcessTreeReaper.snapshot(
                        rootPID: pid,
                        retaining: frozenTree
                    )
                    if ProcessTreeReaper.hasLiveDescendant(in: settledTree) {
                        ProcessTreeReaper.signal(settledTree, signal: SIGKILL)
                    }
                    finish()
                    return
                }
                ProcessTreeReaper.signal(terminationTree, signal: SIGTERM)

                // Preserve the established two-second graceful shutdown
                // budget, but finish immediately once the identity-bound tree
                // and direct Process have actually settled.
                let deadline = DispatchTime.now() + .seconds(2)
                while DispatchTime.now() < deadline {
                    let refreshed = ProcessTreeReaper.snapshot(
                        rootPID: pid,
                        retaining: terminationTree
                    )
                    if !process.isRunning
                        && !ProcessTreeReaper.hasLiveDescendant(in: refreshed) {
                        break
                    }
                    if cancellationEscalationWasRequested() {
                        // Rescan from the original identity-bound snapshot
                        // before freezing/KILLing. This retains descendants that
                        // were reparented after the root received SIGTERM while
                        // still refusing PID-reuse matches.
                        let escalationTree = ProcessTreeReaper.snapshot(
                            rootPID: pid,
                            retaining: terminationTree
                        )
                        _ = ProcessTreeReaper.quiesceAndKill(escalationTree)
                        if process.isRunning { process.waitUntilExit() }
                        finish()
                        return
                    }
                    _ = cancelEscalationSignal.wait(timeout: .now() + .milliseconds(5))
                }

                let killTree = ProcessTreeReaper.snapshot(
                    rootPID: pid,
                    retaining: terminationTree
                )
                if process.isRunning || ProcessTreeReaper.hasLiveDescendant(in: killTree) {
                    _ = ProcessTreeReaper.quiesceAndKill(killTree)
                }
                if process.isRunning { process.waitUntilExit() }
                finish()
            }
            worker.qualityOfService = .userInitiated
            worker.start()
        }

        private func cancellationEscalationWasRequested() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelEscalationRequested
        }

        func waitIfRequested() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !requested || finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }

        private func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            activeTerminationTree = nil
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
            onSettled()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timeoutRequested
        }
    }

    /// Native deadline waiter for process timeouts. It is independent of the
    /// cooperative Swift executor (which can be saturated during the full Core
    /// suite) and is wakeable, so normal completion/cancellation leaves no
    /// sleeping timeout thread behind.
    private final class _ProcessDeadline: @unchecked Sendable {
        private let lock = NSLock()
        private let wake = DispatchSemaphore(value: 0)
        private var cancelled = false
        private var worker: Thread?

        func start(seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
            let boundedMilliseconds = max(1, Int((max(0.001, seconds) * 1_000).rounded(.up)))
            let thread = Thread { [weak self] in
                guard let self else { return }
                let result = wake.wait(timeout: .now() + .milliseconds(boundedMilliseconds))
                lock.lock()
                let shouldFire = result == .timedOut && !cancelled
                lock.unlock()
                if shouldFire { action() }
            }
            thread.qualityOfService = .userInitiated
            lock.lock()
            worker = thread
            lock.unlock()
            thread.start()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            worker = nil
            lock.unlock()
            wake.signal()
        }
    }

    public func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessRunResult {
        try await run(
            executable: executable,
            arguments: arguments,
            currentDirectory: nil,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: TimeInterval(timeoutSeconds),
            outputByteLimit: nil
        )
    }

    /// Shared event-driven subprocess seam for app and core callers that need
    /// a working directory, an exact environment, or stdin. This remains the
    /// same lifecycle owner as the `ProcessAdapter` entry point above: pipe
    /// draining, cancellation, timeout escalation, and process-tree reaping
    /// must not be reimplemented by each feature.
    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        standardInput: Data?,
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int? = nil
    ) async throws -> ProcessRunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = currentDirectory
        proc.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inputPipe = standardInput.map { _ in Pipe() }
        proc.standardInput = inputPipe ?? FileHandle.nullDevice

        let outBuf = _Buffer(byteLimit: outputByteLimit)
        let errBuf = _Buffer(byteLimit: outputByteLimit)
        // Drain pipes concurrently with waitUntilExit so subprocesses
        // producing > 64KB of output don't deadlock on a full pipe buffer.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            outBuf.append(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            errBuf.append(chunk)
        }

        let completion = _ProcessCompletion()
        proc.terminationHandler = { _ in completion.finish() }
        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw MacControlError.ioFailure("Process.run() failed: \(error)")
        }
        if let inputPipe, let standardInput {
            // A helper may accept a payload larger than the pipe buffer. Feed
            // it off-thread so the event-driven termination path remains able
            // to enforce its deadline if the child stops reading.
            let handle = inputPipe.fileHandleForWriting
            let writer = Thread {
                try? handle.write(contentsOf: standardInput)
                try? handle.close()
            }
            writer.qualityOfService = .utility
            writer.start()
        }
        ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(proc.processIdentifier)
        let termination = _ProcessTermination(
            process: proc,
            onSettled: { completion.finish() },
            timeoutSnapshotInstalledObserver: timeoutSnapshotInstalledObserver
        )
        let deadline = _ProcessDeadline()
        deadline.start(seconds: timeoutSeconds) {
            termination.request(timedOut: true)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.wait(continuation)
            }
        } onCancel: {
            deadline.cancel()
            termination.request(timedOut: false)
        }
        // Timeout/cancellation settles the captured process tree before the
        // adapter reports completion; direct-shell exit alone is insufficient.
        await termination.waitIfRequested()
        deadline.cancel()
        proc.terminationHandler = nil

        // Tear down readers, then drain anything still sitting in the pipe.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        outBuf.append(tailOut)
        errBuf.append(tailErr)
        let outData = outBuf.snapshot()
        let errData = errBuf.snapshot()
        if Task.isCancelled {
            throw CancellationError()
        }
        return ProcessRunResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            timedOut: termination.didTimeOut,
            stdoutTruncated: outBuf.truncated,
            stderrTruncated: errBuf.truncated
        )
    }

}

public final class SystemAppControlAdapter: AppControlAdapter, AppStateVerificationAdapter {
    public init() {}

    public func focusApp(named name: String) async throws -> AppControlRunResult {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { throw MacControlError.missingField("app") }
        #if canImport(AppKit)
        return try await Self.focusAppOnMain(named: query)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    public func quitApp(named name: String) async throws -> AppControlRunResult {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { throw MacControlError.missingField("app") }
        #if canImport(AppKit)
        return try await Self.quitAppOnMain(named: query)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    public func isFrontmostApplication(matching name: String) async -> Bool {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { return false }
        #if canImport(AppKit)
        return await Self.isFrontmostApplicationOnMain(matching: query)
        #else
        return false
        #endif
    }

    public func isApplicationRunning(matching name: String) async -> Bool {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { return false }
        #if canImport(AppKit)
        return await Self.isApplicationRunningOnMain(matching: query)
        #else
        return false
        #endif
    }

    private func normalizedAppQuery(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(AppKit)
    @MainActor
    private static func isFrontmostApplicationOnMain(matching query: String) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return application(frontmost, matches: query)
    }

    @MainActor
    private static func isApplicationRunningOnMain(matching query: String) -> Bool {
        !runningApplications(matching: query).isEmpty
    }

    private static func application(_ app: NSRunningApplication, matches query: String) -> Bool {
        let name = app.localizedName ?? ""
        let bundle = app.bundleIdentifier ?? ""
        return name.caseInsensitiveCompare(query) == .orderedSame
            || bundle.caseInsensitiveCompare(query) == .orderedSame
    }

    @MainActor
    private static func focusAppOnMain(named query: String) async throws -> AppControlRunResult {
        if let running = runningApp(matching: query) {
            let activated = running.activate(options: [.activateAllWindows])
            return runResult(
                requested: query,
                app: running,
                launched: false,
                activated: activated,
                terminated: false
            )
        }
        guard let url = applicationURL(matching: query) else {
            throw MacControlError.appControlFailed("app_not_found: \(query)")
        }
        let launched = try await openApplication(at: url)
        let activated = launched.activate(options: [.activateAllWindows])
        return runResult(
            requested: query,
            app: launched,
            fallbackURL: url,
            launched: true,
            activated: activated,
            terminated: false
        )
    }

    @MainActor
    private static func quitAppOnMain(named query: String) async throws -> AppControlRunResult {
        let running = runningApplications(matching: query)
        guard !running.isEmpty else {
            if let url = applicationURL(matching: query) {
                return AppControlRunResult(
                    requestedName: query,
                    matchedName: url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
                    processIdentifier: nil,
                    launched: false,
                    activated: false,
                    terminated: false,
                    alreadyInDesiredState: true
                )
            }
            throw MacControlError.appControlFailed("app_not_running_or_not_found: \(query)")
        }
        let first = running[0]
        let terminated = running.map { $0.terminate() }.contains(true)
        return runResult(
            requested: query,
            app: first,
            launched: false,
            activated: false,
            terminated: terminated
        )
    }

    @MainActor
    private static func openApplication(at url: URL) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error {
                    continuation.resume(throwing: MacControlError.appControlFailed(error.localizedDescription))
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: MacControlError.appControlFailed("launch returned no application for \(url.path)"))
                }
            }
        }
    }

    @MainActor
    private static func runningApp(matching query: String) -> NSRunningApplication? {
        runningApplications(matching: query).first
    }

    @MainActor
    private static func runningApplications(matching query: String) -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications
        let lower = query.lowercased()
        if looksLikeBundleIdentifier(query) {
            let exactBundle = running.filter { ($0.bundleIdentifier ?? "").caseInsensitiveCompare(query) == .orderedSame }
            if !exactBundle.isEmpty { return exactBundle }
        }
        let exactName = running.filter { ($0.localizedName ?? "").caseInsensitiveCompare(query) == .orderedSame }
        if !exactName.isEmpty { return exactName }
        let exactBundle = running.filter { ($0.bundleIdentifier ?? "").caseInsensitiveCompare(query) == .orderedSame }
        if !exactBundle.isEmpty { return exactBundle }
        return running.filter { app in
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            return name.contains(lower) || bundle.contains(lower)
        }
    }

    @MainActor
    private static func applicationURL(matching query: String) -> URL? {
        let expandedQuery = (query as NSString).expandingTildeInPath
        if expandedQuery.hasPrefix("/"), expandedQuery.hasSuffix(".app") {
            let url = URL(fileURLWithPath: expandedQuery)
            if isApplicationBundle(url) { return url }
        }
        if looksLikeBundleIdentifier(query),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            return url
        }
        let fm = FileManager.default
        let appName = query.hasSuffix(".app") ? query : "\(query).app"
        let candidateDirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        for dir in candidateDirs {
            let url = dir.appendingPathComponent(appName)
            if isApplicationBundle(url) { return url }
        }
        return nil
    }

    private static func looksLikeBundleIdentifier(_ query: String) -> Bool {
        query.contains(".") && !query.contains("/") && !query.contains(" ")
    }

    private static func isApplicationBundle(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && FileManager.default.fileExists(atPath: url.path)
    }

    @MainActor
    private static func runResult(
        requested: String,
        app: NSRunningApplication,
        fallbackURL: URL? = nil,
        launched: Bool,
        activated: Bool,
        terminated: Bool
    ) -> AppControlRunResult {
        let name = app.localizedName ?? fallbackURL?.deletingPathExtension().lastPathComponent
        let bundleIdentifier = app.bundleIdentifier ?? fallbackURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        return AppControlRunResult(
            requestedName: requested,
            matchedName: name,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: app.processIdentifier,
            launched: launched,
            activated: activated,
            terminated: terminated
        )
    }
    #endif
}

public final class SystemFileManagerAdapter: FileManagerAdapter, FileStateVerificationAdapter {
    public init() {}
    // FileManager.default is NOT Sendable as of Swift 6 — fetch per-call
    // instead of storing on the actor/adapter. Per Apple's own audit it's
    // thread-safe for these operations even though the type lacks
    // the Sendable bill of health.
    public func readData(at url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return handle.readData(ofLength: maxBytes)
    }
    public func writeData(_ data: Data, to url: URL, append: Bool) throws {
        let fm = FileManager.default
        if append, fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            let parent = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try data.write(to: url)
        }
    }
    public func listDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }
    public func moveItem(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let parent = dst.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try fm.moveItem(at: src, to: dst)
    }
    public func trashItem(at url: URL) throws {
        var resulting: NSURL? = nil
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }
    public func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
