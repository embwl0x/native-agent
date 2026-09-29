import Foundation

// MARK: - URLSession-backed HTTP client (production)

public final class URLSessionResearchHTTPClient: ResearchHTTPClient {
    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "NativeAgent/0.1") {
        self.session = session
        self.userAgent = userAgent
    }

    public func getBounded(url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> ResearchHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let collector = BoundedResearchDownload(limit: max(0, maxBytes))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            collector.cancel()
        }
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
        await run(arguments: ["ps", "--format", "{{json .}}"])
    }

    /// Ownership requires the explicitly configured container name as well as
    /// the local daemon, official image and configured loopback port.
    public func stoppedLocalSearXNG(base: String, containerName: String) async -> String? {
        guard !containerName.isEmpty,
              let url = URL(string: base), url.scheme == "http",
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        let environment = ProcessInfo.processInfo.environment
        let host: String?
        if let explicitHost = environment["DOCKER_HOST"], !explicitHost.isEmpty,
           environment["DOCKER_CONTEXT", default: ""].isEmpty {
            host = explicitHost
        } else {
            host = await run(arguments: ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
        }
        guard host?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://") == true,
              let ids = await run(arguments: ["ps", "--all", "--quiet", "--filter", "status=exited"])
        else { return nil }
        let candidates = ids.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !candidates.isEmpty, candidates.count <= 32,
              candidates.allSatisfy({ $0.allSatisfy(\.isHexDigit) }),
              let json = await run(arguments: ["inspect"] + candidates),
              let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        else { return nil }
        let matches = rows.filter { row in
            guard row["Name"] as? String == "/" + containerName,
                  let config = row["Config"] as? [String: Any],
                  let image = config["Image"] as? String,
                  let state = row["State"] as? [String: Any], state["Status"] as? String == "exited",
                  let hostConfig = row["HostConfig"] as? [String: Any],
                  let bindings = hostConfig["PortBindings"] as? [String: [[String: String]]],
                  let ports = bindings["8080/tcp"] else { return false }
            let repository = image.split(separator: "@").first.map(String.init)?
                .split(separator: ":").first.map(String.init)
            guard repository == "searxng/searxng" || repository == "docker.io/searxng/searxng",
                  ports.contains(where: {
                      $0["HostPort"] == String(url.port ?? 80)
                          && ["", "0.0.0.0", "127.0.0.1", "::", "::1"].contains($0["HostIp"] ?? "")
                  }) else { return false }
            return true
        }
        guard matches.count == 1, let row = matches.first,
              let imageID = row["Image"] as? String,
              let json = await run(arguments: ["image", "inspect", imageID]),
              let images = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
              let image = images.first,
              let defaults = image["Config"] as? [String: Any],
              let config = row["Config"] as? [String: Any],
              let digests = image["RepoDigests"] as? [String],
              digests.contains(where: {
                  $0.hasPrefix("searxng/searxng@sha256:") || $0.hasPrefix("docker.io/searxng/searxng@sha256:")
              }),
              config["Entrypoint"] as? [String] == defaults["Entrypoint"] as? [String],
              config["Cmd"] as? [String] == defaults["Cmd"] as? [String] else { return nil }
        return row["Id"] as? String
    }

    public func restartLocalSearXNG(base: String, containerName: String, containerID: String) async throws {
        guard await stoppedLocalSearXNG(base: base, containerName: containerName) == containerID,
              await run(arguments: ["start", containerID]) != nil else {
            throw ResearchClientError.transport("The identified local SearXNG container could not be restarted; its identity or state may have changed.")
        }
    }

    private func run(arguments: [String]) async -> String? {
        // Locate `docker` on PATH (matches Python's shutil.which).
        guard let dockerPath = Self.whichDocker() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = arguments
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
        //
        // HANG-PROOFING (2026-08-25): the previous shape parked this
        // continuation on `DispatchQueue.global().async { waitUntilExit() }`
        // with a separate 8s Task that only ever called `terminate()`. Under
        // full-suite subprocess churn the shared GCD pool starves — the queued
        // block never STARTS, so the continuation is never resumed even though
        // the child exited long ago (release-gauntlet wedge: 75+ min at 0% CPU
        // with no child process). Same landmine ToolExecution+RunSandbox
        // documents; same cure: a dedicated reap Thread that polls under the
        // deadline, escalates SIGTERM → grace → SIGKILL, and resumes the
        // continuation UNCONDITIONALLY. Worst case is bounded (~10s), never a
        // hang, with zero dependence on GCD scheduling.
        let pidRef = process
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let reaper = Thread {
                let deadline = Date().addingTimeInterval(8)
                while pidRef.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if pidRef.isRunning {
                    pidRef.terminate() // SIGTERM
                    let grace = Date().addingTimeInterval(2)
                    while pidRef.isRunning && Date() < grace {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    if pidRef.isRunning {
                        // SIGKILL by pid is reuse-safe HERE: the child is not
                        // yet reaped (waitUntilExit below is the reap), so the
                        // pid cannot be recycled. waitUntilExit after an
                        // unignorable SIGKILL returns promptly.
                        kill(pidRef.processIdentifier, SIGKILL)
                        pidRef.waitUntilExit()
                    }
                }
                cont.resume()
            }
            reaper.qualityOfService = .userInitiated
            reaper.start()
        }

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
