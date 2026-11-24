import Synchronization
import Foundation
import NativeAgentCore
import PersistenceCore
import os

// Blueprint: | `OAuthTokenManager.swift` | Credential-scoped renewal, account-bound exchange and compare-and-save |

enum OAuthTokenManager {
    enum Credential: Hashable, Sendable {
        case file(URL)
        case secret(String)
    }

    private static let queues = Mutex([Credential: AsyncSerialQueue]())

    static func queue(_ credential: Credential) -> AsyncSerialQueue {
        let key = switch credential {
        case .file(let path): Credential.file(path.standardizedFileURL)
        case .secret: credential
        }
        return queues.withLock { queues in
            if let queue = queues[key] { return queue }
            let queue = AsyncSerialQueue()
            queues[key] = queue
            return queue
        }
    }

    static func resolve<State: Sendable, Value: Sendable>(
        _ credential: Credential,
        read: @escaping @Sendable () throws -> State,
        current: @escaping @Sendable (State) throws -> Value?,
        renew: @escaping @Sendable (State) async throws -> Value
    ) async throws -> Value {
        if case .file = credential, let value = try current(read()) { return value }
        return try await queue(credential).run {
            let state = try read()
            if let value = try current(state) { return value }
            return try await renew(state)
        }
    }

    private static func refreshForm(client: String, refresh: String) -> [String: String] {
        ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client]
    }

    nonisolated(nonsending) static func exchange(_ renewal: Keyring.Renewal) async throws -> OAuthGrantOperations.TokenResponse {
        var form = refreshForm(client: renewal.clientID, refresh: renewal.refreshToken)
        form["client_secret"] = renewal.clientSecret
        let tokens = try await OAuthGrantOperations.postToken(renewal.token, form, basic: renewal.clientAuth == "basic")
        return try OAuthGrantOperations.validateTokenResponse(tokens, requiringRefreshToken: false)
    }

    nonisolated(nonsending) static func exchange(provider: String, endpoint: URL, client: String, refresh: String,
                         session: URLSession, original: [String: Any]) async throws -> OAuthGrantOperations.TokenResponse {
        try OAuthRefreshBinding.requireRefresh(original, provider: provider)
        let form = refreshForm(client: client, refresh: refresh)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await OAuthGrantOperations.post(endpoint, form, json: provider == "anthropic_oauth_direct", session: session)
        } catch {
            throw mapTransportError(error, fallback: transientNetworkError(error, provider: provider, host: endpoint.host, operation: "refresh"))
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = http.statusCode
        if status == 429 { throw LLMError.failure(.rateLimited(retryAfter: parseRetryAfterSeconds(from: response))) }
        if (500..<600).contains(status) { throw LLMError.transient(message: "\(provider) refresh HTTP \(status) (temporary)") }
        if !(200..<300).contains(status) {
            if provider == "xai_oauth_direct" { throw xaiRejection(status, data) }
            throw LLMError.authRejected(provider: provider, detail: providerErrorDetail(data))
        }
        let answer = try OAuthGrantOperations.validateTokenResponse(data, requiringRefreshToken: false)
        try OAuthRefreshBinding.requireSameAccount(answer.fields, original: original, provider: provider)
        return answer
    }

    private static func xaiRejection(_ status: Int, _ data: Data) -> LLMError {
        if status == 403 {
            return .failure(.http(status: status, detail: "xAI refused token renewal; review the account's access in Providers."))
        }
        var rejected = status == 401
        if status == 400 {
            guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.http(status: status, detail: "xAI token endpoint returned an unreadable HTTP 400 error; review its account setup."))
            }
            rejected = fields["error"] as? String == "invalid_grant"
        }
        if rejected {
            return .authRejected(provider: "xai_oauth_direct", detail: "xAI rejected token renewal. Reconnect the account in Providers.")
        }
        return .underlying(message: "xai_oauth_direct refresh HTTP \(status); review its account setup in Providers.")
    }

    static func commit(path: URL, baseline: Data, exact: Bool = false, provider: String,
                       account: OAuthRequestAccount, access: String,
                       read: () throws -> Data?, write: (Data) throws -> Void) throws -> String {
        let replacement: Data?
        do {
            replacement = try CredentialFileLock.withLock(path) {
                guard let current = try read() else { throw LLMError.notConfigured(provider: provider) }
                let matches = exact ? current == baseline
                    : CredentialFileLock.credentialGeneration(ofFileContents: current) == CredentialFileLock.credentialGeneration(ofFileContents: baseline)
                guard matches else { return current }
                try write(current)
                return nil
            }
        } catch let error as LLMError { throw error }
        catch {
            throw LLMError.underlying(message: "\(provider): token rotated but persist failed (\(error.localizedDescription)) — re-sign-in may be required")
        }
        guard let replacement else { return access }
        let object = try ProviderStateValidation.credential(data: replacement)
        try account.check(object, provider: provider)
        guard let token = OAuthRefreshBinding.string(OAuthRefreshBinding.tokenSet(object, provider: provider)["access_token"]) else {
            throw LLMError.notConfigured(provider: provider)
        }
        return token
    }
}
