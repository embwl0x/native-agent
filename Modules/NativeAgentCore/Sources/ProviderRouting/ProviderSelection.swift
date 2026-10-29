import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderSelection.swift` | Provider picker transactions through the existing tuple lock |
extension SwiftNativeProviderRouting {
    public func listProviders() async throws -> [Provider] {
        try await checkedProviderSnapshot().providers
    }
    /// Catalog discovery finishes before the one checked routing read. Every
    /// displayed connection and resolved preference then uses the same config cache.
    public func checkedProviderSnapshot(
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderCatalogSnapshot {
        async let openRouterRead = OpenRouterModelCatalog.modelsWithFreshness(dataRoot: dataRoot)
        async let moonshotRead = MoonshotModelCatalog.modelsWithFreshness(dataRoot: dataRoot)
        let (openRouter, moonshot) = await (openRouterRead, moonshotRead)
        let state = try await reconciledPickerState()
        let inventory = try nativeListProviders(
            openRouterModels: openRouter.models.map { $0.providerJSON() },
            moonshotModels: moonshot.models.map { model in
                var row = model.providerJSON()
                row["default_reasoning_effort"] = .string(MoonshotModelCatalog.defaultReasoningEffort(for: model.id))
                row["supported_reasoning_efforts"] = .array(MoonshotModelCatalog.supportedReasoningEfforts(for: model.id).map { .string($0) })
                row["supports_fast"] = .bool(false)
                return row
            },
            codexCacheURL: codexCacheURL, authEnvironment: authEnvironment,
            additionalProviderIDs: Set(state.active.values)
        )
        let cache = inventory.cache
        return ProviderCatalogSnapshot(
            routing: routingSnapshot(
                surfaces: state.surfaces, activeProviders: state.active,
                soleConnectedRoute: soleConnectedProviderID(cache: cache), configCache: cache,
                revision: state.revision
            ),
            providers: inventory.providers.map { provider in
                var row = provider
                if case .object(var extras)? = row.extras {
                    if row.id == "openrouter" { extras["models_note"] = openRouter.note.map(JSONValue.string) }
                    if row.id == "moonshot" { extras["models_note"] = moonshot.note.map(JSONValue.string) }
                    row.extras = .object(extras)
                }
                return row
            },
            rowSet: ProviderSurfaceRowSet(
                surfacePreferenceKeys: Set(state.surfaces.keys), activeProviderKeys: Set(state.active.keys)
            )
        )
    }
    public func selectionValidator() async throws -> @Sendable (String, String) throws -> Void {
        let providers = try await checkedProviderSnapshot().providers
        return { route, model in
            guard let provider = providers.first(where: { $0.id == route }),
                  provider.configured == true,
                  case .array(let models)? = provider.modelCatalog,
                  models.contains(where: {
                      guard case .object(let row) = $0 else { return false }
                      return row["id"] == .string(model)
                  }) else {
                throw ProviderRoutingError.configurationFailed("\(route) cannot serve \(model). Refresh Providers and choose an available model.")
            }
        }
    }
    public func getProvider(id: String) async throws -> Provider {
        guard let provider = try await listProviders().first(where: { $0.id == id }) else {
            throw ProviderRoutingError.providerNotFound
        }
        return provider
    }
    /// Local choices for helper creation; no network probe or setting change.
    /// The normal creation gate still validates the explicitly chosen tuple.
    public func botModelChoices() throws -> JSONValue {
        let openRouterModels = OpenRouterModelCatalog.readCache(dataRoot: dataRoot)?.map { $0.providerJSON() }
        let moonshotModels = MoonshotModelCatalog.readCache(dataRoot: dataRoot)?.map { model in
            var row = model.providerJSON()
            row["default_reasoning_effort"] = .string(MoonshotModelCatalog.defaultReasoningEffort(for: model.id))
            row["supported_reasoning_efforts"] = .array(MoonshotModelCatalog.supportedReasoningEfforts(for: model.id).map { .string($0) })
            row["supports_fast"] = .bool(false)
            return row
        }
        let rows = try nativeListProviders(
            openRouterModels: openRouterModels, moonshotModels: moonshotModels
        ).providers.filter { $0.configured == true }.map { provider in
            let shipped = !CodexAccountModelCatalog.isAccountBackedProvider(provider.id)
                && (provider.id != "moonshot" || moonshotModels == nil)
                && !FirstPartyModelCatalog.models(forProviderID: provider.id).isEmpty
            let models: [[String: JSONValue]]
            if case .array(let saved)? = provider.modelCatalog {
                models = saved.compactMap { if case .object(let row) = $0 { return row }; return nil }
            } else { models = [] }
            let keys: Set<String> = ["id", "name", "supported_reasoning_efforts", "default_reasoning_effort", "supports_fast", "supports_tools"]
            return JSONValue.object([
                "provider": .string(provider.id), "name": .string(provider.displayName ?? provider.id),
                "readiness": .string("credentials_available"),
                "catalog_source": .string(shipped ? "shipped_catalog" : "local_catalog_suggestions"),
                "models": .array(models.prefix(40).map { .object($0.filter { keys.contains($0.key) }) }),
                "models_truncated": .bool(models.count > 40)
            ])
        }
        return .object(["providers": .array(rows),
            "detail": .string("Choose provider, model and reasoning_effort explicitly. These are local catalog choices on configured accounts, not a live service test. Non-shipped catalogs may be incomplete; creation validates the chosen route. No account or model setting changed.")])
    }
    public func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        guard case .object(let body) = config else {
            throw ProviderRoutingError.invalidRequest
        }
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
            throw ProviderRoutingError.invalidRequest
        }
        try Self.validateProviderConfiguration(body)
        try ProviderStateValidation.credentialFields(body)
        let path = providersDir.appendingPathComponent("\(id).json")
        try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            _ = try ProviderStateValidation.dataIfPresent(at: path)
            if id == "xai_oauth_direct" { _ = try XAIOAuthCredentialStore.read(at: path) }
            var entry = try Self.loadProviderStateObjectChecked(
                at: path,
                description: "provider \(id) configuration"
            )
            try Self.validateProviderConfiguration(entry)
            try ProviderStateValidation.credentialFields(entry)
            if let mode = Self.firstString(body, keys: ["auth_mode", "authMode"]) {
                entry["auth_mode"] = .string(mode)
            }
            let oldReference = Self.firstString(entry, keys: [ProviderAPIKeyStore.referenceField])
            var newReference: String?
            if let apiKey = Self.firstString(body, keys: ["api_key", "apiKey", "key"]) {
                let reference = try ProviderAPIKeyStore.insert(apiKey)
                newReference = reference
                entry[ProviderAPIKeyStore.referenceField] = .string(reference)
                entry.removeValue(forKey: "api_key")
            }
            if let accessToken = Self.firstString(body, keys: ["access_token", "accessToken"]) {
                // A pasted/setup token is a new sign-in with no refresh grant.
                for key in ["tokens", "refresh_token", "id_token", "account_id", "account", "user_info",
                            "oauth_account_identity", "refresh_token_account_identity", "expires_at", "expires_in"] {
                    entry.removeValue(forKey: key)
                }
                entry["access_token"] = .string(accessToken)
            }
            if let model = Self.firstString(body, keys: ["default_model", "defaultModel", "model"]) {
                entry["default_model"] = .string(model)
            }
            if entry["auth_mode"] == nil {
                entry["auth_mode"] = .string(id.contains("oauth") ? "oauth" : "api_key")
            }
            do {
                if id == "xai_oauth_direct", entry["access_token"] != nil {
                    let object = try ProviderStateValidation.credential(data: JSONEncoder().encode(JSONValue.object(entry)))
                    try XAIOAuthCredentialStore.write(object, to: path)
                } else {
                    try await SwiftNativePersistenceCore.writeJSON(.object(entry), to: path)
                }
            } catch {
                // writeJSON can fail after rename. Delete the new item only
                // when checked readback proves its reference was not committed.
                if let newReference {
                    var unreferenced = false
                    do {
                        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path))
                        if case .object(let object) = saved {
                            unreferenced = Self.firstString(object, keys: [ProviderAPIKeyStore.referenceField]) != newReference
                        }
                    } catch {
                        let failure = error as NSError
                        unreferenced = failure.domain == NSCocoaErrorDomain
                            && failure.code == NSFileReadNoSuchFileError
                    }
                    if unreferenced {
                        do {
                            try ProviderAPIKeyStore.delete(newReference)
                        } catch {
                            nativeLog("provider_credentials: save failed; unused Keychain item cleanup failed")
                        }
                    }
                }
                throw error
            }
            if newReference != nil, let oldReference {
                do {
                    try ProviderAPIKeyStore.delete(oldReference)
                } catch {
                    // Cleanup cannot turn a committed rotation into a failed save.
                    nativeLog("provider_credentials: key saved; unused Keychain item cleanup failed")
                }
            }
        }
        // Freshen the authenticated model catalog for providers whose live
        // `/models` list needs credentials. Both refresh paths are non-fatal
        // (models() swallows failures) and keep the on-disk cache — and its
        // TTL stamp — current after a credential change.
        switch id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "moonshot":
            _ = await MoonshotModelCatalog.models(dataRoot: dataRoot, refresh: true)
        case "openrouter":
            _ = await OpenRouterModelCatalog.models(dataRoot: dataRoot, refresh: true)
        default:
            break
        }
        return try await getProvider(id: id)
    }
    public func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences {
        guard case .object(let obj) = body,
              let rawSurface = Self.firstString(obj, keys: ["surface"]) else {
            throw ProviderRoutingError.invalidRequest
        }
        // Saved surface aliases enter through the canonical vocabulary.
        let surface = canonicalRoutingSurface(rawSurface)
        guard MODEL_SURFACES.contains(surface) else {
            throw ProviderRoutingError.invalidRequest
        }
        let model = Self.firstString(obj, keys: ["model"])
        let effort = Self.firstString(obj, keys: ["reasoningEffort", "reasoning_effort"])
        let serviceTier = Self.firstString(obj, keys: ["serviceTier", "service_tier"])
        // S12a: the `inferProvider` body flag (write a route read off the
        // model's name) is gone; a model save keeps the surface's chosen route.
        try await saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: effort,
            serviceTier: serviceTier,
            providerId: nil
        )
        return try await modelPreferencesFromComputed()
    }
    /// One canonical logical mutation boundary for a provider group and its
    /// optional account pin. A durable intent marker protects the two-file
    /// update so restart reconciliation completes the exact tuple or fails
    /// closed if unrelated bytes appeared. Once the marker exists, task
    /// cancellation cannot turn a committed intent into a half-update.
    public func saveGroupSelection(
        group: ProviderSurfaceGroup,
        providerID: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        clearOverride: Bool = false
    ) async throws -> ProviderGroupWriteResult {
        guard ProviderSurfaceGroups.all.contains(group)
            || (group.surfaces.count == 1 && MODEL_SURFACES.contains(group.surfaces[0])) else {
            throw ProviderRoutingError.invalidRequest
        }
        let surfaces = group.surfaces.filter { !clearOverride || $0 != "chat" }
        let validateSelection: (@Sendable (String, String) throws -> Void)?
        if clearOverride || model == nil { validateSelection = nil }
        else { validateSelection = try await selectionValidator() }
        return try await saveSurfaceConfigurations(
            surfaces: surfaces, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, providerId: providerID,
            // Choosing a model or account completes the row; a tier-only or
            // effort-only write changes that control alone, so Chat's effort
            // keeps flowing to the group instead of being pinned on each surface.
            seedMissingControls: model != nil || providerID != nil,
            reconcilePinnedModelWithProvider: model == nil && !clearOverride,
            clearOverride: clearOverride, selectionValidator: validateSelection
        )
    }
    public func saveSurfaceConfiguration(
        surface: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        providerId: String?,
        seedMissingControls: Bool = false,
        reconcilePinnedModelWithProvider: Bool = false,
        clearOverride: Bool = false,
        selectionValidator: (@Sendable (String, String) throws -> Void)? = nil
    ) async throws {
        // Surface commands mutate the owning group's choice, just like the picker.
        _ = try await saveSurfaceConfigurations(
            surfaces: ProviderSurfaceGroups.members(of: surface).filter { !clearOverride || $0 != "chat" }, model: model,
            reasoningEffort: reasoningEffort, serviceTier: serviceTier, providerId: providerId,
            seedMissingControls: seedMissingControls,
            reconcilePinnedModelWithProvider: reconcilePinnedModelWithProvider,
            clearOverride: clearOverride, selectionValidator: selectionValidator
        )
    }
    private func saveSurfaceConfigurations(
        surfaces: [String],
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        providerId: String?,
        seedMissingControls: Bool = false,
        reconcilePinnedModelWithProvider: Bool = false,
        clearOverride: Bool = false,
        adoptingConnectedProvider: Bool = false,
        selectionValidator: (@Sendable (String, String) throws -> Void)? = nil
    ) async throws -> ProviderGroupWriteResult {
        guard !surfaces.isEmpty, surfaces.allSatisfy(MODEL_SURFACES.contains),
              !clearOverride || !surfaces.contains("chat") else { throw ProviderRoutingError.invalidRequest }
        if let providerId {
            guard Self.connectableProviderIds.contains(where: { Self.normalizeProviderId($0) == Self.normalizeProviderId(providerId) }) else {
                throw ProviderRoutingError.providerNotFound
            }
            let configuration = try Self.loadProviderStateObjectChecked(
                at: providersDir.appendingPathComponent("\(providerId).json"), description: "provider configuration"
            )
            try Self.validateProviderConfiguration(configuration)
            guard providerReadiness(id: providerId).ready else {
                throw ProviderRoutingError.configurationFailed("\(providerId) is not connected. Connect it in Providers first.")
            }
        }
        try FileManager.default.createDirectory(
            at: surfaceTransactionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transactionPath = surfaceTransactionPath
        return try await SwiftNativePersistenceCore.withFileLock(transactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            let originalSurfaces = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let savedActive = try Self.loadActiveProviderStateChecked(at: self.activeProviderPath)
            let originalActive = savedActive.mapValues(JSONValue.string)
            let active = WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(savedActive)
            // Adoption decides from the saved assignments while holding the
            // same transaction lock as the picker, never from a prior snapshot.
            let available = adoptingConnectedProvider ? Set(Self.connectableProviderIds.filter {
                self.providerReadiness(id: $0).ready
            }) : []
            if adoptingConnectedProvider, !available.contains(providerId ?? "") {
                return try await self.groupWriteResult(surfaces: [], surfaceRoot: originalSurfaces, activeRoot: originalActive)
            }
            let current = !clearOverride ? await self.selectionRoutingSnapshot(
                surfaces: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(originalSurfaces),
                active: active
            ) : nil
            var surfaceRoot = originalSurfaces
            var activeRoot = originalActive
            for surface in surfaces {
                if adoptingConnectedProvider {
                    let assignment = (active[surface] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if available.contains(assignment) || (surface != "chat" && assignment.isEmpty) { continue }
                }
                let clearOverride = clearOverride || (adoptingConnectedProvider && surface != "chat")
                if let model, !clearOverride {
                    guard let route = providerId ?? current?.activeProviders[surface],
                          Self.connectableProviderIds.contains(where: { Self.normalizeProviderId($0) == Self.normalizeProviderId(route) }),
                          !Self.normalizeModelIdStatic(model, fallback: "").isEmpty else {
                        throw ProviderRoutingError.configurationFailed("Choose a valid model on a configured account.")
                    }
                    if let family = self.inferProviderForModel(model), !Self.providerCanServeModel(route, inferredProvider: family) {
                        throw ProviderRoutingError.configurationFailed("\(route) does not serve \(model). Pick a model that account offers.")
                    }
                    try selectionValidator?(route, model)
                }
                // A bare provider switch preserves a compatible pin and refuses
                // an incompatible one under the same lock as explicit choices.
                var surfacesUntouched = false
                if reconcilePinnedModelWithProvider, !clearOverride, model == nil, let providerId {
                    let folded = Self.canonicalizeRootForWrite(surfaceRoot, surface: surface)
                    let (models, _, _) = Self.parseSurfacesFile(.object(folded))
                    if let pinned = Self.stringFrom(models, key: surface),
                       let inferred = self.inferProviderForModel(pinned),
                       !Self.providerCanServeModel(providerId, inferredProvider: inferred) {
                        throw ProviderRoutingError.configurationFailed("\(providerId) does not serve \(pinned). Choose a model on that account in the picker.")
                    } else {
                        surfacesUntouched = true
                    }
                }
                var updatedSurfaces = surfacesUntouched ? surfaceRoot : Self.updatedSurfaceRoot(
                    surfaceRoot,
                    surface: surface,
                    model: model,
                    reasoningEffort: reasoningEffort ?? (seedMissingControls ? current?.preferences[surface]?.reasoningEffort : nil),
                    serviceTier: serviceTier ?? (seedMissingControls ? current?.preferences[surface]?.serviceTier : nil),
                    seedMissingControls: seedMissingControls
                )
                if clearOverride {
                    updatedSurfaces = Self.canonicalizeRootForWrite(surfaceRoot, surface: surface)
                    updatedSurfaces.removeValue(forKey: surface)
                }
                var updatedActive = Self.updatedActiveRoot(
                    activeRoot,
                    surface: surface,
                    providerId: providerId ?? ""
                )
                if clearOverride {
                    updatedActive = Self.canonicalizeRootForWrite(activeRoot, surface: surface)
                    updatedActive.removeValue(forKey: surface)
                }
                surfaceRoot = updatedSurfaces
                activeRoot = providerId == nil && !clearOverride ? activeRoot : updatedActive
            }
            let intendedSurfaces = surfaceRoot
            let intendedActive = activeRoot
            let changed = surfaces.filter {
                originalSurfaces[$0] != intendedSurfaces[$0] || originalActive[$0] != intendedActive[$0]
            }
            guard intendedSurfaces != originalSurfaces || intendedActive != originalActive else {
                return try await self.groupWriteResult(surfaces: [], surfaceRoot: intendedSurfaces, activeRoot: intendedActive)
            }
            // Cancellation is honored before durable intent publication. From
            // this point onward the operation owns recovery and must either
            // converge now or be completed on the next checked read/mutation.
            try Task.checkCancellation()
            let pending = PendingSurfaceConfiguration(
                surfacesBaseHash: try Self.fileSHA256(self.surfacesPath),
                activeBaseHash: try Self.fileSHA256(self.activeProviderPath),
                surfaces: intendedSurfaces,
                active: intendedActive
            )
            do {
                try await self.commitPickerStateLocked(pending)
            } catch {
                let detail = error.localizedDescription
                // If publishing the first durable intent failed, there is
                // nothing to roll back. Do not manufacture a recovery write.
                do {
                    _ = try FileManager.default.attributesOfItem(atPath: transactionPath.path)
                } catch CocoaError.fileReadNoSuchFile {
                    throw ProviderGroupWriteFailure(
                        detail: "Nothing changed: \(detail)",
                        surfacesRolledBack: [], surfacesPendingRecovery: []
                    )
                } catch {
                    // An unreadable marker is not proof that it is absent.
                    throw ProviderGroupWriteFailure(
                        detail: detail, surfacesRolledBack: [], surfacesPendingRecovery: changed
                    )
                }
                // The group was never exposed through a checked read. Restore
                // the original objects under the same lock, including absent pins.
                // A failed restore leaves its durable intent for the next read.
                do {
                    let currentSurfaces = try Self.loadProviderStateObjectChecked(
                        at: self.surfacesPath, description: "surface preference"
                    )
                    let currentActive = try Self.loadProviderStateObjectChecked(
                        at: self.activeProviderPath, description: "active-provider"
                    )
                    guard (currentSurfaces == originalSurfaces || currentSurfaces == intendedSurfaces),
                          (currentActive == originalActive || currentActive == intendedActive) else {
                        throw ProviderRoutingError.underlying("pending provider selection conflicts with newer provider state")
                    }
                    let rollback = PendingSurfaceConfiguration(
                        surfacesBaseHash: try Self.fileSHA256(self.surfacesPath),
                        activeBaseHash: try Self.fileSHA256(self.activeProviderPath),
                        surfaces: originalSurfaces, active: originalActive
                    )
                    try await self.commitPickerStateLocked(rollback)
                } catch {
                    throw ProviderGroupWriteFailure(
                        detail: detail, surfacesRolledBack: [], surfacesPendingRecovery: changed
                    )
                }
                throw ProviderGroupWriteFailure(
                    detail: detail, surfacesRolledBack: changed, surfacesPendingRecovery: []
                )
            }
            return try await self.groupWriteResult(surfaces: changed, surfaceRoot: intendedSurfaces, activeRoot: intendedActive)
        }
    }
    /// Caller holds the selection lock. Publish durable intent; reconciliation
    /// owns projection writes and verification for selection and compensation.
    func commitPickerStateLocked(_ pending: PendingSurfaceConfiguration) async throws {
        try await SwiftNativePersistenceCore.writeJSON(pending.json, to: surfaceTransactionPath)
        try await reconcilePendingSurfaceConfigurationLocked()
    }
    private func groupWriteResult(
        surfaces: [String], surfaceRoot: [String: JSONValue], activeRoot: [String: JSONValue]
    ) throws -> ProviderGroupWriteResult {
        let revision = try checkedPickerStateLocked().revision
        let active = activeRoot.compactMapValues { value -> String? in
            guard case .string(let id) = value else { return nil }
            return id
        }
        return ProviderGroupWriteResult(
            surfacesChanged: surfaces,
            snapshot: selectionRoutingSnapshot(
                surfaces: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(surfaceRoot),
                active: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(active), revision: revision
            )
        )
    }
    func selectionRoutingSnapshot(surfaces: [String: JSONValue], active: [String: String], revision: Double = 0) -> ProviderRoutingSnapshot {
        let cache = providerConfigCache(for: Set(Self.soleConnectedProbeIds).union(active.values))
        return routingSnapshot(
            surfaces: surfaces, activeProviders: active,
            soleConnectedRoute: soleConnectedProviderID(cache: cache),
            configCache: cache, revision: revision
        )
    }
    /// Restore inherited routing, removing the model, effort/tier and provider
    /// pins in the same recoverable transaction. Chat owns the default.
    public func clearSurfaceOverride(surface: String) async throws {
        try await saveSurfaceConfiguration(
            surface: surface, model: nil, reasoningEffort: nil,
            serviceTier: nil, providerId: nil, clearOverride: true
        )
    }
    public func setActiveProvider(surface: String, providerId: String) async throws {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface),
              !providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRoutingError.invalidRequest
        }
        // Reconcile model pins with provider changes under the same transaction
        // lock so a concurrent model pick cannot be overwritten from a stale read.
        try await saveSurfaceConfiguration(
            surface: surface,
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            providerId: providerId,
            reconcilePinnedModelWithProvider: true
        )
    }
    /// Connect fills a missing/unavailable Chat route and retires unavailable
    /// overrides. The eligibility decision and both files commit together.
    public func adoptConnectedProvider(_ providerId: String) async throws -> ProviderGroupWriteResult {
        try await saveSurfaceConfigurations(
            surfaces: MODEL_SURFACES, model: nil, reasoningEffort: nil,
            serviceTier: nil, providerId: providerId,
            reconcilePinnedModelWithProvider: true, adoptingConnectedProvider: true
        )
    }
}
