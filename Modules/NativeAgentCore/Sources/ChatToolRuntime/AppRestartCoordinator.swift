import Foundation
import PersistenceCore

// MARK: - AppRestartCoordinator (restart_app / Telegram /restart core)
//
// Swift app restart support for Telegram /restart and the restart_app tool.
// The Swift app is an SMAppService login item — quitting does NOT respawn it —
// so the restart sequence needs a DETACHED relauncher process that outlives
// the app: it waits for our PID to exit, then `open`s the app
// bundle again.
//
// ONE core routine for every surface (chat tool `restart_app`, Telegram
// /restart via the injected TelegramRestartRef): cooldown guard, audit
// envelope, stamp, relauncher spawn, and grace-period termination all live
// here exactly once. Surfaces apply their origin and approval gates before
// calling this coordinator; Telegram /restart also checks its owner allowlist.
//
// Sequencing contract that keeps the turn intact:
//   cooldown check → audit write → stamp write → relauncher spawn →
//   success envelope → terminate scheduled after a grace period.
// The grace is what lets the in-flight turn finish persisting and the
// reply reach the surface BEFORE the app dies.
//
// Production chat files an inline approval card when restart_app requires
// confirmation. The person approves the card to replay the guarded restart;
// no manual trust-policy edit is needed.
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
    /// (ChatOrchestrationClient.chat → appendMessage). The grace must
    /// outlive that final reply LLM call + persistence or the app dies
    /// mid-turn and the reply is lost. Turn-completion-TRIGGERED termination
    /// (no fixed timer) is a ledgered follow-up; until then the constant
    /// must stay comfortably above worst-case reply-compose latency.
    public static let terminateGraceSeconds: TimeInterval = 20
    /// Process-wide instance used by the chat dispatch case and the app
    /// layer Telegram bridge. The app layer MUST `configure(...)` it at
    /// launch with the real terminate and relauncher closures (platform
    /// operations live above this module); until then requestRestart refuses
    /// honestly.
    public static let shared = AppRestartCoordinator()

    // MARK: Injectable seams (tests never spawn or terminate for real)

    /// App-bound port that spawns the detached relauncher argv. The app uses
    /// posix_spawn with POSIX_SPAWN_SETSID (own session — survives the
    /// app/launchd job teardown) and stdio on /dev/null.
    private var spawnRelauncher: (@Sendable (_ argv: [String]) throws -> Void)?
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
        self.spawnRelauncher = spawnRelauncher
        self.scheduleTerminate = scheduleTerminate
    }

    /// App-layer wiring point: inject the real terminate scheduler and
    /// relauncher spawn. Called once from applicationDidFinishLaunching.
    public func configure(
        scheduleTerminate: @escaping @Sendable (_ graceSeconds: TimeInterval) -> Void,
        spawnRelauncher: @escaping @Sendable (_ argv: [String]) throws -> Void,
        now: (@Sendable () -> Date)? = nil
    ) {
        self.scheduleTerminate = scheduleTerminate
        self.spawnRelauncher = spawnRelauncher
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

    /// Wait for exit even when a surface takes longer to send its reply.
    /// Opening a still-running app would only activate it, losing the restart.
    public static func relauncherArgv(pid: Int32, appPath: String) -> [String] {
        // Single-quote the app path for the shell; escape embedded quotes.
        let quoted = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 1; done; exec /usr/bin/open \(quoted)
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
    /// fails — otherwise the relauncher waits against a live app while
    /// the cooldown stamp claims a restart happened.
    public func requestRestartDeferringTerminate(
        reason: String, source: String
    ) async -> (envelope: JSONValue, armTerminate: (@Sendable () -> Void)?) {
        // Fail closed when the app layer hasn't injected both hooks: spawning
        // a relauncher without being able to exit would just no-op `open`
        // against a live app while claiming "restarting".
        guard let scheduleTerminate, let spawnRelauncher else {
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
        let spawn = spawnRelauncher
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
                    "note": .string("Restarting in ~\(Int(grace))s — keep the final reply brief (one short sentence) so it lands before termination. A detached relauncher reopens \(appPath) once the process exits."),
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
}
