import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `Research.swift` | `SwiftNativeResearchClient` and research values: SearXNG discovery/search, fetched-source receipts, classified DNS/refused-connection/timeout causes and persisted lab run contracts |

// MARK: - Research
//
// Swift-native SearXNG autodetect, search, fetched-source receipts, and research lab
// persistence. Focused extensions own autodetect, search/fetch parsing,
// lab execution, activity/trace emission, helpers, and transports.

// MARK: - Result types

public struct SearXNGCandidate: Sendable, Equatable {
    public let source: String   // "common-port" | "docker"
    public let baseURL: String  // no trailing "/"

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

    /// `baseURL`, `source` and `error` serialize as null when absent.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        obj["found"] = .bool(found)
        obj["baseURL"] = baseURL.map { .string($0) } ?? .null
        obj["source"] = source.map { .string($0) } ?? .null
        obj["error"] = error.map { .string($0) } ?? .null
        return .object(obj)
    }
}

public struct ResearchSearchResult: Identifiable, Sendable, Hashable, Codable {
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

    /// `source` is comma-joined engine names when `engines` is an array,
    /// otherwise the string `engine` or null.
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
    /// SearXNG engines that failed ("name: reason"), distinct from no matches.
    public let unresponsiveEngines: [String]

    public init(results: [ResearchSearchResult], unresponsiveEngines: [String] = []) {
        self.results = results
        self.unresponsiveEngines = unresponsiveEngines
    }

    public var enginesFailed: Bool { results.isEmpty && !unresponsiveEngines.isEmpty }

    init(data: Data) throws {
        let parsed: JSONValue
        do { parsed = try JSONValue.parse(data) }
        catch { throw ResearchClientError.malformedResponse("SearXNG body is not JSON: \(error)") }
        guard case .object(let payload) = parsed else { throw ResearchClientError.malformedResponse("SearXNG body is not a JSON object") }
        guard case .array(let items)? = payload["results"] else { throw ResearchClientError.malformedResponse("SearXNG results is missing or is not an array") }
        var results: [ResearchSearchResult] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard case .object(let entry) = item else { throw ResearchClientError.malformedResponse("SearXNG results[\(index)] is not an object") }
            guard index < 10 else { continue }
            func string(_ key: String) -> String? { if case .string(let value)? = entry[key] { return value }; return nil }
            func nonempty(_ key: String) -> String? { string(key).flatMap { $0.isEmpty ? nil : $0 } }
            let source: String?
            if case .array(let engines)? = entry["engines"] {
                source = engines.compactMap { if case .string(let value) = $0 { return value }; return nil }.joined(separator: ",")
            } else { source = string("engine") }
            results.append(ResearchSearchResult(title: nonempty("title") ?? nonempty("url") ?? "Untitled",
                url: nonempty("url") ?? "", snippet: string("content") ?? "", source: source))
        }
        let engines: [JSONValue] = if case .array(let values)? = payload["unresponsive_engines"] { values } else { [] }
        self.init(results: results, unresponsiveEngines: engines.compactMap {
            guard case .array(let pair) = $0, case .string(let name)? = pair.first else { return nil }
            if pair.count > 1, case .string(let reason) = pair[1] { return name + ": " + reason }
            return name
        })
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["results": .array(results.map { $0.toJSON() })]
        if !unresponsiveEngines.isEmpty {
            obj["unresponsive_engines"] = .array(unresponsiveEngines.map(JSONValue.string))
        }
        return .object(obj)
    }
}

// MARK: - fetch / lab result types

/// A fetched-source receipt with `{id, url, text, createdAt}`, source coverage
/// and a read outcome. The bounded extraction is retained;
/// readJSON selection and output paging are described in the web-read blueprint.
/// Receipt is written to `data/research/source-<id>.json`.
public struct ResearchFetchRecord: Sendable, Equatable {
    public let id: String
    public let url: String
    public let text: String
    public let createdAt: String
    public let coverage: JSONValue?
    public let sourceReceipt: JSONValue?
    public let verdict: [String: JSONValue]

    public init(id: String, url: String, text: String, createdAt: String, verdict: [String: JSONValue], coverage: JSONValue? = nil, sourceReceipt: JSONValue? = nil) {
        self.id = id
        self.url = url
        self.text = text
        self.createdAt = createdAt
        self.coverage = coverage
        self.sourceReceipt = sourceReceipt
        self.verdict = verdict
    }

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
            fields["agent"] = .string("web")
        }
        if let sourceReceipt { fields["source_receipt"] = sourceReceipt }
        fields.merge(verdict) { _, verdict in verdict }
        return .object(fields)
    }
}

/// A persisted lab run; `error` serializes as null when absent.
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

// MARK: - Stored rows

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
    /// No SearXNG base URL is configured.
    case notConfigured
    /// Non-2xx response or unparseable body.
    case malformedResponse(String)
    case httpStatus(Int)
    case transport(String)
    case noSuchHost(String)
    case connectionRefused(String)
    case timedOut(String)
    case localServerNotRunning(String)

    public var failureReason: String? {
        switch self {
        case .noSuchHost: "no_such_host"
        case .connectionRefused: "connection_refused"
        case .timedOut: "timeout"
        case .transport: "transport_error"
        default: nil
        }
    }

    static func transportFailure(_ error: Error, url: URL) -> ResearchClientError {
        if let failure = error as? ResearchClientError { return failure }
        let host = url.host ?? url.absoluteString
        var cause = error as NSError
        for _ in 0..<5 {
            if cause.domain == NSURLErrorDomain {
                switch URLError.Code(rawValue: cause.code) {
                case .cannotFindHost, .dnsLookupFailed: return .noSuchHost(host)
                case .cannotConnectToHost: return .connectionRefused(host)
                case .timedOut: return .timedOut(host)
                default: break
                }
            }
            if cause.domain == NSPOSIXErrorDomain, cause.code == Int(POSIXErrorCode.ECONNREFUSED.rawValue) {
                return .connectionRefused(host)
            }
            guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cause = underlying
        }
        return .transport(String(describing: error))
    }

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
        case .noSuchHost(let host):
            return "No such host: \(host). DNS could not resolve the hostname; no page was read."
        case .connectionRefused(let host):
            return "Connection refused by \(host); no page was read."
        case .timedOut(let host):
            return "The read from \(host) timed out; no page was read."
        case .transport(let detail) where detail.range(of: #"Code=-120[0-6]\b"#, options: .regularExpression) != nil:
            // 10-08: a search hit was a lookalike mirror; its certificate failed
            // and the raw NSError dump read as "the site is down".
            return "The site's security certificate is not valid for this address, so nothing was read. It may not be "
                + "the site it looks like; prefer the official domain."
        case .transport(let detail):
            return "The source could not be reached: \(detail.prefix(400))."
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
    let http = URLSessionResearchHTTPClient()
    let docker = SystemDockerPSExecutor()

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        let root = dataRoot.standardizedFileURL
        self.receiptsDir = root.appendingPathComponent("research", isDirectory: true)
        self.configPath = receiptsDir.appendingPathComponent("config.json")
        self.labRunsPath = receiptsDir.appendingPathComponent("lab/runs.json")
        self.activityPath = SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
        self.tracesPath = root.appendingPathComponent("traces/events.jsonl")
    }
}
