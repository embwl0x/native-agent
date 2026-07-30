import Foundation
import CryptoKit

// MARK: - U2b wave 1: shared evolution-engine support
//
// Internal helpers shared by EvolutionProposalStore / EvolutionCandidateBuilder /
// EvolutionVerifyRevert. Nothing here executes installs, restarts, or touches
// policy files — pure process plumbing + hashing + env hygiene.

// MARK: - Errors

public enum EvolutionEngineError: Error, LocalizedError, Equatable {
    case storeCorrupt(path: String, detail: String)
    case proposalNotFound(id: String)
    case illegalTransition(id: String, from: String, to: String)
    case invalidRunId(String)
    case duplicateRun(String)
    case diffShaMismatch(expected: String, actual: String)
    case commitNotFound(String)
    case worktreeFailed(detail: String)
    case applyConflict(detail: String)
    case spawnFailed(detail: String)
    case alreadyPendingVerify(existingRunId: String)
    case pendingVerifyMismatch(expected: String, actual: String)
    case pendingVerifyCorrupt(path: String, detail: String)
    case rollbackBundleMissing(runId: String)
    case rollbackCopyFailed(detail: String)
    /// meta.json present but unreadable/undecodable — distinct from missing
    /// (fail-closed: the corrupt file is left in place for a human).
    case rollbackMetaCorrupt(path: String, detail: String)
    /// meta.json decoded but bundleName is not a safe path component —
    /// refuse before any path is built from it.
    case rollbackBundleNameInvalid(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .storeCorrupt(let p, let d): return "evolution store corrupt at \(p): \(d)"
        case .proposalNotFound(let id): return "evolution proposal not found: \(id)"
        case .illegalTransition(let id, let f, let t): return "illegal transition for \(id): \(f) -> \(t)"
        case .invalidRunId(let id): return "invalid run id: \(id)"
        case .duplicateRun(let id): return "candidate run already in flight: \(id)"
        case .diffShaMismatch(let e, let a): return "diff sha mismatch: expected \(e), actual \(a)"
        case .commitNotFound(let sha): return "expected head commit not found: \(sha)"
        case .worktreeFailed(let d): return "worktree operation failed: \(d)"
        case .applyConflict(let d): return "diff did not apply cleanly: \(d)"
        case .spawnFailed(let d): return "process spawn failed: \(d)"
        case .alreadyPendingVerify(let id): return "a pending verify already exists for run \(id) — clear it before staging another"
        case .pendingVerifyMismatch(let e, let a): return "pending verify run id mismatch: expected \(e), actual \(a)"
        case .pendingVerifyCorrupt(let p, let d): return "pending_verify.json corrupt at \(p): \(d)"
        case .rollbackBundleMissing(let id): return "no rollback bundle for run \(id)"
        case .rollbackCopyFailed(let d): return "rollback bundle copy failed: \(d)"
        case .rollbackMetaCorrupt(let p, let d): return "rollback meta.json corrupt at \(p): \(d)"
        case .rollbackBundleNameInvalid(let n): return "rollback bundleName is not a safe path component: \(n)"
        case .underlying(let s): return s
        }
    }
}

// MARK: - Hashing / time

enum EvolutionSupport {
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Filesystem-safe id guard (Workshop executions receipt-path traversal-guard
    /// precedent). Refuse anything that could escape a directory.
    static func isSafePathComponent(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
            && !id.hasPrefix(".") && !id.contains("..")
    }

    /// Prefix-tolerant sha compare (matches SelfImprovementGitOps short/long
    /// HEAD convention). Nil/empty on either side is fail-closed: no match.
    static func shaMatches(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty,
              let b = b?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty
        else { return false }
        let n = min(a.count, b.count)
        guard n >= 7 else { return false } // refuse degenerate short prefixes
        return a.prefix(n).lowercased() == b.prefix(n).lowercased()
    }

    // MARK: - Env scrub

    /// Allowlist lifted verbatim from the daemon-era promotion engine
    /// (`_PROMOTION_ENV_ALLOWLIST`, the retired daemon at dc799383^):
    /// inheriting the full parent env leaks tokens (OPENAI_API_KEY,
    /// GITHUB_TOKEN, …) into an isolated child that doesn't need them and
    /// shouldn't have them.
    static let envAllowlist: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE",
        "TMPDIR", "TZ", "SHELL", "TERM",
        "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
    ]

    static func scrubbedEnvironment(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        source.filter { key, _ in
            envAllowlist.contains(key) || key.hasPrefix("LC_")
        }
    }

    /// Hermeticity overlay on top of the scrubbed base: candidate build/test
    /// children get a per-candidate HOME and TMPDIR so SwiftPM caches, plugin
    /// state, and tmp droppings land inside the candidate dir instead of the
    /// real user profile. XDG_* are re-pointed under the temp home for the
    /// same reason. This contains *mistakes* (a test that writes to $HOME),
    /// not malice — see the threat model in EvolutionCandidateBuilder.swift.
    static func hermeticEnvironment(
        base: [String: String],
        homeDir: URL,
        tmpDir: URL
    ) -> [String: String] {
        var env = base
        env["HOME"] = homeDir.path
        // macOS convention: TMPDIR carries a trailing slash.
        env["TMPDIR"] = tmpDir.path.hasSuffix("/") ? tmpDir.path : tmpDir.path + "/"
        env["XDG_DATA_HOME"] = homeDir.appendingPathComponent(".local/share").path
        env["XDG_CONFIG_HOME"] = homeDir.appendingPathComponent(".config").path
        env["XDG_CACHE_HOME"] = homeDir.appendingPathComponent(".cache").path
        return env
    }
}

// MARK: - Process running (no cooperative-pool pinning)

/// Single-resume latch for Process terminationHandler + cancellation +
/// spawn-failure races (ResumeGuard precedent from ChatOrchestrationClient's
/// runShellLikeProcess).
final class EvolutionResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

final class EvolutionTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func set() { lock.lock(); fired = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return fired }
}

/// Process is not Sendable; the timeout/cancellation closures need a handle.
/// Safe: every mutation site (terminate/kill) is guarded by the exited latch
/// and Process's own thread-safe state queries.
final class EvolutionProcessBox: @unchecked Sendable {
    let proc: Process
    init(_ p: Process) { self.proc = p }
}

struct EvolutionProcessResult: Sendable {
    var exit: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

extension EvolutionSupport {
    /// Run a process and wait WITHOUT blocking a cooperative-pool thread
    /// (terminationHandler + continuation, never waitUntilExit — the
    /// PersistenceCore+FileLock audit precedent). On timeout: SIGTERM, then
    /// SIGKILL after a 10s grace. Task cancellation terminates the child.
    ///
    /// `logURL` non-nil → stdout+stderr stream straight to that file (no pipe,
    /// no 64KB pipe-fill deadlock on long build output) and the returned
    /// stdout/stderr are empty. `logURL` nil → pipe capture, suitable ONLY for
    /// short-output commands (git plumbing); output is read after exit.
    static func run(
        _ arguments: [String],
        cwd: URL,
        environment: [String: String],
        timeout: TimeInterval,
        logURL: URL? = nil
    ) async throws -> EvolutionProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = arguments
        proc.currentDirectoryURL = cwd
        proc.environment = environment
        proc.standardInput = FileHandle.nullDevice

        var outPipe: Pipe?
        var errPipe: Pipe?
        var logHandle: FileHandle?
        if let logURL {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: logURL)
            try fh.seekToEnd()
            proc.standardOutput = fh
            proc.standardError = fh
            logHandle = fh
        } else {
            let op = Pipe()
            let ep = Pipe()
            proc.standardOutput = op
            proc.standardError = ep
            outPipe = op
            errPipe = ep
        }

        let box = EvolutionProcessBox(proc)
        let exited = EvolutionTimeoutFlag()
        let timedOutFlag = EvolutionTimeoutFlag()
        let guardLatch = EvolutionResumeGuard()

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    box.proc.terminationHandler = { _ in
                        exited.set()
                        if guardLatch.claim() { cont.resume(returning: ()) }
                    }
                    do {
                        try box.proc.run()
                    } catch {
                        exited.set()
                        if guardLatch.claim() {
                            cont.resume(throwing: EvolutionEngineError.spawnFailed(detail: "\(error)"))
                        }
                        return
                    }
                    let pid = box.proc.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard !exited.get() else { return }
                        timedOutFlag.set()
                        if box.proc.isRunning { box.proc.terminate() }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                            if !exited.get(), box.proc.isRunning { kill(pid, SIGKILL) }
                        }
                    }
                }
            } onCancel: {
                timedOutFlag.set()
                if box.proc.isRunning { box.proc.terminate() }
            }
        } catch {
            try? logHandle?.close()
            throw error
        }

        try? logHandle?.close()
        // Output buffered in the pipe; the child has exited so this read does
        // not block on a live writer. Short-output commands only (see doc).
        let stdout = outPipe.map {
            String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } ?? ""
        let stderr = errPipe.map {
            String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } ?? ""

        return EvolutionProcessResult(
            exit: proc.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOutFlag.get()
        )
    }
}
