import Foundation
import Darwin
import PersistenceCore

// MARK: - AppRestartCoordinator (restart_app / Telegram /restart core)
//
// Swift app restart support for Telegram /restart and the restart_app tool.
// The Swift app is an SMAppService login item — quitting does NOT respawn it —
// so the restart sequence needs a DETACHED relauncher process that outlives
// the app: it polls for our PID to exit (up to 30s), then `open`s the app
// bundle again.
//
// ONE core routine for every surface (chat tool `restart_app`, Telegram
// /restart via the injected TelegramRestartRef): cooldown guard, audit
// envelope, stamp, relauncher spawn, and grace-period termination all live
// here exactly once. Surfaces differ only in how they gate the call
// (chat: Full Mac + autonomy `confirm`; Telegram: owner allowlist;
// claude/codex bridge: reachable as of 2026-06-13 but confirm-tier with no
// approval inbox there, so it fails closed without a human).
//
// Sequencing contract that keeps the turn intact:
//   cooldown check → audit write → stamp write → relauncher spawn →
//   success envelope → terminate scheduled after a grace period.
// The grace is what lets the in-flight turn finish persisting and the
// reply reach the surface BEFORE the app dies.
//
// PRODUCTION ENABLEMENT (chat surface): production chat wires NO
// ApprovalFiler, so restart_app's default toolAutonomy `confirm` resolves
// to an honest deny ("approval required, no filer") before this coordinator
// is ever reached. That deny is BY DESIGN — the default stays `confirm`.
// The production path to enable the tool is the user setting
// `toolAutonomy.restart_app = "auto"` in data/trust/policy.json (a
// the user-consented install-time step; code must NEVER write the live policy).
public actor AppRestartCoordinator {
    // MARK: Constants

    /// Tool-initiated restarts inside this window refuse with an honest
    /// cooldown envelope — a model stuck in a "restart fixes it" loop must
    /// not be able to bounce the app every turn.
    public static let cooldownSeconds: TimeInterval = 600
    /// Grace between the success envelope and NSApp.terminate.
    ///
    /// 20s, NOT the daemon-era 5s: on the chat surface the tool RESULT is
    /// not the reply — the tool loop makes ANOTHER LLM call to compose the
    /// final reply after dispatch returns, then persists it
    /// (ChatOrchestrationClient.executeTurn → appendMessage). The grace must
    /// outlive that final reply LLM call + persistence or the app dies
    /// mid-turn and the reply is lost. Turn-completion-TRIGGERED termination
    /// (no fixed timer) is a ledgered follow-up; until then the constant
    /// must stay comfortably above worst-case reply-compose latency.
    public static let terminateGraceSeconds: TimeInterval = 20
    /// How long the detached relauncher polls for our PID to exit before it
    /// `open`s the bundle anyway (covers a wedged-but-terminating app).
    public static let relauncherPollSeconds = 30

    /// Process-wide instance used by the chat dispatch case and the app
    /// layer Telegram bridge. The app layer MUST `configure(...)` it at
    /// launch with the real terminate closure (AppKit lives above this
    /// module); until then requestRestart refuses honestly.
    public static let shared = AppRestartCoordinator()

    // MARK: Injectable seams (tests never spawn or terminate for real)

    /// Spawns the detached relauncher argv. Production default uses
    /// posix_spawn with POSIX_SPAWN_SETSID (own session — survives the
    /// app/launchd job teardown) and stdio on /dev/null.
    private var spawnRelauncher: @Sendable (_ argv: [String]) throws -> Void
    /// Schedules app termination after `grace` seconds. Injected from the
    /// app layer (DispatchQueue.main.asyncAfter → NSApp.terminate) because
    /// this module must not import AppKit. nil = unconfigured → refuse.
    private var scheduleTerminate: (@Sendable (_ graceSeconds: TimeInterval) -> Void)?
    private var now: @Sendable () -> Date
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let currentPID: Int32

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: @escaping @Sendable () -> Date = { Date() },
        spawnRelauncher: (@Sendable (_ argv: [String]) throws -> Void)? = nil,
        scheduleTerminate: (@Sendable (_ graceSeconds: TimeInterval) -> Void)? = nil
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.currentPID = currentPID
        self.now = now
        self.spawnRelauncher = spawnRelauncher ?? Self.spawnDetached(argv:)
        self.scheduleTerminate = scheduleTerminate
    }

    /// App-layer wiring point: inject the real terminate scheduler (and
    /// optionally override the relauncher spawn). Called once from
    /// applicationDidFinishLaunching.
    public func configure(
        scheduleTerminate: @escaping @Sendable (_ graceSeconds: TimeInterval) -> Void,
        spawnRelauncher: (@Sendable (_ argv: [String]) throws -> Void)? = nil,
        now: (@Sendable () -> Date)? = nil
    ) {
        self.scheduleTerminate = scheduleTerminate
        if let spawnRelauncher { self.spawnRelauncher = spawnRelauncher }
        if let now { self.now = now }
    }

    // MARK: Paths

    private var auditDir: URL {
        dataRoot.appendingPathComponent("restart_audit", isDirectory: true)
    }
    private var stampURL: URL {
        auditDir.appendingPathComponent("last_restart.json")
    }

    // MARK: Relauncher command

    /// Pure argv builder so tests can assert the exact command without
    /// spawning. The script polls `kill -0 <pid>` once a second for up to
    /// `relauncherPollSeconds`, then `open`s the bundle — open after the
    /// poll window even if the PID is somehow still alive, because `open`
    /// on a running app is a no-op activate, never a second instance.
    public static func relauncherArgv(pid: Int32, appPath: String) -> [String] {
        // Single-quote the app path for the shell; escape embedded quotes.
        let quoted = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        i=0; while /bin/kill -0 \(pid) 2>/dev/null; do i=$((i+1)); if [ "$i" -ge \(relauncherPollSeconds) ]; then break; fi; /bin/sleep 1; done; exec /usr/bin/open \(quoted)
        """
        return ["/bin/sh", "-c", script]
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
    /// grace-period termination is armed before this returns. Surfaces that
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
    /// grace-period terminate; the caller invokes it AFTER handing the reply
    /// to the transport. The restart is already COMMITTED (stamp written,
    /// relauncher spawned) once the
    /// closure exists, so the caller MUST invoke it even if the reply send
    /// fails — otherwise the relauncher times out against a live app while
    /// the cooldown stamp claims a restart happened.
    public func requestRestartDeferringTerminate(
        reason: String, source: String
    ) async -> (envelope: JSONValue, armTerminate: (@Sendable () -> Void)?) {
        // Fail closed when the app layer hasn't injected terminate: spawning
        // a relauncher without being able to exit would just no-op `open`
        // against a live app 30s later while claiming "restarting".
        guard let scheduleTerminate else {
            return (.object([
                "status": .string("failed"),
                "tool": .string("restart_app"),
                "reason": .string("restart_unavailable"),
                "detail": .string("App-layer terminate hook is not configured in this process (headless/test build?). Restart NativeAgent from the Mac app."),
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
        let spawn = self.spawnRelauncher
        let nowFn = self.now
        let pid = self.currentPID
        let cooldown = Self.cooldownSeconds
        let grace = Self.terminateGraceSeconds

        // Everything from cooldown-read to stamp-write runs under flock so
        // two concurrent restart requests (chat + Telegram) serialize: the
        // second sees the first's stamp and refuses with `cooldown`.
        let result: JSONValue
        do {
            result = try await persistence.withFileLock(stampURL) {
                // Clock is read INSIDE the lock (blocker fix 2026-06-10): a
                // now() captured before flock could predate a stamp another
                // process wrote while we waited, yielding negative elapsed —
                // and the old `elapsed >= 0` guard turned that into a
                // cooldown BYPASS instead of a refusal.
                let requestedAt = nowFn()

                // 1. Cooldown guard — refuse honestly inside the window. A
                //    stamp in the FUTURE (cross-process race remnant, clock
                //    skew) counts as cooling-down: negative elapsed refuses.
                let lastRestartAt = Self.readStampDate(stampURL)
                if let last = lastRestartAt {
                    let elapsed = requestedAt.timeIntervalSince(last)
                    if elapsed < cooldown {
                        let detail = elapsed < 0
                            ? "The last restart stamp (\(Self.iso(last))) is in the future relative to now — cross-process race or clock skew. Treating as cooling-down; refusing to restart."
                            : "A tool-initiated restart fired \(Int(elapsed))s ago; refusing to restart again within \(Int(cooldown))s."
                        return .object([
                            "status": .string("failed"),
                            "tool": .string("restart_app"),
                            "reason": .string("cooldown"),
                            "retryAfterSeconds": .double(Double((cooldown - elapsed).rounded(.up))),
                            "lastRestartAt": .string(Self.iso(last)),
                            "detail": .string(detail),
                        ])
                    }
                }

                // 2. Audit envelope FIRST. Restart is fail-closed on audit
                //    (unlike fail-soft builder audits): no receipt → no
                //    restart, because an unauditable app bounce is exactly
                //    the loop this guard exists to make visible.
                let auditURL = auditDir.appendingPathComponent("\(runId).json")
                var auditEntry: [String: Any] = [
                    "toolName": "restart_app",
                    "runId": runId,
                    "requestedAt": Self.iso(requestedAt),
                    "reason": effectiveReason,
                    "source": source,
                    "pid": Int(pid),
                    "appPath": appPath,
                    "relauncherArgv": argv,
                    "graceSeconds": grace,
                    "cooldownSeconds": cooldown,
                ]
                // Omit-when-nil (blocker fix 2026-06-10): never place a Swift
                // Optional into a JSONSerialization dictionary — be explicit
                // about the no-prior-stamp (first ever restart) case.
                if let last = lastRestartAt {
                    auditEntry["lastRestartAt"] = Self.iso(last)
                }
                do {
                    try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
                    let data = try JSONSerialization.data(withJSONObject: auditEntry, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: auditURL)
                } catch {
                    return .object([
                        "status": .string("failed"),
                        "tool": .string("restart_app"),
                        "reason": .string("audit_write_failed"),
                        "audit_error": .string(String(describing: error)),
                        "detail": .string("Refusing to restart without an audit receipt."),
                    ])
                }

                // 3. Cooldown stamp — written only after the audit landed,
                //    immediately before the restart actually fires.
                let stampEntry: [String: Any] = [
                    "firedAt": Self.iso(requestedAt),
                    "runId": runId,
                    "reason": effectiveReason,
                    "source": source,
                ]
                do {
                    let data = try JSONSerialization.data(withJSONObject: stampEntry, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: stampURL)
                } catch {
                    return .object([
                        "status": .string("failed"),
                        "tool": .string("restart_app"),
                        "reason": .string("stamp_write_failed"),
                        "detail": .string(String(describing: error)),
                    ])
                }

                // 4. Spawn the detached relauncher. On failure, roll the
                //    stamp back — no restart fired, so a 10-minute cooldown
                //    against a retry would be a lie.
                do {
                    try spawn(argv)
                } catch {
                    try? FileManager.default.removeItem(at: stampURL)
                    return .object([
                        "status": .string("failed"),
                        "tool": .string("restart_app"),
                        "reason": .string("relauncher_spawn_failed"),
                        "detail": .string(String(describing: error)),
                        "audit_path": .string(auditURL.path),
                    ])
                }

                // 5. Success envelope. Termination is armed by the CALLER
                //    (via the returned closure) AFTER the reply is on its
                //    way to the surface; the grace then lets the turn
                //    persist before the exit (old daemon parity). The note
                //    instructs brevity because the grace is a fixed timer:
                //    the final reply LLM call must finish inside it.
                return .object([
                    "status": .string("restarting"),
                    "tool": .string("restart_app"),
                    "note": .string("Restarting in ~\(Int(grace))s — keep the final reply brief (one short sentence) so it lands before termination. A detached relauncher reopens \(appPath) once the process exits (polls up to \(Self.relauncherPollSeconds)s)."),
                    "runId": .string(runId),
                    "reason": .string(effectiveReason),
                    "source": .string(source),
                    "graceSeconds": .double(grace),
                    "audit_path": .string(auditURL.path),
                ])
            }
        } catch {
            // flock acquisition failure — refuse, do not restart unguarded.
            return (.object([
                "status": .string("failed"),
                "tool": .string("restart_app"),
                "reason": .string("lock_failed"),
                "detail": .string(String(describing: error)),
            ]), nil)
        }

        // 6. Only a real "restarting" envelope earns an arm-terminate
        //    closure; refusals never schedule termination.
        if case .object(let obj) = result,
           case .string("restarting")? = obj["status"] {
            return (result, { scheduleTerminate(grace) })
        }
        return (result, nil)
    }

    // MARK: Helpers

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func readStampDate(_ url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fired = obj["firedAt"] as? String
        else { return nil }
        return ISO8601DateFormatter().date(from: fired)
    }

    /// Production relauncher spawn: posix_spawn with POSIX_SPAWN_SETSID so
    /// the helper becomes its own session leader — it must survive launchd
    /// tearing down the app's process group when the login item exits —
    /// with stdio redirected to /dev/null (nohup-equivalent, no SIGHUP /
    /// no pipe to a dead parent).
    private static func spawnDetached(argv: [String]) throws {
        precondition(!argv.isEmpty)

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
        let rc = posix_spawn(&childPID, argv[0], &fileActions, &attr, cArgs, environ)
        guard rc == 0 else {
            throw NSError(
                domain: "AppRestartCoordinator",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "posix_spawn(\(argv[0])) failed: \(String(cString: strerror(rc)))"]
            )
        }
    }
}
