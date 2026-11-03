import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `Research.swift` | Research values validate current SearXNG fields, skip malformed result and engine-failure rows as named gaps before capping valid siblings, expose independent receipt-retention state and require complete saved Lab rows; required envelope failures and DNS/refused-connection/timeout causes remain explicit |

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
    case found(String, gaps: [String])
    case notFound(String)
    case failed(String)
}

public struct SearXNGAutodetectResult: Sendable, Equatable {
    public var outcome: SearXNGAutodetectOutcome {
        guard found else {
            if !gaps.isEmpty { return .failed("Search discovery has unavailable candidates: " + gaps.joined(separator: "; ")) }
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
            return .found(normalized, gaps: gaps)
        } catch {
            return .failed("SearXNG detection returned an invalid URL: \(error.localizedDescription)")
        }
    }

    public let found: Bool
    public let baseURL: String?
    public let source: String?     // "common-port" | "docker" | nil when none
    public let error: String?
    /// Unavailable candidates, each named by address; independent of selection.
    public let gaps: [String]

    public init(found: Bool, baseURL: String?, source: String?, error: String?, gaps: [String]) {
        self.found = found
        self.baseURL = baseURL
        self.source = source
        self.error = error
        self.gaps = gaps
    }

    /// `baseURL`, `source` and `error` serialize as null when absent.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        obj["found"] = .bool(found)
        obj["baseURL"] = baseURL.map { .string($0) } ?? .null
        obj["source"] = source.map { .string($0) } ?? .null
        obj["error"] = error.map { .string($0) } ?? .null
        obj["gaps"] = .array(gaps.map { .string($0) })
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

    /// `source` is the comma-joined recorded engine list, or null when absent.
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
    /// Unusable result rows, named by their position and failing field.
    public let gaps: [String]

    public init(results: [ResearchSearchResult], unresponsiveEngines: [String] = [], gaps: [String] = []) {
        self.results = results
        self.unresponsiveEngines = unresponsiveEngines
        self.gaps = gaps
    }

    public var enginesFailed: Bool { results.isEmpty && !unresponsiveEngines.isEmpty }

    init(data: Data) throws {
        let parsed: JSONValue
        do { parsed = try JSONValue.parse(data) }
        catch { throw ResearchClientError.malformedResponse("SearXNG body is not JSON: \(error)") }
        guard case .object(let payload) = parsed else { throw ResearchClientError.malformedResponse("SearXNG body is not a JSON object") }
        guard case .array(let items)? = payload["results"] else { throw ResearchClientError.malformedResponse("SearXNG results is missing or is not an array") }
        var results: [ResearchSearchResult] = []
        var gaps: [String] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            do {
                guard case .object(let entry) = item else { throw ResearchClientError.malformedResponse("SearXNG results[\(index)] is not an object") }
                func string(_ key: String) throws -> String {
                    guard case .string(let value)? = entry[key] else {
                        throw ResearchClientError.malformedResponse("SearXNG results[\(index)].\(key) must be a string")
                    }
                    return value
                }
                let title = try string("title"), url = try string("url"), content = try string("content")
                guard let link = URLComponents(string: url), let scheme = link.scheme, !scheme.isEmpty,
                      link.url != nil,
                      !["http", "https"].contains(scheme.lowercased()) || link.host?.isEmpty == false,
                      !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ResearchClientError.malformedResponse("SearXNG results[\(index)].url must be an absolute URL")
                }
                let source: String?
                switch entry["engines"] {
                case .array(let engines)?:
                    let names = try engines.enumerated().map { engineIndex, engine -> String in
                        guard case .string(let name) = engine, !name.isEmpty else {
                            throw ResearchClientError.malformedResponse("SearXNG results[\(index)].engines[\(engineIndex)] must be an engine name")
                        }
                        return name
                    }
                    source = names.isEmpty ? nil : names.joined(separator: ",")
                case nil: source = nil
                default: throw ResearchClientError.malformedResponse("SearXNG results[\(index)].engines must be an array when present")
                }
                // engine is separate current evidence, never a substitute for engines.
                if let engine = entry["engine"] {
                    guard case .string = engine else {
                        throw ResearchClientError.malformedResponse("SearXNG results[\(index)].engine must be a string when present")
                    }
                }
                if results.count < 10 { results.append(ResearchSearchResult(title: title, url: url, snippet: content, source: source)) }
            } catch let error as ResearchClientError {
                gaps.append(error.localizedDescription)
            }
        }
        let engines: [JSONValue]
        switch payload["unresponsive_engines"] {
        case .array(let values)?: engines = values
        default: throw ResearchClientError.malformedResponse("SearXNG unresponsive_engines must be an array")
        }
        var failures: [String] = []
        for (index, value) in engines.enumerated() {
            try Task.checkCancellation()
            guard case .array(let pair) = value, pair.count == 2,
                  case .string(let name) = pair[0], !name.isEmpty,
                  case .string(let reason) = pair[1] else {
                gaps.append("SearXNG unresponsive_engines[\(index)] must contain an engine name and reason")
                continue
            }
            failures.append(name + ": " + reason)
        }
        self.init(results: results, unresponsiveEngines: failures, gaps: gaps)
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["results": .array(results.map { $0.toJSON() })]
        obj["gaps"] = .array(gaps.map(JSONValue.string))
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
    let retentionDirectory: URL

    public init(id: String, url: String, text: String, createdAt: String, verdict: [String: JSONValue], retentionDirectory: URL, coverage: JSONValue? = nil, sourceReceipt: JSONValue? = nil) {
        self.id = id
        self.url = url
        self.text = text
        self.createdAt = createdAt
        self.coverage = coverage
        self.sourceReceipt = sourceReceipt
        self.verdict = verdict
        self.retentionDirectory = retentionDirectory
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
        fields["receipt_retention"] = SwiftNativeResearchClient.receiptRetentionStatus(in: retentionDirectory)
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
    /// One stored source row requires string title/url/snippet and nullable
    /// source, exactly as written by toJSON.
    public init?(row: JSONValue) {
        guard case .object(let obj) = row,
              case .string(let title)? = obj["title"],
              case .string(let url)? = obj["url"],
              case .string(let snippet)? = obj["snippet"] else { return nil }
        switch obj["source"] {
        case .null?: self.init(title: title, url: url, snippet: snippet, source: nil)
        case .string(let source)?: self.init(title: title, url: url, snippet: snippet, source: source)
        default: return nil
        }
    }
}

extension ResearchLabRun {
    /// The complete current saved shape. Unknown historical evidence cannot
    /// become an empty query, brief, timestamp or connector.
    public init?(row: JSONValue) {
        guard case .object(let obj) = row,
              case .string(let id)? = obj["id"],
              case .string(let objective)? = obj["objective"],
              case .string(let status)? = obj["status"],
              case .string(let query)? = obj["query"],
              case .string(let brief)? = obj["brief"],
              case .string(let createdAt)? = obj["createdAt"],
              case .string(let connector)? = obj["connector"],
              case .array(let sourceRows)? = obj["sources"] else { return nil }
        var sources: [ResearchSearchResult] = []
        for sourceRow in sourceRows {
            guard let source = ResearchSearchResult(row: sourceRow) else { return nil }
            sources.append(source)
        }
        let error: String?
        switch obj["error"] {
        case .null?: error = nil
        case .string(let value)?: error = value
        default: return nil
        }
        self.init(
            id: id, objective: objective, status: status, query: query,
            sources: sources, brief: brief, createdAt: createdAt,
            connector: connector, error: error
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
