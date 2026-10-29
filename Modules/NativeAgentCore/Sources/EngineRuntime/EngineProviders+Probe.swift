import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import ChatTurnRuntime
// Blueprint: | `EngineProviders+Probe.swift` | `ProvidersFacade`: `testProvider`, `clearProvider` |

extension ProvidersFacade {
    // Probe the supplied API-key draft or this root's saved credential through the provider's native route.
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
        func recordProbeResult(_ result: NativeAgentShared.ProviderTestResult) async -> NativeAgentShared.ProviderTestResult {
            // Draft probes answer only the sheet; they cannot claim the configured credential was checked.
            guard draftKey == nil else { return result }
            do {
                try await LLMProviderStatusFeed.write(result, dataRoot: dataRoot, checkedAt: Date())
            } catch {
                nativeLog("provider_status: could not persist provider check: \(error.localizedDescription)")
            }
            return result
        }
        // An explicit connection check probes the current saved credential.
        if id.hasSuffix("_oauth_direct") {
            let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedProviderSnapshot()
            let probeModel = try snapshot.probeModel(for: id)
            let llm = makeResidentProviderLLMClient(dataRoot: dataRoot)
            let start = Date()
            // No turn context may override the probe's provider or budget.
            let probe = Task.detached {
                try await LLMCallContext.$providerId.withValue(id) {
                    try await llm.complete(prompt: "ping", system: "This is a provider connection check.", model: probeModel, surface: "chat", purpose: "probe", tools: nil)
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
                try Task.checkCancellation()
                return await recordProbeResult(NativeAgentShared.ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: probeModel,
                    detail: nil, error: error.localizedDescription,
                    cause: ProviderFailure.classify(error)?.encoded, credential: signIn
                ))
            }
        }

        let result = try await SwiftNativeProviderRouting.probeAPIProvider(id, dataRoot: dataRoot, draftKey: draftKey)
        try Task.checkCancellation()
        return await recordProbeResult(result)
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
    ) async throws -> (result: NativeAgentShared.ProviderTestResult, credentialReady: Bool) {
        let current = try await list().providers.first { $0.provider_id == provider.provider_id }
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
