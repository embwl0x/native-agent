import Foundation
#if canImport(Darwin)
import Darwin
#endif
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Result types

public struct RoutePlanResult: Sendable, Equatable {
    public let id: String
    public let message: String
    public let goalType: String
    public let recommendedSurface: String
    public let contextMode: String
    public let risk: String
    public let requiresApproval: Bool
    public let matchedCapabilities: [JSONValue]
    /// High-confidence tool groups already implied by the deterministic route.
    /// This is readiness only: it exposes schemas before the first provider
    /// call and grants no dispatch, approval, or effect authority.
    public let toolReadinessGroups: [String]
    public let nextActions: [String]
    public let createdAt: String

    public init(
        id: String,
        message: String,
        goalType: String,
        recommendedSurface: String,
        contextMode: String,
        risk: String,
        requiresApproval: Bool,
        matchedCapabilities: [JSONValue],
        toolReadinessGroups: [String] = [],
        nextActions: [String],
        createdAt: String
    ) {
        self.id = id
        self.message = message
        self.goalType = goalType
        self.recommendedSurface = recommendedSurface
        self.contextMode = contextMode
        self.risk = risk
        self.requiresApproval = requiresApproval
        self.matchedCapabilities = matchedCapabilities
        self.toolReadinessGroups = toolReadinessGroups
        self.nextActions = nextActions
        self.createdAt = createdAt
    }

    public func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "message": .string(message),
            "goalType": .string(goalType),
            "recommendedSurface": .string(recommendedSurface),
            "contextMode": .string(contextMode),
            "risk": .string(risk),
            "requiresApproval": .bool(requiresApproval),
            "matchedCapabilities": .array(matchedCapabilities),
            "toolReadinessGroups": .array(toolReadinessGroups.map { .string($0) }),
            "nextActions": .array(nextActions.map { .string($0) }),
            "createdAt": .string(createdAt),
        ])
    }

    public init(from json: JSONValue) throws {
        guard case .object(let obj) = json else {
            throw SystemOpsError.malformedResponse("RoutePlanResult: not an object")
        }
        func str(_ k: String) throws -> String {
            if case .string(let s) = obj[k] ?? .null { return s }
            throw SystemOpsError.malformedResponse("RoutePlanResult: missing string '\(k)'")
        }
        func boolean(_ k: String) -> Bool {
            if case .bool(let b) = obj[k] ?? .null { return b }
            return false
        }
        var caps: [JSONValue] = []
        if case .array(let arr) = obj["matchedCapabilities"] ?? .null { caps = arr }
        var actions: [String] = []
        if case .array(let arr) = obj["nextActions"] ?? .null {
            actions = arr.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
        }
        var readinessGroups: [String] = []
        if case .array(let arr) = obj["toolReadinessGroups"] ?? .null {
            readinessGroups = arr.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
        }
        self.init(
            id: try str("id"),
            message: try str("message"),
            goalType: try str("goalType"),
            recommendedSurface: try str("recommendedSurface"),
            contextMode: try str("contextMode"),
            risk: try str("risk"),
            requiresApproval: boolean("requiresApproval"),
            matchedCapabilities: caps,
            toolReadinessGroups: readinessGroups,
            nextActions: actions,
            createdAt: try str("createdAt")
        )
    }
}

public struct SystemRebuildOpResult: Sendable, Equatable {
    public let ok: Bool
    public let message: String?
    public let error: String?

    public init(ok: Bool, message: String?, error: String?) {
        self.ok = ok
        self.message = message
        self.error = error
    }

    public func toJSON() -> JSONValue {
        .object([
            "ok": .bool(ok),
            "message": message.map { .string($0) } ?? .null,
            "error": error.map { .string($0) } ?? .null,
        ])
    }
}

public struct GitStashRecoverOpResult: Sendable, Equatable {
    public let ok: Bool
    public let stashRef: String
    public let output: String
    public let error: String?

    public init(ok: Bool, stashRef: String, output: String, error: String?) {
        self.ok = ok
        self.stashRef = stashRef
        self.output = output
        self.error = error
    }

    public func toJSON() -> JSONValue {
        .object([
            "ok": .bool(ok),
            "stashRef": .string(stashRef),
            "output": .string(output),
            "error": error.map { .string($0) } ?? .null,
        ])
    }
}

// MARK: - Errors

public enum SystemOpsError: Error, Sendable, Equatable, LocalizedError {
    case missingMessage
    case missingLabel
    case scriptMissing(String)
    case subprocessFailed(String)
    case stashNotFound(String)
    case stashPopFailed(String)
    case transport(String)
    case malformedResponse(String)
    case notFlippable(String)
    /// Trust/autonomy gate refused the action. Reason string matches the
    /// daemon PermissionError byte-for-byte (see AutonomyGates.swift).
    case autonomyDenied(String)
    /// Another process already holds the cross-process rebuild lock.
    /// Mirrors Python L45169: "Rebuild already in progress — daemon is
    /// restarting."
    case rebuildInProgress

    public var errorDescription: String? {
        switch self {
        case .missingMessage: return "Message or objective is required"
        case .missingLabel: return "missing stash label"
        case .scriptMissing(let path):
            return "install_app.sh not found at \(path). Rebuild requires a local NativeAgent source checkout."
        case .subprocessFailed(let s): return s
        case .stashNotFound(let label):
            return "stash with label '\(label)' not found in git stash list"
        case .stashPopFailed(let s): return s
        case .transport(let s): return "transport error: \(s)"
        case .malformedResponse(let s): return "malformed response: \(s)"
        case .notFlippable(let s): return s
        case .autonomyDenied(let s): return s
        case .rebuildInProgress: return "Rebuild already in progress — the app is restarting."
        }
    }
}

// MARK: - Protocols

public protocol RouterPlanClient: Sendable {
    func planRoute(message: String) async throws -> RoutePlanResult
}

public protocol SystemRebuildClient: Sendable {
    func systemRebuild() async throws -> SystemRebuildOpResult
}

public protocol GitStashRecoverClient: Sendable {
    func gitStashRecover(label: String) async throws -> GitStashRecoverOpResult
}

// MARK: - Subprocess seam (test-injectable)

public protocol SubprocessRunner: Sendable {
    /// Run a subprocess and wait for it to exit (when `detached` is false) or
    /// kick it off without waiting (when `detached` is true). Returns
    /// (exitCode, stdout, stderr). For detached invocations exitCode is 0,
    /// stdout/stderr are empty.
    func run(
        executable: String,
        arguments: [String],
        cwd: URL?,
        timeout: TimeInterval,
        detached: Bool
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String)
}

/// Production impl backed by Foundation.Process.
public final class SystemSubprocessRunner: SubprocessRunner {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        cwd: URL?,
        timeout: TimeInterval,
        detached: Bool
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let cwd = cwd { proc.currentDirectoryURL = cwd }
        if detached {
            // Detach: discard fds, don't wait. Mirrors Python's
            // subprocess.Popen(stdin/out/err=DEVNULL, start_new_session=True).
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                throw SystemOpsError.subprocessFailed("Process.run() failed: \(error)")
            }
            return (0, "", "")
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        do {
            try proc.run()
        } catch {
            throw SystemOpsError.subprocessFailed("Process.run() failed: \(error)")
        }
        // The wait+drain body is synchronous (dedicated-thread drains +
        // semaphore waits are unavailable from async contexts) — the prior
        // impl blocked the caller on waitUntilExit() the same way, so this
        // keeps behavior parity.
        return Self.awaitExitAndDrains(
            proc, timeout: timeout, outFH: stdoutPipe.fileHandleForReading,
            errFH: stderrPipe.fileHandleForReading
        )
    }

    /// Block until `proc` exits, draining both pipes concurrently, with a
    /// TERM→KILL watchdog at `timeout`. Synchronous by design.
    private static func awaitExitAndDrains(
        _ proc: Process,
        timeout: TimeInterval,
        outFH: FileHandle,
        errFH: FileHandle
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        // AUDIT FIX (2026-07-21): the old body ran `waitUntilExit()` and only
        // THEN drained the pipes — a child writing >64KB filled the pipe
        // buffer and blocked on write, so it never exited; the deadline fired
        // terminate() once with no SIGKILL escalation; and the deadline task
        // was cancelled BEFORE the drains, so a grandchild holding the write
        // FDs hung `readDataToEndOfFile()` unwatched. Mirror
        // FileSystemActions.runProcess: drain BOTH pipes CONCURRENTLY with the
        // wait on DEDICATED THREADS (GCD-pool-independent, so concurrent
        // runners cannot starve the pool waitUntilExit parks on), SIGTERM at
        // the deadline with SIGKILL escalation, and a bounded drain grace that
        // force-closes the read ends if EOF never arrives.
        let box = SubprocessOutputBox()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let outThread = Thread {
            box.setStdout(outFH.readDataToEndOfFile())
            outDone.signal()
        }
        let errThread = Thread {
            box.setStderr(errFH.readDataToEndOfFile())
            errDone.signal()
        }
        outThread.stackSize = 1 << 20
        errThread.stackSize = 1 << 20
        outThread.start()
        errThread.start()

        // Watchdog on its own thread (also pool-independent): TERM at the
        // deadline, SIGKILL after a 2s grace so a TERM-ignoring child cannot
        // hang the runner. Stands down via a flag once the process exits.
        let watchdogDone = SubprocessRunFlag()
        let pid = proc.processIdentifier
        let watchdog = Thread {
            let deadline = Date().addingTimeInterval(max(0, timeout))
            let killDeadline = Date().addingTimeInterval(max(0, timeout) + 2.0)
            var sentTerm = false
            while !watchdogDone.get() {
                Thread.sleep(forTimeInterval: 0.05)
                if watchdogDone.get() { return }
                let now = Date()
                if !sentTerm && now >= deadline {
                    if proc.isRunning { proc.terminate() }
                    sentTerm = true
                }
                if now >= killDeadline {
                    if proc.isRunning { kill(pid, SIGKILL) }
                    return
                }
            }
        }
        watchdog.start()

        proc.waitUntilExit()
        // Process is gone → its OWN pipe write-ends are closed → both drains
        // hit EOF promptly in the normal case. If a GRANDCHILD inherited the
        // stdout/stderr FDs and outlived the direct child, the write-end stays
        // open and `readDataToEndOfFile()` would never return — bound the
        // drain wait and force-close the read end (which makes the blocked
        // read return with what it has) so the runner always returns.
        let drainGrace: DispatchTime = .now() + 2.0
        if outDone.wait(timeout: drainGrace) != .success {
            try? outFH.close()
            outDone.wait()
        }
        if errDone.wait(timeout: drainGrace) != .success {
            try? errFH.close()
            errDone.wait()
        }
        watchdogDone.set()
        let stdoutStr = String(data: box.stdout(), encoding: .utf8) ?? ""
        let stderrStr = String(data: box.stderr(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, stdoutStr, stderrStr)
    }
}

/// Sendable locked box for the two concurrent pipe drains in
/// `SystemSubprocessRunner.run`. Each setter is called exactly once (from its
/// reader thread); the getters run after both drain semaphores signal, so the
/// reads happen-after both writes. Mirrors FileSystemActions.ProcessOutputBox.
private final class SubprocessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func setStdout(_ d: Data) { lock.lock(); out = d; lock.unlock() }
    func setStderr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
    func stdout() -> Data { lock.lock(); defer { lock.unlock() }; return out }
    func stderr() -> Data { lock.lock(); defer { lock.unlock() }; return err }
}

/// Thread-safe one-shot flag for the subprocess watchdog (mirrors the
/// FileSystemActions ProcessTimeoutFlag).
private final class SubprocessRunFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
