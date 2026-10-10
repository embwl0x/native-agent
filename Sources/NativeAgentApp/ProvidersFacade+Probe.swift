import Foundation
import Observation
import Synchronization
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import Cognition

// Provider probe and removal, run against the facade's root. Engine logic
// that belongs to ProviderRouting; it lives here until that move.
extension ProvidersFacade {
    // DAEMON-DEAD PORT (2026-06-02): native reachability probe. Resolves the
    // API key via LLMCredentialResolver (providers/<id>.json), then for
    // OpenAI hits GET /v1/models with a Bearer token and reports latency.
    // Anthropic (GET /v1/models, x-api-key) and OpenRouter (GET /api/v1/key)
    // are probed the same way; 401 (and Anthropic 403) reads "key rejected".
    //
    // User, 2026-09-06: `apiKeyOverride` is the key typed into the provider
    // sheet but not saved yet. Without it the button tested the credential on
    // disk while the sheet showed the result beside an unrelated draft — a bad
    // pasted key could read "Saved and tested" off the old saved one, and a
    // fresh install reported "no api key configured" for a valid pasted key.
    nonisolated func testProvider(_ id: String, apiKeyOverride: String? = nil) async throws -> ProviderTestResult {
        // This write is deliberately attached to the canonical, user-initiated
        // reachability probe rather than to a provider-list refresh. A readable
        // credential is not evidence that the provider was reachable. If the
        // status-file write itself fails, leave the prior record untouched so
        // its age truthfully becomes stale instead of fabricating a fresh row.
        let draftKey: String? = {
            let trimmed = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        func recordProbeResult(_ result: ProviderTestResult, checkedAt: Date = Date()) async -> ProviderTestResult {
            // A draft key is not this provider's credential — it has not been
            // saved. Its probe answers the sheet only; writing it to the status
            // feed would claim a configured provider was reachable when the
            // configured one was never touched (User, 2026-09-06).
            guard draftKey == nil else { return result }
            do {
                try await LLMProviderStatusFeed.write(result, dataRoot: dataRoot, checkedAt: checkedAt)
            } catch {
                nativeLog("provider_status: could not persist provider check: \(error.localizedDescription)")
            }
            return result
        }
        // Successful traffic already proves the OAuth path within the probe's
        // freshness window. Keep its actual date; reading it does not renew it.
        if id.hasSuffix("_oauth_direct") {
            let now = Date()
            if draftKey == nil, let evidence = try await NativeCognitionRuntime.providerPathEvidence(
                providerID: id, dataRoot: dataRoot,
                since: now.addingTimeInterval(-LLMProviderStatusFeed.staleAfter), now: now
            ) {
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "ok", tested: true, response: nil,
                    model_used: evidence.model,
                    detail: "Recent successful model call at \(evidence.observedAt.formatted(.iso8601)) proves this provider path.",
                    error: nil
                ), checkedAt: evidence.observedAt)
            }
            let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedProviderSnapshot()
            let probeModel = try Self.providerProbeModel(id, snapshot: snapshot)
            let llm = makeResidentProviderLLMClient(dataRoot: dataRoot)
            let start = Date()
            // No turn context may override the probe's provider or budget.
            let probe = Task.detached {
                try await LLMCallContext.$providerId.withValue(id) {
                    try await llm.complete(prompt: "ping", system: "This is a provider connection check. Reply with one word.", model: probeModel, surface: "chat", purpose: "probe")
                }
            }
            do {
                _ = try await withTaskCancellationHandler {
                    try await probe.value
                } onCancel: {
                    probe.cancel()
                }
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "ok", tested: true,
                    response: nil, model_used: probeModel,
                    detail: "latency=\(Int(Date().timeIntervalSince(start) * 1000))ms", error: nil
                ))
            } catch is CancellationError {
                // The caller gave up; that says nothing about the provider.
                throw CancellationError()
            } catch {
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: probeModel,
                    detail: nil, error: error.localizedDescription
                ))
            }
        }

        let configFile: String? = switch id {
        case "openai", "anthropic", "moonshot", "kimi-code", "openrouter": "\(id).json"
        default: nil
        }

        guard let configFile else {
            return await recordProbeResult(ProviderTestResult(
                provider_id: id, status: "unknown", tested: false,
                response: nil, model_used: nil,
                detail: "no native probe for \(id)", error: nil
            ))
        }
        guard let apiKey = draftKey ?? LLMCredentialResolver.resolveAPIKey(
            providerConfigFile: configFile, dataRoot: dataRoot
        ), !apiKey.isEmpty else {
            return await recordProbeResult(ProviderTestResult(
                provider_id: id, status: "error", tested: false,
                response: nil, model_used: nil,
                detail: nil, error: "no api key configured"
            ))
        }

        if id == "kimi-code" {
            let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedProviderSnapshot()
            let probeModel = try Self.providerProbeModel(id, snapshot: snapshot)
            // Real reachability probe: the subscription API has no free GET
            // /models, so spend one token on a minimal Messages call. Proves
            // key validity + endpoint reachability, and its 200 also confirms
            // the Anthropic-compat body shape end to end.
            var req = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/messages")!)
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
                let (_, response) = try await URLSession.shared.data(for: req)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    return await recordProbeResult(ProviderTestResult(
                        provider_id: id, status: "ok", tested: true,
                        response: nil, model_used: probeModel,
                        detail: "latency=\(ms)ms", error: nil
                    ))
                }
                let hint = code == 401 ? "key rejected" : "HTTP \(code)"
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: probeModel,
                    detail: "latency=\(ms)ms", error: hint
                ))
            } catch {
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: nil,
                    detail: nil, error: error.localizedDescription
                ))
            }
        }

        // Free authenticated GETs: a models list, or OpenRouter's own key
        // endpoint. The key rides only in a header, never the URL, so no
        // error or log line below can carry it.
        let modelsEndpoint: URL = switch id {
        case "moonshot": MoonshotModelCatalog.endpoint
        case "anthropic": URL(string: "https://api.anthropic.com/v1/models")!
        case "openrouter": URL(string: "https://openrouter.ai/api/v1/key")!
        default: URL(string: "https://api.openai.com/v1/models")!
        }
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
            let (_, response) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                if id == "moonshot" {
                    _ = await MoonshotModelCatalog.models(dataRoot: dataRoot, refresh: true)
                }
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "ok", tested: true,
                    response: nil, model_used: nil,
                    detail: "latency=\(ms)ms", error: nil
                ))
            }
            return await recordProbeResult(ProviderTestResult(
                provider_id: id, status: "error", tested: true,
                response: nil, model_used: nil,
                // Anthropic answers a bad key with 401 or 403.
                detail: "latency=\(ms)ms",
                error: code == 401 || (id == "anthropic" && code == 403) ? "key rejected" : "HTTP \(code)"
            ))
        } catch {
            return await recordProbeResult(ProviderTestResult(
                provider_id: id, status: "error", tested: true,
                response: nil, model_used: nil,
                detail: nil, error: error.localizedDescription
                    .replacingOccurrences(of: apiKey, with: "[redacted]")
            ))
        }
    }

    /// A connectivity probe still needs A model to ask with: the model
    /// selected for this provider on any surface, or the first catalog row
    /// when it is not selected anywhere.
    private nonisolated static func providerProbeModel(_ id: String, snapshot: ProviderCatalogSnapshot) throws -> String {
        guard let provider = snapshot.providers.first(where: { $0.id == id }) else {
            throw ProviderRoutingError.providerNotFound
        }
        let selectedSurface = MODEL_SURFACES.first { snapshot.routing.activeProviders[$0] == id }
        let selectedModel = selectedSurface.flatMap { snapshot.routing.preferences[$0]?.model }
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

    // Remove the matching registry entry under its lock; damaged authority
    // must remain byte-preserved rather than becoming an empty registry.
    nonisolated func clearProvider(_ id: String) async throws {
        // User, 2026-09-06: the facade's own root, not the process default — a
        // removal against an override root was deleting the default install's
        // registry row and credential file and leaving the intended one intact.
        let path = dataRoot.appendingPathComponent("providers/registry.json")
        let persistence = SwiftNativePersistenceCore()
        guard !id.isEmpty, id != ".", id != "..",
              id.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789_-".contains($0) }),
              !["registry", "models", "active", "surfaces", "pending-surface-configuration",
                "openrouter-models-cache", "moonshot-models-cache"].contains(id) else {
            throw ProviderRoutingError.invalidRequest
        }
        let credFile = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(id).json")
        let reference = try await persistence.withFileLock(path) {
            _ = try SwiftNativeProviderRouting.loadProviderRegistryChecked(at: path)
            return try await persistence.withFileLock(credFile) { () async throws -> String? in
                // Validate the target row and credential before the first write.
                // Unrelated rows survive; credential deletion still happens last.
                let remaining = try ProviderStateValidation.registryRemovingProvider(at: path, providerID: id)
                let credential = try ProviderStateValidation.credential(at: credFile)
                let fields = try SwiftNativeProviderRouting.loadProviderStateObjectChecked(
                    at: credFile, description: "provider \(id) configuration"
                )
                try SwiftNativeProviderRouting.validateProviderConfiguration(fields)
                let reference = credential[ProviderAPIKeyStore.referenceField] as? String
                if let remaining {
                    try await persistence.writeJSON(.array(remaining), to: path)
                }
                do {
                    try FileManager.default.removeItem(at: credFile)
                } catch {
                    let failure = error as NSError
                    guard failure.domain == NSCocoaErrorDomain,
                          failure.code == NSFileNoSuchFileError else { throw error }
                }
                return reference
            }
        }
        if let reference {
            do {
                try ProviderAPIKeyStore.delete(reference)
            } catch {
                nativeLog("provider_credentials: provider removed; unused Keychain item cleanup failed")
            }
        }
    }
}
