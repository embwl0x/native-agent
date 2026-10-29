import Darwin
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import Transcripts
import TurnTrace
// Blueprint: | `AppRestartCoordinator.swift` | Shared detached native relauncher observes parent exit before opening; tool restart audit/cooldown, originating-turn settlement with a 60-second stalled-turn bound and 120-second exit deadline; operator menu/restore 60-second deadline covering the whole quit (turn wait, their sleep, termination drain); stalled quit aborts relaunch |

// MARK: - AppRelaunch (restart_app / Telegram /restart core)
// JSON restart receipts and cooldown stamp: local operational state, excluded
// from backup/export/phone sync; PrivacyMap: restart_audit.
//
// Swift app restart support for Telegram /restart and the restart_app tool.
// The Swift app is an SMAppService login item — quitting does NOT respawn it —
// so the restart sequence needs a DETACHED relauncher process that outlives
// the app: it observes our exit within a deadline, then `open`s the app
// bundle again.
//
// ONE core routine for every surface (chat tool `restart_app`, Telegram
// /restart via its deferred restart operation): cooldown guard, audit
// envelope, stamp, relauncher spawn, and settlement-triggered termination live
// here exactly once. Surfaces apply their origin and approval gates before
// calling this coordinator; Telegram /restart also checks its owner allowlist.
//
// Sequencing contract that keeps the turn intact:
//   cooldown check → audit write → stamp write → relauncher spawn →
//   success envelope → originating turn settles → terminate.
// A stalled originating turn has a bounded, explicitly unfinished exit.
//
// Production chat files an inline approval card when restart_app requires
// confirmation. The person approves the card to replay the guarded restart;
// no manual trust-policy edit is needed.
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

    /// Tool-initiated restarts inside this window refuse with an honest
    /// cooldown envelope — a model stuck in a "restart fixes it" loop must
    /// not be able to bounce the app every turn.
    public static let cooldownSeconds: TimeInterval = 600
    /// Retained for existing install-delay clients; restart waits for settlement.
    public static let terminateGraceSeconds: TimeInterval = 20
    /// A refused or stalled quit must not leave a surviving helper forever.
    public static let relaunchExitDeadlineSeconds = 120
    /// The menu/restore relauncher's deadline covers the WHOLE quit, so the
    /// helper never expires before the app exits: the quit hold's turn wait
    /// (20 s, `NativeAgentEngine.waitForInFlightTurnsBeforeQuit`) + her sleep
    /// bound (30 s, `NativeAgentEngine.sleepBound`) + the termination drain's
    /// wait (3 s) + 7 s of margin for AppKit and process exit.
    public static let operatorRelaunchExitDeadlineSeconds = 60
    /// Reserve the operator's whole-quit budget within the relauncher's bound.
    public static let stalledTurnSeconds = TimeInterval(relaunchExitDeadlineSeconds - operatorRelaunchExitDeadlineSeconds)
    /// Process-wide instance used by the chat dispatch case and the app
    /// layer Telegram bridge. The app layer MUST `configure(...)` it at
    /// launch with the real terminate and relauncher closures (platform
    /// operations live above this module); until then requestRestart refuses
    /// honestly.
    public static let shared = AppRelaunch()

    // MARK: App wiring

    /// App-bound port that spawns the detached relauncher argv. The app uses
    /// posix_spawn with POSIX_SPAWN_SETSID (own session — survives the
    /// app/launchd job teardown) and stdio on /dev/null.
    private var spawnRelauncher: (@Sendable (_ argv: [String]) throws -> Void)?
    /// Schedules app termination after `grace` seconds. Injected from the
    /// app layer (DispatchQueue.main.asyncAfter → NSApp.terminate) because
    /// this module must not import AppKit. nil = unconfigured → refuse.
    private var scheduleTerminate: (@Sendable (_ graceSeconds: TimeInterval) -> Void)?
    private let dataRoot = PersistenceCore.defaultDataRoot()
    private let currentPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    /// App-layer wiring point: inject the real terminate scheduler and
    /// relauncher spawn. Called once from applicationDidFinishLaunching.
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

    /// The same executable runs only the exit observer, before any app state
    /// or UI is initialized. It survives the parent and aborts on a stalled quit.
    public static func relauncherArgv(pid: Int32, appPath: String) -> [String] {
        exitObserverArgv(pid: pid, appPath: appPath, seconds: relaunchExitDeadlineSeconds)
    }

    private nonisolated static func exitObserverArgv(pid: Int32, appPath: String, seconds: Int) -> [String] {
        [Bundle.main.executablePath ?? appPath + "/Contents/MacOS/NativeAgentApp",
         "--nativeagent-relaunch-after-exit", String(pid), appPath, String(seconds)]
    }

    /// Called at the executable entry point, before single-instance admission.
    /// kqueue registration precedes the parent read, closing the exit race.
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
        // A detached child is adopted when its original parent exits. Never
        // wait on a reused PID; registration errors while it lives abort.
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

    /// Resolve the bundle to relaunch. In a real .app launch Bundle.main IS
    /// the bundle; under `swift run`/tests it's not, so fall back to the
    /// canonical install path (script/install_app.sh → ~/Applications).
    public static func appBundlePath() -> String {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { return bundle.path }
        return NSString(string: "~/Applications/NativeAgent.app").expandingTildeInPath
    }

    // MARK: Core routine

    /// The single restart entry point for every surface.
    /// Returns a JSON envelope; never throws (failures are honest envelopes,
    /// mirroring the builder-tool convention). On a "restarting" envelope the
    /// settlement-triggered termination is armed before this returns. Surfaces that
    /// must flush a reply over a transport FIRST (Telegram /restart) use
    /// `requestRestartDeferringTerminate` and arm after the send.
    public func requestRestart(reason: String, source: String) async -> JSONValue {
        let (envelope, armTerminate) = await requestRestartDeferringTerminate(
            reason: reason, source: source
        )
        armTerminate?()
        return envelope
    }

    /// Two-phase variant: runs the FULL guarded routine (cooldown → audit →
    /// stamp → relauncher spawn) but does NOT arm termination. When the
    /// envelope status is "restarting", the returned closure schedules the
    /// settlement wait; the caller invokes it AFTER handing the reply
    /// to the transport. The restart is already COMMITTED (stamp written,
    /// relauncher spawned) once the
    /// closure exists, so the caller MUST invoke it even if the reply send
    /// fails — otherwise the relauncher waits against a live app while
    /// the cooldown stamp claims a restart happened.
    public func requestRestartDeferringTerminate(
        reason: String, source: String
    ) async -> (envelope: JSONValue, armTerminate: (@Sendable () -> Void)?) {
        guard !Task.isCancelled else { return (await Self.stopped(), nil) }
        // Fail closed when the app layer hasn't injected both hooks: spawning
        // a relauncher without being able to exit would just no-op `open`
        // against a live app while claiming "restarting".
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

        // Snapshot actor state into lets — withFileLock's body is @Sendable
        // and must not touch actor-isolated members.
        let auditDir = self.auditDir
        let stampURL = self.stampURL
        let spawn = spawnRelauncher
        let pid = self.currentPID
        let cooldown = Self.cooldownSeconds
        let grace = Self.stalledTurnSeconds
        let originRun = ChatPersistenceContext.pinnedTurnRunID
            ?? TurnTraceContext.turnId.flatMap { turn in
                ChatCancelFlag.inFlightTurns(dataRoot: dataRoot).first { $0.turnId == turn }?.runId
            }

        // Everything from cooldown-read to stamp-write runs under flock so
        // two concurrent restart requests (chat + Telegram) serialize: the
        // second sees the first's stamp and refuses with `cooldown`.
        let result: JSONValue
        do {
            result = try await SwiftNativePersistenceCore.withFileLock(stampURL) {
                guard !Task.isCancelled else { return await Self.stopped() }
                // Read the clock under the lock so elapsed time includes any wait for a prior restart.
                let requestedAt = Date()

                // 1. Cooldown guard — refuse honestly inside the window. A
                //    stamp in the FUTURE (cross-process race remnant, clock
                //    skew) counts as cooling-down: negative elapsed refuses.
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
                            ? "The last restart stamp (\(NativeTimestampFormat.plainZulu(last))) is in the future relative to now — cross-process race or clock skew. Treating as cooling-down; refusing to restart."
                            : "A tool-initiated restart fired \(Int(elapsed))s ago; refusing to restart again within \(Int(cooldown))s."
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

                // 2. Audit envelope FIRST. Restart is fail-closed on audit
                //    (unlike fail-soft builder audits): no receipt → no
                //    restart, because an unauditable app bounce is exactly
                //    the loop this guard exists to make visible.
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
                // 3. Cooldown stamp — written only after the audit landed,
                //    immediately before the restart actually fires.
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
                        instruction: "Repair the restart stamp's reported storage error without inventing a restart time. The audit was saved; no restart was scheduled.")
                    fields["audit_path"] = .string(auditURL.path)
                    return .object(fields)
                }

                guard !Task.isCancelled else {
                    return await Self.stopped(auditURL: auditURL, stampURL: stampURL)
                }
                // 4. Spawn the detached relauncher. An unsuccessful attempt
                //    keeps its evidence but does not assert a fired restart.
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

                // 5. Success envelope. Termination is armed by the CALLER
                //    (via the returned closure) AFTER the reply is on its
                //    way to the surface, then waits for its turn's settlement.
                return .object([
                    "status": .string("restarting"),
                    "tool": .string("restart_app"),
                    "note": .string("Restarting after this turn settles. If it stalls for \(Int(grace))s, the app exits with an explicit unfinished outcome. A detached relauncher reopens \(appPath) after process exit; it aborts after \(Self.relaunchExitDeadlineSeconds)s."),
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

        // 6. Only a real "restarting" envelope earns an arm-terminate
        //    closure; refusals never schedule termination.
        if case .object(let obj) = result,
           case .string("restarting")? = obj["status"] {
            return (result, {
                Task.detached {
                    if let originRun {
                        let changes = RestartTurnChanges()
                        defer { changes.cancel() }
                        do {
                            try await BoundedWait.run(seconds: grace, reason: "restart originating turn \(originRun) settlement") {
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
            // lstat observes the stamp entry itself, including a dangling symlink.
            // Only confirmed absence bootstraps; preserve every other read failure.
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
    /// The operator's menu/restore restart aborts if quitting exceeds
    /// `operatorRelaunchExitDeadlineSeconds`.
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

    /// Production relauncher spawn: posix_spawn with POSIX_SPAWN_SETSID so
    /// the helper becomes its own session leader — it must survive launchd
    /// tearing down the app's process group when the login item exits —
    /// with stdio redirected to /dev/null (nohup-equivalent, no SIGHUP /
    /// no pipe to a dead parent).
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
        // POSIX_SPAWN_SETSID (Darwin) — child starts in a NEW session,
        // detached from our session/process group and any controlling tty.
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
        // If quit is refused, we remain the parent when the helper aborts.
        // Observe and reap that exit rather than leaving a zombie until the
        // next app shutdown. Registration precedes the race-closing read.
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
