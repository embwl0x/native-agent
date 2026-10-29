import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Research+WebSearch.swift` | `WebSearchRoutes`: SearXNG results or its plain failure; without SearXNG, `browser_search` (Chrome or their own browser); actual-route receipts and untrusted web-content labels |

/// SearXNG is her search, every engine it has: its results, or its failure
/// said plainly (no fallback hides a broken SearXNG; Doctor names it). A Mac
/// without SearXNG searches through a browser instead — Chrome through the
/// extension when it is connected, else her own browser: the result hands her
/// that search as `browser_search`, which she runs and reads.
public enum WebSearchRoutes {
    /// The whole result envelope: `{status: ok, result: {results, route, elapsed_ms, ...}}`,
    /// `{status: failed, reason, message}`, or, without SearXNG, `{status: ok, result:
    /// {route: chrome|browser, results: [], browser_search}}`.
    public static func search(
        query: String, categories: String?, timeRange: String?,
        chromeConnected: @Sendable () async -> Bool,
        searxng: @Sendable () async throws -> ResearchSearchResponse
    ) async -> JSONValue {
        let started = Date()
        func elapsed() -> JSONValue { .int(Int64(Date().timeIntervalSince(started) * 1000)) }
        func failure(_ reason: String, _ message: String) -> JSONValue {
            .object(["status": .string("failed"), "reason": .string(reason), "route": .string("searxng"),
                     "elapsed_ms": elapsed(), "message": .string("Web search failed. \(message)")])
        }
        let cancelled: JSONValue = .object(["status": .string("cancelled"), "reason": .string("cancelled"),
                                            "message": .string("Web search was cancelled.")])
        do {
            try Task.checkCancellation()
            let response = try await searxng()
            try Task.checkCancellation()
            if response.enginesFailed {
                return failure("searxng_failed", "SearXNG's engines gave no sources: "
                    + response.unresponsiveEngines.joined(separator: "; ") + ". Run Doctor to check SearXNG.")
            }
            guard case .object(var result) = response.toJSON() else {
                return failure("searxng_unreadable", "The search response was unreadable. Retry this search.")
            }
            result["route"] = .string("searxng")
            result["untrusted_remote_data"] = .bool(!response.results.isEmpty)
            if !response.results.isEmpty { result["agent"] = .string("web") }
            else { result["message"] = .string("No results from SearXNG. Try other words.") }
            result["elapsed_ms"] = elapsed()
            return .object(["status": .string("ok"), "result": .object(result)])
        } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return cancelled
        } catch ResearchClientError.notConfigured {
            // No SearXNG on this Mac: the browser is how this Mac searches.
        } catch {
            return failure("searxng_failed", "SearXNG did not answer (\(error.localizedDescription)). Run Doctor to check SearXNG.")
        }
        let chrome = await chromeConnected()
        if Task.isCancelled { return cancelled }
        let place = chrome ? "Chrome" : "your browser"
        let read = chrome ? "it returns the results page" : "then read it with browser.text"
        return .object(["status": .string("ok"), "result": .object([
            "route": .string(chrome ? "chrome" : "browser"),
            "results": .array([]),
            "message": .string("This Mac has no SearXNG, so search in \(place): run browser_search; \(read)."),
            "browser_search": .object([
                "action": .string(chrome ? "chrome.navigate" : "browser.open"),
                "args": .object(["url": .string(browserSearchURL(query: query, categories: categories,
                                                                 timeRange: timeRange, chrome: chrome))]),
            ]),
            "elapsed_ms": elapsed(),
        ])])
    }

    /// Google in her Chrome (the person's real browser); DuckDuckGo's plain
    /// results page in her own browser, which has no sign-in to clear a consent wall.
    static func browserSearchURL(query: String, categories: String?, timeRange: String?, chrome: Bool) -> String {
        let span = ["day": "d", "week": "w", "month": "m", "year": "y"][timeRange ?? ""]
        var components = URLComponents()
        components.scheme = "https"
        components.host = chrome ? "www.google.com" : "html.duckduckgo.com"
        components.path = chrome ? "/search" : "/html/"
        var items = [URLQueryItem(name: "q", value: query)]
        if chrome {
            if categories == "news" { items.append(URLQueryItem(name: "tbm", value: "nws")) }
            if let span { items.append(URLQueryItem(name: "tbs", value: "qdr:\(span)")) }
        } else if let span {
            items.append(URLQueryItem(name: "df", value: span))
        }
        components.queryItems = items
        // URLQueryItem leaves "+", which search engines read as a space ("C++").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url?.absoluteString ?? ""
    }
}
