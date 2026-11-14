import Darwin
import ChatToolParsing
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import Transcripts
import TurnTrace
// Blueprint: | `AppRestartCoordinator.swift` | Wait for exit before relaunch; bound stalled settlement and quit. |

// MARK: - AppRelaunch (restart_app / Telegram /restart core)
// Restart receipts and cooldown stamps are local operational state, excluded from backup/export/phone sync; PrivacyMap: restart_audit. Login items do not
// respawn on quit, so a detached helper must survive exit to reopen the bundle. All surfaces share cooldown → audit → stamp → relauncher → reply →
// originating-turn settlement → termination; stalled settlement exits explicitly unfinished. Callers own origin and approval gates, including the remote
// owner allowlist.
private final class RestartTurnChanges: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let token: NSObjectProtocol

    init() {
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = events.stream
        token = NotificationCenter.default.addObserver(forName: ChatCancelFlag.inFlightDidChange, object: nil, queue: nil) { _ in
            events.continuation.yield(())
        }
    }

    func cancel() { NotificationCenter.default.removeObserver(token) }
}

public actor AppRelaunch {
    // MARK: Constants

    /// The cooldown prevents a model from restarting the app on every turn.
    public static let cooldownSeconds: TimeInterval = 600
    public static let terminateGraceSeconds: TimeInterval = 20
    /// A refused or stalled quit must not leave a surviving helper forever.
    public static let relaunchExitDeadlineSeconds = 120
    /// The whole-quit deadline includes the turn wait (20 s), sleep (30 s), termination drain (3 s) and 7 s for AppKit and process exit.
    public static let operatorRelaunchExitDeadlineSeconds = 60
    /// Reserve the operator's whole-quit budget within the relauncher's bound.
    public static let stalledTurnSeconds = TimeInterval(relaunchExitDeadlineSeconds - operatorRelaunchExitDeadlineSeconds)
    /// Platform hooks live above this module; refuse restarts until app launch configures both hooks.
    public static let shared = AppRelaunch()

    // MARK: App wiring

    /// A new process session survives app/launchd teardown; /dev/null stdio avoids dead-parent pipes.
    private var spawnRelauncher: (@Sendable (_ argv: [String]) throws -> Void)?
    /// App-layer termination injection keeps AppKit outside this module; missing wiring refuses restart.
    private var scheduleTerminate: (@Sendable (_ graceSeconds: TimeInterval) -> Void)?
    private let dataRoot = PersistenceCore.defaultDataRoot()
    private let currentPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    public func configure(
        scheduleTerminate: @escaping @Sendable (_ graceSeconds: TimeInterval) -> Void,
        spawnRelauncher: @escaping @Sendable (_ argv: [String]) throws -> Void
    ) {
        self.scheduleTerminate = scheduleTerminate
        self.spawnRelauncher = spawnRelauncher
    }

    // MARK: Paths

    private var auditDir: URL {
        dataRoot.appendingPathComponent("restart_audit", isDirectory: true)
    }
    private var stampURL: URL {
        auditDir.appendingPathComponent("last_restart.json")
    }

    // MARK: Relauncher command

    /// Run the exit observer before app state or UI startup so the helper remains detached from the app lifecycle.
    public static func relauncherArgv(pid: Int32, appPath: String) -> [String] {
        exitObserverArgv(pid: pid, appPath: appPath, seconds: relaunchExitDeadlineSeconds)
    }

    private nonisolated static func exitObserverArgv(pid: Int32, appPath: String, seconds: Int) -> [String] {
        [Bundle.main.executablePath ?? appPath + "/Contents/MacOS/NativeAgentApp",
         "--nativeagent-relaunch-after-exit", String(pid), appPath, String(seconds)]
    }

    /// Called at the executable entry point, before single-instance admission. kqueue registration precedes the parent read, closing the exit race.
    public nonisolated static func runRelaunchHelperIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--nativeagent-relaunch-after-exit" else { return false }
        guard args.count == 5, let pid = Int32(args[2]), pid > 1,
              let seconds = Int(args[4]), seconds > 0, seconds <= relaunchExitDeadlineSeconds else { return true }
        let queue = kqueue()
        guard queue >= 0 else { return true }
        defer { close(queue) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC),
                            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        let registered = kevent(queue, &change, 1, nil, 0, nil)
        // A detached child is adopted when its original parent exits. Never wait on a reused PID; registration errors while it lives abort.
        if getppid() == pid {
            guard registered == 0 else { return true }
            var event = kevent()
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return true }
                let remaining = deadline - now
                var timeout = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
                let count = kevent(queue, nil, 0, &event, 1, &timeout)
                if count < 0 && errno == EINTR { continue }
                guard count == 1, event.flags & UInt16(EV_ERROR) == 0,
                      event.fflags & UInt32(NOTE_EXIT) != 0 else { return true }
                break
            }
        }
        let path = strdup(args[3])
        defer { free(path) }
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/open"), path, nil]
        defer { free(argv[0]) }
        execv("/usr/bin/open", &argv)
        return true
    }

    public static func appBundlePath() -> String {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { return bundle.path }
        return NSString(string: "~/Applications/NativeAgent.app").expandingTildeInPath
    }

    // MARK: Core routine

    /// Arm settlement-triggered termination before returning success; transports needing to flush first use the deferred entry point.
    public func requestRestart(turn: Turn?, reason: String, source: String) async -> JSONValue {
        let (envelope, armTerminate) = await requestRestartDeferringTerminate(turn: turn,
            reason: reason, source: source
        )
        armTerminate?()
        return envelope
    }

    /// The caller must invoke the returned termination closure after its send attempt, even if sending fails: the stamp and relauncher are already committed.
    public func requestRestartDeferringTerminate(turn: Turn?,
        reason: String, source: String
    ) async -> (envelope: JSONValue, armTerminate: (@Sendable () -> Void)?) {
        guard !Task.isCancelled else { return (await Self.stopped(), nil) }
        // Require both platform hooks before spawning: opening an app that cannot exit would falsely claim a restart.
        guard let scheduleTerminate, let spawnRelauncher else {
            let missing = [
                self.scheduleTerminate == nil ? "scheduleTerminate" : nil,
                self.spawnRelauncher == nil ? "spawnRelauncher" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            return (.object([
                "status": .string("failed"),
                "tool": .string("restart_app"),
                "reason": .string("restart_unavailable"),
                "detail": .string("Restart wiring is missing: \(missing)."),
                "effects": .string("none"),
                "remedy": Repair.why(owner: "NativeAgent", tap: "Quit NativeAgent and open it again",
                    instruction: "This process cannot restart itself (no app-launch restart hooks). Ask the person to quit and reopen NativeAgent."),
            ]), nil)
        }

        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveReason = trimmedReason.isEmpty ? "unspecified" : trimmedReason
        let runId = UUID().uuidString
        let appPath = Self.appBundlePath()
        let argv = Self.relauncherArgv(pid: currentPID, appPath: appPath)

        // Snapshot actor state into lets — withFileLock's body is @Sendable and must not touch actor-isolated members.
        let auditDir = self.auditDir
        let stampURL = self.stampURL
        let spawn = spawnRelauncher
        let pid = self.currentPID
        let cooldown = Self.cooldownSeconds
        let grace = Self.stalledTurnSeconds
        let originRun = turn?.run

        // Lock cooldown-read through stamp-write so concurrent requests cannot both restart the app.
        let result: JSONValue
        do {
            result = try await SwiftNativePersistenceCore.withFileLock(stampURL) {
                guard !Task.isCancelled else { return await Self.stopped() }
                // Read the clock under the lock so elapsed time includes any wait for a prior restart.
                let requestedAt = Date()

                // Future stamps still cool down: clock skew must not permit repeated restarts.
                let lastRestartAt: Date?
                do {
                    lastRestartAt = try Self.readStampDate(stampURL)
                } catch {
                    return .object(SwiftToolDispatcher.builderFailureFields(error,
                        tool: "restart_app", reason: "stamp_read_failed", effects: .none,
                        owner: stampURL.path,
                        instruction: "Preserve the restart stamp and repair its reported storage or firedAt error. No restart was scheduled."))
                }
                if let last = lastRestartAt {
                    let elapsed = requestedAt.timeIntervalSince(last)
                    if elapsed < cooldown {
                        let detail = elapsed < 0
                            ? """
                                The last restart stamp (\(NativeTimestampFormat.plainZulu(last))) is in the future relative to now — cross-process \
                                race or clock skew. Treating as cooling-down; refusing to restart.
                                """
                            : "A restart called through app fired \(Int(elapsed))s ago; refusing to restart again within \(Int(cooldown))s."
                        return .object([
                            "status": .string("failed"),
                            "tool": .string("restart_app"),
                            "reason": .string("cooldown"),
                            "retryAfterSeconds": .double(Double((cooldown - elapsed).rounded(.up))),
                            "lastRestartAt": .string(NativeTimestampFormat.plainZulu(last)),
                            "detail": .string(detail),
                        ])
                    }
                }

                guard !Task.isCancelled else { return await Self.stopped() }

                // Persist the audit before committing a restart so repeated app bounces remain diagnosable.
                let auditURL = auditDir.appendingPathComponent("\(runId).json")
                var auditEntry: [String: Any] = [
                    "toolName": "restart_app",
                    "runId": runId,
                    "requestedAt": NativeTimestampFormat.plainZulu(requestedAt),
                    "reason": effectiveReason,
                    "source": source,
                    "pid": Int(pid),
                    "appPath": appPath,
                    "relauncherArgv": argv,
                    "stalledTurnSeconds": grace,
                    "cooldownSeconds": cooldown,
                ]
                // Omit missing values instead of placing Swift Optionals in JSONSerialization dictionaries.
                if let last = lastRestartAt {
                    auditEntry["lastRestartAt"] = NativeTimestampFormat.plainZulu(last)
                }
                do {
                    try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
                    let data = try JSONSerialization.data(withJSONObject: auditEntry, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: auditURL)
                } catch {
                    return .object(SwiftToolDispatcher.builderFailureFields(error,
                        tool: "restart_app", reason: "audit_write_failed", effects: .unknown,
                        owner: auditURL.path,
                        instruction: "Repair the restart receipt's reported storage error; preserve any partial receipt. No restart was scheduled."))
                }

                guard !Task.isCancelled else { return await Self.stopped(auditURL: auditURL) }
                // Publish the cooldown only after its audit is durable and immediately before committing the restart.
                let stampEntry: [String: Any] = [
                    "firedAt": NativeTimestampFormat.plainZulu(requestedAt),
                    "runId": runId,
                    "reason": effectiveReason,
                    "source": source,
                ]
                do {
                    let data = try JSONSerialization.data(withJSONObject: stampEntry, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: stampURL)
                } catch {
                    var fields = SwiftToolDispatcher.builderFailureFields(error,
                        tool: "restart_app", reason: "stamp_write_failed", effects: .unknown,
                        owner: stampURL.path,
                        instruction: """
                            Repair the restart stamp's reported storage error without inventing a restart time. The audit was saved; no restart was \
                            scheduled.
                            """)
                    fields["audit_path"] = .string(auditURL.path)
                    return .object(fields)
                }

                guard !Task.isCancelled else {
                    return await Self.stopped(auditURL: auditURL, stampURL: stampURL)
                }
                // A failed spawn retains evidence without claiming a committed restart.
                do {
                    try spawn(argv)
                } catch {
                    let settlement = await Self.recordUnscheduled(
                        outcome: "relauncher_spawn_failed", auditURL: auditURL, stampURL: stampURL)
                    if let settlement { return settlement }
                    var fields = SwiftToolDispatcher.builderFailureFields(error,
                        tool: "restart_app", reason: "relauncher_spawn_failed", effects: .unknown,
                        owner: "restart relauncher at \(argv[0]); stamp at \(stampURL.path)",
                        instruction: "Repair the relauncher's reported launch error. The audit and unscheduled stamp were saved; no termination was scheduled.")
                    fields["audit_path"] = .string(auditURL.path)
                    return .object(fields)
                }

                // The caller arms termination after handing off the reply, preserving originating-turn settlement.
                return .object([
                    "status": .string("restarting"),
                    "tool": .string("restart_app"),
                    "note": .string("""
                        Restarting after this turn settles. If it stalls for \(Int(grace))s, the app exits with an explicit unfinished outcome. A \
                        detached relauncher reopens \(appPath) after process exit; it aborts after \(Self.relaunchExitDeadlineSeconds)s.
                        """),
                    "runId": .string(runId),
                    "reason": .string(effectiveReason),
                    "source": .string(source),
                    "stalledTurnSeconds": .double(grace),
                    "audit_path": .string(auditURL.path),
                ])
            }
        } catch is CancellationError {
            return (await Self.stopped(), nil)
        } catch {
            // flock acquisition failure — refuse, do not restart unguarded.
            return (.object(SwiftToolDispatcher.builderFailureFields(error,
                tool: "restart_app", reason: "lock_failed", effects: .none,
                owner: stampURL.path,
                instruction: "Repair the restart lock's reported storage error; preserve the stamp. No restart was scheduled.")), nil)
        }

        // Refusals must never schedule termination.
        let reply = ToolResult(result)
        if case .object(let obj) = result,
           reply.said("restarting"), reply.status == obj["status"]?.stringValue {
            return (result, {
                Task.detached {
                    if let originRun {
                        let changes = RestartTurnChanges()
                        defer { changes.cancel() }
                        do {
                            try await BoundedWait.run(seconds: grace, reason: "restart originating turn \(originRun) settlement",
                                                       deadlines: OperationDeadlines()) { _ in
                                var iterator = changes.stream.makeAsyncIterator()
                                while ChatCancelFlag.inFlightRunIDs().contains(originRun) {
                                    try Task.checkCancellation()
                                    guard await iterator.next() != nil else { throw CancellationError() }
                                }
                            }
                        } catch {
                            FileHandle.standardError.write(Data("[restart] originating turn \(originRun) did not settle: \(error); exiting unfinished\n".utf8))
                        }
                    }
                    scheduleTerminate(0)
                }
            })
        }
        return (result, nil)
    }

    // MARK: Helpers

    private static func stopped(auditURL: URL? = nil, stampURL: URL? = nil) async -> JSONValue {
        if let failure = await recordUnscheduled(outcome: "stopped", auditURL: auditURL, stampURL: stampURL) {
            return failure
        }
        var fields: [String: JSONValue] = [
            "status": .string("stopped"), "tool": .string("restart_app"),
            "reason": .string("cancelled"), "effects": .string("none"),
            "detail": .string("Stopped before scheduling a restart; any produced audit evidence was saved."),
        ]
        if let auditURL { fields["audit_path"] = .string(auditURL.path) }
        return .object(fields)
    }

    /// Settlement is owed even when Stop arrived after the audit or stamp write.
    private static func recordUnscheduled(outcome: String, auditURL: URL?, stampURL: URL?) async -> JSONValue? {
        await settle {
            for url in [auditURL, stampURL].compactMap({ $0 }) {
                do {
                    guard case .object(var fields) = try JSONValue.parse(Data(contentsOf: url)) else {
                        throw NSError(domain: "AppRestartCoordinator", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Restart evidence at \(url.path) is not an object."])
                    }
                    fields["outcome"] = .string(outcome)
                    fields["restartScheduled"] = .bool(false)
                    try JSONValue.object(fields).serializedData(pretty: true).write(to: url, options: .atomic)
                } catch {
                    var fields = SwiftToolDispatcher.builderFailureFields(error,
                        tool: "restart_app", reason: "restart_settlement_failed", effects: .unknown,
                        owner: url.path,
                        instruction: "Preserve the restart evidence and repair its reported settlement error. No termination was scheduled.")
                    if let auditURL { fields["audit_path"] = .string(auditURL.path) }
                    return .object(fields)
                }
            }
            return nil
        }
    }

    private static func readStampDate(_ url: URL) throws -> Date? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // lstat observes the stamp entry itself, including a dangling symlink. Only confirmed absence bootstraps; preserve every other read failure.
            var info = stat()
            guard lstat(url.path, &info) != 0, errno == ENOENT else { throw error }
            return nil
        }
        guard case .object(let obj) = try JSONValue.parse(data),
              case .string(let fired)? = obj["firedAt"],
              let date = NativeTimestampFormat.parsePlainISO8601(fired) else {
            throw NSError(domain: "AppRestartCoordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Restart stamp at \(url.path) must be an object with a valid ISO-8601 firedAt timestamp."])
        }
        if let scheduled = obj["restartScheduled"] {
            guard case .bool(let scheduled) = scheduled else {
                throw NSError(domain: "AppRestartCoordinator", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Restart stamp at \(url.path) has an invalid restartScheduled field."])
            }
            if !scheduled { return nil }
        }
        return date
    }
}

extension AppRelaunch {
    public nonisolated static func relaunchApp(
        bundlePath: String = Bundle.main.bundlePath,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        terminate: () -> Void,
        onSpawnFailure: (Error) -> Void
    ) {
        do {
            try spawnDetached(argv: exitObserverArgv(pid: pid, appPath: bundlePath,
                                                     seconds: operatorRelaunchExitDeadlineSeconds))
        } catch {
            onSpawnFailure(error)
            return
        }
        terminate()
    }

    /// A separate process session survives launchd teardown; /dev/null prevents SIGHUP and writes to dead-parent pipes.
    @discardableResult
    public nonisolated static func spawnDetached(argv: [String]) throws -> pid_t {
        guard let executable = argv.first, !executable.isEmpty else {
            throw NSError(domain: "AppRestartCoordinator", code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "Detached spawn requires a nonempty executable argument."])
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&fileActions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgs where p != nil { free(p) } }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, executable, &fileActions, &attr, cArgs, environ)
        guard rc == 0 else {
            throw NSError(
                domain: "AppRestartCoordinator",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "posix_spawn(\(executable)) failed: \(String(cString: strerror(rc)))"]
            )
        }
        // Reap the helper if quitting is refused; register observation before reading to close the exit race.
        let spawnedPID = childPID
        let exit = DispatchSource.makeProcessSource(identifier: spawnedPID, eventMask: .exit, queue: .global(qos: .utility))
        exit.setEventHandler {
            var status: Int32 = 0
            while waitpid(spawnedPID, &status, 0) < 0 && errno == EINTR { }
            exit.cancel()
            exit.setEventHandler(handler: nil)
        }
        exit.resume()
        var status: Int32 = 0
        let reaped = waitpid(spawnedPID, &status, WNOHANG)
        if reaped == spawnedPID || (reaped < 0 && errno == ECHILD) {
            exit.cancel()
            exit.setEventHandler(handler: nil)
        }
        return childPID
    }
}
