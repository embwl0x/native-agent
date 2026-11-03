import Foundation
import NativeAgentCore
import MacControl
// Blueprint: | `ResearchTransports.swift` | `URLSessionResearchHTTPClient.getBounded`; Docker discovery/start retains daemon readiness polling at 3-second intervals within its 90-second window, with no confirmed push replacement; subprocesses delegate to `MacControl.ProcessExecution` with full output capture |

// MARK: - URLSession-backed HTTP client (production)

public final class URLSessionResearchHTTPClient: Sendable {
    public init() {}

    public func getBounded(
        url: URL, timeout: TimeInterval, maxBytes: Int, pdfMaxBytes: Int? = nil
    ) async throws -> ResearchHTTPResponse {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("NativeAgent/0.1", forHTTPHeaderField: "User-Agent")
        let configuration = URLSession.shared.configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let collector = BoundedResearchDownload(limit: max(0, maxBytes), pdfLimit: pdfMaxBytes.map { max(0, $0) })
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            collector.cancel()
        }
    }
}

// MARK: - System `docker ps` executor (production)

/// Why a local SearXNG container could not be started, in one sentence.
public struct SearXNGStartError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Shells out to `docker ps --format '{{json .}}'` with an 8s deadline.
/// Nil means no Docker executable. Execution failures throw with their cause.
public final class SystemDockerPSExecutor: Sendable {
    public init() {}

    public func runJSONLines() async throws -> String? {
        guard Self.whichDocker() != nil else { return nil }
        try await requireLocalDaemon()
        return try await run(arguments: ["ps", "--format", "{{json .}}"])
    }

    /// Starts the stopped SearXNG container that serves the configured
    /// loopback address, starting Docker Desktop first when its daemon is
    /// down. The container is discovered, never named by hand: the official
    /// image, its default entrypoint, and a binding of 8080/tcp to the
    /// configured port. Returns the started container id; throws a plain
    /// sentence saying why nothing could be started.
    /// `mayOpenDockerDesktop` false leaves a stopped Docker daemon alone.
    public func startLocalSearXNG(base: String, mayOpenDockerDesktop: Bool = true) async throws -> String {
        func fail(_ message: String) -> SearXNGStartError {
            SearXNGStartError(message: message)
        }
        guard let url = URL(string: base), url.scheme == "http",
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw fail("SearXNG is configured at a non-local address, so there is no container on this Mac to start.")
        }
        guard let dockerPath = Self.whichDocker() else {
            throw fail("Docker is not installed, so no local SearXNG container exists to start.")
        }
        try await requireLocalDaemon()
        do {
            _ = try await run(arguments: ["info", "--format", "{{.ServerVersion}}"])
        } catch where Task.isCancelled || error is CancellationError || error is ProcessRunCancellation {
            throw CancellationError()
        } catch {
            guard mayOpenDockerDesktop else {
                throw fail("Docker inventory is unavailable: \(error.localizedDescription). Use Repair to open Docker Desktop and check the configured server.")
            }
            try await startDockerDesktop(dockerPath: dockerPath)
        }
        let port = String(url.port ?? 80)
        // Only a complete listing with no SearXNG in it means "no backend";
        // a listing Docker could not give is an error.
        let ids = try await run(arguments: ["ps", "--all", "--quiet"])
        let candidates = ids.split(whereSeparator: \.isWhitespace).map(String.init)
        guard candidates.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else {
            throw fail("Docker returned malformed container identities; its inventory is unavailable.")
        }
        var rows: [[String: Any]] = []
        if !candidates.isEmpty {
            let json = try await run(arguments: ["inspect"] + candidates)
            guard let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
                  parsed.count == candidates.count,
                  parsed.allSatisfy({ ($0["Config"] as? [String: Any])?["Image"] is String }) else {
                throw fail("Docker could not describe its containers, so Doctor could not look for SearXNG.")
            }
            rows = parsed
        }
        let searxng = rows.filter { row in
            guard let config = row["Config"] as? [String: Any],
                  let image = config["Image"] as? String else { return false }
            let repository = image.split(separator: "@").first.map(String.init)?
                .split(separator: ":").first.map(String.init)
            return repository == "searxng/searxng" || repository == "docker.io/searxng/searxng"
        }
        guard !searxng.isEmpty else {
            throw fail("Docker holds no SearXNG container, so there is no search backend on this Mac to start.")
        }
        let serving = searxng.filter { row in
            guard let hostConfig = row["HostConfig"] as? [String: Any],
                  let bindings = hostConfig["PortBindings"] as? [String: [[String: String]]],
                  let ports = bindings["8080/tcp"] else { return false }
            return ports.contains(where: {
                $0["HostPort"] == port
                    && $0["HostIp"].map { ["", "0.0.0.0", "127.0.0.1", "::", "::1"].contains($0) } == true
            })
        }
        func state(_ row: [String: Any]) -> String? {
            (row["State"] as? [String: Any])?["Status"] as? String
        }
        guard !serving.isEmpty else {
            throw fail("Docker's inventory did not establish a SearXNG container serving port \(port), the configured search address.")
        }
        guard !serving.contains(where: { state($0) == "running" }) else {
            throw fail("A SearXNG container is running on port \(port) but does not answer search.")
        }
        let matches = serving.filter { ["exited", "created"].contains(state($0) ?? "") }
        guard !matches.isEmpty else {
            throw fail("The SearXNG container on port \(port) is \(serving.compactMap(state).first ?? "in an unknown state"), so Doctor will not start it.")
        }
        guard matches.count == 1, let row = matches.first,
              let id = row["Id"] as? String,
              let imageID = row["Image"] as? String else {
            throw fail("SearXNG container identity is unavailable or ambiguous for port \(port); Doctor will not pick one to start.")
        }
        let json = try await run(arguments: ["image", "inspect", imageID])
        guard let images = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
              let image = images.first,
              let defaults = image["Config"] as? [String: Any],
              let config = row["Config"] as? [String: Any],
              let digests = image["RepoDigests"] as? [String],
              digests.contains(where: {
                  $0.hasPrefix("searxng/searxng@sha256:") || $0.hasPrefix("docker.io/searxng/searxng@sha256:")
              }) else {
            throw fail("\(matches.count) stopped SearXNG containers claim port \(port) or run a modified image, so Doctor will not pick one to start.")
        }
        func command(_ object: [String: Any], _ key: String) throws -> [String]? {
            guard let raw = object[key] else { throw fail("Docker image metadata is missing Config.\(key).") }
            if raw is NSNull { return nil }
            guard let arguments = raw as? [String] else { throw fail("Docker image metadata has unreadable Config.\(key).") }
            return arguments
        }
        guard try command(config, "Entrypoint") == command(defaults, "Entrypoint"),
              try command(config, "Cmd") == command(defaults, "Cmd") else {
            throw fail("The SearXNG container on port \(port) runs modified image commands; Doctor will not start it.")
        }
        _ = try await run(arguments: ["start", id])
        return id
    }

    /// Opens the Docker Desktop app that ships this `docker` CLI and waits up
    /// to 90 seconds for its daemon to answer.
    private func startDockerDesktop(dockerPath: String) async throws {
        var app = URL(fileURLWithPath: dockerPath).resolvingSymlinksInPath()
        while app.pathComponents.count > 1, app.pathExtension != "app" {
            app.deleteLastPathComponent()
        }
        guard app.pathExtension == "app" else {
            throw SearXNGStartError(message: "Docker's daemon is not running and no Docker Desktop app was found to start it.")
        }
        _ = try await runResearchSubprocess(executable: "/usr/bin/open", arguments: ["-g", app.path], timeout: 8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        var lastFailure = "Docker's daemon has not answered."
        repeat {
            try await Task.sleep(for: .seconds(3))
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let timeout = min(8, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
            guard timeout > 0 else { break }
            do {
                _ = try await run(arguments: ["info", "--format", "{{.ServerVersion}}"], timeout: timeout)
                return
            } catch where Task.isCancelled || error is CancellationError || error is ProcessRunCancellation {
                throw CancellationError()
            } catch { lastFailure = error.localizedDescription }
        } while ContinuousClock.now < deadline
        throw SearXNGStartError(message: "Docker Desktop was opened but its daemon did not answer within 90 seconds: \(lastFailure)")
    }

    private func run(arguments: [String], timeout: TimeInterval = 8) async throws -> String {
        guard let dockerPath = Self.whichDocker() else {
            throw SearXNGStartError(message: "Docker executable is unavailable.")
        }
        return try await runResearchSubprocess(executable: dockerPath, arguments: arguments, timeout: timeout).stdout
    }

    private func requireLocalDaemon() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host: String
        if let explicitHost = environment["DOCKER_HOST"], !explicitHost.isEmpty,
           environment["DOCKER_CONTEXT", default: ""].isEmpty {
            host = explicitHost
        } else {
            host = try await run(arguments: ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
        }
        guard host.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://") else {
            throw SearXNGStartError(message: "Docker's context does not identify a local Unix-socket daemon; local SearXNG inventory is unavailable.")
        }
    }

    private static func whichDocker() -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            + ":/usr/local/bin:" + NSHomeDirectory() + "/.docker/bin"
        for dir in path.split(separator: ":") {
            let candidate = String(dir) + "/docker"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Docker's one checked subprocess owner; failure is never an empty inventory.
func runResearchSubprocess(
    executable: String, arguments: [String], environment: [String: String]? = nil,
    cwd: URL? = nil, timeout: TimeInterval
) async throws -> ProcessRunResult {
    try Task.checkCancellation()
    let result = try await ProcessExecution().run(
        executable: executable, arguments: arguments, currentDirectory: cwd,
        environment: environment, standardInput: nil, timeoutSeconds: timeout,
        outputByteLimit: Int.max
    )
    guard !result.timedOut, result.exitCode == 0 else {
        throw SearXNGStartError(message: "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " ")) \(result.timedOut ? "timed out" : "exited \(result.exitCode)"): \(result.stderr.prefix(600))")
    }
    return result
}
