import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import ChatTurnRuntime
// Blueprint: | `EngineProviders+Probe.swift` | `ProvidersFacade`: native capability-directed checks, outgoing-credential receipts, post-probe saved-credential matching and `clearProvider` |

extension ProvidersFacade {
    // Probe the supplied API-key draft or this root's saved credential through the provider's native route.
    public nonisolated func testProvider(_ id: String, apiKeyOverride: String? = nil, authMode: String? = nil) async throws -> NativeAgentShared.ProviderTestResult {
        // This write is deliberately attached to the canonical, user-initiated
        // reachability probe rather than to a provider-list refresh. A readable
        // credential is not evidence that the provider was reachable. If the
        // status-file write itself fails, report that failure to the caller;
        // a passing transport probe alone is not a saved verification.
        let draftKey: String? = {
            let trimmed = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        func recordProbeResult(_ result: NativeAgentShared.ProviderTestResult) async throws -> NativeAgentShared.ProviderTestResult {
            // Draft probes answer only the sheet; they cannot claim the configured credential was checked.
            guard draftKey == nil else { return result }
            try await LLMProviderStatusFeed.write(result, dataRoot: dataRoot, checkedAt: Date())
            return result
        }
        // An explicit connection check probes the current saved credential.
        let capability = SwiftNativeProviderRouting.connectionProbe(id, authMode: authMode)
        switch capability {
        case .unsupported:
            return try await recordProbeResult(SwiftNativeProviderRouting.unsupportedConnectionProbe(id))
        case .apiKey: break
        case .oauth:
            let start = Date()
            let credential = OAuthProbeCredential()
            var probeModel: String?
            let result: NativeAgentShared.ProviderTestResult
            do {
                let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedProviderSnapshot()
                let model = try snapshot.probeModel(for: id)
                probeModel = model
                let llm = makeResidentProviderLLMClient(dataRoot: dataRoot)
                // No turn context may override the probe's provider or budget.
                let probe = Task.detached {
                    try await LLMCallContext.$providerId.withValue(id) {
                        try await OAuthProbeCredential.$current.withValue(credential) {
                            try await llm.complete(prompt: "ping", system: "This is a provider connection check.", model: model, surface: "chat", purpose: "probe", tools: nil)
                        }
                    }
                }
                _ = try await withTaskCancellationHandler {
                    try await probe.value
                } onCancel: {
                    probe.cancel()
                }
                guard let fingerprint = credential.fingerprint else {
                    throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                        detail: "The native probe completed without request credential evidence; the saved account was not verified.")
                }
                result = NativeAgentShared.ProviderTestResult(
                    provider_id: id, status: "ok", tested: true,
                    response: nil, model_used: probeModel,
                    detail: "latency=\(Int(Date().timeIntervalSince(start) * 1000))ms", error: nil,
                    credential: fingerprint
                )
            } catch is CancellationError {
                // The caller gave up; that says nothing about the provider.
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                result = NativeAgentShared.ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: probeModel,
                    detail: nil, error: error.localizedDescription,
                    cause: ProviderFailure.classify(error)?.encoded, credential: credential.fingerprint
                )
            }
            // Persistence is outside the transport catch: a save failure must
            // neither become a provider failure nor trigger a second save.
            return try await recordProbeResult(result)
        }

        let result = try await SwiftNativeProviderRouting.probeAPIProvider(id, dataRoot: dataRoot, draftKey: draftKey)
        try Task.checkCancellation()
        return try await recordProbeResult(result)
    }

    // Remove the matching registry entry under its lock; damaged authority
    // must remain byte-preserved rather than becoming an empty registry.
    public nonisolated func clearProvider(_ id: String) async throws {
        // Provider removal is confined to the facade's data root.
        let path = dataRoot.appendingPathComponent("providers/registry.json")
        guard !id.isEmpty, id != ".", id != "..",
              id.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789_-".contains($0) }),
              !["registry", "models", "active", "surfaces", "pending-surface-configuration",
                "openrouter-models-cache", "moonshot-models-cache"].contains(id) else {
            throw ProviderRoutingError.invalidRequest
        }
        let credFile = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(id).json")
        let reference = try await SwiftNativePersistenceCore.withFileLock(path) {
            _ = try SwiftNativeProviderRouting.loadProviderRegistryChecked(at: path)
            return try await SwiftNativePersistenceCore.withFileLock(credFile) { () async throws -> String? in
                // Validate the target row and credential before the first write.
                // Unrelated rows survive; credential deletion still happens last.
                let remaining = try ProviderStateValidation.registryRemovingProvider(at: path, providerID: id)
                let credential = try ProviderStateValidation.credential(at: credFile)
                let reference = credential[ProviderAPIKeyStore.referenceField] as? String
                if let remaining {
                    try await SwiftNativePersistenceCore.writeJSON(.array(remaining), to: path)
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
    ) async throws -> (result: NativeAgentShared.ProviderTestResult, credentialReady: Bool, credentialMatches: Bool) {
        let draft = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let testsDraft = authMode == "api_key" && !draft.isEmpty
        let result = try await testProvider(provider.provider_id,
            apiKeyOverride: testsDraft ? draft : nil, authMode: authMode)
        guard !testsDraft else { return (result, false, false) }
        // A failed attempt owns its cause, even if admission/refresh failed
        // before a request existed. Later readiness reads cannot replace it.
        guard result.status != "error" else { return (result, false, false) }
        // This is a consumer checking the returned receipt, never a source of
        // request evidence. A replacement during the call earns no badge.
        let current = try await list().providers.first { $0.provider_id == provider.provider_id }
        let credentialReady = current?.auth_status.eligible == true
            && (current?.auth_mode == authMode || (current?.auth_mode == nil && provider.auth_modes.count == 1))
        let matches: Bool
        if let tested = result.credential {
            matches = try LLMProviderStatusFeed.credentialFingerprint(providerID: provider.provider_id, dataRoot: dataRoot) == tested
        } else { matches = false }
        return (result, credentialReady, matches)
    }
}
