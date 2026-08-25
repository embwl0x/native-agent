import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import Research

// Eval coverage (ledger fence core.connectors) for the two Research PRODUCTION
// transports. Every existing Research test injects a stub for both, so neither
// real implementation had ever been executed by a test:
//   * URLSessionResearchHTTPClient supplies the Content-Type that fetchURL's
//     HTML-vs-raw decision hangs on (Research+SearchFetch.swift:102). If it
//     returned nil for a real text/html response every fetched page would be
//     persisted as raw markup.
//   * SystemDockerPSExecutor is the only subprocess spawn in this fence and
//     returns nil on EVERY failure mode, so a regression in the PATH lookup or
//     the pipe drain is indistinguishable from "no SearXNG container".
// Both suites are hermetic: a loopback URLProtocol and a fake `docker` script.

// MARK: - URLSessionResearchHTTPClient

/// Answers every request from a canned response — no socket is opened.
private final class ResearchStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastUserAgent: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastUserAgent = request.value(forHTTPHeaderField: "User-Agent")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: Self.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Research production HTTP transport", .serialized)
struct ResearchHTTPTransportTests {
    private func makeClient(
        status: Int,
        headers: [String: String],
        body: Data
    ) -> URLSessionResearchHTTPClient {
        ResearchStubURLProtocol.status = status
        ResearchStubURLProtocol.headers = headers
        ResearchStubURLProtocol.body = body
        ResearchStubURLProtocol.lastUserAgent = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResearchStubURLProtocol.self]
        return URLSessionResearchHTTPClient(
            session: URLSession(configuration: configuration),
            userAgent: "NativeAgent/test"
        )
    }

    // ResearchTransports.swift:23 — the header the sniff depends on must come
    // back verbatim, including the charset parameter (the sniff is a literal
    // `contains("html")`, so a stripped or lowercased-away header changes what
    // gets persisted).
    @Test
    func getReturnsTheContentTypeHeaderVerbatimWithTheStatusAndBody() async throws {
        let client = makeClient(
            status: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<p>hi</p>".utf8)
        )
        let (status, data, contentType) = try await client.get(
            url: try #require(URL(string: "https://page.example/doc")), timeout: 5
        )
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self) == "<p>hi</p>")
        #expect(contentType == "text/html; charset=utf-8")
        #expect(contentType?.contains("html") == true, "the HTML sniff at Research+SearchFetch.swift:102 depends on this")
        #expect(ResearchStubURLProtocol.lastUserAgent == "NativeAgent/test")
    }

    // A response with NO content type must surface as nil rather than an empty
    // string that could accidentally satisfy some future sniff.
    @Test
    func getReportsAMissingContentTypeAsNilAndCarriesNon2xxStatusThrough() async throws {
        let client = makeClient(status: 503, headers: [:], body: Data("nope".utf8))
        let (status, _, contentType) = try await client.get(
            url: try #require(URL(string: "https://page.example/down")), timeout: 5
        )
        // The caller (fetchURL) is what turns a non-2xx into an error; the
        // transport must report it rather than swallow it.
        #expect(status == 503)
        #expect(contentType == nil)
    }
}

// MARK: - SystemDockerPSExecutor

/// Named, diagnostic-bearing failure for a wedged executor call — the suite
/// must FAIL FAST, never hang a gauntlet run (nativeagent-hangproof).
private struct DockerExecutorDeadlineExceeded: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String {
        "SystemDockerPSExecutor.runJSONLines() did not complete within \(seconds)s — "
        + "an unbounded wait in the executor (the 2026-08-25 release-gauntlet wedge "
        + "class: unfulfilled continuation / starved GCD block). The call was abandoned."
    }
}

/// NSLock-guarded one-shot result box, polled by the test-side deadline.
private final class ExecutorResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var isSet = false
    func set(_ v: T) { lock.lock(); value = v; isSet = true; lock.unlock() }
    func get() -> (set: Bool, value: T?) {
        lock.lock(); defer { lock.unlock() }
        return (isSet, value)
    }
}

@Suite("Research docker autodetect transport", .serialized)
struct ResearchDockerTransportTests {
    /// Runs `runJSONLines()` under a hard test-side deadline: polls a result
    /// box every 50ms and throws `DockerExecutorDeadlineExceeded` if the
    /// executor never completes. The wedged task is ABANDONED (cancel is sent
    /// but not relied on — the wedge class is an uncancellable wait); the
    /// suite is .serialized and an abandoned wait idles at 0% CPU, so failing
    /// fast strictly beats wedging the suite. 60s is a generous positive-step
    /// bound (skill rule: production's own worst case is ~10s; this must only
    /// beat the infinite wedge, not race the scheduler).
    private func boundedRunJSONLines(
        _ executor: SystemDockerPSExecutor,
        deadline: TimeInterval = 60
    ) async throws -> String? {
        let box = ExecutorResultBox<String?>()
        let work = Task { box.set(await executor.runJSONLines()) }
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            let (isSet, value) = box.get()
            if isSet { return value ?? nil }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        work.cancel()
        throw DockerExecutorDeadlineExceeded(seconds: deadline)
    }

    /// Installs a fake `docker` on PATH and returns the executor's output.
    /// PATH is PREPENDED (never replaced) so nothing else in the process loses
    /// its own binaries, and restored before returning.
    private func withFakeDocker<T>(
        script: String,
        _ body: (SystemDockerPSExecutor) async throws -> T
    ) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-docker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("docker")
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: binary.path
        )

        let original = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        setenv("PATH", dir.path + ":" + original, 1)
        defer { setenv("PATH", original, 1) }
        return try await body(SystemDockerPSExecutor())
    }

    // The happy path this fence has never executed: docker found on PATH, JSON
    // lines returned intact.
    @Test
    func returnsEveryJSONLineWhenDockerExitsCleanly() async throws {
        let output = try await withFakeDocker(script: """
            #!/bin/sh
            printf '{"Names":"searxng"}\\n{"Names":"other"}\\n{"Names":"third"}\\n'
            """) { try await boundedRunJSONLines($0) }
        let lines = try #require(output).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.hasPrefix("{") })
    }

    // The regression the in-code comment at :48-53 records: output larger than
    // the ~64KB pipe buffer deadlocked the old waitUntilExit-then-read shape,
    // and the failure surfaced as a plain nil ("no containers"). Anything under
    // ~64KB cannot detect it.
    @Test
    func drainsOutputLargerThanThePipeBufferInsteadOfDeadlocking() async throws {
        let output = try await withFakeDocker(script: """
            #!/bin/sh
            head -c 200000 /dev/zero | tr '\\0' 'x'
            """) { try await boundedRunJSONLines($0) }
        #expect((output?.count ?? 0) >= 200_000)
    }

    // A non-zero exit is a real failure and must be nil, not partial output
    // that autodetect would try to parse.
    @Test
    func reportsNilWhenDockerExitsNonZero() async throws {
        let output = try await withFakeDocker(script: """
            #!/bin/sh
            echo '{"Names":"searxng"}'
            exit 3
            """) { try await boundedRunJSONLines($0) }
        #expect(output == nil)
    }

    // The 8s deadline is what keeps a wedged docker from stalling autodetect.
    // Asserted as an upper BOUND (not a tight timing), which is what the code
    // actually promises.
    @Test
    func boundsAHungDockerWithTheTerminationDeadline() async throws {
        let started = Date()
        let output = try await withFakeDocker(script: """
            #!/bin/sh
            sleep 30
            """) { try await boundedRunJSONLines($0) }
        let elapsed = Date().timeIntervalSince(started)
        #expect(output == nil)
        #expect(elapsed < 20, "the 8s SIGTERM deadline did not bound the call (took \(elapsed)s)")
    }
}
