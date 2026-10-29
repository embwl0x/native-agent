import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderOAuthAdmission.swift` | Observed OAuth credential admission and expiry interpretation |

extension SwiftNativeProviderRouting {
    /// The access token a sign-in's readiness judged; a provider check binds its receipt to it, so a new sign-in is never read by the old one's check.
    public nonisolated static func signedInAccessToken(providerID: String, dataRoot: URL) -> String? {
        let providersDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
        return switch providerID {
        case "openai_oauth_direct": validateOpenAIOAuthDirect(dataRoot: dataRoot).2
        case "anthropic_oauth_direct": validateAnthropicOAuthDirect(providersDir: providersDir).2
        case "xai_oauth_direct": validateXAIOAuthDirect(providersDir: providersDir).2
        default: nil
        }
    }
    nonisolated static func validateOpenAIOAuthDirect(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (Bool, String, String?) {
        let path = ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot, environment: environment)
        let object = ChatGPTTransport.loadAuthBlob(at: path)
        let status = ChatGPTTransport.credentialStatus(object, path: path)
        let access = (object?["tokens"] as? [String: Any])?["access_token"] as? String
        return (status.usable, status.detail, status.usable ? access : nil)
    }
    /// `preRead` is the routing snapshot's single locked read of this file; nil means read it here (the Provider Settings listing path).
    nonisolated static func validateAnthropicOAuthDirect(
        providersDir: URL,
        preRead: ProviderConfigRead? = nil
    ) -> (Bool, String, String?) {
        let path = providersDir.appendingPathComponent("anthropic_oauth_direct.json")
        let parsed: [String: Any]?
        if let preRead {
            parsed = preRead.object
        } else if let data = try? Data(contentsOf: path) {
            parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            parsed = nil
        }
        // The adapter that serves the calls decides (see credentialStatus).
        let status = AnthropicOAuthTransport.credentialStatus(parsed)
        let access = parsed.flatMap { OAuthRefreshBinding.tokenSet($0, provider: "anthropic_oauth_direct")["access_token"] as? String }
        return (status.usable, status.detail, access?.isEmpty == false ? access : nil)
    }
    /// `preRead` is the routing snapshot's single locked read of this file; nil means read it here (the Provider Settings listing path).
    nonisolated static func validateXAIOAuthDirect(
        providersDir: URL,
        preRead: ProviderConfigRead? = nil
    ) -> (Bool, String, String?) {
        let path = providersDir.appendingPathComponent("xai_oauth_direct.json")
        let parsed: [String: Any]?
        if let preRead {
            parsed = preRead.object
        } else {
            do { parsed = try XAIOAuthCredentialStore.read(at: path) }
            catch { return (false, "xAI Keychain credentials are unavailable. Reconnect in Providers.", nil) }
        }
        let status = XAIOAuthTransport.credentialStatus(parsed)
        let access = parsed.flatMap { OAuthRefreshBinding.string(OAuthRefreshBinding.tokenSet($0, provider: "xai_oauth_direct")["access_token"]) }
        return (status.usable, status.detail, status.usable ? access : nil)
    }
    /// Decodes persisted OAuth expiry values in the shared app/routing compatibility order.
    public nonisolated static func parseAuthExpiresAt(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        // Persisted expiry must be a representable calendar instant, not merely a finite wire number. Invalid values remain invalid credentials.
        func epoch(_ seconds: TimeInterval) -> Date? {
            guard seconds.isFinite,
                  seconds >= Date.distantPast.timeIntervalSince1970,
                  seconds <= Date.distantFuture.timeIntervalSince1970 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        if let i = raw as? Int { return epoch(TimeInterval(i)) }
        if let d = raw as? Double { return epoch(d) }
        guard let s = raw as? String, !s.isEmpty else { return nil }
        if let unix = TimeInterval(s) { return epoch(unix) }
        return NativeTimestampFormat.parseBasicZulu(s) ?? NativeTimestampFormat.parseISO8601(s)
    }
}
