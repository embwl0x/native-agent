import Foundation
import PersistenceCore
import ProviderRouting

extension NativeOAuthFlow {
    /// Disk-only sign-out: remove the provider's token file. Returns true if
    /// a file was removed (or absent).
    static func clearTokens(providerId: String) -> Bool {
        let normalized = normalizedOAuthProviderId(providerId)
        switch providerId {
        case "openai_oauth_direct":
            let sharedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("auth.json")
                .standardizedFileURL
                .path
            for path in OpenAIOAuthDirectAdapter.authPathCandidates(dataRoot: PersistenceCore.defaultDataRoot()) {
                guard path.standardizedFileURL.path != sharedCodexAuth else { continue }
                if FileManager.default.fileExists(atPath: path.path) {
                    try? FileManager.default.removeItem(at: path)
                }
            }
            return true
        case "anthropic_oauth_direct":
            let path = anthropicTokenPath()
            if FileManager.default.fileExists(atPath: path.path) {
                try? FileManager.default.removeItem(at: path)
            }
            return true
        default:
            guard normalized == "xai_oauth_direct" else { return false }
            let path = XAIOAuthDirectAdapter.tokenPath()
            if FileManager.default.fileExists(atPath: path.path) {
                try? FileManager.default.removeItem(at: path)
            }
            return true
        }
    }

    /// Read the persisted `expires_at` for a provider, or nil if not
    /// signed in / no expiry persisted.
    static func expiresAt(providerId: String) -> Date? {
        let path: URL
        switch normalizedOAuthProviderId(providerId) {
        case "openai_oauth_direct":    path = openAIReadableAuthPath() ?? openAIAuthPath()
        case "anthropic_oauth_direct": path = anthropicTokenPath()
        case "xai_oauth_direct":       path = XAIOAuthDirectAdapter.tokenPath()
        default: return nil
        }
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let d = parseExpiresAt(obj["expires_at"]) { return d }
        if let tokens = obj["tokens"] as? [String: Any] {
            if let d = parseExpiresAt(tokens["expires_at"]) { return d }
            if let access = tokens["access_token"] as? String,
               let payload = jwtPayload(access) {
                if let exp = payload["exp"] as? Int {
                    return Date(timeIntervalSince1970: TimeInterval(exp))
                }
                if let exp = payload["exp"] as? Double {
                    return Date(timeIntervalSince1970: exp)
                }
            }
        }
        if let access = obj["access_token"] as? String,
           let payload = jwtPayload(access) {
            if let exp = payload["exp"] as? Int {
                return Date(timeIntervalSince1970: TimeInterval(exp))
            }
            if let exp = payload["exp"] as? Double {
                return Date(timeIntervalSince1970: exp)
            }
        }
        return nil
    }

    /// Format `expires_at` as a short status string for the OAuth badge.
    static func signInStatusDetail(providerId: String) -> String? {
        guard isSignedIn(providerId: providerId) else { return nil }
        guard let exp = expiresAt(providerId: providerId) else { return "Signed in" }
        let now = Date()
        let remaining = exp.timeIntervalSince(now)
        if remaining <= 0 {
            return "Expired — refresh on next chat"
        }
        let totalSec = Int(remaining)
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let label: String
        if hours >= 1 {
            label = "\(hours)h \(minutes)m"
        } else if minutes >= 1 {
            label = "\(minutes)m"
        } else {
            label = "<1m"
        }
        if remaining <= 120 {
            return "Signed in (refresh on next chat)"
        }
        return "Signed in (expires in \(label))"
    }

    /// Best-effort on-disk auth check used by the UI status badge.
    static func isSignedIn(providerId: String) -> Bool {
        switch normalizedOAuthProviderId(providerId) {
        case "openai_oauth_direct":
            guard let path = openAIReadableAuthPath(),
                  let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = obj["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String,
                  !access.isEmpty
            else { return false }
            return true
        case "anthropic_oauth_direct":
            guard let data = try? Data(contentsOf: anthropicTokenPath()),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            if let s = obj["access_token"] as? String, !s.isEmpty { return true }
            if let nested = (obj["tokens"] as? [String: Any])?["access_token"] as? String,
               !nested.isEmpty { return true }
            return false
        case "xai_oauth_direct":
            guard let data = try? Data(contentsOf: XAIOAuthDirectAdapter.tokenPath()),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            if let s = obj["access_token"] as? String, !s.isEmpty { return true }
            if let nested = (obj["tokens"] as? [String: Any])?["access_token"] as? String,
               !nested.isEmpty { return true }
            return false
        default: return false
        }
    }

    // MARK: - Paths (shared with the read-side adapters)

    static func openAIAuthPath() -> URL {
        OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: PersistenceCore.defaultDataRoot())
    }

    static func openAIReadableAuthPath() -> URL? {
        OpenAIOAuthDirectAdapter
            .authPathCandidates(dataRoot: PersistenceCore.defaultDataRoot())
            .first { OpenAIOAuthDirectAdapter.hasUsableTokens(at: $0) }
    }

    static func anthropicTokenPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
    }
}
