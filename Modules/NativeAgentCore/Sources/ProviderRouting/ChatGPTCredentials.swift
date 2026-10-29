import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `ChatGPTCredentials.swift` | ChatGPTTransport credential discovery, exact account binding and serialized single-use token refresh |
extension ChatGPTTransport {
    /// Explicit injection wins; otherwise use the shared credential discovery
    /// and CLI-adoption consent rules in OpenAIOAuthCredentials.
    /// Effort levels the signed-in account's discovered catalog lists for `model`.
    func accountModel(_ model: String) -> CodexAccountModelCatalog.Model? {
        CodexAccountModelCatalog.matchingModels(
            providerID: "openai_oauth_direct",
            oauthAuthURL: resolveAuthPath(),
            fallbackCacheURL: CodexAccountModelCatalog.cacheCandidate()
        ).first { $0.id == model }
    }
    func resolveAuthPath() -> URL {
        Self.preferredAuthPath(dataRoot: dataRootOverride, authPathOverride: authPathOverride)
    }

    internal func exhaustedCredentialError() -> LLMError {
        if Self.isUserCodexPath(resolveAuthPath()) {
            return .failure(.codexCLISessionExpired)
        }
        return .authRejected(provider: "openai_oauth_direct", detail: OpenAIOAuthDirectExhaustedMarker)
    }
    static func effectiveExpiry(_ access: String, blob: [String: Any]) -> Int? {
        let tokens = blob["tokens"] as? [String: Any] ?? [:]
        return [tokenExpiresAt(access), persistedExpiresAt(blob: blob, tokens: tokens)]
            .compactMap { $0 }.min()
    }
    private static func accessTokenIsFresh(_ expiry: Int?, buffer: Int) -> Bool {
        guard let expiry, expiry > 0 else { return false }
        return TimeInterval(expiry) > Date().timeIntervalSince1970 + TimeInterval(buffer)
    }
    /// The adapter's read verdict; CLI rotation remains owned by the CLI.
    public static func credentialStatus(_ auth: [String: Any]?, path: URL) -> (usable: Bool, detail: String, health: OAuthCredentialHealth) {
        if let auth, OAuthRefreshBinding.hasInvalidExpiry(auth, provider: "openai_oauth_direct") {
            return (false, "Saved expires_at is invalid — repair the credential or sign in again",
                OAuthCredentialHealth(configured: false, expiresAt: nil, canRefresh: false))
        }
        let tokens = auth?["tokens"] as? [String: Any] ?? [:]
        let access = tokens["access_token"] as? String ?? ""
        let cli = isUserCodexPath(path)
        let canRefresh = !cli && OAuthRefreshBinding.string(tokens["refresh_token"]) != nil
            && auth.map { OAuthRefreshBinding.permitsRefresh($0, provider: "openai_oauth_direct") } == true
        let expiry = auth.flatMap { effectiveExpiry(access, blob: $0) }
        let fresh = !access.isEmpty && accessTokenIsFresh(expiry, buffer: cli ? 0 : Int(OAuthGrantOperations.renewalMargin))
        let usable = !access.isEmpty && (fresh || canRefresh)
        let invalidExpiry = expiry.map { $0 <= 0 } == true
        let detail = invalidExpiry ? "The saved credential expiry is invalid. Reconnect your ChatGPT account in Providers."
            : usable ? (fresh ? "Signed in" : "Signed in. Your session will renew on your next chat.")
            : auth == nil ? "Sign in to your ChatGPT account in Providers." : "Reconnect your ChatGPT account in Providers."
        return (usable, detail, OAuthCredentialHealth(configured: usable, expiresAt: expiry.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            canRefresh: canRefresh, requiresRefresh: !fresh))
    }
    /// The CLI owns token rotation. Re-read its file once on expiry or 401;
    /// never acquire a credential lock or spend its single-use refresh grant.
    private func rereadCLIAccessToken(
        at path: URL, staleToken: String?, requestAccount: OAuthRequestAccount
    ) throws -> String {
        // A bound helper must recheck consent before reading the shared file.
        guard resolveAuthPath().standardizedFileURL == path.standardizedFileURL,
              let blob = Self.loadAuthBlob(at: path) else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        try requestAccount.check(blob, provider: "openai_oauth_direct", allowUnboundIdentity: true)
        guard let access = (blob["tokens"] as? [String: Any])?["access_token"] as? String,
              !access.isEmpty,
              Self.accessTokenIsFresh(Self.effectiveExpiry(access, blob: blob), buffer: 0),
              access != staleToken else {
            throw LLMError.failure(.codexCLISessionExpired)
        }
        return access
    }
    /// Re-read under path-scoped refresh serialization and retain the request's
    /// account binding. A forced refresh reuses a token rotated since staleToken.
    func ensureFreshAccessToken(
        forceRefresh: Bool = false,
        staleToken: String? = nil,
        requestAccount: OAuthRequestAccount = OAuthRequestAccount()
    ) async throws -> String {
        // Fast path OUTSIDE the lock — check disk; return if still fresh.
        let path = resolveAuthPath()
        let isCLI = Self.isUserCodexPath(path)
        guard let blob0 = Self.loadAuthBlob(at: path) else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        try requestAccount.check(blob0, provider: "openai_oauth_direct", rejectedToken: staleToken,
                                 allowUnboundIdentity: isCLI)
        let tokens0 = (blob0["tokens"] as? [String: Any]) ?? [:]
        guard let access0 = tokens0["access_token"] as? String, !access0.isEmpty else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        if isCLI {
            if !forceRefresh, Self.accessTokenIsFresh(Self.effectiveExpiry(access0, blob: blob0), buffer: 0) {
                return access0
            }
            return try rereadCLIAccessToken(
                at: path, staleToken: forceRefresh ? (staleToken ?? access0) : nil,
                requestAccount: requestAccount)
        }
        if !forceRefresh {
            // Freshness uses the earlier of JWT exp and persisted expires_at.
            if Self.accessTokenIsFresh(Self.effectiveExpiry(access0, blob: blob0), buffer: Int(OAuthGrantOperations.renewalMargin)) {
                return access0
            }
            // Missing expiry requires refresh.
        }
        // Slow path — serialize via the refresh queue so concurrent callers
        // share ONE refresh instead of double-rotating refresh_token.
        return try await Self.sharedRefreshActor(for: path).run {
            // Re-load INSIDE the critical section: another waiter may have
            // already refreshed while we were queued.
            guard self.resolveAuthPath().standardizedFileURL == path.standardizedFileURL,
                  let baseline = try? Data(contentsOf: path),
                  let blob = try? JSONSerialization.jsonObject(with: baseline) as? [String: Any] else {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            try requestAccount.check(blob, provider: "openai_oauth_direct")
            let tokens = (blob["tokens"] as? [String: Any]) ?? [:]
            guard let access = tokens["access_token"] as? String, !access.isEmpty else {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            if forceRefresh, let staleToken, !staleToken.isEmpty, access != staleToken {
                return access
            }
            if !forceRefresh {
                if Self.accessTokenIsFresh(Self.effectiveExpiry(access, blob: blob), buffer: Int(OAuthGrantOperations.renewalMargin)) {
                    return access  // someone else already refreshed
                }
            }
            return try await self.refreshTokens(at: path, baseline: baseline, blob: blob, requestAccount: requestAccount)
        }
    }
    /// Codex refreshes on its own once a token is inside its last 5 minutes,
    /// and a child job can run for many minutes, so a child starts only with
    /// an hour or more left.
    private static let codexChildRefreshBufferSec: Int = 3_600

    /// Validate the selected credential before spawning. App-owned credentials
    /// renew through the normal refresh queue and sync their access-only copy;
    /// CLI-owned sessions remain read-only. Never resolve a second path here.
    public static func prepareCodexChildHome(_ codexHome: URL, authPath: URL) async throws {
        guard credentialStatus(loadAuthBlob(at: authPath), path: authPath).usable else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        guard let childHome = codexChildHome(mirroring: authPath) else { return }
        guard childHome.standardizedFileURL == codexHome.standardizedFileURL else {
            throw LLMError.underlying(message: "Codex child home does not match the selected credential.")
        }
        if let blob = loadAuthBlob(at: authPath),
           let access = (blob["tokens"] as? [String: Any])?["access_token"] as? String,
           !access.isEmpty,
           !accessTokenIsFresh(effectiveExpiry(access, blob: blob), buffer: codexChildRefreshBufferSec) {
            _ = try await ChatGPTTransport(authPathOverride: authPath)
                .ensureFreshAccessToken(forceRefresh: true, staleToken: access)
        }
        try syncCodexChildCopy(from: authPath)
    }
    /// Refresh and persist tokens at the original app-owned path.
    @discardableResult
    private func refreshTokens(
        at path: URL, baseline: Data, blob: [String: Any], requestAccount: OAuthRequestAccount
    ) async throws -> String {
        // Never rotate the Codex CLI's credentials.
        guard !Self.isUserCodexPath(path) else {
            throw LLMError.failure(.codexCLISessionExpired)
        }
        try ProviderStateValidation.credential(blob)
        guard let tokens = blob["tokens"] as? [String: Any] else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        try OAuthRefreshBinding.requireRefresh(blob, provider: "openai_oauth_direct")
        // Refresh form contains neither scope nor redirect_uri.
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": openAIPublicClientID,
        ]

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await OAuthGrantOperations.post(refreshEndpoint, body, timeout: 30, session: session)
        } catch {
            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: refreshEndpoint, operation: "refresh"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            // 429/5xx are transient; preserve Retry-After for 429.
            if status == 429 {
                throw LLMError.rateLimited(
                    message: "openai_oauth_direct refresh HTTP 429 (temporary)",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                throw LLMError.transient(
                    message: "openai_oauth_direct refresh HTTP \(status) (temporary)")
            }
            // Rejected refresh grants carry reconnect guidance and the provider's error detail.
            throw LLMError.authRejected(
                provider: "openai_oauth_direct", detail: providerErrorDetail(data))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.underlying(message: "refresh: unparseable response")
        }
        try OAuthRefreshBinding.requireSameAccount(payload, original: blob, provider: "openai_oauth_direct")

        // Preserve account_id and other fields the refresh response doesn't return.
        var newBlob = blob
        var merged = tokens
        for key in ["access_token", "refresh_token", "id_token"] {
            if let v = payload[key] as? String, !v.isEmpty {
                merged[key] = v
            }
        }
        // Re-extract account_id if the new access token has one and we
        // don't already have it persisted (fresh sign-in path).
        if let access = merged["access_token"] as? String,
           (merged["account_id"] as? String)?.isEmpty ?? true {
            if let acct = Self.extractAccountIDFromJWT(access) {
                merged["account_id"] = acct
            }
        }
        newBlob["tokens"] = merged
        newBlob["last_refresh"] = NativeTimestampFormat.plainZulu(Date())
        // Also write a top-level expires_at so the OAuth status UI (and the
        // ensureFreshAccessToken persisted-exp fast path) doesn't need to
        // decode the JWT just to know when the next refresh fires. Prefer
        // payload.expires_in (server-authoritative); fall back to the JWT.
        if let exp_in = payload["expires_in"] as? Int {
            let d = Date().addingTimeInterval(TimeInterval(exp_in))
            newBlob["expires_at"] = NativeTimestampFormat.plainZulu(d)
        } else if let access = merged["access_token"] as? String,
                  let exp = Self.tokenExpiresAt(access) {
            let d = Date(timeIntervalSince1970: TimeInterval(exp))
            newBlob["expires_at"] = NativeTimestampFormat.plainZulu(d)
        }
        // Compare original bytes and write under the sign-in/sign-out credential
        // lock. Changed/deleted credentials must not be overwritten or resurrected;
        // any replacement token must still match the request's original account.
        enum RefreshWrite { case wrote, superseded(Data), supersededAndGone }
        let outcome: RefreshWrite
        do {
            // Serialize the blob to bytes outside the closure so we don't
            // carry a non-Sendable [String: Any] across the boundary.
            let bytes = try JSONSerialization.data(
                withJSONObject: newBlob,
                options: [.prettyPrinted, .sortedKeys]
            )
            outcome = try CredentialFileLock.withLock(path) { () -> RefreshWrite in
                guard let current = try? Data(contentsOf: path) else { return .supersededAndGone }
                guard current == baseline else { return .superseded(current) }
                try Self.writeAuthBytesAtomically(bytes, to: path)
                // The rotation is already on disk, so a failed child copy must
                // not fail this refresh; the next Codex spawn re-syncs it and
                // fails loudly there (`prepareCodexChildHome`).
                do {
                    try Self.writeCodexChildCopy(bytes, of: path)
                } catch {
                    FileHandle.standardError.write(Data(
                        "ChatGPTTransport: Codex child credential copy failed: \(error)\n".utf8
                    ))
                }
                return .wrote
            }
        } catch {
            // Rotation consumed the single-use token; persistence failure is fatal.
            FileHandle.standardError.write(Data(
                "ChatGPTTransport: PERSIST FAILED after token rotation — on-disk refresh_token is now stale: \(error)\n".utf8
            ))
            throw LLMError.underlying(
                message: "openai oauth: token rotated but persist failed (\(error.localizedDescription)) — re-sign-in may be required"
            )
        }
        switch outcome {
        case .superseded(let current):
            guard let object = try JSONSerialization.jsonObject(with: current) as? [String: Any] else {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            try requestAccount.check(object, provider: "openai_oauth_direct")
            guard let access = OAuthRefreshBinding.string(OAuthRefreshBinding.tokenSet(object, provider: "openai_oauth_direct")["access_token"]) else {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            return access
        case .supersededAndGone:
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        case .wrote:
            break
        }
        guard let newAccess = merged["access_token"] as? String, !newAccess.isEmpty else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        return newAccess
    }
}
