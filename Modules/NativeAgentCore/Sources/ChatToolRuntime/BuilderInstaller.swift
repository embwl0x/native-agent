import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import AgentWorkspace
import AuthoredCapabilities
import AppKit
import NativeAgentShared
import TrustCenter
import ApprovalInbox
import PersonaEngine
import StandingBots
import ProviderRouting
import CryptoKit
import MemoryV2
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `BuilderInstaller.swift` | Installer launch, helper lifetime and settlement |
extension SwiftToolDispatcher {
    static func impl_install_app(input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let runId = UUID().uuidString
        let started = Date()
        guard let repo = builderSourceRepoRoot(dataRoot: dataRoot) else {
            return builderSourceCheckoutRequiredEnvelope(tool: "install_app", dataRoot: dataRoot)
        }
        let script = repo
            .appendingPathComponent("script", isDirectory: true)
            .appendingPathComponent("install_app.sh")
        let reason = builderResolveString(input, keys: ["reason"]) ?? "unspecified"
        let delay: Int = {
            if case .int(let value)? = input["start_delay_seconds"] {
                return max(5, min(120, Int(value)))
            }
            if case .double(let value)? = input["start_delay_seconds"],
               let delay = Int(exactly: value.rounded(.towardZero)) {
                return max(5, min(120, delay))
            }
            return Int(AppRelaunch.terminateGraceSeconds.rounded(.up))
        }()
        let logURL = dataRoot
            .appendingPathComponent("builder_audit", isDirectory: true)
            .appendingPathComponent("\(runId)-install_app.log")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return await settle {
                let auditEntry: [String: Any] = [
                    "toolName": "install_app",
                    "runId": runId,
                    "createdAt": NativeTimestampFormat.plainZulu(started),
                    "completedAt": NativeTimestampFormat.plainZulu(Date()),
                    "status": "failed_pre_spawn",
                    "reason": "script_missing",
                    "script": script.path,
                    "outer_sandbox_policy": "forced_off",
                ]
                let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
                var env: [String: JSONValue] = [
                    "status": .string("failed"),
                    "effects": .string("none"),
                    "tool": .string("install_app"),
                    "reason": .string("script_missing"),
                    "detail": .string("The install script is missing at script_path, so nothing ran."),
                    "script_path": .string(script.path),
                    "runId": .string(runId),
                    "audit_path": .string(auditURL.path),
                ]
                if let auditErr { env["audit_error"] = .string(auditErr) }
                return .object(env)
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return await settle {
                let auditEntry: [String: Any] = [
                    "toolName": "install_app",
                    "runId": runId,
                    "createdAt": NativeTimestampFormat.plainZulu(started),
                    "completedAt": NativeTimestampFormat.plainZulu(Date()),
                    "status": "failed_pre_spawn",
                    "reason": "log_dir_create_failed",
                    "detail": String(describing: error),
                    "outer_sandbox_policy": "forced_off",
                ]
                let (auditURL, auditErr) = builderWriteAudit(runId: runId, entry: auditEntry, dataRoot: dataRoot)
                var env = Self.builderFailureFields(error,
                    tool: "install_app", reason: "log_dir_create_failed", effects: .none,
                    owner: logURL.deletingLastPathComponent().path,
                    instruction: "Repair the installer log directory's reported storage error. The installer did not launch.")
                env.merge([
                    "runId": .string(runId),
                    "audit_path": .string(auditURL.path),
                ], uniquingKeysWith: { _, receipt in receipt })
                if let auditErr { env["audit_error"] = .string(auditErr) }
                return .object(env)
            }
        }
        @Sendable func entry(_ status: String, detail: String? = nil) -> [String: Any] {
            var audit: [String: Any] = [
                "toolName": "install_app",
                "runId": runId,
                "createdAt": NativeTimestampFormat.plainZulu(started),
                "status": status,
                "reason": reason,
                "script": script.path,
                "repo": repo.path,
                "log_path": logURL.path,
                "start_delay_seconds": delay,
                "detached": true,
                "sandboxed": false,
                "sandbox_mode": "off",
                "outer_sandbox_policy": "forced_off",
            ]
            if status != "running" { audit["completedAt"] = NativeTimestampFormat.plainZulu(Date()) }
            audit["detail"] = detail
            return audit
        }
        // The detached native helper owns the delay, script process, explicit
        // abort signals and terminal audit even after installation quits us.
        let auditURL = logURL.deletingLastPathComponent().appendingPathComponent("\(runId).json")
        let pid: pid_t
        do {
            let running = TurnTraceRedactor.redactValue(JSONValue(fromFoundation: entry("running"))).mapStrings(builderAuditText)
            try running.serializedData(pretty: true).write(to: auditURL, options: .atomic)
            guard !Task.isCancelled else { throw CancellationError() }
            guard let executable = Bundle.main.executablePath else {
                throw CocoaError(.fileNoSuchFile)
            }
            pid = try AppRelaunch.spawnDetached(argv: [executable, "--nativeagent-install-helper",
                repo.path, script.path, logURL.path, auditURL.path, String(delay)])
        } catch {
            let stopped = error is CancellationError
            return await settle {
                let (auditURL, auditErr) = builderWriteAudit(runId: runId,
                    entry: entry(stopped ? "stopped" : "failed", detail: String(describing: error)), dataRoot: dataRoot)
                var env = Self.builderFailureFields(error,
                    tool: "install_app", reason: "spawn_failed", effects: .none,
                    owner: "installer helper at \(Bundle.main.executablePath ?? "missing executable"); audit at \(auditURL.path)",
                    instruction: "Repair the installer helper's reported audit or launch error. The installer did not launch.")
                if stopped {
                    env["status"] = .string("stopped")
                    env["reason"] = .string("stopped_before_spawn")
                    env["failure_code"] = .string("stopped_before_spawn")
                    env["detail"] = .string("Stopped before the installer helper launched. Nothing ran.")
                }
                env.merge([
                    "runId": .string(runId),
                    "audit_path": .string(auditURL.path),
                ], uniquingKeysWith: { _, receipt in receipt })
                if let auditErr { env["audit_error"] = .string(auditErr) }
                return .object(env)
            }
        }
        let env: [String: JSONValue] = [
            "status": .string("scheduled"),
            "tool": .string("install_app"),
            "runId": .string(runId),
            "pid": .int(Int64(pid)),
            "reason": .string(reason),
            "script_path": .string(script.path),
            "log_path": .string(logURL.path),
            "audit_path": .string(auditURL.path),
            "start_delay_seconds": .int(Int64(delay)),
            "detached": .bool(true),
            "sandboxed": .bool(false),
            "sandbox_mode": .string("off"),
            "outer_sandbox_policy": .string("forced_off"),
            "note": .string("Installation handed to helper PID \(pid). It owns the start delay, installer and terminal audit at audit_path; stopping this conversation does not abort it."),
        ]
        return .object(env)
    }
    /// The executable entry point stays synchronous: SwiftUI's App.main never
    /// returns, so an async main would hold the main actor for the whole run and
    /// no @MainActor launch work would ever start (10-23: her engine and bridges
    /// never came up). In helper mode this process has no UI: it waits here for
    /// the helper's own task and then exits.
    public static func runScheduledInstallerHelperIfRequestedBlocking() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--nativeagent-install-helper" else { return false }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await runScheduledInstallerHelperIfRequested()
            done.signal()
        }
        done.wait()
        return true
    }
    /// Executable-only mode, before runtime startup. The accepted install has
    /// its own process owner; app shutdown does not cancel it. Sending a stop
    /// signal to this helper is the separate explicit abort boundary.
    static func runScheduledInstallerHelperIfRequested() async -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--nativeagent-install-helper" else { return false }
        guard args.count == 7, let delay = Int(args[6]), (5...120).contains(delay),
              let bytes = try? Data(contentsOf: URL(fileURLWithPath: args[5])) else { return true }
        let process = Process()
        let work = SubprocessWork(process)
        let startDelay = Task { try await Task.sleep(for: .seconds(delay)) }
        let signals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { work.stop(); startDelay.cancel() }
            source.resume()
            return source
        }
        @Sendable func finish(_ status: String, code: Int32? = nil, detail: String) {
            for source in signals { source.cancel(); source.setEventHandler(handler: nil) }
            do {
                var audit = try JSONDecoder().decode([String: JSONValue].self, from: bytes)
                audit["pid"] = .int(Int64(getpid()))
                audit["status"] = .string(status)
                audit["exitCode"] = code.map { .int(Int64($0)) }
                audit["detail"] = .string(detail)
                audit["completedAt"] = .string(NativeTimestampFormat.plainZulu(Date()))
                try JSONEncoder().encode(audit)
                    .write(to: URL(fileURLWithPath: args[5]), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Installer settlement failed: \(error)\n".utf8))
            }
        }
        // A signal can interrupt admission during this user-selected delay.
        // The physical helper owns the wait and checks cancellation before run.
        await withTaskCancellationHandler {
            _ = await startDelay.result
        } onCancel: {
            work.stop()
            startDelay.cancel()
        }
        do {
            let log = URL(fileURLWithPath: args[4])
            try Data().write(to: log, options: .withoutOverwriting)
            let output = try FileHandle(forWritingTo: log)
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [args[3]]
            process.currentDirectoryURL = URL(fileURLWithPath: args[2])
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            await work.run(reapDescendantsOnExit: false) { exit in
                try? output.close()
                finish(exit.stopped ? "stopped" : exit.code == 0 ? "completed" : "failed", code: exit.code,
                    detail: exit.launchError ?? (exit.stopped
                        ? "Installation stopped. Installer output is saved in log_path; any completed installation steps remain."
                        : "Installer exited; its output is saved in log_path."))
            }
        } catch {
            await settle { finish("failed", detail: String(describing: error)) }
        }
        return true
    }
}
