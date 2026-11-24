import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import SenseCore
// Blueprint: | `ChatGPTCredentials.swift` | ChatGPT credential discovery, CLI-owned sessions and account-bound renewal |
extension ChatGPTTransport {
    /// Explicit injection wins; otherwise use the shared credential discovery and CLI-adoption consent rules in OpenAIOAuthCredentials. Effort levels the
    /// signed-in account's discovered catalog lists for `model`.
    func accountModel(_ model: String, preview: Bool = false) -> CodexAccountModelCatalog.Model? {
        CodexAccountModelCatalog.matchingModels(
            providerID: "openai_oauth_direct",
            oauthAuthURL: resolveAuthPath(),
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(), preview: preview
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
    public static func credentialStatus(at path: URL) throws -> (usable: Bool, detail: String, health: OAuthCredentialHealth) {
        credentialStatus(try loadAuthBlob(at: path), path: path)
    }

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
    /// The CLI owns token rotation. Re-read its file once on expiry or 401; never acquire a credential lock or spend its single-use refresh grant.
    private func rereadCLIAccessToken(
        at path: URL, staleToken: String?, requestAccount: OAuthRequestAccount
    ) throws -> String {
        // A bound helper must recheck consent before reading the shared file.
        guard resolveAuthPath().standardizedFileURL == path.standardizedFileURL,
              let blob = try Self.loadAuthBlob(at: path) else {
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
    /// Re-read under path-scoped refresh serialization and retain the request's account binding. A forced refresh reuses a token rotated since staleToken.
    func ensureFreshAccessToken(
        forceRefresh: Bool = false,
        staleToken: String? = nil,
        requestAccount: OAuthRequestAccount = OAuthRequestAccount()
    ) async throws -> String {
        let path = resolveAuthPath()
        if Self.isUserCodexPath(path) {
            guard let blob = try Self.loadAuthBlob(at: path),
                  let access = (blob["tokens"] as? [String: Any])?["access_token"] as? String, !access.isEmpty else {
                throw LLMError.notConfigured(provider: providerId)
            }
            try requestAccount.check(blob, provider: providerId, rejectedToken: staleToken, allowUnboundIdentity: true)
            if !forceRefresh, Self.accessTokenIsFresh(Self.effectiveExpiry(access, blob: blob), buffer: 0) { return access }
            return try rereadCLIAccessToken(at: path, staleToken: forceRefresh ? (staleToken ?? access) : nil, requestAccount: requestAccount)
        }
        return try await OAuthTokenManager.resolve(.file(path), read: { [self] in
            guard resolveAuthPath().standardizedFileURL == path.standardizedFileURL else { throw OAuthRequestAccount.changed(providerId) }
            guard let auth = try Self.checkedAuth(at: path) else { throw LLMError.notConfigured(provider: providerId) }
            try requestAccount.check(auth.object, provider: providerId, rejectedToken: staleToken)
            guard let access = (auth.object["tokens"] as? [String: Any])?["access_token"] as? String, !access.isEmpty else {
                throw LLMError.notConfigured(provider: providerId)
            }
            return (bytes: auth.bytes, access: access, expiry: Self.effectiveExpiry(access, blob: auth.object))
        }, current: { state in
            if forceRefresh {
                guard let staleToken, !staleToken.isEmpty, state.access != staleToken else { return nil }
                return state.access
            }
            return Self.accessTokenIsFresh(state.expiry, buffer: Int(OAuthGrantOperations.renewalMargin)) ? state.access : nil
        }, renew: { [self] state in
            try await refreshTokens(at: path, baseline: state.bytes, blob: ProviderStateValidation.credential(data: state.bytes), requestAccount: requestAccount)
        })
    }
    /// A child may run for minutes and the CLI refreshes in its last five, so require an hour of validity at spawn.
    private static let codexChildRefreshBufferSec: Int = 3_600

    /// Validate the selected credential before spawning. App-owned credentials renew through the normal refresh queue and sync their access-only copy;
    /// CLI-owned sessions remain read-only. Never resolve a second path here. Returns the access token the child is handed.
    @discardableResult
    public static func prepareCodexChildHome(_ codexHome: URL, authPath: URL) async throws -> String? {
        let auth = try loadAuthBlob(at: authPath)
        guard credentialStatus(auth, path: authPath).usable else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        // A CLI-owned session has no copy: the child reads this file in place.
        guard let childHome = codexChildHome(mirroring: authPath) else { return (auth?["tokens"] as? [String: Any])?["access_token"] as? String }
        guard childHome.standardizedFileURL == codexHome.standardizedFileURL else {
            throw LLMError.underlying(message: "Codex child home does not match the selected credential.")
        }
        if let blob = auth,
           let access = (blob["tokens"] as? [String: Any])?["access_token"] as? String,
           !access.isEmpty,
           !accessTokenIsFresh(effectiveExpiry(access, blob: blob), buffer: codexChildRefreshBufferSec) {
            _ = try await ChatGPTTransport(authPathOverride: authPath)
                .ensureFreshAccessToken(forceRefresh: true, staleToken: access)
        }
        return try syncCodexChildCopy(from: authPath)
    }
    @discardableResult
    private func refreshTokens(
        at path: URL, baseline: Data, blob: [String: Any], requestAccount: OAuthRequestAccount
    ) async throws -> String {
        guard let refreshEndpoint else {
            throw LLMError.providerError(message: "ChatGPT refresh endpoint is invalid; correct its provider configuration.")
        }
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
        let answer = try await OAuthTokenManager.exchange(provider: providerId, endpoint: refreshEndpoint, client: openAIPublicClientID,
            refresh: refresh, session: session, original: blob)
        let payload = answer.fields
        let newAccess = answer.accessToken

        // Preserve account_id and other fields the refresh response doesn't return.
        var newBlob = blob
        var merged = tokens
        merged.removeValue(forKey: "expires_at")
        merged.removeValue(forKey: "expires_in")
        merged["access_token"] = newAccess
        if let refresh = answer.refreshToken { merged["refresh_token"] = refresh }
        if let idToken = payload["id_token"] as? String, !idToken.isEmpty {
            merged["id_token"] = idToken
        }
        if (merged["account_id"] as? String)?.isEmpty ?? true,
           let acct = Self.extractAccountIDFromJWT(newAccess) {
            merged["account_id"] = acct
        }
        newBlob["last_refresh"] = NativeTimestampFormat.plainZulu(Date())
        newBlob["tokens"] = merged
        // The new token owns its expiry. Never retain the preceding token's date.
        newBlob.removeValue(forKey: "expires_at")
        newBlob.removeValue(forKey: "expires_in")
        newBlob["expires_at"] = answer.expiresIn.map { NativeTimestampFormat.plainZulu(Date().addingTimeInterval($0)) }
        let bytes = try JSONSerialization.data(withJSONObject: newBlob, options: [.prettyPrinted, .sortedKeys])
        return try OAuthTokenManager.commit(path: path, baseline: baseline, exact: true, provider: providerId,
            account: requestAccount, access: newAccess, read: { try ProviderStateValidation.dataIfPresent(at: path) }) { _ in
            try Self.writeAuthBytesAtomically(bytes, to: path)
            do { try Self.writeCodexChildCopy(bytes, of: path) }
            catch { FileHandle.standardError.write(Data("ChatGPTTransport: Codex child credential copy failed: \(error)\n".utf8)) }
        }
    }
}
