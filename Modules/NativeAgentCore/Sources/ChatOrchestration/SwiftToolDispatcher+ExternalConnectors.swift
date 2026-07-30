import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftToolDispatcher {
    /// gpt-5.5 review fix: XConnectorActions.timelineHome / userTweets wrap
    /// HTTP errors into `{status: "failed", statusCode: N, ...}` envelopes
    /// rather than throwing — so a raw `do { primary } catch { fallback }`
    /// never fired and the OAuth1 fallback was dead code. This helper
    /// inspects the envelope: only falls back to the OAuth1 endpoint on
    /// 401/403 auth/scope failures from OAuth2. All other failures
    /// (network, validation, rate limit, server) propagate so the LLM
    /// sees the actual error instead of a misleading second-try result.
    func xConnectorWithOAuthFallback(
        input: [String: JSONValue],
        primary: ([String: JSONValue]) async throws -> JSONValue,
        fallback: ([String: JSONValue]) async throws -> JSONValue
    ) async throws -> JSONValue {
        let primaryResult = try await primary(input)
        guard case .object(let obj) = primaryResult,
              case .string(let status)? = obj["status"],
              status == "failed" else {
            return primaryResult
        }
        let statusCode: Int = {
            if case .int(let i)? = obj["statusCode"] { return Int(i) }
            if case .double(let d)? = obj["statusCode"] { return Int(d) }
            // XConnectorActions.httpFailureEnvelope historically carried the
            // code only as error:"http_<code>" — without this parse the
            // OAuth1 fallback was dead code (audit 2026-06-09).
            if case .string(let e)? = obj["error"], e.hasPrefix("http_"),
               let code = Int(e.dropFirst("http_".count)) {
                return code
            }
            return 0
        }()
        guard statusCode == 401 || statusCode == 403 else {
            return primaryResult
        }
        return try await fallback(input)
    }

}
