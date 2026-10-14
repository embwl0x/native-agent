import Foundation
import NativeAgentCore
import MacControl

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
/// `noBackend` means this Mac has no SearXNG to start at all.
public struct SearXNGStartError: LocalizedError, Sendable {
    public let message: String
    public var noBackend = false
    public var errorDescription: String? { message }
}

/// Shells out to `docker ps --format '{{json .}}'` with an 8s deadline.
/// Returns nil if docker isn't on PATH or the call fails, matching
/// `Daemon.docker_searxng_candidates`'s `except Exception: return []`
/// branch.
public final class SystemDockerPSExecutor: Sendable {
    public init() {}

    public func runJSONLines() async -> String? {
        await run(arguments: ["ps", "--format", "{{json .}}"])
    }

    /// Starts the stopped SearXNG container that serves the configured
    /// loopback address, starting Docker Desktop first when its daemon is
    /// down. The container is discovered, never named by hand: the official
    /// image, its default entrypoint, and a binding of 8080/tcp to the
    /// configured port. Returns the started container id; throws a plain
    /// sentence saying why nothing could be started.
    /// `mayOpenDockerDesktop` false leaves a stopped Docker daemon alone.
    public func startLocalSearXNG(base: String, mayOpenDockerDesktop: Bool = true) async throws -> String {
        func fail(_ message: String, noBackend: Bool = false) -> SearXNGStartError {
            SearXNGStartError(message: message, noBackend: noBackend)
        }
        guard let url = URL(string: base), url.scheme == "http",
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw fail("SearXNG is configured at a non-local address, so there is no container on this Mac to start.")
        }
        guard let dockerPath = Self.whichDocker() else {
            throw fail("Docker is not installed, so no local SearXNG container exists to start.", noBackend: true)
        }
        if await run(arguments: ["info", "--format", "{{.ServerVersion}}"]) == nil {
            guard mayOpenDockerDesktop else {
                throw fail("Docker is not running, and when it last ran it held no SearXNG container.", noBackend: true)
            }
            try await startDockerDesktop(dockerPath: dockerPath)
        }
        let environment = ProcessInfo.processInfo.environment
        let host: String?
        if let explicitHost = environment["DOCKER_HOST"], !explicitHost.isEmpty,
           environment["DOCKER_CONTEXT", default: ""].isEmpty {
            host = explicitHost
        } else {
            host = await run(arguments: ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
        }
        guard host?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://") == true else {
            throw fail("Docker points at a remote daemon, so no local SearXNG container can be started.")
        }
        let port = String(url.port ?? 80)
        // Only a complete listing with no SearXNG in it means "no backend";
        // a listing Docker could not give is an error.
        guard let ids = await run(arguments: ["ps", "--all", "--quiet"]) else {
            throw fail("Docker could not list its containers, so Doctor could not look for SearXNG.")
        }
        let candidates = ids.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { $0.allSatisfy(\.isHexDigit) }
        var rows: [[String: Any]] = []
        if !candidates.isEmpty {
            guard let json = await run(arguments: ["inspect"] + candidates),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
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
            throw fail("Docker holds no SearXNG container, so there is no search backend on this Mac to start.", noBackend: true)
        }
        let serving = searxng.filter { row in
            guard let hostConfig = row["HostConfig"] as? [String: Any],
                  let bindings = hostConfig["PortBindings"] as? [String: [[String: String]]],
                  let ports = bindings["8080/tcp"] else { return false }
            return ports.contains(where: {
                $0["HostPort"] == port
                    && ["", "0.0.0.0", "127.0.0.1", "::", "::1"].contains($0["HostIp"] ?? "")
            })
        }
        func state(_ row: [String: Any]) -> String? {
            (row["State"] as? [String: Any])?["Status"] as? String
        }
        guard !serving.isEmpty else {
            throw fail("Docker's SearXNG container does not serve port \(port), the configured search address.")
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
              config["Cmd"] as? [String] == defaults["Cmd"] as? [String] else {
            throw fail("\(matches.count) stopped SearXNG containers claim port \(port) or run a modified image, so Doctor will not pick one to start.")
        }
        guard await run(arguments: ["start", id]) != nil else {
            throw fail("Docker refused to start the SearXNG container \(id.prefix(12)).")
        }
        return id
    }

    /// Opens the Docker Desktop app that ships this `docker` CLI and waits up
    /// to 90 seconds for its daemon to answer.
    private func startDockerDesktop(dockerPath: String) async throws {
        var app = URL(fileURLWithPath: dockerPath).resolvingSymlinksInPath()
        while app.pathComponents.count > 1, app.pathExtension != "app" {
            app.deleteLastPathComponent()
        }
        guard app.pathExtension == "app",
              await runResearchSubprocess(executable: "/usr/bin/open", arguments: ["-g", app.path], timeout: 8)?.exitCode == 0
        else {
            throw SearXNGStartError(message: "Docker's daemon is not running and no Docker Desktop app was found to start it.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        repeat {
            try await Task.sleep(for: .seconds(3))
            if await run(arguments: ["info", "--format", "{{.ServerVersion}}"]) != nil { return }
        } while ContinuousClock.now < deadline
        throw SearXNGStartError(message: "Docker Desktop was opened but its daemon did not answer within 90 seconds.")
    }

    private func run(arguments: [String]) async -> String? {
        // Locate `docker` on PATH (matches Python's shutil.which).
        guard let dockerPath = Self.whichDocker(),
              let result = await runResearchSubprocess(executable: dockerPath, arguments: arguments, timeout: 8),
              result.exitCode == 0 else { return nil }
        return result.stdout
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

/// Run a subprocess under a deadline with stdin closed; nil when it cannot
/// start. Shared by the docker probes (8s) and Codex web search (60s).
func runResearchSubprocess(
    executable: String, arguments: [String], environment: [String: String]? = nil,
    cwd: URL? = nil, timeout: TimeInterval
) async -> ProcessRunResult? {
    guard !Task.isCancelled else { return nil }
    return try? await SystemProcessAdapter().run(
        executable: executable, arguments: arguments, currentDirectory: cwd,
        environment: environment, standardInput: nil, timeoutSeconds: timeout,
        outputByteLimit: Int.max
    )
}
