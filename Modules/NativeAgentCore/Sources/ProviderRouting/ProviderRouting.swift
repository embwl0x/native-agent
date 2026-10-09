import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

// MARK: - SwiftNative impl
//
// Phase B (2026-05-31): the per-surface PICKER methods
// (`computeModelPreferences`, `modelForSurface`, `normalizeModelId`,
// `normalizeReasoningEffort`, `inferProviderForModel`) are now SwiftNative —
// they read/write Swift-native provider picker state through PersistenceCore
// without any HTTP.
//
// The SwiftNative actor reads/writes the provider registry, provider token
// files, and model-surface picker directly.

public actor SwiftNativeProviderRouting: ProviderRoutingProtocol {
    public enum SurfaceCommitStep: Sendable {
        case manifestPrepared
        case surfacesCommitted
        case activeProviderCommitted
    }

    private let dataRoot: URL
    private let surfacesPath: URL
    private let activeProviderPath: URL
    private let persistence: any PersistenceCoreProtocol
    private let surfaceCommitFailureInjector: (@Sendable (SurfaceCommitStep) throws -> Void)?

    /// `dataRoot` owns provider registry/config/catalog reads and writes. The
    /// two path overrides are narrower fixture seams for picker files only;
    /// they must not silently leave the rest of the actor on the personal
    /// root. Secondary/test runtimes therefore pass their exact data root.
    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        surfacesPathOverride: URL? = nil,
        activeProviderPathOverride: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        surfaceCommitFailureInjector: (@Sendable (SurfaceCommitStep) throws -> Void)? = nil
    ) {
        self.persistence = persistence
        self.surfaceCommitFailureInjector = surfaceCommitFailureInjector
        self.dataRoot = dataRoot.standardizedFileURL
        if let override = surfacesPathOverride {
            self.surfacesPath = override
        } else {
            self.surfacesPath = self.dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("surfaces.json")
        }
        if let override = activeProviderPathOverride {
            self.activeProviderPath = override
        } else {
            self.activeProviderPath = self.dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("active.json")
        }
    }

    private var surfaceTransactionPath: URL {
        surfacesPath.deletingLastPathComponent()
            .appendingPathComponent("pending-surface-configuration.json")
    }

    /// Provider state is bootstrap-empty only when absent. Existing unreadable,
    /// malformed, or wrong-shaped bytes are unavailable and must never be
    /// rewritten by a picker/config mutation as if they were missing.
    public nonisolated static func loadProviderStateObjectChecked(
        at path: URL,
        description: String
    ) throws -> [String: JSONValue] {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ProviderRoutingError.underlying("saved \(description) state is unreadable")
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ProviderRoutingError.underlying("saved \(description) state is malformed")
        }
        guard case .object(let object) = value else {
            throw ProviderRoutingError.underlying("saved \(description) state must be a JSON object")
        }
        if description == "surface preference" {
            try validateSurfacePreferences(object)
        }
        return object
    }

    private nonisolated static func validateSurfacePreferences(_ root: [String: JSONValue]) throws {
        for (surface, value) in root {
            if case .string = value { continue } // Supported legacy model pin.
            guard case .object(let fields) = value else {
                throw ProviderRoutingError.underlying("saved surface preference for \(surface) must be a string or object")
            }
            for field in ["model", "reasoningEffort", "reasoning_effort", "serviceTier", "service_tier"] {
                guard let value = fields[field] else { continue }
                guard case .string = value else {
                    throw ProviderRoutingError.underlying("saved surface preference \(surface).\(field) must be a string")
                }
            }
            if let fast = fields["fastMode"], case .bool = fast {} else if fields["fastMode"] != nil {
                throw ProviderRoutingError.underlying("saved surface preference \(surface).fastMode must be a boolean")
            }
        }
    }

    public nonisolated static func loadActiveProviderStateChecked(
        at path: URL
    ) throws -> [String: String] {
        let raw = try loadProviderStateObjectChecked(at: path, description: "active-provider")
        return try loadActiveProviderObjectChecked(raw)
    }

    public nonisolated static func validateProviderConfiguration(_ fields: [String: JSONValue]) throws {
        for field in ["auth_mode", "authMode", "api_key", "apiKey", "key", "access_token", "accessToken",
                      "refresh_token", "id_token", "setup_token", "token", "default_model", "defaultModel", "model", "token_type", "scope"] {
            guard let value = fields[field] else { continue }
            guard case .string = value else {
                throw ProviderRoutingError.underlying("saved provider field \(field) must be a string")
            }
        }
        if let tokens = fields["tokens"] {
            guard case .object(let object) = tokens else {
                throw ProviderRoutingError.underlying("saved provider tokens must be an object")
            }
            try validateProviderConfiguration(object)
        }
        for field in ["expires_at", "expires_in"] {
            guard let value = fields[field] else { continue }
            switch value {
            case .string, .int, .double: break
            default: throw ProviderRoutingError.underlying("saved provider field \(field) has an invalid type")
            }
        }
    }

    public nonisolated static func loadProviderRegistryChecked(at path: URL) throws -> [JSONValue]? {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile { return nil }
        let data = try Data(contentsOf: path)
        guard case .array(let rows) = try JSONValue.parse(data) else {
            throw ProviderRoutingError.underlying("The saved provider registry is not an array.")
        }
        let providers = try JSONDecoder().decode([Provider].self, from: data)
        guard providers.allSatisfy({ !$0.id.isEmpty }), Set(providers.map(\.id)).count == providers.count else {
            throw ProviderRoutingError.underlying("The saved provider registry has missing or duplicate ids.")
        }
        return rows
    }

    private struct PendingSurfaceConfiguration: Sendable {
        let surfacesBaseHash: String?
        let activeBaseHash: String?
        let surfaces: [String: JSONValue]
        let active: [String: JSONValue]

        var json: JSONValue {
            .object([
                "schemaVersion": .int(1),
                "surfacesBaseHash": surfacesBaseHash.map(JSONValue.string) ?? .null,
                "activeBaseHash": activeBaseHash.map(JSONValue.string) ?? .null,
                "surfaces": .object(surfaces),
                "active": .object(active),
            ])
        }

        init(
            surfacesBaseHash: String?,
            activeBaseHash: String?,
            surfaces: [String: JSONValue],
            active: [String: JSONValue]
        ) {
            self.surfacesBaseHash = surfacesBaseHash
            self.activeBaseHash = activeBaseHash
            self.surfaces = surfaces
            self.active = active
        }

        init(json: [String: JSONValue]) throws {
            guard case .int(1)? = json["schemaVersion"],
                  case .object(let surfaces)? = json["surfaces"],
                  case .object(let active)? = json["active"] else {
                throw ProviderRoutingError.underlying("pending provider selection is malformed")
            }
            func optionalHash(_ value: JSONValue?) throws -> String? {
                switch value ?? .null {
                case .null:
                    return nil
                case .string(let hash) where hash.count == 64:
                    return hash
                default:
                    throw ProviderRoutingError.underlying("pending provider selection hash is malformed")
                }
            }
            self.surfacesBaseHash = try optionalHash(json["surfacesBaseHash"])
            self.activeBaseHash = try optionalHash(json["activeBaseHash"])
            self.surfaces = surfaces
            self.active = active
            try SwiftNativeProviderRouting.validateSurfacePreferences(surfaces)
            _ = try SwiftNativeProviderRouting.loadActiveProviderObjectChecked(active)
        }
    }

    private nonisolated static func loadActiveProviderObjectChecked(
        _ raw: [String: JSONValue]
    ) throws -> [String: String] {
        var active: [String: String] = [:]
        active.reserveCapacity(raw.count)
        for (surface, value) in raw {
            guard case .string(let providerId) = value,
                  !providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderRoutingError.underlying(
                    "saved active-provider entry for \(surface) must be a non-empty string"
                )
            }
            active[surface] = providerId
        }
        return active
    }

    private nonisolated static func fileSHA256(_ path: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ProviderRoutingError.underlying("provider selection bytes are unreadable")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func updatedSurfaceRoot(
        _ root: [String: JSONValue],
        surface: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        seedMissingControls: Bool,
        overwriteExisting: Bool
    ) -> [String: JSONValue] {
        let root = canonicalizeRootForWrite(root, surface: surface)
        if !overwriteExisting, root[surface] != nil { return root }
        var updated = root
        var entry: [String: JSONValue] = [:]
        if case .object(let existing)? = updated[surface] { entry = existing }
        if case .string(let existing)? = updated[surface] { entry["model"] = .string(existing) }
        if let model { entry["model"] = .string(model) }
        if let reasoningEffort {
            entry["reasoningEffort"] = .string(reasoningEffort)
        } else if seedMissingControls, entry["reasoningEffort"] == nil {
            entry["reasoningEffort"] = .string("medium")
        }
        if let serviceTier {
            entry["serviceTier"] = .string(normalizeServiceTierStatic(serviceTier))
        } else if seedMissingControls, entry["serviceTier"] == nil {
            entry["serviceTier"] = .string("default")
        }
        updated[surface] = .object(entry)
        return updated
    }

    private nonisolated static func updatedActiveRoot(
        _ root: [String: JSONValue],
        surface: String,
        providerId: String,
        overwriteExisting: Bool
    ) -> [String: JSONValue] {
        let root = canonicalizeRootForWrite(root, surface: surface)
        if !overwriteExisting, root[surface] != nil { return root }
        var updated = root
        updated[surface] = .string(providerId)
        return updated
    }

    /// P2-3 write-side migration, applied ONLY to the surface actually being
    /// mutated. Rewriting a picker file wholesale would be a flag day; folding
    /// just the key we are about to overwrite means the legacy `missions` entry
    /// is retired exactly when its replacement is written, so the file can
    /// never end up carrying two entries that disagree about the same surface.
    /// Untouched surfaces keep their bytes.
    private nonisolated static func canonicalizeRootForWrite(
        _ root: [String: JSONValue],
        surface: String
    ) -> [String: JSONValue] {
        guard surface == WorkshopSurfaceVocabulary.canonical,
              let legacyEntry = root[WorkshopSurfaceVocabulary.legacy] else { return root }
        var updated = root
        updated.removeValue(forKey: WorkshopSurfaceVocabulary.legacy)
        if updated[surface] == nil { updated[surface] = legacyEntry }
        return updated
    }

    /// Finish an interrupted two-file picker commit before any later read or
    /// mutation observes the surface/model tuple. The durable intent is valid
    /// only while each live projection is either its recorded base bytes or
    /// the exact intended object; unrelated concurrent bytes fail closed and
    /// leave the marker available for explicit recovery instead of being
    /// silently overwritten.
    private func reconcilePendingSurfaceConfigurationLocked() async throws {
        guard FileManager.default.fileExists(atPath: surfaceTransactionPath.path) else { return }
        let raw = try Self.loadProviderStateObjectChecked(
            at: surfaceTransactionPath,
            description: "pending provider selection"
        )
        let pending = try PendingSurfaceConfiguration(json: raw)

        let currentSurfaces = try Self.loadProviderStateObjectChecked(
            at: surfacesPath,
            description: "surface preference"
        )
        let currentActiveObject = try Self.loadProviderStateObjectChecked(
            at: activeProviderPath,
            description: "active-provider"
        )
        _ = try Self.loadActiveProviderObjectChecked(currentActiveObject)

        let surfacesRecoverable = try currentSurfaces == pending.surfaces
            || Self.fileSHA256(surfacesPath) == pending.surfacesBaseHash
        let activeRecoverable = try currentActiveObject == pending.active
            || Self.fileSHA256(activeProviderPath) == pending.activeBaseHash
        guard surfacesRecoverable, activeRecoverable else {
            throw ProviderRoutingError.underlying(
                "pending provider selection conflicts with newer provider state"
            )
        }

        if currentSurfaces != pending.surfaces {
            try await persistence.withFileLock(surfacesPath) {
                try await self.persistence.writeJSON(.object(pending.surfaces), to: self.surfacesPath)
            }
        }
        if currentActiveObject != pending.active {
            try await persistence.withFileLock(activeProviderPath) {
                try await self.persistence.writeJSON(.object(pending.active), to: self.activeProviderPath)
            }
        }

        let verifiedSurfaces = try Self.loadProviderStateObjectChecked(
            at: surfacesPath,
            description: "surface preference"
        )
        let verifiedActive = try Self.loadProviderStateObjectChecked(
            at: activeProviderPath,
            description: "active-provider"
        )
        _ = try Self.loadActiveProviderObjectChecked(verifiedActive)
        guard verifiedSurfaces == pending.surfaces, verifiedActive == pending.active else {
            throw ProviderRoutingError.underlying("pending provider selection did not converge")
        }
        do {
            try FileManager.default.removeItem(at: surfaceTransactionPath)
        } catch {
            throw ProviderRoutingError.underlying("clear pending provider selection failed")
        }
    }

    private func reconciledPickerState() async throws -> (
        surfaces: [String: JSONValue],
        active: [String: String]
    ) {
        try await persistence.withFileLock(surfaceTransactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            let surfaces = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let active = try Self.loadActiveProviderStateChecked(at: self.activeProviderPath)
            // P2-3 read seam. Both picker files are keyed by surface, and a
            // 0.3.x install has `missions` keys in them. Fold here — the ONE
            // place either file becomes in-memory state — so the snapshot,
            // preferences, and pins all speak the canonical vocabulary. The
            // files themselves are left untouched; only a later WRITE migrates
            // them (see `updatedSurfaceRoot` / `updatedActiveRoot`).
            return (
                WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(surfaces),
                WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(active)
            )
        }
    }

    // MARK: Provider management

    public func listProviders() async throws -> [Provider] {
        try await checkedProviderSnapshot().providers
    }

    /// Catalog discovery finishes before the one checked routing read. Every
    /// displayed connection and resolved preference then uses the same config cache.
    public func checkedProviderSnapshot(
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderCatalogSnapshot {
        let openRouter = await OpenRouterModelCatalog.modelsWithFreshness(dataRoot: dataRoot)
        let moonshot = await MoonshotModelCatalog.modelsWithFreshness(dataRoot: dataRoot)
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
                soleConnectedProvider: soleConnectedProviderFamily(cache: cache),
                soleConnectedRoute: soleConnectedProviderID(cache: cache), configCache: cache
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
        try await persistence.withFileLock(path) {
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
                    try await persistence.writeJSON(.object(entry), to: path)
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

    public func testProvider(id: String) async throws -> ProviderTestResult {
        let provider = try await getProvider(id: id)
        let ready = provider.configured == true
        let status = ready ? "ok" : "needs_credentials"
        let detail: String = {
            if case .object(let obj)? = provider.oauthStatus,
               case .string(let d)? = obj["detail"] {
                return d
            }
            // Honest label: this surface checks credential PRESENCE only —
            // no network probe is issued (tested:false below is accurate,
            // but the old "Credentials available" read as a passed test in
            // the UI; audit 2026-06-09, silent-stub class). A real probe is
            // ledgered as an upgrade.
            return ready
                ? "Credentials present (connectivity not tested)"
                : "No usable credentials found"
        }()
        return ProviderTestResult(rawResponse: .object([
            "provider_id": .string(id),
            "status": .string(status),
            "tested": .bool(false),
            "detail": .string(detail),
        ]))
    }

    public func getModelPreferences() async throws -> ModelPreferences {
        return try await modelPreferencesFromComputed()
    }

    public func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences {
        guard case .object(let obj) = body,
              let rawSurface = Self.firstString(obj, keys: ["surface"]) else {
            throw ProviderRoutingError.invalidRequest
        }
        // P2-3: accept the 0.3.x `missions` spelling from any caller (iOS one
        // version behind, a saved shortcut, an old script) and route it to the
        // canonical surface rather than rejecting it as unknown.
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
            serviceTier: serviceTier, providerId: providerID, seedMissingControls: true,
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
        overwriteExisting: Bool = true,
        reconcilePinnedModelWithProvider: Bool = false,
        clearOverride: Bool = false,
        selectionValidator: (@Sendable (String, String) throws -> Void)? = nil
    ) async throws {
        // Surface commands mutate the owning group's choice, just like the picker.
        _ = try await saveSurfaceConfigurations(
            surfaces: ProviderSurfaceGroups.members(of: surface).filter { !clearOverride || $0 != "chat" }, model: model,
            reasoningEffort: reasoningEffort, serviceTier: serviceTier, providerId: providerId,
            seedMissingControls: seedMissingControls, overwriteExisting: overwriteExisting,
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
        overwriteExisting: Bool = true,
        reconcilePinnedModelWithProvider: Bool = false,
        clearOverride: Bool = false,
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
        return try await persistence.withFileLock(transactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            let originalSurfaces = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let originalActive = try Self.loadProviderStateObjectChecked(
                at: self.activeProviderPath,
                description: "active-provider"
            )
            let active = WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(
                try Self.loadActiveProviderObjectChecked(originalActive)
            )
            let current = model != nil && !clearOverride ? await self.selectionRoutingSnapshot(
                surfaces: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(originalSurfaces),
                active: active
            ) : nil
            var surfaceRoot = originalSurfaces
            var activeRoot = originalActive
            for surface in surfaces {
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
                if reconcilePinnedModelWithProvider, model == nil, let providerId {
                    let folded = Self.canonicalizeRootForWrite(surfaceRoot, surface: surface)
                    let (models, _) = Self.parseSurfacesFile(.object(folded))
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
                    reasoningEffort: reasoningEffort,
                    serviceTier: serviceTier,
                    seedMissingControls: seedMissingControls,
                    overwriteExisting: overwriteExisting
                )

                if clearOverride {
                    updatedSurfaces = Self.canonicalizeRootForWrite(surfaceRoot, surface: surface)
                    updatedSurfaces.removeValue(forKey: surface)
                }
                var updatedActive = Self.updatedActiveRoot(
                    activeRoot,
                    surface: surface,
                    providerId: providerId ?? "",
                    overwriteExisting: overwriteExisting
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
                return await self.groupWriteResult(surfaces: [], surfaceRoot: intendedSurfaces, activeRoot: intendedActive)
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
            return await self.groupWriteResult(surfaces: changed, surfaceRoot: intendedSurfaces, activeRoot: intendedActive)
        }
    }

    /// Caller holds the common selection lock. The same durable writer commits
    /// the requested group and, on failure, its exact pre-write inheritance.
    private func commitPickerStateLocked(_ pending: PendingSurfaceConfiguration) async throws {
        try await persistence.writeJSON(pending.json, to: surfaceTransactionPath)
        try surfaceCommitFailureInjector?(.manifestPrepared)
        try await persistence.withFileLock(surfacesPath) {
            try await self.persistence.writeJSON(.object(pending.surfaces), to: self.surfacesPath)
        }
        try surfaceCommitFailureInjector?(.surfacesCommitted)
        try await persistence.withFileLock(activeProviderPath) {
            try await self.persistence.writeJSON(.object(pending.active), to: self.activeProviderPath)
        }
        try surfaceCommitFailureInjector?(.activeProviderCommitted)
        try await reconcilePendingSurfaceConfigurationLocked()
    }

    private func groupWriteResult(
        surfaces: [String], surfaceRoot: [String: JSONValue], activeRoot: [String: JSONValue]
    ) -> ProviderGroupWriteResult {
        let active = activeRoot.compactMapValues { value -> String? in
            guard case .string(let id) = value else { return nil }
            return id
        }
        return ProviderGroupWriteResult(
            surfacesChanged: surfaces,
            snapshot: selectionRoutingSnapshot(
                surfaces: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(surfaceRoot),
                active: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(active)
            )
        )
    }

    private func selectionRoutingSnapshot(surfaces: [String: JSONValue], active: [String: String]) -> ProviderRoutingSnapshot {
        let cache = providerConfigCache(for: Set(Self.soleConnectedProbeIds).union(active.values))
        return routingSnapshot(
            surfaces: surfaces, activeProviders: active,
            soleConnectedProvider: soleConnectedProviderFamily(cache: cache),
            soleConnectedRoute: soleConnectedProviderID(cache: cache),
            configCache: cache
        )
    }

    /// Canonical raw-pin mutation. `seedMissingControls` exists only for the
    /// established Mac picker contract; all persistence and corruption
    /// handling still remain owned here.
    public func saveSurfacePreference(
        surface: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        seedMissingControls: Bool = false,
        overwriteExisting: Bool = true
    ) async throws {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface) else { throw ProviderRoutingError.invalidRequest }
        try FileManager.default.createDirectory(
            at: surfaceTransactionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await persistence.withFileLock(surfaceTransactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            let root = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            _ = try Self.loadActiveProviderStateChecked(at: self.activeProviderPath)
            let updated = Self.updatedSurfaceRoot(
                root,
                surface: surface,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier,
                seedMissingControls: seedMissingControls,
                overwriteExisting: overwriteExisting
            )
            guard updated != root else { return }
            try Task.checkCancellation()
            try await self.persistence.withFileLock(self.surfacesPath) {
                try await self.persistence.writeJSON(.object(updated), to: self.surfacesPath)
            }
        }
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
        // Provider switches must not strand a stale model pin from the old
        // provider's family: the router no longer silently substitutes at
        // dispatch (it fails loud, 2026-08-21), so the mismatch has to be
        // resolved HERE, where the user made the change and the panel shows
        // the result. The pin check and the rewrite happen INSIDE the same
        // surface-transaction lock (a pre-read across an await could race a
        // concurrent explicit model pick — gpt-5.5 review).
        try await saveSurfaceConfiguration(
            surface: surface,
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            providerId: providerId,
            reconcilePinnedModelWithProvider: true
        )
    }

    private nonisolated var providersDir: URL {
        dataRoot.appendingPathComponent("providers", isDirectory: true)
    }

    private func nativeListProviders(
        openRouterModels: [[String: JSONValue]]? = nil,
        moonshotModels: [[String: JSONValue]]? = nil,
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        additionalProviderIDs: Set<String> = []
    ) throws -> (providers: [Provider], cache: ProviderConfigCache) {
        var byId: [String: Provider] = [:]
        for value in try Self.loadProviderRegistryChecked(at: providersDir.appendingPathComponent("registry.json")) ?? [] {
            let provider = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(value))
            byId[provider.id] = provider
        }
        let skipNames: Set<String> = [
            "registry.json", "models.json", "active.json", "surfaces.json",
            "pending-surface-configuration.json", "cli_session_adoption.json",
            "openrouter-models-cache.json", "moonshot-models-cache.json",
        ]
        var ids = Set(Self.connectableProviderIds).union(byId.keys)
        if let files = try? FileManager.default.contentsOfDirectory(at: providersDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" && !skipNames.contains(file.lastPathComponent) {
                ids.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        let cache = providerConfigCache(for: ids.union(additionalProviderIDs), authEnvironment: authEnvironment)
        for id in ids {
            if let error = cache.reads[id]?.unreadable { throw ProviderRoutingError.underlying(error) }
            var row = byId[id] ?? Provider(id: id)
            row.displayName = Self.connectableProviderIds.contains(id) ? displayName(for: id) : (row.displayName ?? displayName(for: id))
            row.kind = id.contains("oauth") || id == "codex" ? "oauth" : "api_key"
            // Preserve custom registry catalogs; shipped routes always use current catalogs.
            if Self.connectableProviderIds.contains(id) || row.modelCatalog == nil {
                row.modelCatalog = .array(modelsForProvider(
                    id, openRouterModels: openRouterModels, moonshotModels: moonshotModels,
                    codexCacheURL: codexCacheURL, authEnvironment: authEnvironment
                ).map { .object($0) })
            }
            var extras: [String: JSONValue] = [:]
            if case .object(let saved)? = row.extras { extras = saved }
            if Self.connectableProviderIds.contains(id) || extras["auth_modes"] == nil {
                extras["auth_modes"] = .array(authModes(for: id).map { .string($0) })
            }
            row.extras = .object(extras)
            byId[id] = providerWithReadiness(row, cache: cache, authEnvironment: authEnvironment)
        }
        return (byId.values.sorted { ($0.displayName ?? $0.id) < ($1.displayName ?? $1.id) }, cache)
    }

    private func providerWithReadiness(
        _ provider: Provider, cache: ProviderConfigCache,
        authEnvironment: [String: String]
    ) -> Provider {
        var row = provider
        let readiness = providerReadiness(id: row.id, cache: cache, authEnvironment: authEnvironment)
        row.configured = readiness.ready
        row.active = readiness.ready
        row.oauthStatus = .object([
            "provider_id": .string(row.id),
            "state": .string(readiness.ready ? "ready" : readiness.state),
            "detail": .string(readiness.detail),
        ])
        row.lastError = readiness.ready ? nil : readiness.detail
        var extras: [String: JSONValue] = [:]
        if case .object(let saved)? = row.extras { extras = saved }
        let config = cache.reads[row.id]?.object ?? [:]
        for (key, alias) in [("auth_mode", "authMode"), ("default_model", "defaultModel")] {
            if let value = (config[key] as? String ?? config[alias] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                extras[key] = .string(value)
            }
        }
        row.extras = .object(extras)
        return row
    }

    /// User, 2026-09-06: `cache` carries the routing snapshot's single locked
    /// read of each `providers/<id>.json`. When it is nil (the live Provider
    /// Settings listing, which is not resolving models alongside) each branch
    /// reads its own file exactly as before.
    /// The body reads the same credential admission as provider routing, without catalog discovery.
    public nonisolated func hasUsableCredentials() -> Bool {
        ["anthropic_oauth_direct", "anthropic", "openai_oauth_direct", "openai",
         "openrouter", "moonshot", "kimi-code", "xai_oauth_direct"].contains {
            providerReadiness(id: $0).ready
        }
    }

    private nonisolated func providerReadiness(
        id: String,
        cache: ProviderConfigCache? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (ready: Bool, state: String, detail: String) {
        if let readiness = cache?.readiness[id] { return readiness }
        /// API-key presence for `id`, reading the provider config from the
        /// snapshot's read when there is one.
        func keyReady() -> Bool {
            if let read = cache?.reads[id] {
                return LLMCredentialResolver.resolveAPIKey(providerConfigObject: read.object) != nil
            }
            return LLMCredentialResolver.resolveAPIKey(
                providerConfigFile: "\(id).json",
                dataRoot: dataRoot
            ) != nil
        }
        switch id {
        case "openai_oauth_direct", "codex":
            if id == "codex" {
                var environment = authEnvironment
                environment["PATH"] = SwiftCodexDeviceLoginManager.augmentedPath(environment["PATH"])
                guard (try? SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: environment)) != nil else {
                    return (false, "needs_install", "Install Codex CLI to use this account through Codex.")
                }
            }
            // Reads codex_home/auth.json and the OAuth candidate paths, not
            // `providers/<id>.json` — nothing in the model lane touches those,
            // so there is no shared read to make.
            let result = Self.validateOpenAIOAuthDirect(dataRoot: dataRoot, environment: authEnvironment)
            return (result.0, "needs_oauth", result.1)
        case "anthropic_oauth_direct":
            let result = Self.validateAnthropicOAuthDirect(
                providersDir: providersDir,
                preRead: cache?.reads[id]
            )
            return (result.0, "needs_oauth", result.1)
        case "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            let result = Self.validateXAIOAuthDirect(
                providersDir: providersDir,
                preRead: cache?.reads[id]
            )
            return (result.0, "needs_oauth", result.1)
        case "openai":
            let ready = keyReady()
            return (ready, "needs_key", ready ? "API key available" : "No OpenAI API key configured")
        case "anthropic":
            let ready = keyReady()
            return (ready, "needs_key", ready ? "API key available" : "No Anthropic API key configured")
        case "openrouter":
            let ready = keyReady()
            return (ready, "needs_key", ready ? "API key available" : "No OpenRouter API key configured")
        case "moonshot":
            let ready = keyReady()
            return (ready, "needs_key", ready ? "Moonshot API key available" : "No Moonshot API key configured")
        case "kimi-code":
            let ready = keyReady()
            return (ready, "needs_key", ready ? "Kimi Code API key available" : "No Kimi Code API key configured")
        default:
            // The cached read has already resolved any Keychain reference.
            // Bookkeeping alone (auth mode/default model) is not a credential.
            let config = (cache?.reads[id] ?? readProviderConfig(id)).object ?? [:]
            let credentialKeys = ["api_key", "access_token", "setup_token", "refresh_token", "token", "id_token"]
            let tokens = config["tokens"] as? [String: Any] ?? [:]
            let credentials = credentialKeys.compactMap { config[$0] as? String }
                + [tokens["access_token"] as? String].compactMap { $0 }
            let ready = credentials.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return (ready, ready ? "ready" : "needs_credentials", ready ? "Provider credential available" : "No provider credential configured")
        }
    }

    private nonisolated func displayName(for id: String) -> String {
        switch id {
        case "openai": return "OpenAI (API key)"
        case "openai_oauth_direct": return "ChatGPT (OAuth)"
        case "codex": return "Codex CLI"
        case "anthropic": return "Anthropic (API key)"
        case "anthropic_oauth_direct": return "Anthropic (OAuth / Setup-Token)"
        case "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xAI Grok (OAuth)"
        case "openrouter": return "OpenRouter"
        case "moonshot": return "Moonshot AI (Kimi)"
        case "kimi-code": return "Kimi Code"
        default: return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private nonisolated func authModes(for id: String) -> [String] {
        if id.contains("oauth") || id == "codex" { return ["oauth"] }
        if ["openai", "anthropic", "openrouter", "moonshot", "kimi-code"].contains(id) { return ["api_key"] }
        return ["api_key", "oauth"]
    }

    /// Can this route actually run this model at this Think level, on THIS
    /// install? Used wherever a provider/model/effort tuple is CHOSEN rather
    /// than resolved — the Bots editor, the bot tools, the bot runner, and a bot
    /// session continued in Chat.
    ///
    /// 2026-09-13 review: the pure shape check accepted any nonempty pair,
    /// because a route this build ships no catalog for looked "valid" and
    /// nothing asked whether the account was even connected. This requires the
    /// provider to be CONNECTED and the model to be one the route offers.
    ///
    /// It never reaches the network. A bot run must not wait on a catalog fetch
    /// (that hung the suite once), so a fetched-catalog route is judged from the
    /// cache that is already on disk — and a cache that is stale, absent or
    /// known-truncated cannot convict: the pick stands. Moonshot uses the same
    /// cached rows as its picker; other shipped catalogs remain authoritative.
    public func botChoiceRejection(
        provider: String?,
        model: String?,
        reasoningEffort: String?
    ) -> String? {
        let moonshotModels = Self.normalizeProviderId(provider ?? "") == "moonshot"
            ? MoonshotModelCatalog.readCache(dataRoot: dataRoot) : nil
        let accountModels = CodexAccountModelCatalog.isAccountBackedProvider(provider ?? "")
            ? CodexAccountModelCatalog.load(
                providerID: provider!,
                cacheURL: CodexAccountModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: dataRoot),
                useDefaultCacheWhenNil: false
            ) : nil
        if let shape = ProviderModelChoice.rejection(
            provider: provider, model: model, reasoningEffort: reasoningEffort,
            accountModels: accountModels, moonshotModels: moonshotModels
        ) {
            return shape
        }
        let route = provider!.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = model!.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = reasoningEffort!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard providerReadiness(id: route).ready else {
            return "\(route) is not connected. Connect it in Providers, or choose an account that is."
        }
        if accountModels != nil || moonshotModels != nil { return nil }
        let shipped = FirstPartyModelCatalog.models(forProviderID: route)
        if !shipped.isEmpty {
            guard let row = shipped.first(where: { $0.id.lowercased() == picked.lowercased() }) else {
                return "\(route) does not offer \(picked). Pick a model from its list."
            }
            let supported = row.supportedReasoningEfforts ?? []
            if !supported.isEmpty, !supported.contains(effort) {
                return "\(picked) does not support Think \(effort); it supports "
                    + supported.joined(separator: ", ") + "."
            }
            return nil
        }
        // A fetched-catalog route: convict only on a complete, fresh cache that
        // does not list the model.
        if Self.normalizeProviderId(route) == "openrouter",
           OpenRouterModelCatalog.cachedAvailability(of: picked, dataRoot: dataRoot) == .unavailable {
            return "OpenRouter no longer lists \(picked). Pick a model from its list."
        }
        return nil
    }

    /// `openRouterModels` / `moonshotModels` are the provider's fetched list
    /// when the caller read it (empty = the fetch had nothing), nil when it did
    /// not. S12a: an empty fetch used to be papered over with a compiled-in
    /// list. Unread, OpenRouter offers nothing and Moonshot its shipped rows;
    /// fetched Moonshot rows also govern saved picks and helper validation.
    private nonisolated func modelsForProvider(
        _ id: String,
        openRouterModels: [[String: JSONValue]]? = nil,
        moonshotModels: [[String: JSONValue]]? = nil,
        codexCacheURL: URL? = nil,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [[String: JSONValue]] {
        let openai = FirstPartyModelCatalog.publicOpenAIModels.map { $0.providerJSON() }

        let anthropic = FirstPartyModelCatalog.anthropicModels.map { $0.providerJSON() }
        let openrouter = openRouterModels ?? []
        let xai = FirstPartyModelCatalog.xAIModels.map { $0.providerJSON() }
        let moonshot = moonshotModels ?? FirstPartyModelCatalog.moonshotModels.map { $0.providerJSON() }
        switch id {
        case "openai": return openai
        case "openai_oauth_direct", "codex":
            let cacheURL = codexCacheURL ?? CodexAccountModelCatalog.chatGPTOAuthCacheCandidate(
                dataRoot: dataRoot, environment: authEnvironment
            )
            return CodexAccountModelCatalog.providerModels(
                providerID: id, cacheURL: cacheURL,
                useDefaultCacheWhenNil: id == "codex" && cacheURL == nil
                    && !OpenAIOAuthDirectAdapter.hasUsableTokens(at: NativeOAuthFlow.openAIAppOwnedAuthPath(dataRoot: dataRoot))
            ).map { model in
                var row: [String: JSONValue] = [
                    "id": .string(model.id), "name": .string(model.name),
                    "context_length": .int(Int64(model.context_length)),
                    "supports_streaming": .bool(model.supports_streaming),
                    "supports_vision": .bool(model.supports_vision),
                    "supports_tools": .bool(model.supports_tools),
                    "supports_json_mode": .bool(model.supports_json_mode),
                ]
                row["default_reasoning_effort"] = model.default_reasoning_effort.map(JSONValue.string)
                row["supported_reasoning_efforts"] = model.supported_reasoning_efforts.map { .array($0.map(JSONValue.string)) }
                row["supports_fast"] = model.supports_fast.map(JSONValue.bool)
                return row
            }
        case "anthropic", "anthropic_oauth_direct", "anthropic_mcp": return anthropic
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return xai
        case "openrouter": return openrouter
        case "moonshot": return moonshot
        case "kimi-code": return FirstPartyModelCatalog.kimiCodeModels.map { $0.providerJSON() }
        default: return openai + anthropic + xai + openrouter + moonshot
        }
    }

    private func modelPreferencesFromComputed() async throws -> ModelPreferences {
        let prefs = try await computeModelPreferences()
        var current: [String: JSONValue] = [:]
        for surface in MODEL_SURFACES {
            if let p = prefs[surface] {
                current[surface] = .object([
                    "surface": .string(surface),
                    "model": .string(p.model),
                    "reasoningEffort": .string(p.reasoningEffort),
                    "reasoning_effort": .string(p.reasoningEffort),
                    "serviceTier": .string(p.serviceTier),
                    "service_tier": .string(p.serviceTier),
                ])
            }
        }
        return ModelPreferences(
            surfaceModels: .object(current),
            defaultModel: prefs["chat"]?.model,
            extras: .object([
                "current": .object(current),
                "status": .string("ok"),
            ])
        )
    }

    // MARK: Phase B — Swift-native picker

    /// Read Swift-native provider picker state and seed every MODEL_SURFACE.
    /// Surface models/efforts come from `providers/surfaces.json`; active
    /// provider hints come from `providers/active.json`.
    public func computeModelPreferences() async throws -> [String: SurfacePreference] {
        try await checkedRoutingSnapshot().preferences
    }

    /// Read the two picker stores through their canonical reconciliation seam
    /// and classify every persisted key against the visible Provider Settings
    /// row set. This does not invent rows for unknown keys: callers must show
    /// those as a repair-needed state until a runtime owner is registered or a
    /// dated retirement is declared above.
    public func providerSurfaceRowSet() async throws -> ProviderSurfaceRowSet {
        let pickerState = try await reconciledPickerState()
        return ProviderSurfaceRowSet(
            surfacePreferenceKeys: Set(pickerState.surfaces.keys),
            activeProviderKeys: Set(pickerState.active.keys)
        )
    }

    /// Preferences, active-provider hints, and explicit pins derived from one
    /// recovered tuple while the common transaction lock is held by
    /// `reconciledPickerState()`. No caller can observe a model from one picker
    /// commit paired with the provider from another.
    public func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        let pickerState = try await reconciledPickerState()
        let configCache = providerConfigCache(
            for: Set(Self.soleConnectedProbeIds).union(pickerState.active.values)
        )
        return routingSnapshot(
            surfaces: pickerState.surfaces,
            activeProviders: pickerState.active,
            soleConnectedProvider: soleConnectedProviderFamily(cache: configCache),
            soleConnectedRoute: soleConnectedProviderID(cache: configCache),
            configCache: configCache
        )
    }

    /// Checked diagnostic view of the picker that never repairs or writes its
    /// authority files. A pending two-file selection is intentionally adverse
    /// here: execution may resume its exact recovery transaction, but a
    /// read-only CLI must not turn a request to inspect routing into a write.
    ///
    /// Hold the writer's transaction lock across both reads without running
    /// recovery. Marker absence alone cannot rule out a complete save between
    /// the reads. The lock may create a sidecar, but never writes authority.
    public func checkedRoutingSnapshotReadOnly() async throws -> ProviderRoutingSnapshot {
        let transactionPath = surfaceTransactionPath
        let (surfaces, active) = try await persistence.withFileLock(transactionPath) {
            guard !FileManager.default.fileExists(atPath: transactionPath.path) else {
                throw ProviderRoutingError.underlying(
                    "provider selection is pending recovery; the read-only preference probe will not reconcile it"
                )
            }
            let surfaces = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let active = try Self.loadActiveProviderStateChecked(at: self.activeProviderPath)
            return (surfaces, active)
        }
        let canonicalActive = WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(active)
        let configCache = providerConfigCache(
            for: Set(Self.soleConnectedProbeIds).union(canonicalActive.values)
        )
        return routingSnapshot(
            surfaces: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(surfaces),
            activeProviders: canonicalActive,
            soleConnectedProvider: soleConnectedProviderFamily(cache: configCache),
            // 2026-09-13, fourth review: this read-only entry point omitted the
            // route, so an OAuth-only install with nothing pinned resolved to an
            // empty route AND an empty model — the 0.4.11 dream failure exactly, from the
            // other side. Both entry points carry it now, and the parameter has
            // no default so a third one cannot forget.
            soleConnectedRoute: soleConnectedProviderID(cache: configCache),
            configCache: configCache
        )
    }

    /// A3.6: the sole connected provider FAMILY, or nil when zero or ≥2
    /// distinct families have usable credentials. Used to adapt unpinned
    /// surface seeds so a fresh install that connected exactly one provider
    /// doesn't route its first turn at a provider the stranger never connected.
    ///
    /// DELIBERATELY presence-based, not liveness-probed (Wave-1 review
    /// accepted-with-rationale): readiness here is credential-shape presence;
    /// a live probe has no place in a routing-snapshot read. If the one
    /// present credential is INVALID, adaptation still improves the failure —
    /// the first turn surfaces `.authRejected` naming the provider the user
    /// actually connected, instead of "not configured" for one they never
    /// touched. Bad-key detection belongs to the turn path, not the seed.
    /// `PRIMARY_MODEL` is a GPT id (`gpt-5.6-sol`), so without this an
    /// Anthropic-only install would default chat to OpenAI and fail the first
    /// turn with "not configured: openai".
    /// Every route this build can connect: the ids the provider list always
    /// shows, and the ids the sole-connected probe walks. ONE list, because the
    /// probe used to carry its own copy and `kimi-code` was missing from it —
    /// a Kimi Code-only install with nothing saved resolved no model at all.
    static let connectableProviderIds = [
        "anthropic", "anthropic_oauth_direct",
        "openai", "openai_oauth_direct", "codex",
        "xai_oauth_direct", "moonshot", "kimi-code", "openrouter",
    ]

    /// The provider ids the sole-connected probe walks. Named so the routing
    /// snapshot can pre-read exactly these config files once.
    static var soleConnectedProbeIds: [String] { connectableProviderIds }

    func soleConnectedProviderFamily(cache: ProviderConfigCache? = nil) -> String? {
        var families: Set<String> = []
        for id in Self.soleConnectedProbeIds where providerReadiness(id: id, cache: cache).ready {
            // Codex is the CLI transport for OpenAI models — group it with
            // the openai family so a codex-only install seeds to GPT.
            let family = id == "codex" ? "openai" : Self.normalizeProviderId(id)
            families.insert(family)
        }
        return families.count == 1 ? families.first : nil
    }

    /// The EXACT id of the one connected route, or nil when zero or several are.
    ///
    /// 2026-09-13, third review: the family answer above collapses `codex` and
    /// `openai_oauth_direct` into "openai", and that string was being used as a
    /// route — so a ChatGPT-account-only install resolved against a family name
    /// that no adapter is registered under, and a Codex-CLI-only install looked
    /// like the OpenAI API. A route is a provider record's own id or nothing.
    func soleConnectedProviderID(cache: ProviderConfigCache? = nil) -> String? {
        var connected: [String] = []
        for id in Self.soleConnectedProbeIds where providerReadiness(id: id, cache: cache).ready {
            connected.append(id)
        }
        if connected.count == 1 { return connected.first }
        // One ChatGPT sign-in makes TWO ids ready — `openai_oauth_direct` and
        // `codex` both read `codex_home/auth.json`. That is one account, so it
        // still answers, with the in-app adapter's id (the transport a turn
        // takes unless a person picks the CLI row). Any other pair is genuinely
        // two accounts and stays ambiguous.
        if Set(connected) == ["openai_oauth_direct", "codex"] { return "openai_oauth_direct" }
        return nil
    }

    private func routingSnapshot(
        surfaces: [String: JSONValue],
        activeProviders: [String: String],
        soleConnectedProvider: String?,
        soleConnectedRoute: String?,
        configCache: ProviderConfigCache?
    ) -> ProviderRoutingSnapshot {
        let surfacesFile = JSONValue.object(surfaces)
        let (parsedSurfaceModels, parsedSurfaceEfforts) = Self.parseSurfacesFile(surfacesFile)
        let parsedSurfaceServiceTiers = Self.parseSurfaceServiceTiers(surfacesFile)
        // A saved pick the surface's own ROUTE no longer carries is NOT a pick
        // (User, 2026-09-13). Judging it HERE means the router and the Providers
        // page agree: the surface follows its group's choice, and the page's
        // origin caption reads "Same as Chat" or the group's override rather
        // than claiming an override that no longer exists. Nothing is rewritten
        // on disk — this is a read-time answer — and the whole tuple goes, so no
        // lane is left on an effort or a route picked for a model that is gone.
        let accountCacheURL = CodexAccountModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: dataRoot)
        let accountCatalogs = Dictionary(uniqueKeysWithValues: ["codex", "openai_oauth_direct"].map { route in
            (route, CodexAccountModelCatalog.load(
                providerID: route, cacheURL: accountCacheURL, useDefaultCacheWhenNil: false
            ))
        })
        var cachedModelIDs = accountCatalogs.mapValues { Set($0.map { $0.id.lowercased() }) }
        if let moonshotModels = MoonshotModelCatalog.readCache(dataRoot: dataRoot) {
            cachedModelIDs["moonshot"] = Set(moonshotModels.map { $0.id.lowercased() })
        }
        let retiredPickSurfaces = Self.surfacesWithRetiredPicks(
            parsedSurfaceModels, accountModels: cachedModelIDs
        ) {
            [weak self] surface, model in
            activeProviders[surface]
                ?? activeProviders["chat"]
                ?? self?.inferProviderForModel(model)
        }
        // A pick that cannot be used ends ONE way (2026-09-13, second review):
        // the surface is unset and says what to fix. Substituting the route's
        // own default was the same silent change under another name — the person
        // asked for one model and got a different one without being told.
        var unusablePicks: [String: String] = [:]
        if case .object(let parsed) = parsedSurfaceModels {
            for surface in retiredPickSurfaces {
                guard case .string(let unusable)? = parsed[surface] else { continue }
                let route = activeProviders[surface] ?? activeProviders["chat"]
                if FirstPartyModelCatalog.descriptor(for: unusable) == nil {
                    unusablePicks[surface] = "Your model, \(unusable), is no longer offered. Choose one."
                } else if let route {
                    unusablePicks[surface] = "\(unusable) isn't offered on \(route). Choose one."
                } else {
                    unusablePicks[surface] = "\(unusable) isn't offered. Choose one."
                }
            }
        }
        let surfaceModels = Self.dropping(retiredPickSurfaces, from: parsedSurfaceModels)
        let surfaceEfforts = Self.dropping(retiredPickSurfaces, from: parsedSurfaceEfforts)
        let surfaceServiceTiers = Self.dropping(retiredPickSurfaces, from: parsedSurfaceServiceTiers)
        let routesBeforeRetirement = activeProviders
        let activeProviders = activeProviders.filter {
            // Chat's own route is never dropped: it is the answer everything
            // else inherits, and losing it would strand the whole install.
            $0.key == "chat" || !retiredPickSurfaces.contains($0.key)
        }

        // Chat uses an explicit picker choice, including a saved provider-sheet
        // choice. Connecting an account without a choice leaves its model unset.
        // The exact connected route, never a family name (third review).
        let chatRoute = activeProviders["chat"] ?? soleConnectedRoute
        // Read defaults from the same cached generation as credential readiness.
        let savedDefaults = savedProviderDefaults(
            for: Set(activeProviders.values).union(chatRoute.map { [$0] } ?? []),
            cache: configCache
        )
        for (surface, route) in activeProviders.merging(chatRoute.map { ["chat": $0] } ?? [:], uniquingKeysWith: { first, _ in first }) {
            guard Self.stringFrom(parsedSurfaceModels, key: surface) == nil,
                  case .model(let saved)? = savedDefaults[route] else { continue }
            let offered = modelsForProvider(route).compactMap { model -> String? in
                if case .string(let id)? = model["id"] { return id }
                return nil
            }
            if !offered.isEmpty, !offered.contains(saved) {
                unusablePicks[surface] = "\(saved) isn't offered on \(route). Choose one."
            }
        }
        // 2026-09-13 review: a RETIRED Chat pick is not quietly replaced by the
        // route's default — that is a literal by another name, and it hides the
        // fact that the model the person chose is gone. Chat reads "not set up"
        // and `retiredPicks` carries the id so the Providers page and the turn
        // refusal can both name it. A saved provider-sheet pick is also explicit.
        let chatModelRaw = Self.stringFrom(surfaceModels, key: "chat")
            ?? (unusablePicks["chat"] != nil
                ? nil
                : chatRoute.flatMap { defaultModelForProvider($0, savedDefaults: savedDefaults) })
            ?? ""
        let chatModel = Self.normalizeModelIdStatic(chatModelRaw, fallback: "")
        let chatEffortRaw = Self.stringFrom(surfaceEfforts, key: "chat") ?? DEFAULT_REASONING_EFFORT
        let chatEffort = Self.normalizeReasoningEffortStatic(
            chatEffortRaw,
            fallback: DEFAULT_REASONING_EFFORT,
            model: chatModel,
            providerID: activeProviders["chat"],
            supportedReasoningEfforts: accountCatalogs[chatRoute ?? ""]?
                .first { $0.id == chatModel }?.supportedReasoningEfforts
        )
        let chatServiceTier = Self.normalizeServiceTierStatic(
            Self.stringFrom(surfaceServiceTiers, key: "chat") ?? "default"
        )

        // User, 2026-09-13: there is no per-surface seed table any more. Every
        // surface belongs to a Providers group (`ProviderSurfaceGroups`, the one
        // membership table the page reads too) and resolves to that group's
        // choice: an override the page wrote onto every member, else Chat's
        // route, model and effort. The hand-written seeds this replaced
        // (`dream`/`rem`/`studio_wander` cheap, `workshop`/`autonomy`/`swarms`
        // primary, `training` another) could aim a lane at a model the group's
        // connected route cannot serve — exactly how 0.4.11 dreams died on a
        // ChatGPT-account-only install ("Dream, REM, everything should go to the
        // memory model").
        // User, 2026-09-13, and the 2026-09-13 review: the Providers GROUP is the
        // routing rule, not a coincidence of identical per-surface keys. Each
        // group has one canonical tuple — model, effort, Fast, route — and every
        // member resolves to it. Chat's group takes Chat's own keys; Work and
        // Memory and mind take their override (the page writes it onto every
        // member, so the first member carrying one IS the override) and
        // otherwise Chat's. A per-surface key written by anything else is a pin
        // the page shows, never a way to split a group's routing.
        struct CanonicalTuple: Equatable {
            let model: String
            let effort: String
            let serviceTier: String
            let provider: String?
        }
        let chatTuple = CanonicalTuple(
            model: chatModel,
            effort: chatEffort,
            serviceTier: chatServiceTier,
            provider: chatRoute
        )
        func tuple(
            for surface: String,
            models: JSONValue,
            efforts: JSONValue,
            tiers: JSONValue,
            routes: [String: String]
        ) -> CanonicalTuple? {
            let saved = Self.stringFrom(models, key: surface)
            guard saved != nil || routes[surface] != nil else { return nil }
            let provider = routes[surface] ?? chatRoute
            let model = Self.normalizeModelIdStatic(
                saved ?? provider.flatMap { defaultModelForProvider($0, savedDefaults: savedDefaults) } ?? "",
                fallback: ""
            )
            // Keep a provider-only assignment even without a default: it needs
            // a model selection, rather than silently inheriting Chat's account.
            guard !model.isEmpty || routes[surface] != nil else { return nil }
            return CanonicalTuple(
                model: model,
                effort: Self.normalizeReasoningEffortStatic(
                    Self.stringFrom(efforts, key: surface) ?? chatEffort,
                    fallback: chatEffort,
                    model: model,
                    providerID: provider,
                    supportedReasoningEfforts: accountCatalogs[provider ?? ""]?
                        .first { $0.id == model }?.supportedReasoningEfforts
                ),
                serviceTier: Self.normalizeServiceTierStatic(
                    Self.stringFrom(tiers, key: surface) ?? chatServiceTier
                ),
                provider: provider
            )
        }
        func savedTuple(for surface: String) -> CanonicalTuple? {
            tuple(for: surface, models: surfaceModels, efforts: surfaceEfforts,
                  tiers: surfaceServiceTiers, routes: activeProviders)
        }
        // A retired pick refuses only where it was IN EFFECT: a Work or Memory
        // and mind override (the same tuple on every member, all now retired),
        // judged by the same unanimity rule as below over the picks as saved.
        // Dropping it used to hand those members Chat's model without a word
        // (S12, 2026-09-26). A lone per-surface key never routed anything — its
        // group follows Chat — so it keeps its notice on the Providers row but
        // refuses nothing, and never blocks the rest of its group.
        var retiredOverrideSurfaces: Set<String> = []
        for group in ProviderSurfaceGroups.all where group.id != ProviderSurfaceGroups.chat.id {
            guard group.surfaces.allSatisfy(retiredPickSurfaces.contains) else { continue }
            let saved = group.surfaces.map {
                tuple(for: $0, models: parsedSurfaceModels, efforts: parsedSurfaceEfforts,
                      tiers: parsedSurfaceServiceTiers, routes: routesBeforeRetirement)
            }
            if let first = saved.first ?? nil, saved.allSatisfy({ $0 == first }) {
                retiredOverrideSurfaces.formUnion(group.surfaces)
            }
        }
        var canonicalByGroup: [String: CanonicalTuple] = [:]
        for group in ProviderSurfaceGroups.all {
            if group.id == ProviderSurfaceGroups.chat.id {
                canonicalByGroup[group.id] = chatTuple
                continue
            }
            // A group OVERRIDE is what the Providers page writes: the same
            // choice on every member. Unanimity is the test, and it is what
            // separates an override from one stray key written by something
            // else — a single pin stays a pin on its own surface (the page
            // shows that row as Mixed) instead of quietly becoming the whole
            // group's answer.
            // The WHOLE tuple, not just the model (third review): two members on
            // the same model but different accounts — an API key and an OAuth
            // sign-in — are two different answers, and calling that an override
            // would route half a group through a transport nobody chose. Mixed
            // is the honest reading, and the page already says so.
            let members = group.surfaces.map(savedTuple)
            let first = members.first ?? nil
            let unanimous = !members.contains(where: { $0 == nil })
                && members.allSatisfy {
                    $0?.model == first?.model
                        && $0?.provider == first?.provider
                        && $0?.effort == first?.effort
                        && $0?.serviceTier == first?.serviceTier
                }
            canonicalByGroup[group.id] = unanimous
                ? (members.first ?? chatTuple) ?? chatTuple
                : chatTuple
        }

        var out: [String: SurfacePreference] = [:]
        var resolvedProviders: [String: String] = [:]
        var mismatchedPicks: [String: String] = [:]
        for surface in MODEL_SURFACES {
            // The group's tuple, and only the group's (User, 2026-09-13, second
            // review). The Providers page offers three choices and says
            // "Choosing here sets all four", so a per-surface key on disk is
            // something a person cannot see and must not be able to split a
            // group with. Legacy keys are ignored here and cleared by the next
            // group write.
            let canonical = ProviderSurfaceGroups.group(for: surface)
                .flatMap { canonicalByGroup[$0.id] } ?? chatTuple
            // The route is part of the answer and travels WITH the model
            // (2026-09-13 review): an inherited surface used to get Chat's model
            // without Chat's exact route, which is how a model reached a
            // provider that cannot serve it. A surface's own assignment is the
            // last resort, for a lane explicitly pointed somewhere before any
            // choice was made anywhere.
            let route = canonical.provider ?? activeProviders[surface]
            // A provider-only lane may inherit its saved provider-sheet pick.
            //
            // EXCEPT when the reason there is nothing is that the pick was
            // RETIRED (2026-09-13 review): substituting the route's default
            // there is a literal by another name and hides that the model the
            // person chose is gone. The surface reads as not set up, and so do
            // the surfaces inheriting from a retired Chat pick.
            // A pick that cannot be used never falls back to anything: not for
            // this surface, not for the group it inherits from, not for Chat.
            let unusableBlocksFallback = retiredOverrideSurfaces.contains(surface)
                || unusablePicks["chat"] != nil
            let model = canonical.model.isEmpty
                ? (unusableBlocksFallback
                    ? ""
                    : Self.normalizeModelIdStatic(
                        route.flatMap { defaultModelForProvider($0, savedDefaults: savedDefaults) } ?? "",
                        fallback: ""
                    ))
                : canonical.model
            // A model its route cannot serve is refused, never swapped for the
            // route's own default (S12, 2026-09-26): the surface is unset and
            // says why, on the Providers row and in the turn refusal.
            var effectiveModel = retiredOverrideSurfaces.contains(surface) ? "" : model
            if !effectiveModel.isEmpty, let route,
               let family = inferProviderForModel(model),
               !Self.providerCanServeModel(route, inferredProvider: family) {
                mismatchedPicks[surface] = "\(model) isn't available on \(route). Choose one."
                effectiveModel = ""
            }
            let effort = Self.normalizeReasoningEffortStatic(
                canonical.effort,
                fallback: DEFAULT_REASONING_EFFORT,
                model: effectiveModel,
                providerID: route,
                supportedReasoningEfforts: accountCatalogs[route ?? ""]?
                    .first { $0.id == effectiveModel }?.supportedReasoningEfforts
            )
            if let route, !route.isEmpty { resolvedProviders[surface] = route }
            out[surface] = SurfacePreference(
                surface: surface,
                model: effectiveModel,
                reasoningEffort: effort,
                serviceTier: canonical.serviceTier,
                modelKnown: nil
            )
        }
        var pinnedModels: [String: String] = [:]
        if case .object(let models) = surfaceModels {
            for (surface, value) in models {
                guard case .string(let model) = value, !model.isEmpty else { continue }
                pinnedModels[surface] = model
            }
        }
        return ProviderRoutingSnapshot(
            preferences: out,
            activeProviders: resolvedProviders,
            pinnedModels: pinnedModels,
            unusablePicks: unusablePicks.merging(mismatchedPicks) { saved, _ in saved }
        )
    }

    /// Lookup a single surface. Throws `.invalidRequest` if the surface
    /// is not a known MODEL_SURFACE — mirrors the daemon's contract.
    public func modelForSurface(_ surface: String) async throws -> SurfacePreference {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface) else {
            throw ProviderRoutingError.invalidRequest
        }
        let prefs = try await computeModelPreferences()
        // computeModelPreferences seeds every MODEL_SURFACE, so this is total.
        return prefs[surface]!
    }

    /// Mirrors Python `normalize_model_id`: trim, reject empty, reject any
    /// character outside `[A-Za-z0-9._:/+-]`, length 1..100. Returns
    /// `fallback` on rejection. Does NOT lowercase — Python doesn't either.
    public nonisolated func normalizeModelId(_ raw: String, fallback: String = "") -> String {
        Self.normalizeModelIdStatic(raw, fallback: fallback)
    }

    /// Mirrors Python `normalize_reasoning_effort`: lowercase + trim, then
    /// accept only one of REASONING_EFFORT_OPTIONS. Anything else (including
    /// "") returns `fallback`. Note Python's behavior: empty string → fallback,
    /// invalid string → fallback — identical paths.
    public nonisolated func normalizeReasoningEffort(_ raw: String, fallback: String = "medium") -> String {
        Self.normalizeReasoningEffortStatic(raw, fallback: fallback)
    }

    /// SWIFT-NATIVE PHASE B CORRECTION of `_provider_hint_for_model_id`:
    /// the daemon's Python helper folds OpenRouter's `anthropic/claude-...`
    /// into `anthropic_oauth_direct` and only avoids the mis-routing via the
    /// `inferProvider=false` body flag on the picker save. The Swift path
    /// reads the namespace literally:
    ///   - `anthropic/...`  -> openrouter   (OpenRouter namespace)
    ///   - `openai/...`     -> openrouter
    ///   - bare `claude-...` / `sonnet/`+`opus/`+`haiku/` -> anthropic_oauth_direct
    ///   - bare `gpt-...`   -> openai_oauth_direct
    ///   - bare `grok-...`  -> xai_oauth_direct
    ///   - everything else  -> nil
    /// Returning nil (rather than "") lets the caller decide whether to fall
    /// through to the persisted active provider.
    public nonisolated func inferProviderForModel(_ modelId: String) -> String? {
        Self.inferredProviderID(forModel: modelId)
    }

    /// Size background evidence from the selected route's catalog without a
    /// second read of the saved selection. OpenRouter reads through its own
    /// catalog (cache, TTL refresh, failure backoff); `catalogFailure` is why
    /// that list could not be fetched when the model is missing from it.
    public func catalogContextLength(forModel modelID: String, providerID: String) async
        -> (contextLength: Int?, catalogFailure: String?) {
        let openRouter = providerID == "openrouter"
            ? await OpenRouterModelCatalog.modelsWithFreshness(dataRoot: dataRoot) : nil
        let moonshot = providerID == "moonshot"
            ? MoonshotModelCatalog.readCache(dataRoot: dataRoot)?.map { $0.providerJSON() } : nil
        let rows = modelsForProvider(providerID,
            openRouterModels: openRouter?.models.map { $0.providerJSON() }, moonshotModels: moonshot)
        guard let row = rows.first(where: {
            guard case .string(let id) = $0["id"] else { return false }
            return id.lowercased() == modelID.lowercased()
        }),
              case .int(let length) = row["context_length"], length > 0 else { return (nil, openRouter?.failure) }
        return (Int(exactly: length), nil)
    }

    public nonisolated static func inferredProviderID(forModel modelId: String) -> String? {
        let lower = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return nil }
        // Slash-namespaced id => an OpenRouter / aggregator model id.
        if lower.hasPrefix("anthropic/") || lower.hasPrefix("openai/") {
            return "openrouter"
        }
        if lower.hasPrefix("claude-")
            || lower.hasPrefix("sonnet/") || lower.hasPrefix("opus/") || lower.hasPrefix("haiku/") {
            return "anthropic_oauth_direct"
        }
        if lower.hasPrefix("gpt-") {
            return "openai_oauth_direct"
        }
        if lower.hasPrefix("grok-") {
            return "xai_oauth_direct"
        }
        // Kimi Code SUBSCRIPTION ids (kimi-for-coding[-highspeed], bare k3)
        // resolve to "kimi-code" ahead of the moonshot prefix branch below.
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(lower) {
            return "kimi-code"
        }
        if lower.hasPrefix("kimi-") || lower.hasPrefix("moonshot-") {
            return "moonshot"
        }
        return nil
    }

    /// The model a route answers with when nobody has picked one: the saved
    /// "Model it falls back to", else the first row of that route's catalog.
    /// Public so onboarding can WRITE it down when the first account connects —
    /// the resolver has no literal to fall back on.
    public func defaultModelForProviderID(_ providerId: String) -> String? {
        defaultModelForProvider(providerId)
    }

    private nonisolated func defaultModelForProvider(
        _ providerId: String,
        savedDefaults: [String: SavedProviderDefault]? = nil
    ) -> String? {
        // A saved provider-sheet choice may be inherited. Catalog ordering
        // never chooses a model for a surface without an explicit pick.
        let offered = modelsForProvider(providerId).compactMap { model -> String? in
            if case .string(let id)? = model["id"] { return id }
            return nil
        }
        switch savedDefaults?[providerId] ?? configuredDefaultModel(providerId) {
        case .model(let saved):
            if offered.isEmpty || offered.contains(saved) { return saved }
            FileHandle.standardError.write(Data(
                "[provider-routing] \(providerId) no longer offers saved default '\(saved)'; choose a model in the picker\n".utf8
            ))
            return nil
        case .unreadable(let reason):
            // User, 2026-09-06: corrupt authority is not "no selection". Falling
            // through to the catalog seed here silently re-pointed the surface
            // at a different model than the one the person picked. Say so and
            // keep whatever model the caller already had.
            FileHandle.standardError.write(Data(
                "[provider-routing] keeping the current model: \(reason)\n".utf8
            ))
            return nil
        case .absent:
            break
        }
        return nil
    }

    /// What `providers/<id>.json` says about the provider's `default_model`.
    /// User, 2026-09-06: "absent" and "corrupt" used to be the same answer
    /// (nil), and nil sends the caller to the catalog seed — so a config file
    /// that failed to parse silently MOVED the person's selected model to
    /// whatever the catalog listed first. Corruption is now its own case and
    /// means "keep the model you already have".
    enum SavedProviderDefault {
        case absent
        case model(String)
        case unreadable(String)

        /// The saved pick, or nil for both absent and unreadable. Callers that
        /// must distinguish the two switch on the case instead.
        var model: String? {
            if case .model(let id) = self { return id }
            return nil
        }
    }

    /// The `default_model` the person picked in the provider sheet, read from
    /// `providers/<id>.json` (where `configureProvider` writes it).
    ///
    /// User, 2026-09-06: read under the SAME per-file lock `configureProvider`
    /// writes under. The read was unlocked and happened once per surface, so a
    /// save landing mid-snapshot resolved some surfaces against the old
    /// default and the rest against the new one.
    private nonisolated func configuredDefaultModel(
        _ providerId: String,
        cache: ProviderConfigCache? = nil
    ) -> SavedProviderDefault {
        let trimmedId = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedId.contains("/") else { return .absent }
        let read = cache?.reads[trimmedId] ?? readProviderConfig(trimmedId)
        if let reason = read.unreadable { return .unreadable(reason) }
        guard let object = read.object else { return .absent }
        for key in ["default_model", "defaultModel"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return .model(trimmed) }
            }
        }
        return .absent
    }

    /// One `providers/<id>.json`, read and parsed under the SAME per-file lock
    /// `configureProvider` writes under. `object` nil with no `unreadable`
    /// reason means the file simply is not there.
    struct ProviderConfigRead {
        var object: [String: Any]?
        var unreadable: String?
    }

    /// Every `providers/<id>.json` one routing snapshot needs, each read
    /// exactly once.
    ///
    /// User, 2026-09-06: the readiness probes behind `soleConnectedProviderFamily`
    /// read these same files UNLOCKED, and ran BEFORE the locked `default_model`
    /// reads — so a `configureProvider` save landing between the two produced a
    /// single snapshot that decided which provider was connected from the old
    /// bytes and what that provider defaults to from the new ones. Both lanes
    /// now read from this, filled once, under the writer's lock.
    struct ProviderConfigCache {
        var reads: [String: ProviderConfigRead] = [:]
        var readiness: [String: (ready: Bool, state: String, detail: String)] = [:]
    }

    private nonisolated func readProviderConfig(_ providerId: String) -> ProviderConfigRead {
        let trimmedId = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedId.contains("/") else { return ProviderConfigRead() }
        let path = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(trimmedId).json")
        guard FileManager.default.fileExists(atPath: path.path) else { return ProviderConfigRead() }
        do {
            return try CredentialFileLock.withLock(path) { () -> ProviderConfigRead in
                guard let data = try? Data(contentsOf: path) else {
                    return ProviderConfigRead(
                        unreadable: "provider \(trimmedId) configuration could not be read"
                    )
                }
                guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return ProviderConfigRead(
                        unreadable: "provider \(trimmedId) configuration is not a JSON object"
                    )
                }
                guard case .object(let fields) = try JSONValue.parse(data) else {
                    return ProviderConfigRead(unreadable: "provider configuration is malformed")
                }
                try Self.validateProviderConfiguration(fields)
                if trimmedId == "xai_oauth_direct" {
                    object = try XAIOAuthCredentialStore.read(at: path)
                }
                // Resolve the Keychain reference under the config writer's lock
                // so readiness and model settings share one credential generation.
                if object[ProviderAPIKeyStore.referenceField] != nil {
                    let key = LLMCredentialResolver.resolveAPIKey(providerConfigObject: object)
                    object.removeValue(forKey: ProviderAPIKeyStore.referenceField)
                    object["api_key"] = key
                }
                return ProviderConfigRead(object: object)
            }
        } catch {
            return ProviderConfigRead(
                unreadable: "provider \(trimmedId) configuration is locked: \(error.localizedDescription)"
            )
        }
    }

    /// Fill the per-snapshot cache. The set is the readiness probes plus every
    /// provider a surface names, so neither lane has to read a file the other
    /// already read.
    nonisolated func providerConfigCache(
        for providerIds: Set<String>,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderConfigCache {
        var cache = ProviderConfigCache()
        for id in providerIds {
            let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedId.isEmpty, !trimmedId.contains("/") else { continue }
            cache.reads[trimmedId] = readProviderConfig(trimmedId)
        }
        for id in cache.reads.keys {
            cache.readiness[id] = providerReadiness(id: id, cache: cache, authEnvironment: authEnvironment)
        }
        return cache
    }

    /// Read each provider's saved config ONCE per routing snapshot, so every
    /// surface in that snapshot resolves against the same bytes.
    private nonisolated func savedProviderDefaults(
        for providerIds: Set<String>,
        cache: ProviderConfigCache? = nil
    ) -> [String: SavedProviderDefault] {
        var out: [String: SavedProviderDefault] = [:]
        for id in providerIds {
            out[id] = configuredDefaultModel(id, cache: cache)
        }
        return out
    }

    /// Bare GPT ids are shared by direct OpenAI transports and the Codex CLI.
    /// Compatibility must not normalize Codex into OpenAI because adapter
    /// selection still needs to preserve the user's exact auth route.
    nonisolated static func providerCanServeModel(
        _ activeProvider: String,
        inferredProvider: String
    ) -> Bool {
        let active = normalizeProviderId(activeProvider)
        let inferred = normalizeProviderId(inferredProvider)
        return active == inferred || (active == "codex" && inferred == "openai")
    }

    nonisolated static func normalizeProviderId(_ raw: String) -> String {
        ProviderFamilyIdentity.normalize(raw)
    }

    /// Read `<dataRoot>/providers/active.json`, returning the surface→providerId
    /// map. Missing is empty; the throwing preference path rejects corruption.
    /// This nonthrowing compatibility view stays conservative on corruption.
    /// Surfaces the value the user's picker writes
    /// via `setActiveProvider(surface:providerId:)` so the dispatch layer can
    /// honor it as a tiebreaker when a model id is ambiguous.
    public func activeProvidersForSurfaces() async -> [String: String] {
        (try? await activeProvidersForSurfacesChecked()) ?? [:]
    }

    public func readActiveProvidersChecked() async throws -> [String: String] {
        try await activeProvidersForSurfacesChecked()
    }

    /// The SAVED per-surface assignments, exactly as `providers/active.json`
    /// holds them — no sole-account answer, no Chat inheritance, no resolution
    /// of any kind. `readActiveProvidersChecked` returns the RESOLVED map, in
    /// which a single connected account already supplies Chat's route, so a
    /// caller asking "has a choice been written down yet?" reads yes before
    /// anything is persisted (2026-09-13 review). Adoption asks THIS.
    public func savedActiveProvidersChecked() async throws -> [String: String] {
        try await reconciledPickerState().active
    }

    public func activeProvidersForSurfacesChecked() async throws -> [String: String] {
        try await checkedRoutingSnapshot().activeProviders
    }

    /// Actor override of the protocol default. Reads `providers/surfaces.json`
    /// and returns the explicitly-pinned model for `surface` only when the
    /// key is present (and non-empty). Returns nil for any unpinned surface,
    /// so dream / REM can fall back to the chat-surface picker without
    /// confusing a daemon-era seed for a user pin.
    public func pinnedModelStringForSurface(_ surface: String) async -> String? {
        try? await pinnedModelStringForSurfaceChecked(surface)
    }

    public func pinnedModelStringForSurfaceChecked(_ surface: String) async throws -> String? {
        ProviderRoutingSurfaceLookup.value(try await checkedRoutingSnapshot().pinnedModels, surface)
    }

    /// Parse `providers/surfaces.json` into (surfaceModels, surfaceEfforts)
    /// objects in the shape `Self.objectAt` returns. Tolerates two on-disk
    /// shapes: nested `{"chat": {"model":"...","reasoningEffort":"..."}}` and
    /// flat `{"chat": "gpt-5.5"}` (the latter for the simplest picker writes).
    /// Model values also tolerate JSON scalars so migrated picker data keeps
    /// the old Python `str(value or base)` compatibility.
    nonisolated static func parseSurfacesFile(_ raw: JSONValue) -> (JSONValue, JSONValue) {
        guard case .object(let obj) = raw, !obj.isEmpty else {
            return (.object([:]), .object([:]))
        }
        var models: [String: JSONValue] = [:]
        var efforts: [String: JSONValue] = [:]
        for (surface, entry) in obj {
            switch entry {
            case .string(let s):
                if !s.isEmpty { models[surface] = .string(s) }
            case .object(let inner):
                if let m = Self.stringFrom(.object(inner), key: "model") {
                    models[surface] = .string(m)
                }
                if case .string(let e)? = inner["reasoningEffort"], !e.isEmpty {
                    efforts[surface] = .string(e)
                } else if case .string(let e)? = inner["reasoning_effort"], !e.isEmpty {
                    efforts[surface] = .string(e)
                }
            case .bool(_), .int(_), .double(_):
                if let m = Self.stringFrom(.object([surface: entry]), key: surface) {
                    models[surface] = .string(m)
                }
            default:
                continue
            }
        }
        return (.object(models), .object(efforts))
    }

    nonisolated static func parseSurfaceServiceTiers(_ raw: JSONValue) -> JSONValue {
        guard case .object(let obj) = raw, !obj.isEmpty else {
            return .object([:])
        }
        var tiers: [String: JSONValue] = [:]
        for (surface, entry) in obj {
            guard case .object(let inner) = entry else { continue }
            if case .string(let tier)? = inner["serviceTier"], !tier.isEmpty {
                tiers[surface] = .string(tier)
            } else if case .string(let tier)? = inner["service_tier"], !tier.isEmpty {
                tiers[surface] = .string(tier)
            } else if case .bool(let fast)? = inner["fastMode"] {
                tiers[surface] = .string(fast ? "priority" : "default")
            }
        }
        return .object(tiers)
    }

    // MARK: helpers (nonisolated statics so init + nonisolated methods can call)

    /// Strip picks whose route's catalog no longer carries them, including
    /// account discovery over its offline rows. An OpenRouter or
    /// self-hosted id this build has never seen is left alone.
    /// The surfaces whose saved pick their own ROUTE no longer carries. Such a
    /// pick is not a pick: the surface returns to its Providers group's choice.
    ///
    /// 2026-09-13 review: it returns SURFACES, not a filtered model map, because
    /// a retired pick has to take the whole surface tuple with it — its effort,
    /// its Fast setting and its provider assignment. Dropping the model alone
    /// left the lane on an effort and a route chosen for a model that is gone,
    /// which is not "back with its group" in any sense a person would recognise.
    nonisolated static func surfacesWithRetiredPicks(
        _ models: JSONValue,
        accountModels: [String: Set<String>] = [:],
        routeForSurface: (String, String) -> String?
    ) -> Set<String> {
        guard case .object(let obj) = models else { return [] }
        var retired: Set<String> = []
        for (surface, value) in obj {
            guard case .string(let model) = value,
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let route = routeForSurface(surface, model)
            let carried = route.flatMap {
                accountModels[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            }.map {
                $0.contains(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            } ?? FirstPartyModelCatalog.routeCarries(model, providerID: route)
            if !carried {
                retired.insert(surface)
            }
        }
        return retired
    }

    nonisolated static func dropping(_ surfaces: Set<String>, from value: JSONValue) -> JSONValue {
        guard case .object(let obj) = value, !surfaces.isEmpty else { return value }
        return .object(obj.filter { !surfaces.contains($0.key) })
    }

    nonisolated static func normalizeModelIdStatic(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        if trimmed.count > 100 { return fallback }
        // Python: re.fullmatch(r"[A-Za-z0-9._:/+-]{1,100}", model)
        let allowed: Set<Character> = {
            var s: Set<Character> = []
            for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/+-" {
                s.insert(c)
            }
            return s
        }()
        for ch in trimmed {
            if !allowed.contains(ch) { return fallback }
        }
        // GPT-5.5 was NativeAgent's primary fallback before GPT-5.6 shipped.
        // Normalize persisted legacy picks at the shared routing boundary so
        // every surface converges on Sol instead of silently downgrading.
        // No literal remaps live here. A retired id is handled where the picker
        // state is read (`liveSurfaceModels`): it stops being a pick, and the
        // surface returns to its group's choice. User, 2026-09-13: "All model
        // selections should be taken care of at the picker."
        return trimmed
    }

    nonisolated static func normalizeReasoningEffortStatic(_ raw: String, fallback: String) -> String {
        normalizeReasoningEffortStatic(raw, fallback: fallback, model: nil)
    }

    nonisolated static func normalizeReasoningEffortStatic(
        _ raw: String,
        fallback: String,
        model: String?,
        providerID: String? = nil,
        supportedReasoningEfforts: [String]? = nil
    ) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard REASONING_EFFORT_OPTIONS.contains(normalized) else { return fallback }
        let lowerModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var supported: Set<String>
        switch lowerModel {
        case let model where model.hasPrefix("kimi-") || model.hasPrefix("moonshot-"):
            supported = Set(MoonshotModelCatalog.supportedReasoningEfforts(for: model))
        case "gpt-6-sol" where providerID?.lowercased() == "openai":
            supported = Set(FirstPartyModelCatalog.publicGPT56Efforts)
        case FirstPartyModelCatalog.gpt6AstraModelID, "gpt-6.1-sol", "gpt-6-sol":
            supported = providerID?.lowercased() == "openai"
                ? Set(FirstPartyModelCatalog.publicGPT6AstraEfforts)
                : Set(FirstPartyModelCatalog.accountGPT6AstraEfforts)
        case "gpt-6-luna":
            supported = Set(FirstPartyModelCatalog.accountGPT56LunaEfforts)
        case "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra":
            supported = providerID?.lowercased() == "openai"
                ? Set(FirstPartyModelCatalog.publicGPT56Efforts)
                : Set(FirstPartyModelCatalog.accountGPT56SolTerraEfforts)
        case "gpt-5.6-luna":
            supported = providerID?.lowercased() == "openai"
                ? Set(FirstPartyModelCatalog.publicGPT56Efforts)
                : Set(FirstPartyModelCatalog.accountGPT56LunaEfforts)
        default:
            let bareAnthropic = lowerModel.hasPrefix("anthropic/")
                ? String(lowerModel.dropFirst("anthropic/".count))
                : lowerModel
            if let descriptor = FirstPartyModelCatalog.anthropicDescriptor(for: bareAnthropic) {
                supported = Set(descriptor.supportedReasoningEfforts)
            } else if let descriptor = FirstPartyModelCatalog.xAIDescriptor(for: lowerModel) {
                supported = Set(descriptor.supportedReasoningEfforts)
            } else if lowerModel.hasPrefix("claude-") || lowerModel.hasPrefix("anthropic/claude-") {
                supported = ["low", "medium", "high"]
            } else {
                supported = ["low", "medium", "high", "xhigh"]
            }
        }
        if let supportedReasoningEfforts {
            supported = Set(supportedReasoningEfforts)
        }
        guard supported.contains(normalized) else {
            let cleanFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if supported.contains(cleanFallback) { return cleanFallback }
            if supported.contains("high") { return "high" }
            for candidate in REASONING_EFFORT_OPTIONS where supported.contains(candidate) {
                return candidate
            }
            return "high"
        }
        return normalized
    }

    nonisolated static func normalizeServiceTierStatic(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "priority", "fast": return "priority"
        default: return "default"
        }
    }

    /// Return the nested object at `key` from `node`, or empty object.
    nonisolated static func objectAt(_ node: JSONValue, key: String) -> JSONValue {
        if case .object(let obj) = node, let v = obj[key], case .object = v {
            return v
        }
        return .object([:])
    }

    /// Mirrors Python's truthiness rules: `None`, `False`, `0`, `0.0`, `""`,
    /// empty list, empty dict — all falsy. Used to preserve the `value or
    /// base` compatibility for migrated picker data.
    nonisolated static func isPythonFalsy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .bool(let b): return !b
        case .int(let i): return i == 0
        case .double(let d): return d == 0
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        }
    }

    /// Mirrors Python's `str(value or "")` coercion for migrated picker
    /// values. int/double/bool all coerce; null/empty containers fold to `""`.
    public nonisolated static func jsonValueAsPythonStr(_ v: JSONValue) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return pythonFloatStr(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    /// Render a double the way Python's `str(float)` does for migrated
    /// picker values (1.5 → "1.5", 2.0 → "2.0"). Avoids scientific
    /// notation for the round-trip common cases.
    nonisolated static func pythonFloatStr(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e16 {
            return "\(d)"  // Swift renders 2.0 as "2.0" — matches Python.
        }
        return "\(d)"
    }

    /// Return the string at `key` from `node`, coerced via Python's
    /// `str(value or "")` rules. Returns nil if the value is missing or
    /// Python-falsy (so the caller can fall through to a fallback like
    /// Python's `a or b or c` chain).
    nonisolated static func stringFrom(_ node: JSONValue, key: String) -> String? {
        guard case .object(let obj) = node, let v = obj[key] else { return nil }
        if isPythonFalsy(v) { return nil }
        let coerced = jsonValueAsPythonStr(v)
        return coerced.isEmpty ? nil : coerced
    }

    /// Walk `keys` in order, returning the first one whose value is
    /// Python-truthy (after str-coercion). Mirrors Python's chained
    /// `a or b or c`.
    nonisolated static func firstNonEmptyString(_ node: JSONValue, keys: [String]) -> String? {
        for k in keys {
            if let s = stringFrom(node, key: k) { return s }
        }
        return nil
    }

    nonisolated static func firstString(
        _ obj: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if case .string(let s)? = obj[key] {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private nonisolated static func validateOpenAIOAuthDirect(
        dataRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (Bool, String) {
        let paths = openAIOAuthCandidatePaths(dataRoot: dataRoot, environment: environment)
        var sawAuth = false
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            sawAuth = true
            let tokens = (obj["tokens"] as? [String: Any]) ?? [:]
            let access = (tokens["access_token"] as? String) ?? ""
            if access.isEmpty { continue }
            let refresh = (tokens["refresh_token"] as? String) ?? ""
            if let expDate = parseAuthExpiresAt(tokens["expires_at"])
                ?? parseAuthExpiresAt(obj["expires_at"])
                ?? jwtExpiry(access) {
                if expDate > Date() {
                    return (true, "Signed in")
                }
                if !refresh.isEmpty && OAuthRefreshBinding.permitsRefresh(obj, provider: "openai_oauth_direct") {
                    return (true, "Signed in. Your session will renew on your next chat.")
                }
                continue
            }
            return (true, "Signed in")
        }
        if sawAuth {
            return (false, "Reconnect your ChatGPT account in Providers.")
        }
        return (false, "Sign in to your ChatGPT account in Providers.")
    }

    /// Production keeps the intentional shared-Codex compatibility search.
    /// An alternate root is a separate body: it may inspect only its exact
    /// `<root>/codex_home/auth.json`, never the repo/default app-support path or
    /// `~/.codex/auth.json`.
    nonisolated static func openAIOAuthCandidatePaths(
        dataRoot: URL,
        defaultDataRoot: URL = PersistenceCore.defaultDataRoot(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let root = dataRoot.standardizedFileURL
        guard root == defaultDataRoot.standardizedFileURL else {
            return [root
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")]
        }
        return OpenAIOAuthDirectAdapter.authPathCandidates(
            dataRoot: root, environment: environment,
            allowSharedFallbacks: true
        )
    }

    /// `preRead` is the routing snapshot's single locked read of this file; nil
    /// means read it here (the Provider Settings listing path).
    private nonisolated static func validateAnthropicOAuthDirect(
        providersDir: URL,
        preRead: ProviderConfigRead? = nil
    ) -> (Bool, String) {
        let path = providersDir.appendingPathComponent("anthropic_oauth_direct.json")
        let parsed: [String: Any]?
        if let preRead {
            parsed = preRead.object
        } else if let data = try? Data(contentsOf: path) {
            parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            parsed = nil
        }
        // The adapter that serves the calls decides (see credentialStatus).
        let status = AnthropicOAuthDirectAdapter.credentialStatus(parsed)
        return (status.usable, status.detail)
    }

    /// `preRead` is the routing snapshot's single locked read of this file; nil
    /// means read it here (the Provider Settings listing path).
    private nonisolated static func validateXAIOAuthDirect(
        providersDir: URL,
        preRead: ProviderConfigRead? = nil
    ) -> (Bool, String) {
        let path = providersDir.appendingPathComponent("xai_oauth_direct.json")
        let parsed: [String: Any]?
        if let preRead {
            parsed = preRead.object
        } else {
            do { parsed = try XAIOAuthCredentialStore.read(at: path) }
            catch { return (false, "xAI Keychain credentials are unavailable. Reconnect in Providers.") }
        }
        guard let obj = parsed, !obj.isEmpty else {
            return (false, "Sign in to your xAI account in Providers.")
        }
        let tokens = OAuthRefreshBinding.tokenSet(obj, provider: "xai_oauth_direct")
        let access = ((tokens["access_token"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = ((tokens["refresh_token"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !refresh.isEmpty else {
            return (false, "Reconnect your xAI account in Providers.")
        }
        if let expDate = parseAuthExpiresAt(obj["expires_at"]) ?? jwtExpiry(access) {
            if expDate > Date() {
                return (true, "Signed in")
            }
            if !refresh.isEmpty && OAuthRefreshBinding.permitsRefresh(obj, provider: "xai_oauth_direct") {
                return (true, "Signed in. Your session will renew on your next chat.")
            }
            return (false, "Reconnect your xAI account in Providers.")
        }
        return (true, "Signed in")
    }

    /// Decodes persisted OAuth expiry values in the shared app/routing compatibility order.
    public nonisolated static func parseAuthExpiresAt(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let i = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
        if let d = raw as? Double { return Date(timeIntervalSince1970: d) }
        guard let s = raw as? String, !s.isEmpty else { return nil }
        if let unix = TimeInterval(s) { return Date(timeIntervalSince1970: unix) }
        let basic = DateFormatter()
        basic.calendar = Calendar(identifier: .iso8601)
        basic.locale = Locale(identifier: "en_US_POSIX")
        basic.timeZone = TimeZone(secondsFromGMT: 0)
        basic.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        if let d = basic.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }

    private nonisolated static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var body = String(parts[1])
        while body.count % 4 != 0 { body.append("=") }
        body = body
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let exp = obj["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
        if let exp = obj["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        return nil
    }
}

// MARK: - Factory

/// SwiftNative handles provider routing directly. The provider-selection
/// decisions during chat turns happen inside the ChatOrchestration pipeline,
/// using Swift-native model preference data. This subsystem is
/// config/inspection only.
public func makeProviderRouting(
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any ProviderRoutingProtocol {
    return SwiftNativeProviderRouting(dataRoot: dataRoot)
}

// MARK: - Public model lookup

/// Verified context window for the exact admitted provider/model tuple.
/// Returns nil when this build has no evidence for that tuple; callers that
/// size prompt material must use their conservative floor rather than treating
/// the UI gauge's unknown-model fallback as a measured capability.
public func verifiedContextLength(
    forModel modelId: String,
    providerID: String?,
    dataRoot: URL? = nil
) -> Int? {
    let model = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !model.isEmpty else { return nil }
    guard let rawProvider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawProvider.isEmpty else {
        return FirstPartyModelCatalog.descriptor(for: model)?.contextLength
            ?? verifiedOpenRouterContextLength(forModel: model)
    }
    let provider = rawProvider.lowercased()
    if provider == "openrouter" {
        return dataRoot.flatMap {
            OpenRouterModelCatalog.cachedDescriptor(for: model, dataRoot: $0)?.contextLength
        } ?? verifiedOpenRouterContextLength(forModel: model)
    }
    let firstPartyProviders: Set<String> = [
        "openai", "codex", "openai_oauth_direct",
        "anthropic", "anthropic_oauth_direct", "anthropic_mcp",
        "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth",
        "moonshot", "kimi", "kimi-code",
    ]
    guard firstPartyProviders.contains(provider) else { return nil }
    return FirstPartyModelCatalog.descriptor(for: model, providerID: provider)?.contextLength
}

private func verifiedOpenRouterContextLength(forModel modelId: String) -> Int? {
    switch modelId {
    case "meta-llama/llama-3.3-70b-instruct": return 131_072
    case "anthropic/claude-sonnet-5": return 1_000_000
    default: return nil
    }
}

/// Context-window budget (input-token cap) for a known model id. Single
/// source of truth used by the chat-context status bar. Returns 200_000 for
/// any unknown id so the UI shows the safer of the two values rather than 0.
///
/// 2026-06-07: lifted out of the private `modelsForProvider` table so the
/// Mac UI's getSessionContext can derive the budget directly from
/// `appModel.chatModel` without going through the async provider catalog.
public func contextLength(forModel modelId: String) -> Int {
    let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let descriptor = FirstPartyModelCatalog.descriptor(for: id) {
        return descriptor.contextLength
    }
    switch id {
    // Every first-party id is answered by the catalog lookup above, so the rows
    // that used to repeat those windows here were dead and could drift from it
    // (2026-09-13). What remains is ids no shipped catalog carries.
    // OpenRouter passthroughs (live rows 2026-08-07; the delisted
    // anthropic/claude-3.5-sonnet entry was retired with them).
    // Non-gauge consumer note: ChatSessionAutocompactor reads this length
    // directly, so the 1M row lets a Sonnet-5-via-OpenRouter session keep the
    // user-configured compaction ceiling instead of clamping to a 200k
    // window's 40% — correct for a genuinely 1M-window model.
    case "meta-llama/llama-3.3-70b-instruct": return 131_072
    case "anthropic/claude-sonnet-5": return 1_000_000
    default:
        // gpt-5.5 review #4 (NEEDS_FIX): unknown-model fallback was 200_000
        // which is optimistic — a 128k-window model would then read percent
        // below 100 even when it had blown its real budget and stopped
        // accepting input. Default to 128_000 so the gauge errs toward
        // pessimism (the user sees pressure sooner) and only widen for ids that
        // self-identify as long-context. opus/sonnet/gpt-5.5 family ids
        // already hit explicit cases above.
        return 128_000
    }
}
