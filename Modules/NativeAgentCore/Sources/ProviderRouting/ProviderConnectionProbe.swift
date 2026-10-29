import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ProviderConnectionProbe.swift` | provider connection probes |

public extension SwiftNativeProviderRouting {
    static func probeAPIProvider(_ id: String, dataRoot: URL, draftKey: String?) async throws -> NativeAgentShared.ProviderTestResult {
        let configFile: String? = switch id {
        case "openai", "anthropic", "moonshot", "kimi-code", "openrouter": "\(id).json"
        default: nil
        }

        guard let configFile else {
            return NativeAgentShared.ProviderTestResult(
                provider_id: id, status: "unknown", tested: false,
                response: nil, model_used: nil,
                detail: "no native probe for \(id)", error: nil
            )
        }
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
        // Status and the provider's own words through the one typed classifier.
        // A key is rejected only on invalid-credential evidence: a 401, or a 403
        // whose words say the key is invalid. Any other 403 is an unexplained
        // refusal (an OpenAI key may generate without listing models): it
        // neither rejects the key nor proves it; quota and rate limits stay theirs.
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
            // Real reachability probe: the subscription API has no free GET
            // /models, so spend one token on a minimal Messages call. Proves
            // key validity + endpoint reachability, and its 200 also confirms
            // the Anthropic-compat body shape end to end.
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

        // Free authenticated GETs: a models list, or OpenRouter's own key
        // endpoint. The key rides only in a header, never the URL, so no
        // error or log line below can carry it.
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
    /// A connectivity probe still needs A model to ask with: the model
    /// selected for this provider on any surface, or the first catalog row
    /// when it is not selected anywhere.
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

/// A local Claude CLI presence check is the only evidence this panel has for
/// its persistent-MCP connection claim. Do not manufacture readiness from a
/// provider-list payload that may have been collected before the CLI moved or
/// was removed.
public enum AnthropicMCPCLIProbe {
    public enum Availability: Equatable, Sendable {
        case checking
        case available(path: String)
        case unavailable(reason: String)
    }

    public static func probe(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Availability {
        guard let path = environment["PATH"], !path.isEmpty else {
            return .unavailable(reason: "Claude CLI could not be checked because PATH is unavailable.")
        }
        let directories = path.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        guard !directories.isEmpty else {
            return .unavailable(reason: "Claude CLI could not be checked because PATH has no absolute directories.")
        }
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("claude")
                .path
            if isExecutable(candidate) {
                return .available(path: candidate)
            }
        }
        return .unavailable(reason: "Claude CLI was not found on PATH. Install or restore Claude Code, then test again.")
    }
}
