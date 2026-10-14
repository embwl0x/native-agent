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

/// The result of one SearXNG discovery attempt. Research owns presentation of
/// this result so an incidental discovery cannot replace the app-wide status
/// message used by other mounted surfaces.
public enum SearXNGAutodetectOutcome: Equatable, Sendable {
    case found(String)
    case notFound(String)
    case failed(String)
}

public struct SearXNGAutodetectResult: Sendable, Equatable {
    public var outcome: SearXNGAutodetectOutcome {
        guard found else {
            let detail = error?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return .notFound(detail)
            }
            return .notFound("No reachable local instance was found.")
        }
        guard let baseURL = baseURL,
              !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("SearXNG detection returned no usable URL.")
        }
        do {
            let normalized = try SwiftNativeResearchClient.normalizedSearXNGBaseURL(baseURL)
            return .found(normalized)
        } catch {
            return .failed("SearXNG detection returned an invalid URL: \(error.localizedDescription)")
        }
    }

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

public struct ResearchSearchResult: Identifiable, Sendable, Hashable {
    public var id: String { url }
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
    /// 2026-09-23: SearXNG engines that failed ("name: reason"). Without them an
    /// empty search reads as "nothing exists" when the engines were just down.
    public let unresponsiveEngines: [String]

    public init(results: [ResearchSearchResult], unresponsiveEngines: [String] = []) {
        self.results = results
        self.unresponsiveEngines = unresponsiveEngines
    }

    /// Mirrors Python's `{"results": [...]}` response.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["results": .array(results.map { $0.toJSON() })]
        if !unresponsiveEngines.isEmpty {
            obj["unresponsive_engines"] = .array(unresponsiveEngines.map(JSONValue.string))
        }
        return .object(obj)
    }
}

// MARK: - fetch / lab result types (wave 30 W17)

/// Retains the legacy `{id, url, text, createdAt}` fields and adds source
/// coverage and a read outcome for current fetches. All text extracted within
/// the bounded response is retained; the tool-output pager handles sections.
/// Receipt is written to `data/research/source-<id>.json`.
public struct ResearchFetchRecord: Sendable, Equatable {
    public let id: String
    public let url: String
    public let text: String
    public let createdAt: String
    public let coverage: JSONValue?
    public let sourceReceipt: JSONValue?

    public init(id: String, url: String, text: String, createdAt: String, coverage: JSONValue? = nil, sourceReceipt: JSONValue? = nil) {
        self.id = id
        self.url = url
        self.text = text
        self.createdAt = createdAt
        self.coverage = coverage
        self.sourceReceipt = sourceReceipt
    }

    /// Legacy fields remain stable; current reads add explicit source coverage.
    public func toJSON() -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "url": .string(url),
            "text": .string(text),
            "createdAt": .string(createdAt),
            "untrusted_remote_data": .bool(!text.isEmpty),
        ]
        if let coverage { fields["coverage"] = coverage }
        if !text.isEmpty {
            fields["untrusted_remote_data"] = .bool(true)
            fields["agent"] = .string("web")
        }
        if let sourceReceipt { fields["source_receipt"] = sourceReceipt }
        if case .object(let details)? = coverage,
           case .string(let extraction)? = details["extraction_status"] {
            switch extraction {
            case "unsupported_content_type", "unsupported_text_encoding",
                 "file_too_large", "unreadable_document", "encrypted_document", "no_text_in_document":
                // HTTP receipt success is not successful readable extraction.
                // Keep that transport evidence in coverage while stating the
                // actual read outcome at the ordinary tool-result boundary.
                fields["status"] = .string("failed")
                fields["reason"] = .string(extraction)
            case "html_text", "plain_text", "empty_text", "pdf_text":
                if case .bool(let complete)? = details["complete"] {
                    fields["status"] = .string(complete ? "completed" : (text.isEmpty ? "failed" : "partial"))
                    if !complete && text.isEmpty { fields["reason"] = .string("incomplete_empty_extraction") }
                }
                if details["thin_page"] == .bool(true) {
                    fields["reason"] = .string("thin_page")
                    fields["hint"] = details["hint"]
                }
            default: break
            }
        }
        return .object(fields)
    }
}

/// Mirrors Python `run_research_lab`'s `run` dict:
/// `{id, objective, status, query, sources, brief, createdAt, connector,
/// error}`. `error` is null on success, a string when search failed.
public struct ResearchLabRun: Identifiable, Sendable, Hashable {
    public let id: String
    public let objective: String
    public let status: String      // "completed" | "needs_connector" | "failed"
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

// MARK: - Stored rows (S10)

extension ResearchSearchResult {
    /// One stored source row: `title`, `url` and `snippet` are required;
    /// a present field of the wrong type makes the row malformed.
    public init?(row: JSONValue) {
        guard case .object(let obj) = row,
              case .string(let title)? = obj["title"],
              case .string(let url)? = obj["url"],
              case .string(let snippet)? = obj["snippet"] else { return nil }
        switch obj["source"] {
        case nil, .null?: self.init(title: title, url: url, snippet: snippet, source: nil)
        case .string(let source)?: self.init(title: title, url: url, snippet: snippet, source: source)
        default: return nil
        }
    }
}

extension ResearchLabRun {
    /// One stored `lab/runs.json` row: `id`, `objective`, `status` and every
    /// source are required; an absent text field reads as empty, a present
    /// field of the wrong type makes the run malformed.
    public init?(row: JSONValue) {
        guard case .object(let obj) = row,
              case .string(let id)? = obj["id"],
              case .string(let objective)? = obj["objective"],
              case .string(let status)? = obj["status"],
              case .array(let sourceRows)? = obj["sources"] else { return nil }
        var sources: [ResearchSearchResult] = []
        for sourceRow in sourceRows {
            guard let source = ResearchSearchResult(row: sourceRow) else { return nil }
            sources.append(source)
        }
        var malformed = false
        func text(_ key: String) -> String? {
            switch obj[key] {
            case nil, .null?: return nil
            case .string(let value)?: return value
            default: malformed = true; return nil
            }
        }
        let query = text("query"), brief = text("brief"), connector = text("connector")
        let error = text("error"), createdAt = text("createdAt")
        guard !malformed else { return nil }
        self.init(
            id: id, objective: objective, status: status, query: query ?? "",
            sources: sources, brief: brief ?? "", createdAt: createdAt ?? "",
            connector: connector ?? "", error: error
        )
    }
}

// MARK: - Errors

public enum ResearchClientError: LocalizedError, Sendable, Equatable {
    /// `searxng_base_url` is empty in config — matches Python's
    /// `raise ValueError("SearXNG base URL is not configured")` at
    /// the retired daemon.
    case notConfigured
    /// Non-2xx response or unparseable body.
    case malformedResponse(String)
    case httpStatus(Int)
    case transport(String)
    case localServerNotRunning(String)

    /// Keep the actual read failure useful in ordinary Workspace recovery.
    /// NSError's synthesized enum number otherwise hides even an HTTP refusal.
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Web search is not configured. Open a known website in Browser, or set up a search connection."
        case .malformedResponse(let detail):
            return "The source could not be read: \(detail.prefix(400)). Check the address or open it in Browser."
        case .httpStatus(let status):
            return "HTTP \(status) refused this public read."
        case .transport(let detail) where detail.range(of: #"Code=-120[0-6]\b"#, options: .regularExpression) != nil:
            // 10-08: a search hit was a lookalike mirror; its certificate failed
            // and the raw NSError dump read as "the site is down".
            return "The site's security certificate is not valid for this address, so nothing was read. It may not be "
                + "the site it looks like; prefer the official domain."
        case .transport(let detail):
            return "The source could not be reached: \(detail.prefix(400)). Check the connection or open it in Browser."
        case .localServerNotRunning:
            return "The configured local research service is not running. Start it or use another available research route."
        }
    }
}

public struct ResearchHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String?
    public let finalURL: URL?
    public let observedBytes: Int
    public let truncated: Bool

    public init(status: Int, body: Data, contentType: String?, finalURL: URL?, observedBytes: Int, truncated: Bool) {
        self.status = status; self.body = body; self.contentType = contentType
        self.finalURL = finalURL; self.observedBytes = observedBytes; self.truncated = truncated
    }
}

// MARK: - SwiftNative impl

public actor SwiftNativeResearchClient {
    let configPath: URL
    let receiptsDir: URL
    let labRunsPath: URL
    // Activity-feed + trace-ledger sinks. The Mac UI runs research lab
    // in-process; the activity feed and trace ledger both read these files, so
    // emitting here keeps those surfaces complete.
    let activityPath: URL
    let tracesPath: URL
    let persistence = SwiftNativePersistenceCore()
    let http = URLSessionResearchHTTPClient()
    let docker = SystemDockerPSExecutor()

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        let root = dataRoot.standardizedFileURL
        self.receiptsDir = root.appendingPathComponent("research", isDirectory: true)
        self.configPath = receiptsDir.appendingPathComponent("config.json")
        self.labRunsPath = receiptsDir.appendingPathComponent("lab/runs.json")
        self.activityPath = root.appendingPathComponent("activity/events.jsonl")
        self.tracesPath = root.appendingPathComponent("traces/events.jsonl")
    }
}
