import Foundation

// MARK: - URLSession-backed HTTP client (production)

public final class URLSessionResearchHTTPClient: ResearchHTTPClient {
    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "NativeAgent/0.1") {
        self.session = session
        self.userAgent = userAgent
    }

    public func get(url: URL, timeout: TimeInterval) async throws -> (Int, Data, String?) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ResearchClientError.transport("non-HTTP response")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        return (http.statusCode, data, contentType)
    }
}

// MARK: - System `docker ps` executor (production)

/// Shells out to `docker ps --format '{{json .}}'` with an 8s deadline.
/// Returns nil if docker isn't on PATH or the call fails, matching
/// `Daemon.docker_searxng_candidates`'s `except Exception: return []`
/// branch.
public final class SystemDockerPSExecutor: DockerPSExecutor {
    public init() {}

    public func runJSONLines() async -> String? {
        // Locate `docker` on PATH (matches Python's shutil.which).
        guard let dockerPath = Self.whichDocker() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = ["ps", "--format", "{{json .}}"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stdout/stderr CONTINUOUSLY while docker runs. The old shape
        // (waitUntilExit BEFORE readDataToEndOfFile) deadlocked any docker
        // output larger than the ~64KB pipe buffer: docker blocked in
        // write(2), never exited, the 8s SIGTERM fired, and the call
        // misreported nil. Same pattern as ToolExecution+RunSandbox
        // (audit 2026-06-09; applied here 2026-06-10).
        let stdoutBuf = ResearchPipeCaptureBuffer()
        let stderrBuf = ResearchPipeCaptureBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stdoutBuf.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stderrBuf.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // 8s deadline matches Python's `timeout=8`.
        let pidRef = process
        let deadlineTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if pidRef.isRunning {
                pidRef.terminate()
            }
        }
        // waitUntilExit on a global queue via continuation — blocking the
        // cooperative-pool thread here would starve other tasks for the full
        // run (up to 8s on a hung docker).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                pidRef.waitUntilExit()
                cont.resume()
            }
        }
        deadlineTask.cancel()

        // Final drain: nil the handlers, then grab whatever is still buffered
        // WITHOUT blocking — a grandchild holding an inherited write end would
        // make an EOF-waiting read (readDataToEndOfFile) hang forever.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuf.appendNonBlockingDrain(from: stdoutPipe.fileHandleForReading)
        stderrBuf.appendNonBlockingDrain(from: stderrPipe.fileHandleForReading)

        if process.terminationStatus != 0 { return nil }
        return String(data: stdoutBuf.data, encoding: .utf8)
    }

    private static func whichDocker() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for dir in path.split(separator: ":") {
            let candidate = String(dir) + "/docker"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Thread-safe capture buffer for subprocess pipes — appended from
/// FileHandle's readabilityHandler queue, read after exit. Local copy of
/// ToolExecution's PipeCaptureBuffer (private there; same shape).
private final class ResearchPipeCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    /// Grab whatever is already buffered without waiting for EOF — a
    /// grandchild holding an inherited write end would make a blocking
    /// read wait forever.
    func appendNonBlockingDrain(from handle: FileHandle) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            append(Data(bytes: chunk, count: n))
        }
    }
}
