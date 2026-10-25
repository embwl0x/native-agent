import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import ChatTurnRuntime
import Cognition
// Blueprint: | `EngineProviders+Probe.swift` | `ProvidersFacade`: `testProvider`, `clearProvider` |

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
    public nonisolated func testProvider(_ id: String, apiKeyOverride: String? = nil) async throws -> NativeAgentShared.ProviderTestResult {
        // This write is deliberately attached to the canonical, user-initiated
        // reachability probe rather than to a provider-list refresh. A readable
        // credential is not evidence that the provider was reachable. If the
        // status-file write itself fails, leave the prior record untouched so
        // its age truthfully becomes stale instead of fabricating a fresh row.
        let draftKey: String? = {
            let trimmed = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        func recordProbeResult(_ result: NativeAgentShared.ProviderTestResult, checkedAt: Date = Date()) async -> NativeAgentShared.ProviderTestResult {
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
                return await recordProbeResult(NativeAgentShared.ProviderTestResult(
                    provider_id: id, status: "ok", tested: true, response: nil,
                    model_used: evidence.model,
                    detail: "Recent successful model call at \(evidence.observedAt.formatted(.iso8601)) proves this provider path.",
                    error: nil
                ), checkedAt: evidence.observedAt)
            }
            let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedProviderSnapshot()
            let probeModel = try snapshot.probeModel(for: id)
            let llm = makeResidentProviderLLMClient(dataRoot: dataRoot)
            let start = Date()
            // No turn context may override the probe's provider or budget.
            let probe = Task.detached {
                try await LLMCallContext.$providerId.withValue(id) {
                    try await llm.complete(prompt: "ping", system: "This is a provider connection check.", model: probeModel, surface: "chat", purpose: "probe")
                }
            }
            // The sign-in this check sends, hashed before it is sent, as a key's
            // probe does; a refresh during the call leaves the receipt unbound.
            let signIn = LLMProviderStatusFeed.credentialFingerprint(providerID: id, dataRoot: dataRoot)
            do {
                _ = try await withTaskCancellationHandler {
                    try await probe.value
                } onCancel: {
                    probe.cancel()
                }
                return await recordProbeResult(NativeAgentShared.ProviderTestResult(
                    provider_id: id, status: "ok", tested: true,
                    response: nil, model_used: probeModel,
                    detail: "latency=\(Int(Date().timeIntervalSince(start) * 1000))ms", error: nil,
                    credential: signIn
                ))
            } catch is CancellationError {
                // The caller gave up; that says nothing about the provider.
                throw CancellationError()
            } catch {
                return await recordProbeResult(NativeAgentShared.ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: probeModel,
                    detail: nil, error: error.localizedDescription,
                    cause: ProviderFailure.classify(error)?.encoded, credential: signIn
                ))
            }
        }

        return await recordProbeResult(try await SwiftNativeProviderRouting.probeAPIProvider(id, dataRoot: dataRoot, draftKey: draftKey))
    }

    // Remove the matching registry entry under its lock; damaged authority
    // must remain byte-preserved rather than becoming an empty registry.
    public nonisolated func clearProvider(_ id: String) async throws {
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

extension ProvidersFacade {
    @MainActor
    public func testConfiguredProvider(
        _ provider: ProviderInfo, authMode: String, apiKey: String
    ) async throws -> (result: NativeAgentShared.ProviderTestResult, credentialReady: Bool) {
        let current = try await list().first { $0.provider_id == provider.provider_id }
        let credentialReady = current?.auth_status.eligible == true
            && (current?.auth_mode == authMode || (current?.auth_mode == nil && provider.auth_modes.count == 1))
        let result: NativeAgentShared.ProviderTestResult
        if authMode != "api_key" {
            result = .init(provider_id: provider.provider_id, status: "unknown", tested: false,
                response: nil, model_used: nil,
                detail: "No connection test is available for this sign-in method. It was not checked.", error: nil)
        } else {
            let draft = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            result = try await testProvider(provider.provider_id, apiKeyOverride: draft.isEmpty ? nil : draft)
        }
        return (result, credentialReady)
    }
}
