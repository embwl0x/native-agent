import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderOAuthAdmission.swift` | Observed OAuth credential admission and expiry interpretation |

extension SwiftNativeProviderRouting {
    /// The access token a sign-in's readiness judged; a provider check binds its receipt to it, so a new sign-in is never read by the old one's check.
    public nonisolated static func signedInAccessToken(providerID: String, dataRoot: URL) throws -> String? {
        let providersDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let reading: (Bool, String, String?, unavailable: Bool)
        switch providerID {
        case "openai_oauth_direct": reading = validateOpenAIOAuthDirect(dataRoot: dataRoot)
        case "anthropic_oauth_direct": reading = validateAnthropicOAuthDirect(providersDir: providersDir)
        case "xai_oauth_direct": reading = validateXAIOAuthDirect(providersDir: providersDir)
        default: return nil
        }
        if reading.unavailable {
            throw ProviderFailure.Diagnostic(cause: .routingUnavailable, detail: reading.1)
        }
        return reading.2
    }
    nonisolated static func validateOpenAIOAuthDirect(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (Bool, String, String?, unavailable: Bool) {
        let path = ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot, environment: environment)
        let object: [String: Any]?
        do { object = try ChatGPTTransport.loadAuthBlob(at: path) }
        catch { return (false, ProviderFailure.diagnosticDescription(error), nil, true) }
        let status = ChatGPTTransport.credentialStatus(object, path: path)
        let access = (object?["tokens"] as? [String: Any])?["access_token"] as? String
        return (status.usable, status.detail, status.usable ? access : nil, false)
    }
    /// `preRead` is the routing snapshot's single locked read of this file; nil means read it here (the Provider Settings listing path).
    nonisolated static func validateAnthropicOAuthDirect(
        providersDir: URL,
        preRead: ProviderConfigRead? = nil
    ) -> (Bool, String, String?, unavailable: Bool) {
        let path = providersDir.appendingPathComponent("anthropic_oauth_direct.json")
        let parsed: [String: Any]?
        if let preRead {
            if let reason = preRead.unreadable { return (false, reason, nil, true) }
            parsed = preRead.object
        } else {
            do {
                let data = try ProviderStateValidation.dataIfPresent(at: path)
                parsed = try data.map { try ProviderStateValidation.credential(data: $0) }
            } catch {
                return (false,
                    "Anthropic credentials at \(path.path) could not be read: \(error.localizedDescription). Repair that file before reconnecting.", nil, true)
            }
        }
        // The serving adapter owns credential usability.
        let status = AnthropicOAuthTransport.credentialStatus(parsed)
        let access = parsed.flatMap { OAuthRefreshBinding.tokenSet($0, provider: "anthropic_oauth_direct")["access_token"] as? String }
        return (status.usable, status.detail, access?.isEmpty == false ? access : nil, false)
    }
    /// `preRead` is the routing snapshot's single locked read of this file; nil means read it here (the Provider Settings listing path).
    nonisolated static func validateXAIOAuthDirect(
        providersDir: URL,
        preRead: ProviderConfigRead? = nil
    ) -> (Bool, String, String?, unavailable: Bool) {
        let path = providersDir.appendingPathComponent("xai_oauth_direct.json")
        let parsed: [String: Any]?
        if let preRead {
            if let reason = preRead.unreadable { return (false, reason, nil, true) }
            parsed = preRead.object
        } else {
            do { parsed = try XAIOAuthCredentialStore.read(at: path) }
            catch { return (false,
                "xAI credentials at \(path.path) are unavailable: \(error.localizedDescription). Repair their Keychain reference in Providers.", nil, true) }
        }
        let status = XAIOAuthTransport.credentialStatus(parsed)
        let access = parsed.flatMap { OAuthRefreshBinding.string(OAuthRefreshBinding.tokenSet($0, provider: "xai_oauth_direct")["access_token"]) }
        return (status.usable, status.detail, status.usable ? access : nil, false)
    }
    /// Persisted expiry uses the shared app/routing decoding order.
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
