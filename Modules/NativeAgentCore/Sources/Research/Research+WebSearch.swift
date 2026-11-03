import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Research+WebSearch.swift` | `WebSearchRoutes`: checked SearXNG results, explicit not-configured/runtime failures and untrusted web-content labels; no alternate search route |

/// SearXNG owns web search. Configuration and transport failures remain
/// failed search receipts with the cause and setup remedy.
public enum WebSearchRoutes {
    /// The whole result envelope: `{status: ok, result: {results, route, elapsed_ms, ...}}`,
    /// or `{status: failed, reason, message}`.
    public static func search(
        query: String, categories: String?, timeRange: String?,
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
                return .object(["status": .string("failed"), "reason": .string("searxng_failed"),
                    "route": .string("searxng"), "elapsed_ms": elapsed(), "result": response.toJSON(),
                    "message": .string("SearXNG's engines gave no sources: "
                        + response.unresponsiveEngines.joined(separator: "; ") + ". Run Doctor to check SearXNG.")])
            }
            guard case .object(var result) = response.toJSON() else {
                return failure("searxng_unreadable", "The search response was unreadable. Retry this search.")
            }
            result["route"] = .string("searxng")
            result["untrusted_remote_data"] = .bool(!response.results.isEmpty)
            if !response.results.isEmpty { result["agent"] = .string("web") }
            else { result["message"] = .string(response.gaps.isEmpty
                ? "No results from SearXNG. Try other words."
                : "No usable results; the named result gaps do not establish no matches. Repair the reported SearXNG result fields.") }
            result["elapsed_ms"] = elapsed()
            return .object(["status": .string("ok"), "result": .object(result)])
        } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return cancelled
        } catch ResearchClientError.notConfigured {
            return failure("searxng_not_configured", "SearXNG is not configured. Configure SearXNG in Research settings, then retry the search.")
        } catch {
            return failure("searxng_failed", "SearXNG did not answer (\(error.localizedDescription)). Run Doctor to check SearXNG.")
        }
    }

}
