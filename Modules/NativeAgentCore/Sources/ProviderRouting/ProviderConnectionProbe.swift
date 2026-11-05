import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ProviderConnectionProbe.swift` | Native probe capabilities and request-bound OAuth credential evidence; API-key connection probes |

/// One probe's last transport attempt, including a token renewed after 401. Only a fingerprint is retained; readiness never supplies request evidence.
public final class OAuthProbeCredential: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: String?

    public init() {}

    public var fingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func sending(_ request: URLRequest) {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ") else { return }
        lock.lock()
        defer { lock.unlock() }
        sent = LLMProviderStatusFeed.fingerprint(String(authorization.dropFirst("Bearer ".count)))
    }
}
public extension SwiftNativeProviderRouting {
    enum ConnectionProbe: Sendable {
        case oauth, apiKey, unsupported
    }

    static func connectionProbe(_ id: String, authMode: String?) -> ConnectionProbe {
        switch (id, authMode) {
        case ("openai_oauth_direct", nil), ("anthropic_oauth_direct", nil), ("xai_oauth_direct", nil),
             ("openai_oauth_direct", "oauth"?), ("anthropic_oauth_direct", "oauth"?), ("xai_oauth_direct", "oauth"?):
            return .oauth
        case ("openai", nil), ("anthropic", nil), ("moonshot", nil), ("kimi-code", nil), ("openrouter", nil),
             ("openai", "api_key"?), ("anthropic", "api_key"?), ("moonshot", "api_key"?), ("kimi-code", "api_key"?), ("openrouter", "api_key"?):
            return .apiKey
        default: return .unsupported
        }
    }

    static func unsupportedConnectionProbe(_ id: String) -> NativeAgentShared.ProviderTestResult {
        .init(provider_id: id, status: "unknown", tested: false,
              response: nil, model_used: nil,
              detail: "No native connection test is available for this provider and sign-in method. It was not checked.", error: nil)
    }

    static func probeAPIProvider(_ id: String, dataRoot: URL, draftKey: String?) async throws -> NativeAgentShared.ProviderTestResult {
        guard case .apiKey = connectionProbe(id, authMode: "api_key") else {
            return unsupportedConnectionProbe(id)
        }
        let configFile = "\(id).json"
        guard let apiKey = try draftKey ?? LLMCredentialResolver.checkedAPIKey(
            providerConfigFile: configFile, dataRoot: dataRoot
        ), !apiKey.isEmpty else {
            return NativeAgentShared.ProviderTestResult(
                provider_id: id, status: "error", tested: false,
                response: nil, model_used: nil,
                detail: nil, error: "no api key configured"
            )
        }

        // Hashed before anything is sent: the verdict belongs to exactly this key.
        let credential = LLMProviderStatusFeed.fingerprint(apiKey)
        func failed(_ failure: ProviderFailure, model: String?, evidence: String,
                    meaning: String? = nil) -> NativeAgentShared.ProviderTestResult {
            NativeAgentShared.ProviderTestResult(
                provider_id: id, status: "error", tested: true, response: nil, model_used: model, detail: evidence,
                error: failure == .authExpired ? LLMProviderStatusFeed.keyRejected
                    : evidence + " — " + (meaning ?? failure.errorDescription ?? "the check failed"),
                cause: failure.encoded, credential: credential)
        }
        // Only invalid-credential evidence rejects a key. An unexplained 403 neither proves nor rejects it; quota and rate limits retain their own causes.
        func refused(_ code: Int, _ body: Data, model: String?, ms: Int) -> NativeAgentShared.ProviderTestResult {
            let detail = String(ProviderFailure.wireDetail(body).replacingOccurrences(of: apiKey, with: "[redacted]").prefix(160))
            let evidence = "HTTP \(code) after \(ms)ms" + (detail.isEmpty ? "" : ": " + detail)
            guard code == 403 else { return failed(ProviderFailure.http(status: code, detail: detail), model: model, evidence: evidence) }
            let worded = ProviderFailure.wire(detail, fallback: .refused)
            return worded == .refused
                ? failed(.refused, model: model, evidence: evidence,
                         meaning: "this check's endpoint refused without saying why; the key is neither rejected nor proven")
                : failed(worded, model: model, evidence: evidence)
        }

        if id == "kimi-code" {
            let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedProviderSnapshot()
            let probeModel = try snapshot.probeModel(for: id)
            // The subscription endpoint has no free models probe, so a one-token Messages request proves credentials, reachability and wire compatibility.
            guard let endpoint = URL(string: "https://api.kimi.com/coding/v1/messages") else { throw URLError(.badURL) }
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.timeoutInterval = 20
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": probeModel,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ])
            let start = Date()
            do {
                let (body, response) = try await URLSession.shared.data(for: req)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    return NativeAgentShared.ProviderTestResult(
                        provider_id: id, status: "ok", tested: true,
                        response: nil, model_used: probeModel,
                        detail: "latency=\(ms)ms", error: nil, credential: credential
                    )
                }
                return refused(code, body, model: probeModel, ms: ms)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                return failed(ProviderFailure.classify(error) ?? .network, model: nil,
                              evidence: error.localizedDescription.replacingOccurrences(of: apiKey, with: "[redacted]"))
            }
        }

        // Free authenticated GETs: a models list, or OpenRouter's own key endpoint. The key rides only in a header, never the URL, so no error or log line
        // below can carry it.
        let modelsEndpoint: URL? = switch id {
        case "moonshot": MoonshotModelCatalog.endpoint
        case "anthropic": URL(string: "https://api.anthropic.com/v1/models")
        case "openrouter": URL(string: "https://openrouter.ai/api/v1/key")
        default: URL(string: "https://api.openai.com/v1/models")
        }
        guard let modelsEndpoint else { throw URLError(.badURL) }
        var req = URLRequest(url: modelsEndpoint)
        req.httpMethod = "GET"
        if id == "anthropic" {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 15
        let start = Date()
        do {
            let (body, response) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                var catalogDetail = ""
                if id == "moonshot" {
                    let models = try MoonshotModelCatalog.parseModelsResponse(body)
                    guard !models.isEmpty else { throw LLMError.invalidResponse(status: code) }
                    let result = await MoonshotModelCatalog.ttlCache.publish(
                        ModelCatalogFetch(models: models, isComplete: true), credential: apiKey, dataRoot: dataRoot)
                    if case .failure(let failure) = result, !failure.superseded {
                        catalogDetail = "; catalog not saved: \(failure.reason)"
                    }
                }
                return NativeAgentShared.ProviderTestResult(
                    provider_id: id, status: "ok", tested: true,
                    response: nil, model_used: nil,
                    detail: "latency=\(ms)ms" + catalogDetail, error: nil, credential: credential
                )
            }
            return refused(code, body, model: nil, ms: ms)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return failed(ProviderFailure.classify(error) ?? .network, model: nil,
                          evidence: error.localizedDescription.replacingOccurrences(of: apiKey, with: "[redacted]"))
        }
    }
}

public extension ProviderCatalogSnapshot {
    /// A probe needs an explicit model: use the provider's selected model, else its first declared catalog row.
    func probeModel(for id: String) throws -> String {
        guard let provider = providers.first(where: { $0.id == id }) else {
            throw ProviderRoutingError.providerNotFound
        }
        let selectedSurface = MODEL_SURFACES.first { routing.activeProviders[$0] == id }
        let selectedModel = selectedSurface.flatMap { routing.preferences[$0]?.model }
        let offeredModels: [String]
        if case .array(let models)? = provider.modelCatalog {
            offeredModels = models.compactMap {
                guard case .object(let row) = $0, case .string(let model)? = row["id"] else { return nil }
                return model
            }
        } else { offeredModels = [] }
        guard let probeModel = selectedModel.flatMap({ offeredModels.contains($0) ? $0 : nil })
            ?? offeredModels.first else { throw ProviderRoutingError.unavailable }
        return probeModel
    }

}

private enum ProbeCredentialPart: LLMCallPart { static let unset: OAuthProbeCredential? = nil }
extension LLMCall {
    public var probeCredential: OAuthProbeCredential? {
        get { self[ProbeCredentialPart.self] }
        set { self[ProbeCredentialPart.self] = newValue }
    }
}
