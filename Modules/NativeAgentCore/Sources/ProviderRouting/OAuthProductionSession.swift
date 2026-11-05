import Foundation
import NativeAgentCore
// Blueprint: | `OAuthProductionSession.swift` | `OAuthProductionSession` enum; `make` |

enum OAuthProductionSession {
    private static let configurationFailure = "NativeAgent OAuth configuration unavailable: "

    static func make(requestTimeout: String?, resourceTimeout: String?) -> URLSession {
        let cfg = URLSessionConfiguration.default
        let failure: String?
        do {
            cfg.timeoutIntervalForRequest = try timeoutValue(requestTimeout, defaultValue: 240)
            cfg.timeoutIntervalForResource = try timeoutValue(resourceTimeout, defaultValue: 600)
            failure = nil
        } catch {
            // Construction remains nonthrowing, but the session is unavailable. Both adapters validate it before any token or transport operation.
            failure = error.localizedDescription
        }
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        session.sessionDescription = failure.map { configurationFailure + $0 }
        return session
    }

    static func validate(_ session: URLSession) throws {
        if let description = session.sessionDescription, description.hasPrefix(configurationFailure) {
            throw LLMError.providerError(message: description)
        }
    }

    private static func timeoutValue(_ raw: String?, defaultValue: TimeInterval) throws -> TimeInterval {
        guard let raw else { return defaultValue }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = TimeInterval(trimmed), parsed.isFinite, parsed > 0 else {
            throw LLMError.providerError(message: """
                OAuth timeout override must be a finite positive number of seconds. Correct the NATIVE_AGENT OAuth timeout environment setting and \
                restart NativeAgent.
                """)
        }
        return parsed
    }
}
