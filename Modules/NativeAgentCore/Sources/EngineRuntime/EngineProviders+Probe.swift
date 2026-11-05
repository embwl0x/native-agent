import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import ChatTurnRuntime
import ChatTurnContracts
// Blueprint: | `EngineProviders+Probe.swift` | `ProvidersFacade`, `clearProvider`; Native probes and matched credential verification |

extension ProvidersFacade {
    public nonisolated func testProvider(_ id: String, apiKeyOverride: String? = nil, authMode: String? = nil) async throws -> NativeAgentShared
        .ProviderTestResult {
        try await beginProviderProbe(id)
        do {
            let result = try await performProviderTest(id, apiKeyOverride: apiKeyOverride, authMode: authMode)
            await settle { @MainActor in self.finishProviderProbe(id) }
            return result
        } catch {
            await settle { @MainActor in self.finishProviderProbe(id) }
            throw error
        }
    }

    @MainActor private func beginProviderProbe(_ id: String) throws {
        guard providerProbeStarts[id] == nil else {
            throw PartCallError(code: "provider_probe_running", message: "This account's connection check is already running.")
        }
        providerProbeStarts[id] = Date()
        refreshFace()
    }

    @MainActor private func finishProviderProbe(_ id: String) {
        providerProbeStarts.removeValue(forKey: id)
        refreshFace()
    }

    private nonisolated func performProviderTest(
        _ id: String, apiKeyOverride: String?, authMode: String?
    ) async throws -> NativeAgentShared.ProviderTestResult {
        // Persist verification only from the explicit native probe; readable credentials prove no reachability, and transport success does not excuse a failed
        // status write.
        let draftKey: String? = {
            let trimmed = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        func recordProbeResult(_ result: NativeAgentShared.ProviderTestResult) async throws -> NativeAgentShared.ProviderTestResult {
            // Draft probes cannot verify the configured credential.
            guard draftKey == nil else { return result }
            try await LLMProviderStatusFeed.write(result, dataRoot: dataRoot, checkedAt: Date())
            _ = await refreshSettings(refreshCatalog: false) { error, _ in error.localizedDescription }
            return result
        }
        // Explicit checks must probe the current saved credential.
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
                var turn = Turn()
                turn.envelope = .native("provider:probe:" + id)
                turn.admission = ModelAdmission(provider: id, model: model)
                var call = LLMCall(turn: turn, surface: "chat", purpose: "probe")
                call.probeCredential = credential
                let heldCall = call
                let probe = Task.detached {
                    try await llm.complete(prompt: "ping", system: "This is a provider connection check.", model: model,
                        tools: nil, call: heldCall)
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
            // Keep persistence outside transport handling so a save failure cannot become provider failure or a duplicate save.
            return try await recordProbeResult(result)
        }

        let result = try await SwiftNativeProviderRouting.probeAPIProvider(id, dataRoot: dataRoot, draftKey: draftKey)
        try Task.checkCancellation()
        return try await recordProbeResult(result)
    }

    // Lock registry removal; damaged authority must remain byte-preserved, never empty.
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
                // Validate the target before writing, preserve siblings and delete credentials last.
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
        // Failed attempts retain their cause even before request creation; later readiness cannot overwrite it.
        guard result.status != "error" else { return (result, false, false) }
        // Only the returned receipt proves this request; credential replacement mid-call earns no badge.
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
