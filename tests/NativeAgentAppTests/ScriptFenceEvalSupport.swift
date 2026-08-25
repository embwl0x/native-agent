import Foundation

/// Shared helpers for the `scripts` fence evals (docs/evals/ledger.json).
///
/// These evals treat `script/` as a PRODUCTION surface: nothing here edits a
/// shell gate, it only asserts observable properties of one. Two flavours:
///
///  * WIRING evals read the scripts as text and assert that what one script
///    names still exists in another (the "dead step" / "orphan suite" class).
///  * BEHAVIOUR evals copy a script into a throwaway fixture root, put stubs
///    ahead of it on PATH, run it, and assert on exit code + observed effect.
///
/// Everything is hermetic: fixtures live under a per-test temp dir, and no eval
/// in this fence ever runs against the checkout's `data/` or `persona/`.
enum ScriptFenceEval {
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path), u.path != "/" {
            u.deleteLastPathComponent()
        }
        return u
    }()

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func names(in directory: String, suffix: String) -> [String] {
        let path = repo.appendingPathComponent(directory).path
        let all = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return all.filter { $0.hasSuffix(suffix) }.sorted()
    }

    // MARK: - Hermetic fixtures

    static func makeTempDir(_ label: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nativeagent-scripts-eval-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func write(_ contents: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// Copy one repo script into a fixture root at the SAME relative path, so
    /// its own `dirname $0/..` root resolution lands inside the fixture.
    @discardableResult
    static func copyScript(_ relativePath: String, into root: URL) throws -> URL {
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: repo.appendingPathComponent(relativePath), to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    // MARK: - Bounded subprocess

    struct RunResult {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var combined: String { stdout + stderr }
    }

    /// Run a command with a hard deadline. Drains both pipes on dedicated
    /// threads (a GCD pool starves under concurrent subprocess load and
    /// silently truncates to empty), and escalates SIGTERM -> SIGKILL through
    /// the Process object rather than a raw pid.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 180
    ) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        func drain(_ pipe: Pipe, into sink: @escaping (Data) -> Void) -> Thread {
            let thread = Thread {
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    sink(chunk)
                }
            }
            thread.stackSize = 512 * 1024
            thread.start()
            return thread
        }
        let outThread = drain(outPipe) { chunk in lock.lock(); outData.append(chunk); lock.unlock() }
        let errThread = drain(errPipe) { chunk in lock.lock(); errData.append(chunk); lock.unlock() }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                let hardDeadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < hardDeadline { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        let joinDeadline = Date().addingTimeInterval(5)
        while (!outThread.isFinished || !errThread.isFinished), Date() < joinDeadline { usleep(10_000) }
        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()
        return RunResult(status: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
    }

    static func bash(_ script: String, cwd: URL? = nil, environment: [String: String]? = nil,
                     timeout: TimeInterval = 180) throws -> RunResult {
        try run("/bin/bash", ["-c", script], cwd: cwd, environment: environment, timeout: timeout)
    }

    /// A minimal, deterministic environment for fixture runs: real tools stay
    /// reachable, but `stubDir` (when given) shadows them.
    static func environment(stubDir: URL?, extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let base = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = stubDir.map { "\($0.path):\(base)" } ?? base
        env["NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX"] = nil
        for (k, v) in extra { env[k] = v }
        return env
    }
}
