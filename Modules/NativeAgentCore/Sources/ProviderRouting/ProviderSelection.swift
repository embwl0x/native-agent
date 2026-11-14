import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderSelection.swift` | recoverable forward picker transactions |
extension SwiftNativeProviderRouting {
    public func listProviders() async throws -> [Provider] {
        try await checkedProviderSnapshot().providers
    }
    /// Catalog discovery finishes before the one checked routing read. Every displayed connection and resolved preference then uses the same config cache.
    public func checkedProviderSnapshot(
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment, preview: Bool = false
    ) async throws -> ProviderCatalogSnapshot {
        async let openRouterRead = OpenRouterModelCatalog.modelsWithFreshness(dataRoot: dataRoot)
        async let moonshotRead = MoonshotModelCatalog.modelsWithFreshness(dataRoot: dataRoot)
        let (openRouter, moonshot) = await (openRouterRead, moonshotRead)
        let state = try await reconciledPickerState()
        let inventory = try nativeListProviders(
            openRouterModels: openRouter.models.map { $0.providerJSON() },
            moonshotModels: moonshot.models.map { $0.providerJSON() },
            codexCacheURL: codexCacheURL, authEnvironment: authEnvironment,
            additionalProviderIDs: Set(state.active.values),
            savedModels: Set(state.surfaces.values.compactMap { $0.objectValue?["model"]?.stringValue }), preview: preview
        )
        let cache = inventory.cache
        return ProviderCatalogSnapshot(
            routing: try routingSnapshot(
                surfaces: state.surfaces, activeProviders: state.active,
                soleConnectedRoute: soleConnectedProviderID(cache: cache), configCache: cache,
                revision: state.revision, preview: preview
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
    /// What a slot holds: the persisted choice for it, with inheritance resolved from saved values (its own saved model; else, when it follows
    /// Chat's account, Chat's saved model; else its account's saved default). Never the effective routing snapshot, which blanks a choice exactly
    /// when it needs repair. The one producer of "the model already in the slot" for `ModelSlot.mayHold`. The slot's account is resolved as routing
    /// resolves it (`routingSnapshot`): its own assignment, else Chat's, else `soleConnectedRoute` (`soleConnectedProviderID`, routing's rule for
    /// an unassigned slot), which the caller passes so the two cannot disagree.
    nonisolated func savedModelInSlot(_ surface: String, route: String, surfaces: [String: JSONValue], active: [String: String],
                                      soleConnectedRoute: String?) -> String? {
        let models = Self.parseSurfacesFile(.object(surfaces)).0
        let ownRoute = active[surface]
        guard (ownRoute ?? active["chat"] ?? soleConnectedRoute) == route else { return nil }
        if let model = Self.stringFrom(models, key: surface) { return model }
        if ownRoute == nil, let model = Self.stringFrom(models, key: "chat") { return model }
        let saved = (readProviderConfig(route).object?["default_model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved : nil
    }
    /// Every save passes through this: the model must be one the slot may hold (`ModelSlot.mayHold`: offered, or already in the slot), then its
    /// row's Think levels are checked. The third argument is the model the slot holds now, saved or inherited.
    public func selectionValidator(reasoningEffort: String? = nil) async throws -> @Sendable (String, String, String?) throws -> Void {
        let providers = try await checkedProviderSnapshot().providers
        let dataRoot = self.dataRoot
        return { route, model, savedInSlot in
            guard let provider = providers.first(where: { $0.id == route }),
                  provider.configured == true,
                  case .array(let models)? = provider.modelCatalog,
                  let row = FirstPartyModelCatalog.pickerRow(model, providerID: route, rows: models, dataRoot: dataRoot) else {
                throw ProviderRoutingError.configurationFailed("\(route) cannot serve \(model). Refresh Providers and choose an available model.")
            }
            guard ModelSlot.mayHold(model, rowOffered: row["offered"] != .bool(false), savedInSlot: savedInSlot) else {
                var note: String?
                if case .object(let extras)? = provider.extras { note = extras["models_note"]?.stringValue }
                throw ProviderRoutingError.configurationFailed(
                    ModelSlot.refusal(note: note, accountName: SwiftNativeProviderRouting.displayName(for: route)))
            }
            guard case .array(let efforts)? = row["supported_reasoning_efforts"] else {
                throw ProviderRoutingError.configurationFailed("\(route)'s thinking capabilities for \(model) are unavailable. Reload Providers.")
            }
            if let reasoningEffort, !efforts.isEmpty, !efforts.contains(.string(reasoningEffort)) {
                throw ProviderRoutingError.configurationFailed("\(model) does not offer Think \(reasoningEffort). Choose a declared level in Providers.")
            }
        }
    }
    public func getProvider(id: String) async throws -> Provider {
        guard let provider = try await listProviders().first(where: { $0.id == id }) else {
            throw ProviderRoutingError.providerNotFound
        }
        return provider
    }
    /// Local choices for helper creation; no network probe or setting change. The normal creation gate still validates the explicitly chosen tuple.
    public func botModelChoices() throws -> JSONValue {
        let openRouterModels = OpenRouterModelCatalog.readCache(dataRoot: dataRoot)?.map { $0.providerJSON() }
        let moonshotModels = MoonshotModelCatalog.readCache(dataRoot: dataRoot)?.map { $0.providerJSON() }
        let rows = try nativeListProviders(
            openRouterModels: openRouterModels, moonshotModels: moonshotModels
        ).providers.filter { $0.configured == true }.map { provider in
            let live = FirstPartyModelDiscovery.isLiveRoute(provider.id)
            let shipped = !live && !CodexAccountModelCatalog.isAccountBackedProvider(provider.id)
                && (provider.id != "moonshot" || moonshotModels == nil)
                && !FirstPartyModelCatalog.models(forProviderID: provider.id).isEmpty
            let models: [[String: JSONValue]]
            if case .array(let saved)? = provider.modelCatalog {
                // Helper choices are what may be chosen: the rows the provider offers.
                models = saved.compactMap { if case .object(let row) = $0, row["offered"] != .bool(false) { return row }; return nil }
            } else { models = [] }
            let keys: Set<String> = ["id", "name", "supported_reasoning_efforts", "default_reasoning_effort", "supports_fast", "supports_tools",
                "controls_note"]
            var choice: [String: JSONValue] = [
                "provider": .string(provider.id), "name": .string(provider.displayName ?? provider.id),
                "readiness": .string("credentials_available"),
                "catalog_source": .string(shipped ? "shipped_catalog" : "local_catalog_suggestions"),
                "models": .array(models.prefix(40).map { .object($0.filter { keys.contains($0.key) }) }),
                "models_truncated": .bool(models.count > 40)
            ]
            // Where the rows come from is a fact of the list, never the presence of a note; the note travels beside them as text.
            if live {
                let isProviderList = FirstPartyModelDiscovery.currentList(route: provider.id, dataRoot: dataRoot).isLive
                choice["catalog_source"] = .string(isProviderList ? "provider_list" : "shipped_floor")
            } else if models.isEmpty {
                choice["catalog_source"] = .string("unavailable")
            }
            if case .object(let extras)? = provider.extras, let note = extras["models_note"] {
                choice["models_note"] = note
            }
            return JSONValue.object(choice)
        }
        return .object(["providers": .array(rows),
            "detail": .string("""
                Choose provider, model and reasoning_effort explicitly. These are local catalog choices on configured accounts, not a live service test. \
                Non-shipped catalogs may be incomplete; creation validates the chosen route. No account or model setting changed.
                """)])
    }
    public func configureProvider(id: String, config: JSONValue, expectedRevision: String? = nil) async throws -> Provider {
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
            let current = try ProviderStateValidation.dataIfPresent(at: path)
            if let expectedRevision, Self.providerConfigurationRevision(current) != expectedRevision {
                throw WireFailure(code: "provider_conflict", message: "This account changed while editing. Read the account and apply the edit again.",
                    cause: nil, effects: .none)
            }
            if id == "xai_oauth_direct" { _ = try XAIOAuthCredentialStore.read(at: path) }
            var entry = try Self.loadProviderStateObjectChecked(
                at: path,
                description: "provider \(id) configuration"
            )
            try Self.validateProviderConfiguration(entry)
            try ProviderStateValidation.credentialFields(entry)
            if let mode = Self.firstString(body, keys: ["auth_mode"]) {
                entry["auth_mode"] = .string(mode)
            }
            let oldReference = Self.firstString(entry, keys: [ProviderAPIKeyStore.referenceField])
            var newReference: String?
            if let apiKey = Self.firstString(body, keys: ["api_key"]) {
                let reference = try ProviderAPIKeyStore.insert(apiKey)
                newReference = reference
                entry[ProviderAPIKeyStore.referenceField] = .string(reference)
                entry.removeValue(forKey: "api_key")
            }
            if let accessToken = Self.firstString(body, keys: ["access_token"]) {
                // A pasted/setup token is a new sign-in with no refresh grant.
                for key in ["tokens", "refresh_token", "id_token", "account_id", "account", "user_info",
                            "oauth_account_identity", "refresh_token_account_identity", "expires_at", "expires_in"] {
                    entry.removeValue(forKey: key)
                }
                entry["access_token"] = .string(accessToken)
            }
            if let model = Self.firstString(body, keys: ["default_model"]) {
                entry["default_model"] = .string(model)
            }
            // A settings-only default-model patch must preserve the connection, including an authentication method that has never been chosen.
            if entry["auth_mode"] == nil, body.keys.contains(where: { $0 != "default_model" }) {
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
                // writeJSON can fail after rename. Delete the new item only when checked readback proves its reference was not committed.
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
        // Credential changes refresh authenticated discovery without changing save success; catalog failure remains owned by its cache.
        switch id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "moonshot":
            _ = await MoonshotModelCatalog.modelsWithFreshness(dataRoot: dataRoot, refresh: true)
        case "openrouter":
            _ = await OpenRouterModelCatalog.modelsWithFreshness(dataRoot: dataRoot, refresh: true)
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
        // Saved surface spellings must pass the canonical vocabulary.
        let surface = canonicalRoutingSurface(rawSurface)
        guard MODEL_SURFACES.contains(surface) else {
            throw ProviderRoutingError.invalidRequest
        }
        let model = Self.firstString(obj, keys: ["model"])
        let effort = Self.firstString(obj, keys: ["reasoningEffort"])
        let serviceTier = Self.firstString(obj, keys: ["serviceTier"])
        // Saving a model preserves the surface's chosen provider instead of inferring a route from its name.
        try await saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: effort,
            serviceTier: serviceTier,
            providerId: nil
        )
        return try await modelPreferencesFromComputed()
    }
    /// Durable intent protects the group tuple across restart and cancellation; unrelated bytes fail closed instead of overwriting another commit.
    public func saveGroupSelection(
        group: ProviderSurfaceGroup,
        providerID: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        clearOverride: Bool = false,
        expectedRevision: Double? = nil,
        expectedChatChoice: ProviderTurnChoice? = nil
    ) async throws -> ProviderGroupWriteResult {
        guard ProviderSurfaceGroups.all.contains(group)
            || (group.surfaces.count == 1 && MODEL_SURFACES.contains(group.surfaces[0])) else {
            throw ProviderRoutingError.invalidRequest
        }
        let surfaces = group.surfaces.filter { !clearOverride || $0 != "chat" }
        return try await saveSurfaceConfigurations(
            surfaces: surfaces, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, providerId: providerID,
            // Effort/tier-only writes must not pin inherited model/account or other controls.
            seedMissingControls: model != nil || providerID != nil,
            reconcilePinnedModelWithProvider: model == nil && !clearOverride,
            clearOverride: clearOverride,
            expectedRevision: expectedRevision, expectedChatChoice: expectedChatChoice
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
        selectionValidator: (@Sendable (String, String, String?) throws -> Void)? = nil
    ) async throws {
        // Surface commands must mutate their owning group like the picker.
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
        selectionValidator: (@Sendable (String, String, String?) throws -> Void)? = nil,
        expectedRevision: Double? = nil,
        expectedChatChoice: ProviderTurnChoice? = nil
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
            let readiness = providerReadiness(id: providerId)
            guard readiness.ready else {
                throw ProviderRoutingError.configurationFailed(readiness.detail)
            }
        }
        let validateSelection: (@Sendable (String, String, String?) throws -> Void)?
        if clearOverride || (model == nil && reasoningEffort == nil) { validateSelection = nil }
        else if let selectionValidator { validateSelection = selectionValidator }
        else { validateSelection = try await self.selectionValidator(reasoningEffort: reasoningEffort) }
        try FileManager.default.createDirectory(
            at: surfaceTransactionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transactionPath = surfaceTransactionPath
        return try await SwiftNativePersistenceCore.withFileLock(transactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            if let expectedRevision {
                let state = try self.checkedPickerStateLocked()
                let snapshot = try await self.selectionRoutingSnapshot(
                    surfaces: state.surfaces, active: state.active, revision: state.revision, preview: false)
                let choice: ProviderTurnChoice?
                if let preference = snapshot.preferences["chat"], let provider = snapshot.activeProviders["chat"] {
                    choice = .init(provider: provider, model: preference.model, reasoningEffort: preference.reasoningEffort,
                                   fast: preference.serviceTier == "priority")
                } else { choice = nil }
                guard state.revision == expectedRevision, choice == expectedChatChoice else {
                    throw ProviderRoutingError.configurationFailed("The Chat choice changed while editing. Read Providers and choose again.")
                }
            }
            let originalSurfaces = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let savedActive = try Self.loadActiveProviderStateChecked(at: self.activeProviderPath)
            let originalActive = savedActive.mapValues(JSONValue.string)
            let active = savedActive
            // Adoption decides from the saved assignments while holding the same transaction lock as the picker, never from a prior snapshot.
            let available = adoptingConnectedProvider ? Set(Self.connectableProviderIds.filter {
                self.providerReadiness(id: $0).ready
            }) : []
            if adoptingConnectedProvider, !available.contains(providerId ?? "") {
                return try await self.groupWriteResult(surfaces: [], surfaceRoot: originalSurfaces, activeRoot: originalActive)
            }
            // Read the proposed controls before deriving inherited values, so a corrected value can repair an invalid saved choice without first admitting
            // that invalid choice. Nothing is published here.
            var proposedSurfaces = originalSurfaces
            var proposedActive = active
            if !clearOverride {
                for surface in surfaces {
                    var fields: [String: JSONValue] = [:]
                    if case .object(let saved)? = proposedSurfaces[surface] { fields = saved }
                    if let model { fields["model"] = .string(model) }
                    if let reasoningEffort { fields["reasoningEffort"] = .string(reasoningEffort) }
                    if let serviceTier { fields["serviceTier"] = .string(serviceTier) }
                    proposedSurfaces[surface] = .object(fields)
                    if let providerId { proposedActive[surface] = providerId }
                }
            }
            let current = !clearOverride ? try await self.selectionRoutingSnapshot(
                surfaces: proposedSurfaces, active: proposedActive, preview: false
            ) : nil
            // The model each slot holds now, from the saved values (`ModelSlot.mayHold` lets a slot keep it, so repairing its Think works), on the
            // account routing gives the slot.
            var soleConnected: String?
            if validateSelection != nil { soleConnected = await self.soleConnectedProviderID() }
            func savedInSlot(_ surface: String, _ route: String) -> String? {
                self.savedModelInSlot(surface, route: route, surfaces: originalSurfaces, active: active, soleConnectedRoute: soleConnected)
            }
            var surfaceRoot = originalSurfaces
            var activeRoot = originalActive
            for surface in surfaces {
                if adoptingConnectedProvider {
                    let assignment = (active[surface] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if available.contains(assignment) || (surface != "chat" && assignment.isEmpty) { continue }
                }
                let clearOverride = clearOverride || (adoptingConnectedProvider && surface != "chat")
                if !clearOverride, let route = providerId ?? current?.activeProviders[surface],
                   route == "openrouter", let picked = model ?? current?.preferences[surface]?.model,
                   let refusal = await self.botChoiceRejection(provider: route, model: picked,
                        reasoningEffort: reasoningEffort ?? current?.preferences[surface]?.reasoningEffort) {
                    throw ProviderRoutingError.configurationFailed(refusal)
                }
                if let model, !clearOverride {
                    guard let route = providerId ?? current?.activeProviders[surface],
                          Self.connectableProviderIds.contains(where: { Self.normalizeProviderId($0) == Self.normalizeProviderId(route) }),
                          !Self.normalizeModelIdStatic(model, fallback: "").isEmpty else {
                        throw ProviderRoutingError.configurationFailed("Choose a valid model on a configured account.")
                    }
                    if let family = self.inferProviderForModel(model), !Self.providerCanServeModel(route, inferredProvider: family) {
                        throw ProviderRoutingError.configurationFailed("\(route) does not serve \(model). Pick a model that account offers.")
                    }
                    try validateSelection?(route, model, savedInSlot(surface, route))
                } else if reasoningEffort != nil, !clearOverride,
                          let route = providerId ?? current?.activeProviders[surface],
                          let selected = current?.preferences[surface]?.model {
                    try validateSelection?(route, selected, savedInSlot(surface, route))
                }
                // An account-only change preserves the exact saved choice; an incompatible pin needs an explicit combined selection.
                var surfacesUntouched = false
                if reconcilePinnedModelWithProvider, !clearOverride, model == nil, let providerId {
                    let (models, _, _) = Self.parseSurfacesFile(.object(surfaceRoot))
                    if let pinned = Self.stringFrom(models, key: surface),
                       let inferred = self.inferProviderForModel(pinned),
                       !Self.providerCanServeModel(providerId, inferredProvider: inferred) {
                        throw ProviderRoutingError.configurationFailed("""
                            \(providerId) does not serve the saved model \(pinned). Choose the account and model together in Providers; no setting \
                            changed.
                            """)
                    }
                    surfacesUntouched = true
                }
                if !clearOverride, let route = providerId ?? current?.activeProviders[surface],
                   Self.normalizeProviderId(route) == "openrouter",
                   let selectedModel = model ?? current?.preferences[surface]?.model,
                   let effort = reasoningEffort ?? current?.preferences[surface]?.reasoningEffort,
                   let rejection = await self.botChoiceRejection(provider: route, model: selectedModel, reasoningEffort: effort) {
                    throw ProviderRoutingError.configurationFailed(rejection)
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
                    updatedSurfaces = surfaceRoot
                    updatedSurfaces.removeValue(forKey: surface)
                }
                var updatedActive = Self.updatedActiveRoot(
                    activeRoot,
                    surface: surface,
                    providerId: providerId ?? ""
                )
                if clearOverride {
                    updatedActive = activeRoot
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
            // Validate resulting controls before publishing durable intent.
            let intendedRouting = try await self.selectionRoutingSnapshot(
                surfaces: intendedSurfaces,
                active: intendedActive.compactMapValues { if case .string(let id) = $0 { return id }; return nil }, preview: false
            )
            for surface in surfaces {
                if let fault = intendedRouting.unusablePickNotice(for: surface) {
                    throw ProviderRoutingError.configurationFailed(fault)
                }
            }
            guard intendedSurfaces != originalSurfaces || intendedActive != originalActive else {
                return try await self.groupWriteResult(surfaces: [], surfaceRoot: intendedSurfaces, activeRoot: intendedActive)
            }
            // Cancellation is honored before durable intent publication. From this point onward the operation owns recovery and must either converge now or
            // be completed on the next checked read/mutation.
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
                throw await self.pickerWriteFailure(error, pending: pending, changed: changed)
            }
            return try await self.groupWriteResult(surfaces: changed, surfaceRoot: intendedSurfaces, activeRoot: intendedActive)
        }
    }
    /// Readback only: never replace the forward intent with preceding values. The existing reconciliation owner finishes retained intent on the next
    /// checked read; missing/conflicting/unreadable intent is reported as such.
    private func pickerWriteFailure(_ error: Error, pending: PendingSurfaceConfiguration, changed: [String]) -> ProviderGroupWriteFailure {
        var committed: [String] = []
        var waiting: [String] = []
        var unknown: [String] = []
        var details = [error.localizedDescription]
        for (path, target, baseHash) in [(surfacesPath, pending.surfaces, pending.surfacesBaseHash),
                                          (activeProviderPath, pending.active, pending.activeBaseHash)] {
            do {
                if try ProviderStateValidation.dataIfPresent(at: path) == nil {
                    if baseHash == nil { waiting.append(path.path) }
                    else {
                        unknown.append(path.path)
                        details.append("\(path.path) is missing after a previously present projection")
                    }
                } else if try Self.loadProviderStateObjectChecked(at: path, description: "provider selection projection") == target {
                    committed.append(path.path)
                } else if try Self.fileSHA256(path) == baseHash {
                    waiting.append(path.path)
                } else {
                    unknown.append(path.path)
                    details.append("\(path.path) conflicts with the forward intent")
                }
            } catch {
                unknown.append(path.path)
                details.append("\(path.path) readback is unavailable: \(error.localizedDescription)")
            }
        }
        let intentStatus: String
        do {
            if let data = try ProviderStateValidation.dataIfPresent(at: surfaceTransactionPath) {
                intentStatus = try JSONValue.parse(data) == pending.json ? "retained" : "conflicting"
            } else { intentStatus = "absent" }
        } catch {
            intentStatus = "unavailable"
            details.append("Intent readback is unavailable: \(error.localizedDescription)")
        }
        details.append("""
            Forward intent \(intentStatus) at \(surfaceTransactionPath.path); committed: \(committed.joined(separator: ", ")); pending: \
            \(waiting.joined(separator: ", ")); unknown: \(unknown.joined(separator: ", ")).
            """)
        return ProviderGroupWriteFailure(detail: details.joined(separator: " "),
            forwardIntent: pending.json, intentStatus: intentStatus,
            projectionsCommitted: committed, projectionsPending: waiting, projectionsUnknown: unknown,
            surfacesPendingRecovery: intentStatus == "absent" && waiting.isEmpty && unknown.isEmpty ? [] : changed)
    }
    /// Caller holds the selection lock; durable intent owns all projection writes and verification.
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
            snapshot: try selectionRoutingSnapshot(
                surfaces: surfaceRoot,
                active: active, revision: revision, preview: false
            )
        )
    }
    func selectionRoutingSnapshot(surfaces: [String: JSONValue], active: [String: String], revision: Double = 0,
        preview: Bool = false) throws -> ProviderRoutingSnapshot {
        let cache = providerConfigCache(for: Set(Self.soleConnectedProbeIds).union(active.values))
        return try routingSnapshot(
            surfaces: surfaces, activeProviders: active,
            soleConnectedRoute: soleConnectedProviderID(cache: cache),
            configCache: cache, revision: revision, preview: preview
        )
    }
    public func setActiveProvider(surface: String, providerId: String) async throws {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface),
              !providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRoutingError.invalidRequest
        }
        // Reconcile model pins with provider changes under the same transaction lock so a concurrent model pick cannot be overwritten from a stale read.
        try await saveSurfaceConfiguration(
            surface: surface,
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            providerId: providerId,
            reconcilePinnedModelWithProvider: true
        )
    }
    /// Adoption eligibility and both picker projections commit together.
    public func adoptConnectedProvider(_ providerId: String) async throws -> ProviderGroupWriteResult {
        try await saveSurfaceConfigurations(
            surfaces: MODEL_SURFACES, model: nil, reasoningEffort: nil,
            serviceTier: nil, providerId: providerId,
            reconcilePinnedModelWithProvider: true, adoptingConnectedProvider: true
        )
    }
}
