import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import Research

// MARK: - Test stubs

/// HTTP client stub. Actor-backed for Swift 6 async safety. Keyed on the
/// FULL URL string. Each fixture is (status, body). Missing key → throws
/// ResearchClientError.transport so callers can distinguish "no fixture"
/// from "fixture says 500".
actor _ResearchHTTPStub: ResearchHTTPClient {
    private var fixtures: [String: (Int, Data, String?)] = [:]
    private(set) var requests: [(URL, TimeInterval)] = []

    func set(_ url: String, status: Int, body: Data, contentType: String? = nil) {
        fixtures[url] = (status, body, contentType)
    }

    func get(url: URL, timeout: TimeInterval) async throws -> (Int, Data, String?) {
        requests.append((url, timeout))
        if let fix = fixtures[url.absoluteString] { return fix }
        throw ResearchClientError.transport("no fixture for \(url.absoluteString)")
    }
}

/// `docker ps` stub returning canned stdout.
final class _DockerStub: DockerPSExecutor, @unchecked Sendable {
    let stdout: String?
    init(_ stdout: String?) { self.stdout = stdout }
    func runJSONLines() async -> String? { stdout }
}

// MARK: - Helpers

private func makeTempDir() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ResearchTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readJSONFile(_ url: URL) -> JSONValue? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONValue.parse(data)
}

/// Builds a SwiftNativeResearchClient with ALL FIVE path overrides pinned
/// inside `tmp`. The production constructor defaults every non-overridden
/// path to PersistenceCore.defaultDataRoot(), which under `swift test`
/// resolves to the LIVE repo data/ tree — so every test construction MUST
/// go through this helper or it pollutes data/activity + data/traces.
/// Per-path params let a test point an individual override somewhere
/// specific; the remaining constructor params pass straight through with
/// the production defaults.
private func makeHermeticClient(
    in tmp: URL,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
    http: any ResearchHTTPClient = URLSessionResearchHTTPClient(),
    docker: any DockerPSExecutor = SystemDockerPSExecutor(),
    configPathOverride: URL? = nil,
    receiptsDirOverride: URL? = nil,
    labRunsPathOverride: URL? = nil,
    activityPathOverride: URL? = nil,
    tracesPathOverride: URL? = nil,
    userAgent: String = "NativeAgent/0.1",
    now: @escaping @Sendable () -> Date = { Date() },
    receiptIDFactory: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
) -> SwiftNativeResearchClient {
    SwiftNativeResearchClient(
        persistence: persistence,
        http: http,
        docker: docker,
        configPathOverride: configPathOverride ?? tmp.appendingPathComponent("config/config.json"),
        receiptsDirOverride: receiptsDirOverride ?? tmp.appendingPathComponent("research"),
        labRunsPathOverride: labRunsPathOverride ?? tmp.appendingPathComponent("research/lab/runs.json"),
        activityPathOverride: activityPathOverride ?? tmp.appendingPathComponent("activity/events.jsonl"),
        tracesPathOverride: tracesPathOverride ?? tmp.appendingPathComponent("traces/events.jsonl"),
        userAgent: userAgent,
        now: now,
        receiptIDFactory: receiptIDFactory
    )
}

// MARK: - autodetect: happy path (first common-port responds)

@Test func autodetectFirstCommonPortRespondsAndPersists() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let receiptsDir = tmp.appendingPathComponent("research")

    let http = _ResearchHTTPStub()
    // First common-port candidate (http://127.0.0.1:8888) responds with the
    // exact `nativeagent` query the daemon issues — body just needs a
    // `results` key.
    await http.set("http://127.0.0.1:8888/search?q=nativeagent&format=json",
                   status: 200, body: Data(#"{"results": []}"#.utf8))

    let client = makeHermeticClient(
        in: tmp,
        http: http,
        docker: _DockerStub(nil),
        configPathOverride: configPath,
        receiptsDirOverride: receiptsDir
    )
    let result = try await client.autodetectSearXNG()

    #expect(result.found == true)
    #expect(result.baseURL == "http://127.0.0.1:8888")
    #expect(result.source == "common-port")
    #expect(result.error == nil)

    // Persisted to data/config/config.json under `searxng_base_url`.
    let persisted = readJSONFile(configPath)
    if case .object(let obj) = persisted ?? .null,
       case .string(let s) = obj["searxng_base_url"] ?? .null {
        #expect(s == "http://127.0.0.1:8888")
    } else {
        Issue.record("config.json missing searxng_base_url")
    }
}

// MARK: - autodetect: deterministic candidate ORDER

@Test func autodetectProbesCommonPortsInDeterministicOrder() async throws {
    let tmp = makeTempDir()
    let http = _ResearchHTTPStub()
    // No fixture set → every probe throws transport, every check returns
    // false, autodetect returns found=false.
    let client = makeHermeticClient(in: tmp, http: http, docker: _DockerStub(nil))
    let result = try await client.autodetectSearXNG()
    #expect(result.found == false)
    #expect(result.error == "No reachable SearXNG instance found")

    // Daemon's seed order: 127.0.0.1:8888, 127.0.0.1:8080, localhost:8888,
    // localhost:8080. Must be probed in that order (no others).
    let urls = await http.requests.map(\.0.absoluteString)
    let expected = [
        "http://127.0.0.1:8888/search?q=nativeagent&format=json",
        "http://127.0.0.1:8080/search?q=nativeagent&format=json",
        "http://localhost:8888/search?q=nativeagent&format=json",
        "http://localhost:8080/search?q=nativeagent&format=json",
    ]
    #expect(urls == expected, "candidate order drifted; got \(urls)")
}

// MARK: - autodetect: docker fallback

@Test func autodetectFallsBackToDockerCandidate() async throws {
    let tmp = makeTempDir()
    let http = _ResearchHTTPStub()
    // None of the common ports respond.
    // Docker reports one searxng container on host port 9999.
    let dockerLine = #"{"Image": "searxng/searxng:latest", "Names": "my-searxng", "Labels": "", "Ports": "0.0.0.0:9999->8080/tcp"}"#
    await http.set("http://127.0.0.1:9999/search?q=nativeagent&format=json",
             status: 200, body: Data(#"{"results": [{"title":"x","url":"y"}]}"#.utf8))

    let client = makeHermeticClient(in: tmp, http: http, docker: _DockerStub(dockerLine))
    let result = try await client.autodetectSearXNG()
    #expect(result.found == true)
    #expect(result.baseURL == "http://127.0.0.1:9999")
    #expect(result.source == "docker")
}

// MARK: - autodetect: dedup by base URL

@Test func autodetectDedupesBaseURLs() async throws {
    let tmp = makeTempDir()
    let http = _ResearchHTTPStub()
    // Docker emits a duplicate of 127.0.0.1:8888 — should NOT be probed twice.
    let dockerLine = #"{"Image": "searxng/searxng", "Names": "dup", "Labels": "", "Ports": "0.0.0.0:8888->8080/tcp"}"#
    let client = makeHermeticClient(in: tmp, http: http, docker: _DockerStub(dockerLine))
    _ = try await client.autodetectSearXNG()
    let probedHosts = await http.requests.map { $0.0.absoluteString }
    let count8888 = probedHosts.filter { $0.contains("127.0.0.1:8888") }.count
    #expect(count8888 == 1, "duplicate base URL was probed \(count8888) times")
}

// MARK: - autodetect: docker timeout matches Python

@Test func autodetectDockerHaystackRequiresSearxngToken() async throws {
    let tmp = makeTempDir()
    let http = _ResearchHTTPStub()
    // Docker reports a NON-searxng container — must be ignored.
    let dockerLine = #"{"Image": "nginx", "Names": "frontend", "Labels": "", "Ports": "0.0.0.0:9999->80/tcp"}"#
    let client = makeHermeticClient(in: tmp, http: http, docker: _DockerStub(dockerLine))
    _ = try await client.autodetectSearXNG()
    let urls = await http.requests.map(\.0.absoluteString)
    #expect(!urls.contains(where: { $0.contains(":9999") }),
            "non-searxng container should not be probed")
}

// MARK: - search: not-configured throws

@Test func searchThrowsWhenBaseURLNotConfigured() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    // Write a config WITHOUT searxng_base_url.
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: configPath)

    let client = makeHermeticClient(
        in: tmp,
        http: _ResearchHTTPStub(),
        docker: _DockerStub(nil),
        configPathOverride: configPath
    )
    do {
        _ = try await client.search(query: "anything")
        Issue.record("expected ResearchClientError.notConfigured")
    } catch ResearchClientError.notConfigured {
        // pass
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func searchThrowsWhenBaseURLEmpty() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": ""}"#.utf8).write(to: configPath)

    let client = makeHermeticClient(
        in: tmp,
        http: _ResearchHTTPStub(),
        docker: _DockerStub(nil),
        configPathOverride: configPath
    )
    do {
        _ = try await client.search(query: "x")
        Issue.record("expected ResearchClientError.notConfigured")
    } catch ResearchClientError.notConfigured {} catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - search: happy path + receipt + response shape

@Test func searchParsesResultsWritesReceiptReturnsCorrectShape() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let receiptsDir = tmp.appendingPathComponent("research")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Use a base with trailing slash to exercise rstrip.
    try Data(#"{"searxng_base_url": "http://searx.example.com/"}"#.utf8).write(to: configPath)

    let body = #"""
    {
      "results": [
        {"title": "First", "url": "https://a.example", "content": "snippet-a", "engines": ["google", "bing"]},
        {"title": "", "url": "https://b.example", "content": "snippet-b", "engine": "duckduckgo"},
        {"url": "https://c.example", "content": "snippet-c"},
        {"title": "D", "content": "snippet-d"}
      ]
    }
    """#
    let http = _ResearchHTTPStub()
    await http.set("http://searx.example.com/search?q=nativeagent%20vs%20codex&format=json",
             status: 200, body: Data(body.utf8))

    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let fixedID = "rcpt-1234"
    let client = makeHermeticClient(
        in: tmp,
        http: http,
        docker: _DockerStub(nil),
        configPathOverride: configPath,
        receiptsDirOverride: receiptsDir,
        now: { fixedNow },
        receiptIDFactory: { fixedID }
    )

    let resp = try await client.search(query: "nativeagent vs codex")

    // 4 input rows, all kept (no slice past 10).
    #expect(resp.results.count == 4)

    // Row 1: title preserved, source = engines joined by ",".
    #expect(resp.results[0].title == "First")
    #expect(resp.results[0].url == "https://a.example")
    #expect(resp.results[0].snippet == "snippet-a")
    #expect(resp.results[0].source == "google,bing")

    // Row 2: title falls back to url (empty string → url), source = scalar engine.
    #expect(resp.results[1].title == "https://b.example")
    #expect(resp.results[1].source == "duckduckgo")

    // Row 3: no title → url; no engine/engines → nil source.
    #expect(resp.results[2].title == "https://c.example")
    #expect(resp.results[2].source == nil)

    // Row 4: title "D" preserved (no url present), url="", snippet kept.
    // (For the "Untitled" fallback see searchUntitledFallbackWhenNoTitleAndNoURL.)
    #expect(resp.results[3].title == "D")
    #expect(resp.results[3].url == "")
    #expect(resp.results[3].snippet == "snippet-d")

    // Receipt written to data/research/<id>.json with exact field set.
    let receiptPath = receiptsDir.appendingPathComponent("\(fixedID).json")
    guard let receipt = readJSONFile(receiptPath),
          case .object(let obj) = receipt else {
        Issue.record("receipt missing or not an object"); return
    }
    if case .string(let s) = obj["id"] ?? .null { #expect(s == fixedID) } else { Issue.record("id missing") }
    if case .string(let s) = obj["query"] ?? .null { #expect(s == "nativeagent vs codex") } else { Issue.record("query missing") }
    if case .string(let s) = obj["url"] ?? .null {
        // Trailing slash stripped from base; URL contains the configured query.
        #expect(s.hasPrefix("http://searx.example.com/search?"))
        #expect(s.contains("format=json"))
    } else { Issue.record("url missing") }
    if case .array(let arr) = obj["results"] ?? .null {
        #expect(arr.count == 4)
    } else { Issue.record("results missing") }
    if case .string(let s) = obj["createdAt"] ?? .null {
        // ISO-8601 with +00:00 suffix (matches Python now_iso()).
        #expect(s.hasSuffix("+00:00"), "createdAt does not end in +00:00: \(s)")
    } else { Issue.record("createdAt missing") }
}

// MARK: - search: title fallback chain — only "Untitled" when BOTH title AND url are empty

@Test func searchUntitledFallbackWhenNoTitleAndNoURL() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": "http://searx.example"}"#.utf8).write(to: configPath)

    // One row: NO title, NO url, just content. Python's `item.get("title")
    // or item.get("url") or "Untitled"` → "Untitled".
    let body = #"{"results": [{"content": "snippet-only"}]}"#
    let http = _ResearchHTTPStub()
    await http.set("http://searx.example/search?q=q&format=json",
                   status: 200, body: Data(body.utf8))

    let client = makeHermeticClient(
        in: tmp,
        http: http,
        docker: _DockerStub(nil),
        configPathOverride: configPath
    )
    let resp = try await client.search(query: "q")
    #expect(resp.results.count == 1)
    #expect(resp.results[0].title == "Untitled")
    #expect(resp.results[0].url == "")
}

// MARK: - search: caps at first 10 results

/// 2026-07-21 audit: search/fetch wrote one receipt JSON per call with no
/// retention. The prune must keep the newest N receipt files, and never
/// touch config.json or the lab ledger sharing the same directory.
@Test func receiptRetentionKeepsNewestAndSparesNonReceipts() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let receiptsDir = tmp.appendingPathComponent("research")
    let labDir = receiptsDir.appendingPathComponent("lab")
    try FileManager.default.createDirectory(at: labDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": "http://searx.example"}"#.utf8).write(to: configPath)
    try Data("[]".utf8).write(to: labDir.appendingPathComponent("runs.json"))
    try Data("{}".utf8).write(to: receiptsDir.appendingPathComponent("config.json"))

    // Seed limit+5 receipts with strictly increasing mtimes (oldest first).
    let seeded = SwiftNativeResearchClient.receiptRetentionLimit + 5
    var oldestNames: [String] = []
    for i in 0..<seeded {
        let name = "\(UUID().uuidString.lowercased()).json"
        if i < 6 { oldestNames.append(name) }
        let url = receiptsDir.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000 + Double(i))],
            ofItemAtPath: url.path)
    }

    let http = _ResearchHTTPStub()
    await http.set("http://searx.example/search?q=q\u{0026}format=json", status: 200,
                   body: Data(#"{"results": []}"#.utf8))
    let client = makeHermeticClient(
        in: tmp, http: http, docker: _DockerStub(nil),
        configPathOverride: configPath, receiptsDirOverride: receiptsDir)
    _ = try await client.search(query: "q")

    let files = try FileManager.default.contentsOfDirectory(atPath: receiptsDir.path)
    let receipts = files.filter { name in
        let stem = String(name.dropLast(".json".count))
        return name.hasSuffix(".json")
            && (stem.hasPrefix("source-") || UUID(uuidString: stem) != nil)
    }
    #expect(receipts.count == SwiftNativeResearchClient.receiptRetentionLimit)
    // The 6 oldest (5 seeded overflow + the next-oldest) were pruned.
    for name in oldestNames {
        #expect(!receipts.contains(name), "oldest receipt survived prune: \(name)")
    }
    // Non-receipt files sharing the directory are never touched.
    #expect(files.contains("config.json"))
    #expect(FileManager.default.fileExists(atPath: labDir.appendingPathComponent("runs.json").path))
}

@Test func searchCapsToFirstTenResults() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let receiptsDir = tmp.appendingPathComponent("research")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": "http://searx.example"}"#.utf8).write(to: configPath)

    // 15 results — Python clamps with [:10], Swift must too.
    var items: [String] = []
    for i in 0..<15 {
        items.append("{\"title\": \"row-\(i)\", \"url\": \"https://r\(i).example\", \"content\": \"c\(i)\"}")
    }
    let body = "{\"results\":[" + items.joined(separator: ",") + "]}"

    let http = _ResearchHTTPStub()
    await http.set("http://searx.example/search?q=q&format=json",
             status: 200, body: Data(body.utf8))

    let client = makeHermeticClient(
        in: tmp,
        http: http,
        docker: _DockerStub(nil),
        configPathOverride: configPath,
        receiptsDirOverride: receiptsDir
    )
    let resp = try await client.search(query: "q")
    #expect(resp.results.count == 10)
    #expect(resp.results.first?.title == "row-0")
    #expect(resp.results.last?.title == "row-9")
}

// MARK: - search: non-2xx throws malformedResponse

@Test func searchThrowsOnNonSuccessStatus() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": "http://searx.example"}"#.utf8).write(to: configPath)

    let http = _ResearchHTTPStub()
    await http.set("http://searx.example/search?q=q&format=json",
             status: 503, body: Data("upstream error".utf8))

    let client = makeHermeticClient(
        in: tmp,
        http: http,
        docker: _DockerStub(nil),
        configPathOverride: configPath
    )
    do {
        _ = try await client.search(query: "q")
        Issue.record("expected malformedResponse for HTTP 503")
    } catch ResearchClientError.malformedResponse {} catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - response-shape parity with Python dict

/// Exercises the documented byte-shape of the Python response. Catches
/// silent drift in our JSON key names or null vs missing convention.
@Test func autodetectResultJSONMatchesPythonKeys() {
    let result = SearXNGAutodetectResult(
        found: false, baseURL: nil, source: nil,
        error: "No reachable SearXNG instance found"
    )
    let json = result.toJSON()
    guard case .object(let obj) = json else {
        Issue.record("toJSON did not return an object"); return
    }
    // Python emits all 4 keys, with `null` for the missing values.
    #expect(obj.count == 4)
    #expect(obj["found"] == .bool(false))
    #expect(obj["baseURL"] == .null)
    #expect(obj["source"] == .null)
    #expect(obj["error"] == .string("No reachable SearXNG instance found"))
}

@Test func searchResultJSONMatchesPythonKeys() {
    let row = ResearchSearchResult(
        title: "T", url: "U", snippet: "S", source: "google,bing")
    let json = row.toJSON()
    guard case .object(let obj) = json else {
        Issue.record("toJSON not object"); return
    }
    #expect(obj.count == 4)
    #expect(obj["title"] == .string("T"))
    #expect(obj["url"] == .string("U"))
    #expect(obj["snippet"] == .string("S"))
    #expect(obj["source"] == .string("google,bing"))

    let nilSource = ResearchSearchResult(title: "T", url: "U", snippet: "S", source: nil)
    if case .object(let obj2) = nilSource.toJSON() {
        #expect(obj2["source"] == .null)
    }
}

// MARK: - factory

@Test func factoryReturnsSwiftNative() async {
    let client = makeResearchClient()
    #expect(client is SwiftNativeResearchClient,
            "expected SwiftNativeResearchClient from the no-daemon factory")
}

@Test func factoryDerivesResearchStorageFromInjectedDataRoot() async throws {
    let root = makeTempDir().standardizedFileURL
    let client = try #require(makeResearchClient(dataRoot: root) as? SwiftNativeResearchClient)
    let configPath = await client.configPath
    let labRunsPath = await client.labRunsPath
    let activityPath = await client.activityPath
    let tracesPath = await client.tracesPath

    #expect(configPath == root
        .appendingPathComponent("research", isDirectory: true)
        .appendingPathComponent("config.json"))
    #expect(labRunsPath == root
        .appendingPathComponent("research", isDirectory: true)
        .appendingPathComponent("lab", isDirectory: true)
        .appendingPathComponent("runs.json"))
    #expect(activityPath == root
        .appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl"))
    #expect(tracesPath == root
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl"))
}


// MARK: - fetchURL (wave 30 W17)

@Test func fetchRejectsNonHTTPScheme() async throws {
    let tmp = makeTempDir()
    let client = makeHermeticClient(in: tmp, http: _ResearchHTTPStub(), docker: _DockerStub(nil))
    do {
        _ = try await client.fetchURL("file:///etc/passwd")
        Issue.record("expected malformedResponse for non-http scheme")
    } catch ResearchClientError.malformedResponse {} catch {
        Issue.record("wrong error: \(error)")
    }
    do {
        _ = try await client.fetchURL("ftp://example.com/x")
        Issue.record("expected malformedResponse for ftp scheme")
    } catch ResearchClientError.malformedResponse {} catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func fetchStripsHTMLWhenContentTypeHTMLAndWritesSourceReceipt() async throws {
    let tmp = makeTempDir()
    let receiptsDir = tmp.appendingPathComponent("research")
    let http = _ResearchHTTPStub()
    let html = "<html><head><style>body{color:red}</style></head>"
        + "<body><script>var x = 1 &amp; 2;</script>"
        + "<p>Hello&nbsp;&amp;   welcome</p><p>Second  line</p></body></html>"
    await http.set("https://page.example/doc", status: 200,
                   body: Data(html.utf8), contentType: "text/html; charset=utf-8")

    let client = makeHermeticClient(
        in: tmp,
        http: http, docker: _DockerStub(nil),
        receiptsDirOverride: receiptsDir,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        receiptIDFactory: { "src-1" }
    )
    let rec = try await client.fetchURL("https://page.example/doc")

    #expect(!rec.text.contains("var x"), "script body should be stripped")
    #expect(!rec.text.contains("color:red"), "style body should be stripped")
    // PARITY NOTE: &nbsp; decodes to U+00A0, but `" ".join(data.split())`
    // (Python) and `.split(whereSeparator: .isWhitespace)` (Swift) BOTH treat
    // U+00A0 as whitespace, so it collapses to a regular space. Both sides
    // agree the run is "Hello & welcome".
    #expect(rec.text.contains("Hello & welcome"), "entities decoded + ws collapsed: \(rec.text)")
    #expect(!rec.text.contains("\u{00A0}"), "nbsp must collapse like Python str.split()")
    #expect(rec.text.contains("Second line"))
    #expect(rec.id == "src-1")
    #expect(rec.url == "https://page.example/doc")
    #expect(rec.createdAt.hasSuffix("+00:00"))

    let receiptPath = receiptsDir.appendingPathComponent("source-src-1.json")
    guard let receipt = readJSONFile(receiptPath), case .object(let obj) = receipt else {
        Issue.record("source receipt missing or not object"); return
    }
    #expect(obj["id"] == .string("src-1"))
    #expect(obj["url"] == .string("https://page.example/doc"))
    if case .string(let t) = obj["text"] ?? .null {
        #expect(t.contains("welcome"))
    } else { Issue.record("text missing") }
}

@Test func fetchKeepsRawTextWhenNotHTML() async throws {
    let tmp = makeTempDir()
    let http = _ResearchHTTPStub()
    let raw = "plain &amp; <b>not decoded</b> body"
    await http.set("https://api.example/data.json", status: 200,
                   body: Data(raw.utf8), contentType: "application/json")
    let client = makeHermeticClient(
        in: tmp,
        http: http, docker: _DockerStub(nil),
        receiptIDFactory: { "src-2" }
    )
    let rec = try await client.fetchURL("https://api.example/data.json")
    #expect(rec.text == raw)
}

@Test func fetchThrowsOnNon2xx() async throws {
    let tmp = makeTempDir()
    let http = _ResearchHTTPStub()
    await http.set("https://gone.example/", status: 404,
                   body: Data("nope".utf8), contentType: "text/html")
    let client = makeHermeticClient(in: tmp, http: http, docker: _DockerStub(nil))
    do {
        _ = try await client.fetchURL("https://gone.example/")
        Issue.record("expected malformedResponse for HTTP 404")
    } catch ResearchClientError.malformedResponse {} catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - researchLabRuns (wave 30 W17)

@Test func labRunsSortsByCreatedAtDescending() async throws {
    let tmp = makeTempDir()
    let labPath = tmp.appendingPathComponent("research/lab/runs.json")
    try FileManager.default.createDirectory(
        at: labPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stored = #"""
    [
      {"id": "a", "createdAt": "2026-01-01T00:00:00+00:00"},
      {"id": "c", "createdAt": "2026-03-01T00:00:00+00:00"},
      {"id": "b", "createdAt": "2026-02-01T00:00:00+00:00"}
    ]
    """#
    try Data(stored.utf8).write(to: labPath)

    let client = makeHermeticClient(
        in: tmp,
        http: _ResearchHTTPStub(), docker: _DockerStub(nil),
        labRunsPathOverride: labPath
    )
    let runs = try await client.researchLabRuns()
    #expect(runs.count == 3)
    func idOf(_ v: JSONValue) -> String {
        if case .object(let o) = v, case .string(let s) = o["id"] ?? .null { return s }
        return "?"
    }
    #expect(idOf(runs[0]) == "c")
    #expect(idOf(runs[1]) == "b")
    #expect(idOf(runs[2]) == "a")
}

@Test func labRunsEmptyWhenFileMissing() async throws {
    let tmp = makeTempDir()
    let client = makeHermeticClient(in: tmp, http: _ResearchHTTPStub(), docker: _DockerStub(nil))
    let runs = try await client.researchLabRuns()
    #expect(runs.isEmpty)
}

// MARK: - runResearchLab (wave 30 W17)

@Test func runLabRequiresObjective() async throws {
    let tmp = makeTempDir()
    let client = makeHermeticClient(in: tmp, http: _ResearchHTTPStub(), docker: _DockerStub(nil))
    do {
        _ = try await client.runResearchLab(objective: "   ", maxResults: 5)
        Issue.record("expected malformedResponse for empty objective")
    } catch ResearchClientError.malformedResponse {} catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func runLabHappyPathPersistsAndBuildsBrief() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let labPath = tmp.appendingPathComponent("research/lab/runs.json")
    let receiptsDir = tmp.appendingPathComponent("research")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": "http://searx.example"}"#.utf8).write(to: configPath)

    let body = #"""
    {"results": [
      {"title": "First", "url": "https://a.example", "content": "x"},
      {"title": "Second", "url": "https://b.example", "content": "y"},
      {"title": "Third", "url": "https://c.example", "content": "z"},
      {"title": "Fourth", "url": "https://d.example", "content": "w"}
    ]}
    """#
    let http = _ResearchHTTPStub()
    await http.set("http://searx.example/search?q=quantum&format=json",
                   status: 200, body: Data(body.utf8))

    let client = makeHermeticClient(
        in: tmp,
        http: http, docker: _DockerStub(nil),
        configPathOverride: configPath,
        receiptsDirOverride: receiptsDir,
        labRunsPathOverride: labPath,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        receiptIDFactory: { "run-1" }
    )
    let run = try await client.runResearchLab(objective: "quantum", maxResults: 3)

    #expect(run.sources.count == 3)
    #expect(run.status == "completed")
    #expect(run.connector == "searxng")
    #expect(run.error == nil)
    #expect(run.brief == "Captured 3 source(s) for: quantum. Top sources: First; Second; Third")

    let persisted = readJSONFile(labPath)
    guard case .array(let rows) = persisted ?? .null, let first = rows.first,
          case .object(let firstObj) = first else {
        Issue.record("runs.json missing/empty"); return
    }
    #expect(firstObj["id"] == .string("run-1"))
}

// MARK: - runResearchLab activity/trace emission (wave 31 W03)

/// Helper: read all JSONL envelopes from a file as JSONValue objects.
private func readJSONLFile(_ url: URL) -> [JSONValue] {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
        try? JSONValue.parse(Data($0.utf8))
    }
}

@Test func runLabEmitsActivityAndTraceOnSuccess() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let labPath = tmp.appendingPathComponent("research/lab/runs.json")
    let activityPath = tmp.appendingPathComponent("activity/events.jsonl")
    let tracesPath = tmp.appendingPathComponent("traces/events.jsonl")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": "http://searx.example"}"#.utf8).write(to: configPath)

    let body = #"{"results": [{"title": "A", "url": "https://a.x", "content": "c"}, {"title": "B", "url": "https://b.x", "content": "c"}]}"#
    let http = _ResearchHTTPStub()
    await http.set("http://searx.example/search?q=quantum&format=json",
                   status: 200, body: Data(body.utf8))

    let client = makeHermeticClient(
        in: tmp,
        http: http, docker: _DockerStub(nil),
        configPathOverride: configPath,
        labRunsPathOverride: labPath,
        activityPathOverride: activityPath,
        tracesPathOverride: tracesPath,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        receiptIDFactory: { "run-1" }
    )
    let run = try await client.runResearchLab(objective: "quantum", maxResults: 5)
    #expect(run.status == "completed")

    // Activity: kind=research, title="Research lab run", detail=objective,
    // status="ok", missionId=null, payload={researchRunId, sourceCount}.
    let activity = readJSONLFile(activityPath)
    #expect(activity.count == 1)
    guard case .object(let a) = activity.first ?? .null else {
        Issue.record("no activity event"); return
    }
    #expect(a["kind"] == .string("research"))
    #expect(a["title"] == .string("Research lab run"))
    #expect(a["detail"] == .string("quantum"))
    #expect(a["status"] == .string("ok"))
    #expect(a["missionId"] == JSONValue.null)
    guard case .object(let ap) = a["payload"] ?? .null else { Issue.record("no payload"); return }
    #expect(ap["researchRunId"] == .string("run-1"))
    #expect(ap["sourceCount"] == .int(2))

    // Trace: kind=research.run, title=objective, status=run.status="completed",
    // payload carries status too.
    let traces = readJSONLFile(tracesPath)
    #expect(traces.count == 1)
    guard case .object(let t) = traces.first ?? .null else {
        Issue.record("no trace event"); return
    }
    #expect(t["kind"] == .string("research.run"))
    #expect(t["title"] == .string("quantum"))
    #expect(t["status"] == .string("completed"))
    guard case .object(let tp) = t["payload"] ?? .null else { Issue.record("no trace payload"); return }
    #expect(tp["researchRunId"] == .string("run-1"))
    #expect(tp["status"] == .string("completed"))
    #expect(tp["sourceCount"] == .int(2))
}

@Test func runLabEmitsWarnActivityAndNeedsConnectorTraceOnFailure() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let activityPath = tmp.appendingPathComponent("activity/events.jsonl")
    let tracesPath = tmp.appendingPathComponent("traces/events.jsonl")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: configPath)   // no searxng_base_url -> notConfigured

    let client = makeHermeticClient(
        in: tmp,
        http: _ResearchHTTPStub(), docker: _DockerStub(nil),
        configPathOverride: configPath,
        activityPathOverride: activityPath,
        tracesPathOverride: tracesPath,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        receiptIDFactory: { "run-2" }
    )
    let run = try await client.runResearchLab(objective: "anything", maxResults: 5)
    #expect(run.status == "needs_connector")

    let activity = readJSONLFile(activityPath)
    guard case .object(let a) = activity.first ?? .null else { Issue.record("no activity"); return }
    #expect(a["status"] == .string("warn"))   // Python: "ok" if not search_error else "warn"
    guard case .object(let ap) = a["payload"] ?? .null else { Issue.record("no payload"); return }
    #expect(ap["sourceCount"] == .int(0))

    let traces = readJSONLFile(tracesPath)
    guard case .object(let t) = traces.first ?? .null else { Issue.record("no trace"); return }
    #expect(t["status"] == .string("needs_connector"))  // trace status = run.status, NOT warn
}

@Test func runLabRedactsSecretInObjectiveDetail() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let activityPath = tmp.appendingPathComponent("activity/events.jsonl")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: configPath)

    let client = makeHermeticClient(
        in: tmp,
        http: _ResearchHTTPStub(), docker: _DockerStub(nil),
        configPathOverride: configPath,
        activityPathOverride: activityPath,
        receiptIDFactory: { "run-3" }
    )
    // An OpenAI-shaped key embedded in the objective must be redacted in the
    // activity detail (matches the daemon's redact_secret_text on title/detail).
    let secret = ["sk", "proj", "ABCDEFGHIJKLMNOPQRSTUVWX1234"].joined(separator: "-")
    _ = try await client.runResearchLab(objective: "find \(secret) please", maxResults: 5)

    let activity = readJSONLFile(activityPath)
    guard case .object(let a) = activity.first ?? .null,
          case .string(let detail) = a["detail"] ?? .null else {
        Issue.record("no activity detail"); return
    }
    #expect(!detail.contains(secret))
    #expect(detail.contains("[REDACTED_OPENAI_KEY:"))
}

@Test func redactSecretTextMatchesDaemonFormat() {
    // Static helper parity: bearer token (case-insensitive) + github token.
    let gh = ["ghp", "abcdefghijklmnopqrstuvwxyz0123"].joined(separator: "_")
    let redactedGH = SwiftNativeResearchClient.redactSecretText("token \(gh) end")
    #expect(!redactedGH.contains(gh))
    #expect(redactedGH.contains("[REDACTED_GITHUB_TOKEN:"))
    // A benign objective is untouched.
    #expect(SwiftNativeResearchClient.redactSecretText("quantum computing") == "quantum computing")
}

@Test func runLabNeedsConnectorWhenSearchFails() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let labPath = tmp.appendingPathComponent("research/lab/runs.json")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: configPath)

    let client = makeHermeticClient(
        in: tmp,
        http: _ResearchHTTPStub(), docker: _DockerStub(nil),
        configPathOverride: configPath,
        labRunsPathOverride: labPath,
        receiptIDFactory: { "run-2" }
    )
    let run = try await client.runResearchLab(objective: "anything", maxResults: 5)
    #expect(run.status == "needs_connector")
    #expect(run.connector == "none")
    #expect(run.sources.isEmpty)
    #expect(run.error == "SearXNG base URL is not configured")
    #expect(run.brief.hasPrefix("Research connector needs setup"))
}

@Test func runLabClampsMaxResultsToEight() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": "http://searx.example"}"#.utf8).write(to: configPath)

    var items: [String] = []
    for i in 0..<12 { items.append("{\"title\": \"t\(i)\", \"url\": \"https://r\(i).x\", \"content\": \"c\"}") }
    let body = "{\"results\":[" + items.joined(separator: ",") + "]}"
    let http = _ResearchHTTPStub()
    await http.set("http://searx.example/search?q=q&format=json", status: 200, body: Data(body.utf8))

    let client = makeHermeticClient(
        in: tmp,
        http: http, docker: _DockerStub(nil),
        configPathOverride: configPath
    )
    let run = try await client.runResearchLab(objective: "q", maxResults: 99)
    #expect(run.sources.count == 8)
}

@Test func runLabCapsHistoryAtHundred() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    let labPath = tmp.appendingPathComponent("research/lab/runs.json")
    try FileManager.default.createDirectory(
        at: labPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: configPath)
    var rows: [String] = []
    for i in 0..<100 {
        let ts = String(format: "2026-01-%02dT00:00:00+00:00", (i % 28) + 1)
        rows.append("{\"id\": \"old-\(i)\", \"createdAt\": \"\(ts)\"}")
    }
    try Data(("[" + rows.joined(separator: ",") + "]").utf8).write(to: labPath)

    let client = makeHermeticClient(
        in: tmp,
        http: _ResearchHTTPStub(), docker: _DockerStub(nil),
        configPathOverride: configPath,
        labRunsPathOverride: labPath,
        now: { Date(timeIntervalSince1970: 2_000_000_000) },
        receiptIDFactory: { "newest" }
    )
    _ = try await client.runResearchLab(objective: "x", maxResults: 5)
    let persisted = readJSONFile(labPath)
    guard case .array(let stored) = persisted ?? .null else {
        Issue.record("runs.json not an array"); return
    }
    #expect(stored.count == 100)
    if case .object(let o) = stored[0], case .string(let id) = o["id"] ?? .null {
        #expect(id == "newest")
    } else { Issue.record("newest run not first") }
}

// MARK: - HTML entity decode parity

@Test func htmlEntityDecodeCoversNamedAndNumeric() {
    #expect(SwiftNativeResearchClient.decodeHTMLEntities("a &amp; b") == "a & b")
    #expect(SwiftNativeResearchClient.decodeHTMLEntities("&lt;tag&gt;") == "<tag>")
    #expect(SwiftNativeResearchClient.decodeHTMLEntities("&#65;&#66;") == "AB")
    #expect(SwiftNativeResearchClient.decodeHTMLEntities("&#x41;&#x42;") == "AB")
    #expect(SwiftNativeResearchClient.decodeHTMLEntities("&bogus;") == "&bogus;")
    #expect(SwiftNativeResearchClient.decodeHTMLEntities("Tom & Jerry") == "Tom & Jerry")
}

// MARK: - HTML CDATA / entity parity (wave 30 W17, gpt-5.5 review fixes)

/// FIX #1: `<` inside <script>/<style> is CDATA in Python's HTMLParser, not
/// markup. These three cases were verified byte-for-byte against the real
/// Python TextExtractor.
@Test func extractTextTreatsScriptStyleBodiesAsCDATA() {
    // Python: '<script>if (a < b) { x(); }</script><p>Title</p>' -> "Title"
    #expect(SwiftNativeResearchClient.extractText(
        fromHTML: "<script>if (a < b) { x(); }</script><p>Title</p>") == "Title")
    // Python: '<style>a{x:1} @media (max-width: 5px){}</style><p>Body</p>' -> "Body"
    #expect(SwiftNativeResearchClient.extractText(
        fromHTML: "<style>a{x:1} @media (max-width: 5px){}</style><p>Body</p>") == "Body")
}

/// FIX #3: widened named-entity table covers the common HTML5 refs.
/// Verified against Python: 'Price: 5&euro; or &pound;3' -> "Price: 5€ or £3".
@Test func extractTextDecodesCommonHTML5Entities() {
    #expect(SwiftNativeResearchClient.extractText(
        fromHTML: "<p>Price: 5&euro; or &pound;3</p>") == "Price: 5\u{20AC} or \u{00A3}3")
    #expect(SwiftNativeResearchClient.decodeHTMLEntities("&euro;&pound;&raquo;") == "\u{20AC}\u{00A3}\u{00BB}")
}

/// FIX #5: content-type sniff matches Python's case-SENSITIVE
/// `"html" in content_type`.
@Test func fetchDoesNotStripWhenContentTypeIsUppercaseHTML() async throws {
    let tmp = makeTempDir()
    let http = _ResearchHTTPStub()
    let raw = "<p>kept &amp; raw</p>"
    await http.set("https://up.example/", status: 200,
                   body: Data(raw.utf8), contentType: "Text/HTML")  // capital HTML
    let client = makeHermeticClient(
        in: tmp,
        http: http, docker: _DockerStub(nil),
        receiptIDFactory: { "ct" }
    )
    let rec = try await client.fetchURL("https://up.example/")
    // Python's `"html" in "Text/HTML"` is False -> no stripping. Raw kept.
    #expect(rec.text == raw)
}

/// FIX #4: maxResults == 0 defaults to 5 (Python `maxResults or 5`).
@Test func runLabZeroMaxResultsDefaultsToFive() async throws {
    let tmp = makeTempDir()
    let configPath = tmp.appendingPathComponent("config/config.json")
    try FileManager.default.createDirectory(
        at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"searxng_base_url": "http://searx.example"}"#.utf8).write(to: configPath)
    var items: [String] = []
    for i in 0..<10 { items.append("{\"title\": \"t\(i)\", \"url\": \"https://r\(i).x\", \"content\": \"c\"}") }
    let body = "{\"results\":[" + items.joined(separator: ",") + "]}"
    let http = _ResearchHTTPStub()
    await http.set("http://searx.example/search?q=q&format=json", status: 200, body: Data(body.utf8))
    let client = makeHermeticClient(
        in: tmp,
        http: http, docker: _DockerStub(nil),
        configPathOverride: configPath
    )
    let run = try await client.runResearchLab(objective: "q", maxResults: 0)
    // 0 -> 5; search returns 10, lab clamps to 5.
    #expect(run.sources.count == 5)
}
