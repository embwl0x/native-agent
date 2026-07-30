import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Research
//
// Swift-native SearXNG autodetect, search/fetch receipts, and research lab
// persistence. Focused extensions own autodetect, search/fetch parsing,
// lab execution, activity/trace emission, helpers, and transports.

// MARK: - Result types

public struct SearXNGCandidate: Sendable, Equatable {
    public let source: String   // "common-port" | "docker"
    public let baseURL: String  // already rstripped of trailing "/"

    public init(source: String, baseURL: String) {
        self.source = source
        self.baseURL = baseURL
    }
}

public struct SearXNGAutodetectResult: Sendable, Equatable {
    public let found: Bool
    public let baseURL: String?
    public let source: String?     // "common-port" | "docker" | nil when none
    public let error: String?

    public init(found: Bool, baseURL: String?, source: String?, error: String?) {
        self.found = found
        self.baseURL = baseURL
        self.source = source
        self.error = error
    }

    /// JSON-serializable shape (matches Python's autodetect_searxng return
    /// dict byte-for-byte: keys `found`, `baseURL`, `source`, `error` with
    /// nullable strings).
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        obj["found"] = .bool(found)
        obj["baseURL"] = baseURL.map { .string($0) } ?? .null
        obj["source"] = source.map { .string($0) } ?? .null
        obj["error"] = error.map { .string($0) } ?? .null
        return .object(obj)
    }
}

public struct ResearchSearchResult: Sendable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String
    public let source: String?

    public init(title: String, url: String, snippet: String, source: String?) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.source = source
    }

    /// Mirrors Python's per-item dict: `{title, url, snippet, source}`.
    /// `source` is comma-joined `engines` when that key is a list, else the
    /// scalar `engine` key, else `null` (matches the Python `if isinstance`
    /// fallback chain at the retired daemon).
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        obj["title"] = .string(title)
        obj["url"] = .string(url)
        obj["snippet"] = .string(snippet)
        obj["source"] = source.map { .string($0) } ?? .null
        return .object(obj)
    }
}

public struct ResearchSearchResponse: Sendable, Equatable {
    public let results: [ResearchSearchResult]

    public init(results: [ResearchSearchResult]) {
        self.results = results
    }

    /// Mirrors Python's `{"results": [...]}` response.
    public func toJSON() -> JSONValue {
        .object(["results": .array(results.map { $0.toJSON() })])
    }
}

// MARK: - fetch / lab result types (wave 30 W17)

/// Mirrors Python `fetch_url`'s record dict: `{id, url, text, createdAt}`.
/// `text` is the (HTML-stripped, when content-type is HTML) body, capped at
/// 40_000 chars (matches the retired daemon). Receipt is written to
/// `data/research/source-<id>.json`.
public struct ResearchFetchRecord: Sendable, Equatable {
    public let id: String
    public let url: String
    public let text: String
    public let createdAt: String

    public init(id: String, url: String, text: String, createdAt: String) {
        self.id = id
        self.url = url
        self.text = text
        self.createdAt = createdAt
    }

    /// Byte-for-byte mirror of the Python record dict key set.
    public func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "url": .string(url),
            "text": .string(text),
            "createdAt": .string(createdAt),
        ])
    }
}

/// Mirrors Python `run_research_lab`'s `run` dict:
/// `{id, objective, status, query, sources, brief, createdAt, connector,
/// error}`. `error` is null on success, a string when search failed.
public struct ResearchLabRun: Sendable, Equatable {
    public let id: String
    public let objective: String
    public let status: String      // "completed" | "needs_connector"
    public let query: String
    public let sources: [ResearchSearchResult]
    public let brief: String
    public let createdAt: String
    public let connector: String   // "searxng" | "none"
    public let error: String?

    public init(
        id: String, objective: String, status: String, query: String,
        sources: [ResearchSearchResult], brief: String, createdAt: String,
        connector: String, error: String?
    ) {
        self.id = id
        self.objective = objective
        self.status = status
        self.query = query
        self.sources = sources
        self.brief = brief
        self.createdAt = createdAt
        self.connector = connector
        self.error = error
    }

    /// Mirrors the Python `run` dict key order/shape. `error` serializes to
    /// `null` when nil (matches Python's `search_error or None`).
    public func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "objective": .string(objective),
            "status": .string(status),
            "query": .string(query),
            "sources": .array(sources.map { $0.toJSON() }),
            "brief": .string(brief),
            "createdAt": .string(createdAt),
            "connector": .string(connector),
            "error": error.map { .string($0) } ?? .null,
        ])
    }
}

// MARK: - Errors

public enum ResearchClientError: Error, Sendable, Equatable {
    /// `searxng_base_url` is empty in config — matches Python's
    /// `raise ValueError("SearXNG base URL is not configured")` at
    /// the retired daemon.
    case notConfigured
    /// Non-2xx response or unparseable body.
    case malformedResponse(String)
    case transport(String)
}

// MARK: - Protocol

public protocol ResearchClientProtocol: Sendable {
    /// Scan candidate base URLs (common ports + `docker ps`), probe each
    /// via `/search?q=nativeagent&format=json`, persist the first
    /// responsive one to `data/research/config.json` under
    /// `searxng_base_url`, return the structured result.
    func autodetectSearXNG() async throws -> SearXNGAutodetectResult

    /// Run a SearXNG query against the configured base URL, parse the top
    /// 10 results, write a receipt JSON to `data/research/<uuid>.json`,
    /// return `{results: [...]}`.
    func search(query: String) async throws -> ResearchSearchResponse

    /// GET an http/https URL (1MB read cap), strip HTML->text when the
    /// content-type is HTML, cap text at 40_000 chars, write a receipt to
    /// `data/research/source-<id>.json`, return the record. Mirrors
    /// `Daemon.fetch_url`.
    func fetchURL(_ url: String) async throws -> ResearchFetchRecord

    /// Read `data/research/lab/runs.json`, return the runs sorted by
    /// `createdAt` descending. Mirrors `Daemon.research_lab_runs`
    ///. Returns the raw stored JSON rows.
    func researchLabRuns() async throws -> [JSONValue]

    /// Run a research-lab pass: search the objective, build a brief, persist
    /// the run (newest-first, capped at 100) to `data/research/lab/runs.json`,
    /// return it using the stable research-lab record shape.
    ///
    /// The SwiftNative impl emits activity/events.jsonl and traces/events.jsonl
    /// entries alongside the run so the Mac activity feed and trace ledger stay
    /// complete for research-lab runs.
    func runResearchLab(objective: String, maxResults: Int) async throws -> ResearchLabRun
}

// MARK: - Network + Docker dependency boundaries (test seams)

/// Thin URLSession seam — implemented by URLSession.shared in production
/// and by the test stub `_ResearchHTTPStub` in ResearchTests. Keeps
/// SwiftNativeResearchClient mockable without dragging in URLProtocol
/// subclasses at the call sites.
public protocol ResearchHTTPClient: Sendable {
    /// GET the URL, return (status, body, contentType). `contentType` is the
    /// raw `Content-Type` response header (nil if absent) — used by
    /// `fetchURL` to decide HTML->text stripping. Should NOT throw on non-2xx
    /// — callers do their own status branching.
    func get(url: URL, timeout: TimeInterval) async throws -> (Int, Data, String?)
}

/// `docker ps` shell-out seam — production runs the real binary if
/// present; tests inject a fake to return canned JSON-per-line.
public protocol DockerPSExecutor: Sendable {
    /// Returns the `docker ps --format '{{json .}}'` stdout, or nil if
    /// docker isn't on PATH or the call failed within the 8s timeout
    /// (matches `Daemon.docker_searxng_candidates` at the retired daemon
    /// L42811).
    func runJSONLines() async -> String?
}

// MARK: - SwiftNative impl

public actor SwiftNativeResearchClient: ResearchClientProtocol {
    let configPath: URL
    let receiptsDir: URL
    let labRunsPath: URL
    // Activity-feed + trace-ledger sinks. The Mac UI runs research lab
    // in-process; the activity feed and trace ledger both read these files, so
    // emitting here keeps those surfaces complete.
    let activityPath: URL
    let tracesPath: URL
    let persistence: any PersistenceCoreProtocol
    let http: any ResearchHTTPClient
    let docker: any DockerPSExecutor
    let userAgent: String
    let now: @Sendable () -> Date
    let receiptIDFactory: @Sendable () -> String

    /// Production initializer.
    ///
    /// `configPathOverride` + `receiptsDirOverride` + `nowOverride` +
    /// `receiptIDFactoryOverride` are test seams. `persistence`, `http`,
    /// `docker` are protocol-typed so tests can pin behavior without
    /// touching disk or the network.
    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
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
    ) {
        self.persistence = persistence
        self.http = http
        self.docker = docker
        self.userAgent = userAgent
        self.now = now
        self.receiptIDFactory = receiptIDFactory
        let root = dataRoot.standardizedFileURL
        if let override = configPathOverride {
            self.configPath = override
        } else {
            self.configPath = root
                .appendingPathComponent("research", isDirectory: true)
                .appendingPathComponent("config.json")
        }
        if let override = receiptsDirOverride {
            self.receiptsDir = override
        } else {
            self.receiptsDir = root.appendingPathComponent("research", isDirectory: true)
        }
        if let override = labRunsPathOverride {
            self.labRunsPath = override
        } else {
            // Mirrors Python: root / "research" / "lab" / "runs.json"
            //.
            self.labRunsPath = root
                .appendingPathComponent("research", isDirectory: true)
                .appendingPathComponent("lab", isDirectory: true)
                .appendingPathComponent("runs.json")
        }
        if let override = activityPathOverride {
            self.activityPath = override
        } else {
            // Matches data-root layout: root / "activity" / "events.jsonl"
            //.
            self.activityPath = root
                .appendingPathComponent("activity", isDirectory: true)
                .appendingPathComponent("events.jsonl")
        }
        if let override = tracesPathOverride {
            self.tracesPath = override
        } else {
            // Matches data-root layout: root / "traces" / "events.jsonl"
            //. Same file DispatchLedger appends to.
            self.tracesPath = root
                .appendingPathComponent("traces", isDirectory: true)
                .appendingPathComponent("events.jsonl")
        }
    }
}

// MARK: - Factory

public func makeResearchClient(
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any ResearchClientProtocol {
    return SwiftNativeResearchClient(dataRoot: dataRoot)
}
