import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import Dispatcher
import MacControl
import TurnTrace
import AgentWorkspace
import AuthoredCapabilities
import AppKit
import NativeAgentShared
import ApprovalInbox
import PersonaEngine
import StandingBots
import ProviderRouting
import CryptoKit
import MemoryV2
import SwarmRuns
import MacIntegration
// Blueprint: | `BuilderProcess.swift` | Process launch, environment and confinement |
extension SwiftToolDispatcher {
    // Escape SBPL literals so paths cannot alter confinement or credential/Trust denials.
    static func sbplEscapeLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    // The PATH shim disables SwiftPM's inner sandbox while the selected outer profile keeps confinement.
    /// The `swift` wrapper installed on PATH for sandboxed spawns. Injects
    /// `--disable-sandbox` only for the subcommands that accept it, only when the
    /// caller has not already passed it, and always re-execs the real toolchain
    /// binary by absolute path (so the shim can never recurse into itself).
    static func builderSwiftPMShimScript(realSwiftPath: String) -> String {
        """
        #!/bin/sh
        # NativeAgent builder shim — generated, do not edit.
        # sandbox-exec cannot nest, so SwiftPM's own manifest sandbox must be off
        # while NativeAgent's outer profile provides the confinement.
        real='\(realSwiftPath)'
        case "$1" in
          build|test|run|package)
            sub="$1"
            shift
            for a in "$@"; do
              if [ "$a" = "--disable-sandbox" ]; then
                exec "$real" "$sub" "$@"
              fi
            done
            exec "$real" "$sub" --disable-sandbox "$@"
            ;;
        esac
        exec "$real" "$@"
        """
    }
    /// Absolute path of the real `swift` driver, resolved without consulting the
    /// shim directory. `/usr/bin/swift` is the system xcrun stub and is what an
    /// unsandboxed spawn would have hit anyway.
    static func builderRealSwiftPath() -> String? {
        let candidates = [
            "/usr/bin/swift",
            "/usr/local/bin/swift",
            "/opt/homebrew/bin/swift",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// Create (idempotently) the shim directory and return it, or nil if it could
    /// not be built. Failing to nil is fail-SAFE: the spawn keeps its sandbox and
    /// a SwiftPM command fails loudly, rather than silently running unconfined.
    /// Executable shim/staging files live in OS temp, outside backup/export/
    /// phone sync and the data-root PrivacyMap, like this owner's patch text.
    static func builderSwiftPMShimDirectory(baseDirectory: URL? = nil) -> URL? {
        guard let realSwift = builderRealSwiftPath() else { return nil }
        let fm = FileManager.default
        // Per-user private temp (/var/folders/<hash>/T, mode 700) — not the
        // world-writable /tmp, so the shim cannot be pre-planted by another user.
        let dir = (baseDirectory ?? fm.temporaryDirectory)
            .appendingPathComponent(InstallPaths.current.name("nativeagent-swiftpm-shim"), isDirectory: true)
        let shim = dir.appendingPathComponent("swift", isDirectory: false)
        let script = builderSwiftPMShimScript(realSwiftPath: realSwift)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // createDirectory leaves an existing directory's permissions
            // unchanged. Reassert the private boundary on every call, including
            // the idempotent fast path.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            return nil
        }
        if let existing = try? String(contentsOf: shim, encoding: .utf8),
           existing == script,
           fm.isExecutableFile(atPath: shim.path) {
            return dir
        }
        do {
            // Stage under a unique name, mark executable, then atomically swap in.
            // A concurrent spawn therefore sees either the old shim or the new
            // one — never a half-written or not-yet-executable file.
            let staged = dir.appendingPathComponent("swift.staged-\(UUID().uuidString)")
            try script.write(to: staged, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            if fm.fileExists(atPath: shim.path) {
                _ = try fm.replaceItemAt(shim, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: shim)
            }
            // replaceItemAt may preserve the destination inode's mode (for
            // example a stale 0644 shim). Reassert the executable contract on
            // the final path, not only on the staging file.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            return dir
        } catch {
            // Lost a race with a sibling writer? Accept only the exact expected
            // script with the full private/executable permission contract.
            if let landed = try? String(contentsOf: shim, encoding: .utf8),
               landed == script,
               fm.isExecutableFile(atPath: shim.path),
               (try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)) != nil {
                return dir
            }
            return nil
        }
    }
    static func builderSandboxProfile(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        let writableRoots = builderAllowedRoots(dataRoot: dataRoot)
            .map { #"          (subpath "\#(Self.sbplEscapeLiteral($0.path))")"# }
            .joined(separator: "\n")
        let home = Self.sbplEscapeLiteral(
            URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path)
        var seenTrustPaths = Set<String>()
        let trustRules = builderWriteDeniedSubtrees(dataRoot: dataRoot).compactMap { url -> String? in
            let path = url.path
            guard seenTrustPaths.insert(path).inserted else { return nil }
            return #"        (deny file-write* (subpath "\#(Self.sbplEscapeLiteral(path))"))"#
        }.joined(separator: "\n")
        // allow-default then carve file-write* down to the workspace + build
        // caches; the LAST matching rule wins in SBPL, so the trailing deny on
        // the trust dir overrides the workspace allow for that subpath. NOTE:
        // this is WRITE confinement — reads, process-exec, and network stay open
        // by design (git fetch/push + SwiftPM package resolution need network;
        // denying it would cut capability). It contains workspace-escaping
        // WRITES, not secret reads; receipts say sandbox_mode=workspace_write.
        return """
        (version 1)
        (allow default)
        \(Self.sbplAutomationDenials)
        (deny file-write*)
        (allow file-write*
        \(writableRoots)
          (subpath "/tmp")
          (subpath "/private/tmp")
          (subpath "/private/var/folders")
          (subpath "\(home)/Library/Caches")
          (subpath "\(home)/Library/Developer")
          (subpath "\(home)/.swiftpm")
          (subpath "\(home)/.cache")
          (literal "/dev/null"))
        \(trustRules)
        """
    }
    /// Developer Mode removes workspace-only confinement without removing the
    /// non-bypassable system and authority floor. The process may write across
    /// ordinary user space (Desktop, Documents, checked-out repositories, and
    /// build caches), while macOS still enforces denials for protected OS roots,
    /// credentials, and NativeAgent-owned state. The canonical workspace is
    /// allowed back after the data-root denial because public installs place it
    /// inside Application Support.
    static func builderDeveloperSandboxProfile(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        let workspace = builderWorkspaceRoot(dataRoot: dataRoot)
            .standardizedFileURL.resolvingSymlinksInPath().path
        var seen = Set<String>()
        let denyRules = builderDeveloperProtectedRoots(dataRoot: dataRoot).compactMap { path -> String? in
            guard seen.insert(path).inserted else { return nil }
            return #"        (deny file-write* (subpath "\#(Self.sbplEscapeLiteral(path))"))"#
        }.joined(separator: "\n")
        let trustPath = dataRoot.appendingPathComponent("trust", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return """
        (version 1)
        (allow default)
        \(Self.sbplAutomationDenials)
        \(denyRules)
        (allow file-write* (subpath "\(Self.sbplEscapeLiteral(workspace))"))
        (deny file-write* (subpath "\(Self.sbplEscapeLiteral(trustPath))"))
        """
    }
    /// Deny Apple Events and their transport after allow default to prevent delegated writes outside confinement.
    static let sbplAutomationDenials = """
        (deny appleevent-send)
        (deny mach-lookup (global-name "com.apple.coreservices.appleevents"))
        (deny mach-lookup (global-name "com.apple.appleeventsd"))
    """
    enum BuilderShellSandboxMode: String, Sendable {
        case readOnly = "read_only"
        /// Strict / locked-down posture: workspace-confined AND the off-ramps
        /// (env break-glass, `securityPolicy.shellSandboxEnabled`) do not apply.
        case lockedDown = "locked_down"
        case workspaceWrite = "workspace_write"
        case developerFullMac = "developer_full_mac"
        case off
    }
    /// The trust modes User means by "yolo": the operator has explicitly taken
    /// the wrapper off, so the harness must not second-guess it with one.
    static let builderYoloPermissionLevels: Set<String> = [
        "full_mac_os", "wide_open_receipts",
    ]
    /// Trust selects confinement; locked-down mode overrides all environment and policy escape hatches.
    static func builderShellSandboxMode(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> BuilderShellSandboxMode {
        let policy = await SwiftNativeTrustCenter(
            dataRoot: dataRoot
        ).loadTrustPolicy()
        var permissionLevel = "balanced"
        if case .string(let raw)? = policy["permissionLevel"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { permissionLevel = trimmed }
        }
        // Tier 3 first: a locked-down posture outranks every off-ramp below,
        // including the env break-glass. Checked before the env var on purpose.
        if permissionLevel == "strict" || permissionLevel == "locked_down" {
            return .lockedDown
        }
        // Tier 1: yolo. Explicit permission level AND a live Full Mac window.
        if Self.builderYoloPermissionLevels.contains(permissionLevel),
           let trust = MacControlPolicy.fromTrustPolicyObject(policy).trustPolicy,
           MacControlGate.fullMacActive(trust) {
            return .off
        }
        if let v = environment["NATIVE_AGENT_SHELL_SANDBOX"],
           v == "0" || v.lowercased() == "false" {
            return .off
        }
        if case .bool(true)? = policy["developerMode"] {
            return .developerFullMac
        }
        if case .object(let sec)? = policy["securityPolicy"],
           case .bool(let enabled)? = sec["shellSandboxEnabled"] {
            return enabled ? .workspaceWrite : .off
        }
        return .workspaceWrite
    }
    /// How a command line starts, decided once for every caller (the shell
    /// tools and a part's program): the sandbox Trust selects, the folder it
    /// may start in, and the SwiftPM shim first on PATH inside the sandbox.
    /// Nil when that folder is not one the command may start in.
    struct BuilderLaunch: Sendable {
        let mode: BuilderShellSandboxMode
        let executable: String
        let arguments: [String]
        let cwd: String
        let pathPrefix: String?
        let environment: [String: String]?
    }
    static func builderLaunch(executable: String, args: [String], cwd: String, dataRoot: URL, readWords: [String]? = nil) async -> BuilderLaunch? {
        // The workspace is infrastructure, not a model-created side effect.
        // Launch prepares it for every entry surface.
        _ = try? NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
        // Resolve the effective confinement posture before cwd validation.
        // Full Mac YOLO deliberately removes the workspace wrapper, so it must
        // also be able to start in a user-selected external project. Ordinary
        // modes retain the canonical workspace/source-checkout boundary.
        let mode = await builderShellSandboxMode(dataRoot: dataRoot)
        let directory = builderNormalizeCwd(cwd, dataRoot: dataRoot, allowOutsideWorkspace: mode == .off)
        guard directory.rejection == nil else { return nil }
        let resolvedCwd = directory.path
        if let readWords {
            let read = FileReadSourceMaterial.shellReadLaunch(words: readWords, cwd: resolvedCwd, dataRoot: dataRoot)
            return BuilderLaunch(mode: .readOnly, executable: "/usr/bin/sandbox-exec", arguments: read.arguments,
                                 cwd: resolvedCwd, pathPrefix: nil, environment: read.environment)
        }
        // sandbox-exec replaces itself with the target, so watchdog signals reach the command's pid/pgid.
        guard mode != .off else {
            return BuilderLaunch(mode: mode, executable: executable, arguments: args, cwd: resolvedCwd, pathPrefix: nil, environment: nil)
        }
        let profile = mode == .developerFullMac ? builderDeveloperSandboxProfile(dataRoot: dataRoot) : builderSandboxProfile(dataRoot: dataRoot)
        return BuilderLaunch(mode: mode, executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, executable] + args,
                             cwd: resolvedCwd, pathPrefix: builderSwiftPMShimDirectory()?.path, environment: nil)
    }
    static func runShellLikeProcess(
        toolName: String,
        executable: String,
        args: [String],
        cwd: String,
        timeoutSeconds: Int,
        sourcePayloadForAudit: String? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        // Two narrow seams used by the agent-host command adapter alone. Left
        // nil/false, every existing caller behaves exactly as it did.
        //
        // `environmentOverride` replaces this app's inherited environment — it
        // holds provider keys and the bridge token, which an EXTERNAL agent's
        // command must never be handed.
        //
        // `reapDescendantsOnExit` also settles the process group when the
        // direct child exits, not only on timeout: an agent CLI can leave
        // something running behind it, and that must not outlive the turn or
        // the temp directory the run was given.
        environmentOverride: [String: String]? = nil,
        closeStandardInput: Bool = false,
        reapDescendantsOnExit: Bool = false,
        // A command tool (shell, bash): the call completed once the command
        // ran, and its exit code, output and timeout are the command's answer.
        exitIsAnswer: Bool = false,
        // Each stdout line as it is written, for a caller that shows progress
        // live. The envelope is unchanged. Agent-host command runs only.
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async -> JSONValue {
        // Allocate run identity and start time before validation so pre-spawn failures receive audit receipts.
        let runId = UUID().uuidString
        let started = Date()
        let readWords = ["shell", "bash"].contains(toolName)
            ? sourcePayloadForAudit.flatMap { AuthoredToolEffects.shellReadOnlyWords(["cmd": .string($0)]) } : nil
        // Normalize and bound-check cwd. On failure: write a pre-spawn
        // audit envelope, then return a clean denied envelope (carry the
        // audit_error if the write itself failed so it's visible).
        guard let launch = await builderLaunch(executable: executable, args: args, cwd: cwd, dataRoot: dataRoot, readWords: readWords) else {
            let auditEntry: [String: Any] = [
                "toolName": toolName,
                "runId": runId,
                "createdAt": NativeTimestampFormat.plainZulu(started),
                "completedAt": NativeTimestampFormat.plainZulu(Date()),
                "status": "failed_pre_spawn",
                "reason": "cwd_invalid_or_outside_workspace",
                "cwd_requested": cwd,
                "workspace_root": builderWorkspaceRoot(dataRoot: dataRoot).path,
                "executable": executable,
                "args": args,
                "outer_sandbox_policy": "policy",
            ]
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            var env: [String: JSONValue] = [
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string(toolName),
                "reason": .string("cwd_invalid_or_outside_workspace"),
                "execution": .string("not_run"),
                "effect": .string("none"),
                "detail": .string("cwd is not an existing folder this tool may work in; use one inside workspace_root. Nothing ran."),
                "cwd_requested": .string(cwd),
                "workspace_root": .string(builderWorkspaceRoot(dataRoot: dataRoot).path),
                "source_checkout_available": .bool(builderSourceRepoRoot(dataRoot: dataRoot) != nil),
                "runId": .string(runId),
                "audit_path": .string(auditURL.path),
                "outer_sandbox_policy": .string("policy"),
            ]
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }
        let clampedTimeout = builderEffectiveTimeoutSeconds(timeoutSeconds)
        let sandboxMode = launch.mode, resolvedCwd = launch.cwd
        let sandboxed = sandboxMode != .off
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        // Environment. SwiftPM nesting shim, only relevant when we DID wrap: `sandbox_apply` refuses to nest, and SwiftPM
        //     self-sandboxes its manifest compile, so ANY `swift build/test/run/
        //     package` under our wrapper dies with "Invalid manifest" before a
        //     line of Swift executes — including indirect ones inside a shell
        //     script (e.g. script/task_ledger.sh). Confinement is not supposed to
        //     mean execution denial, so instead of lifting the wrapper we put a
        //     `swift` shim first on PATH that injects `--disable-sandbox`. The
        //     OUTER profile still confines every write (verified empirically:
        //     `swift run --disable-sandbox` builds AND runs under the workspace
        //     profile, while an out-of-workspace write is still denied).
        var env = launch.environment ?? environmentOverride ?? ProcessInfo.processInfo.environment
        var effectiveCompatRewrites: [String] = []
        let developerDirectory = await Self.builderSelectedDeveloperDirectory(environment: env)
        let developerPromptPolicy = Self.builderEnvironmentSuppressingDeveloperToolsPrompt(
            environment: env,
            selectedDeveloperDirectory: developerDirectory
        )
        env = developerPromptPolicy.environment
        if developerPromptPolicy.suppressed {
            effectiveCompatRewrites.append(
                "suppressed interactive Apple developer-tools install prompt; install Xcode Command Line Tools manually to use Apple toolchain shims"
            )
        }
        let resolvedCompatRewrites = effectiveCompatRewrites
        if let shimDir = launch.pathPrefix {
            let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = shimDir + ":" + existingPath
        }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: resolvedCwd)
        if closeStandardInput { process.standardInput = FileHandle.nullDevice }
        process.qualityOfService = .utility
        @Sendable func spawnFailure(_ error: any Error) -> JSONValue {
            let spawnAudit: [String: Any] = [
                "toolName": toolName,
                "runId": runId,
                "createdAt": NativeTimestampFormat.plainZulu(started),
                "completedAt": NativeTimestampFormat.plainZulu(Date()),
                "status": "failed_pre_spawn",
                "reason": "spawn_failed",
                "detail": ChatToolOutcome.errorMessage(error),
                "cwd": resolvedCwd,
                "executable": executable,
                "args": args,
                "sandboxed": sandboxed,
                "outer_sandbox_policy": "policy",
            ]
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: spawnAudit, dataRoot: dataRoot)
            var env = Self.builderFailureFields(error,
                tool: toolName, reason: "spawn_failed", effects: .none,
                owner: "process launch for \(executable) in \(resolvedCwd)",
                instruction: "Repair the reported executable, working-directory or pipe error before another command. Nothing ran.")
            env.merge([
                "execution": .string("not_run"),
                "effect": .string("none"),
                "runId": .string(runId),
                "sandboxed": .bool(sandboxed),
                "outer_sandbox_policy": .string("policy"),
                "audit_path": .string(auditURL.path),
            ], uniquingKeysWith: { _, receipt in receipt })
            if let auditErr { env["audit_error"] = .string(auditErr) }
            return .object(env)
        }
        let outputCapture: InvokeOutputCapture
        do {
            outputCapture = try InvokeOutputCapture(process: process,
                stdoutCap: 16 * 1024 * 1024, stderrCap: 16 * 1024 * 1024, onStdoutLine: onStdoutLine)
        } catch {
            return await settle { spawnFailure(error) }
        }
        return await SubprocessWork(process).run(
            timeoutSeconds: clampedTimeout, reapDescendantsOnExit: reapDescendantsOnExit
        ) { exit in
            let (stdoutText, stderrText) = outputCapture.finish(appendTruncationNotes: false)
            if let error = exit.launchError {
                return spawnFailure(ToolFailureError(error, effects: .none, code: "spawn_failed"))
            }
            let pipeTruncated = outputCapture.truncated
            let exitCode = exit.code
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            // A launched shell timeout is command data; an explicit Stop is cancellation.
            let timeoutIsAnswer = exitIsAnswer && exit.launched && exit.timedOut
            let status = exit.stopped && !timeoutIsAnswer ? "stopped" : exitIsAnswer || exitCode == 0 ? "completed" : "failed"
            var auditEntry: [String: Any] = [
                "toolName": toolName,
                "runId": runId,
                "createdAt": NativeTimestampFormat.plainZulu(started),
                "completedAt": NativeTimestampFormat.plainZulu(Date()),
                "status": status,
                "durationMs": durationMs,
                "timeoutSecondsEffective": clampedTimeout,
                "timedOut": exit.timedOut,
                "exitCode": Int(exitCode),
                "processExitCode": Int(exitCode),
                "cwd": resolvedCwd,
                "executable": executable,
                "args": args,
                "stdout_len": stdoutText.count,
                "stderr_len": stderrText.count,
                "stdout": stdoutText,
                "stderr": stderrText,
                "pipe_truncated": pipeTruncated,
                "sandboxed": sandboxed,
                "sandbox_mode": sandboxMode.rawValue,
                "outer_sandbox_policy": "policy",
            ]
            if let sourcePayloadForAudit { auditEntry["sourcePayload"] = sourcePayloadForAudit }
            if exit.stopped { auditEntry["reason"] = exit.timedOut ? "watchdog_timeout" : "stopped" }
            if !resolvedCompatRewrites.isEmpty {
                auditEntry["compat_rewrites"] = resolvedCompatRewrites
            }
            let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
            // Envelope-side truncation cap (~32KB each). Head+tail, NOT
            // head-only: build/test errors land at the END of the stream, so
            // a bare .prefix(32K) kept the progress noise and dropped the
            // errors — blinding her on any build that outran the cap. Keep
            // 8KB head (command echo + first/root-cause error) + 24KB tail
            // (final errors + test summary + exit). Same budget, errors survive.
            let (envStdout, envStdoutTruncated) = SwiftToolDispatcher.headTailPreserve(
                stdoutText, headBudget: 8_192, tailBudget: 24_576)
            let (envStderr, envStderrTruncated) = SwiftToolDispatcher.headTailPreserve(
                stderrText, headBudget: 8_192, tailBudget: 24_576)
            var envelope: [String: JSONValue] = [
                "status": .string(status),
                "tool": .string(toolName),
                "runId": .string(runId),
                "exit_code": .int(Int64(exitCode)),
                "process_exit_code": .int(Int64(exitCode)),
                "stdout": .string(envStdout),
                "stderr": .string(envStderr),
                "durationMs": .int(Int64(durationMs)),
                "timeout_seconds_effective": .int(Int64(clampedTimeout)),
                "timed_out": .bool(exit.timedOut),
                "ran": .bool(exit.launched),
                "execution": .string(exit.launched ? "executed" : "not_run"),
                "cwd": .string(resolvedCwd),
                "sandboxed": .bool(sandboxed),
                "sandbox_mode": .string(sandboxMode.rawValue),
                "outer_sandbox_policy": .string("policy"),
                "audit_path": .string(auditURL.path),
            ]
            // What a person reads on the row: it ran, and what it answered.
            if exitIsAnswer {
                envelope["summary"] = .string(exit.launched
                    ? "Ran · exit \(exitCode)" + (exit.timedOut ? " · timed out after \(clampedTimeout) s" : "")
                    : "Stopped before launch")
            }
            if exit.timedOut {
                if !exitIsAnswer { envelope["reason"] = .string("watchdog_timeout") }
                envelope["detail"] = .string("The process exceeded the effective \(clampedTimeout)-second builder timeout and its process tree was terminated.")
            } else if exit.stopped {
                envelope["reason"] = .string("stopped")
                envelope["detail"] = .string(exit.launched
                    ? "Stopped the process tree. Captured output is saved in the audit; any changes already made remain."
                    : "Stopped before launch. Nothing ran.")
            }
            if !resolvedCompatRewrites.isEmpty {
                envelope["compat_rewrites"] = .array(resolvedCompatRewrites.map { .string($0) })
            }
            if envStdoutTruncated || envStderrTruncated || pipeTruncated {
                envelope["_truncated"] = .bool(true)
            }
            if let auditErr { envelope["audit_error"] = .string(auditErr) }
            return .object(envelope)
        }
    }
}
