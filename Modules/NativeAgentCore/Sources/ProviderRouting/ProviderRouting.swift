import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderRouting.swift` | `SwiftNativeProviderRouting` actor; `checkedProviderSnapshot`, `checkedRoutingSnapshot`, `saveGroupSelection`, `adoptConnectedProvider`, `catalogContextLength`, `routingRepairInput`, `reconstructRouting`; effort-only group rows inherit Chat's current model/account without seeding other controls; provider interpretation, byte-checked picker/configuration decode reuse with fresh credential/readiness checks; checked picker revisions come from both files under the transaction lock and travel with phone snapshots/readbacks, recoverable group writes/adoption and byte-preserving explicit routing reconstruction |
/// Owns provider registry, credentials and per-surface routing state.
public actor SwiftNativeProviderRouting: Sendable {
    let dataRoot: URL
    let surfacesPath: URL
    let activeProviderPath: URL
    private struct PickerGeneration: Sendable {
        let surfacesBytes: Data?
        let activeBytes: Data?
        let surfaces: [String: JSONValue]
        let active: [String: String]
    }
    private nonisolated let pickerGeneration = OSAllocatedUnfairLock<PickerGeneration?>(initialState: nil)
    // Only validated file objects live here, never resolved Keychain values or readiness. The writer's lock and a fresh byte read precede every lookup. Raw Foundation JSON is immutable; the lock guards the memo and callers mutate only
    // their value copies, never its stored dictionaries.
    nonisolated let configurationGenerations = OSAllocatedUnfairLock(
        uncheckedState: [String: (bytes: Data, read: ProviderConfigRead)]()
    )
    /// `dataRoot` owns provider registry/config/catalog reads and writes. The two path overrides are narrower fixture seams for picker files only; they must not silently leave the rest of the actor on the personal root. Secondary/test
    /// runtimes therefore pass their exact data root.
    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        surfacesPathOverride: URL? = nil,
        activeProviderPathOverride: URL? = nil
    ) {
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
    var surfaceTransactionPath: URL {
        surfacesPath.deletingLastPathComponent()
            .appendingPathComponent("pending-surface-configuration.json")
    }
    /// Read the reconstruction input without requiring the damaged state to decode.
    public func routingRepairInput() async throws -> JSONValue {
        let transactionPath = surfaceTransactionPath
        return try await SwiftNativePersistenceCore.withFileLock(transactionPath) {
            var fields: [String: JSONValue] = [:]
            for (key, path) in [("surfaces", self.surfacesPath), ("active", self.activeProviderPath),
                                ("pending", transactionPath)] {
                fields[key + "BaseHash"] = try Self.fileSHA256(path).map(JSONValue.string) ?? .null
                if FileManager.default.fileExists(atPath: path.path) {
                    fields[key + "Bytes"] = .string(try Data(contentsOf: path).base64EncodedString())
                }
            }
            return .object(fields)
        }
    }
    /// An explicit complete replacement, guarded by the bytes inspected by the caller. The old projections and intent remain beside their files, named by digest.
    public func reconstructRouting(_ input: JSONValue) async throws {
        guard case .object(let fields) = input,
              case .object(let surfaces)? = fields["surfaces"],
              case .object(let active)? = fields["active"],
              surfaces["chat"] != nil, active["chat"] != nil else {
            throw ProviderRoutingError.configurationFailed("Reconstruction needs complete surfaces and active objects, including Chat, and the three BaseHash values from providers.routing_repair.")
        }
        try Self.validateSurfacePreferences(surfaces)
        let routes = try Self.loadActiveProviderObjectChecked(active)
        guard Set(surfaces.keys) == Set(routes.keys), surfaces.keys.allSatisfy(MODEL_SURFACES.contains) else {
            throw ProviderRoutingError.configurationFailed("Reconstruction needs an explicit model and account for every selected surface.")
        }
        let providers = try nativeListProviders(
            openRouterModels: OpenRouterModelCatalog.readCache(dataRoot: dataRoot)?.map { $0.providerJSON() },
            moonshotModels: MoonshotModelCatalog.readCache(dataRoot: dataRoot)?.map { $0.providerJSON() }
        ).providers
        for (surface, value) in surfaces {
            let model: String?
            switch value {
            case .string(let selected): model = selected
            case .object(let selected):
                if case .string(let id)? = selected["model"] { model = id } else { model = nil }
            default: model = nil
            }
            guard let model, let route = routes[surface],
                  let provider = providers.first(where: { $0.id == route }), provider.configured == true,
                  case .array(let models)? = provider.modelCatalog,
                  models.contains(where: { if case .object(let row) = $0 { return row["id"] == .string(model) }; return false }) else {
                throw ProviderRoutingError.configurationFailed("Reconstruction needs a connected account and an available model for \(surface).")
            }
        }
        let transactionPath = surfaceTransactionPath
        try await SwiftNativePersistenceCore.withFileLock(transactionPath) {
            for (key, path) in [("surfaces", self.surfacesPath), ("active", self.activeProviderPath),
                                ("pending", transactionPath)] {
                let hash = try Self.fileSHA256(path)
                guard fields[key + "BaseHash"] == (hash.map(JSONValue.string) ?? .null) else {
                    throw ProviderRoutingError.configurationFailed("Provider routing changed after inspection. Read providers.routing_repair again; nothing was replaced.")
                }
            }
            try Task.checkCancellation()
            for path in [self.surfacesPath, self.activeProviderPath, transactionPath] {
                guard let hash = try Self.fileSHA256(path) else { continue }
                let saved = path.appendingPathExtension("repair-" + hash)
                if !FileManager.default.fileExists(atPath: saved.path) {
                    try FileManager.default.copyItem(at: path, to: saved)
                } else if try Data(contentsOf: saved) != Data(contentsOf: path) {
                    throw ProviderRoutingError.configurationFailed("The preserved routing bytes do not match their digest; nothing was replaced.")
                }
            }
            try await self.commitPickerStateLocked(PendingSurfaceConfiguration(
                surfacesBaseHash: try Self.fileSHA256(self.surfacesPath),
                activeBaseHash: try Self.fileSHA256(self.activeProviderPath), surfaces: surfaces, active: active
            ))
        }
    }
    /// Provider state is bootstrap-empty only when absent. Existing unreadable, malformed, or wrong-shaped bytes are unavailable and must never be rewritten by a picker/config mutation as if they were missing.
    public nonisolated static func loadProviderStateObjectChecked(
        at path: URL,
        description: String
    ) throws -> [String: JSONValue] {
        try decodeProviderStateObjectChecked(
            providerStateBytesChecked(at: path, description: description), at: path, description: description
        )
    }
    private nonisolated static func providerStateBytesChecked(at path: URL, description: String) throws -> Data? {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        do {
            return try Data(contentsOf: path)
        } catch {
            throw providerStateFailure(at: path, description: description, detail: "is unreadable")
        }
    }
    private nonisolated static func decodeProviderStateObjectChecked(
        _ data: Data?, at path: URL, description: String
    ) throws -> [String: JSONValue] {
        guard let data else { return [:] }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw providerStateFailure(at: path, description: description, detail: "is malformed")
        }
        guard case .object(let object) = value else {
            throw providerStateFailure(at: path, description: description, detail: "must be a JSON object")
        }
        if description == "surface preference" {
            do { try validateSurfacePreferences(object) }
            catch { throw providerStateFailure(at: path, description: description, detail: error.localizedDescription) }
        }
        return object
    }
    private nonisolated static func providerStateFailure(at path: URL, description: String, detail: String) -> Error {
        guard ["surface preference", "active-provider", "pending provider selection"].contains(description) else {
            return ProviderRoutingError.underlying("saved \(description) state \(detail)")
        }
        let generation = (try? fileSHA256(path)) ?? "unreadable"
        return ToolFailureError(
            "Saved \(description) state \(detail). Inspect providers.routing_repair, then set its JSON text with the inspected BaseHash values and explicitly chosen complete surfaces and active objects. Original bytes are retained by digest; inspection does not repair routing.",
            effects: .none, owner: "\(path.path) generation \(generation)",
            nextCall: ToolFailureError.call("app", ["action": .string("setting.get"), "args": .object(["setting": .string("providers.routing_repair")])])
        )
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
        do { return try loadActiveProviderObjectChecked(raw) }
        catch { throw providerStateFailure(at: path, description: "active-provider", detail: error.localizedDescription) }
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
    public nonisolated static func loadProviderRegistryChecked(at path: URL) throws -> [Provider]? {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile { return nil }
        let data = try Data(contentsOf: path)
        let providers = try JSONDecoder().decode([Provider].self, from: data)
        guard providers.allSatisfy({ !$0.id.isEmpty }), Set(providers.map(\.id)).count == providers.count else {
            throw ProviderRoutingError.underlying("The saved provider registry has missing or duplicate ids.")
        }
        return providers
    }
    struct PendingSurfaceConfiguration: Sendable {
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
    nonisolated static func fileSHA256(_ path: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ProviderRoutingError.underlying("provider selection bytes are unreadable")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func updatedSurfaceRoot(
        _ root: [String: JSONValue],
        surface: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        seedMissingControls: Bool
    ) -> [String: JSONValue] {
        let root = canonicalizeRootForWrite(root, surface: surface)
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
    nonisolated static func updatedActiveRoot(
        _ root: [String: JSONValue],
        surface: String,
        providerId: String
    ) -> [String: JSONValue] {
        let root = canonicalizeRootForWrite(root, surface: surface)
        var updated = root
        updated[surface] = .string(providerId)
        return updated
    }
    /// Canonicalize only the surface being written; untouched surfaces keep their bytes.
    nonisolated static func canonicalizeRootForWrite(
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
    /// Finish an interrupted two-file picker commit before any later read or mutation observes the surface/model tuple. The durable intent is valid only while each live projection is either its recorded base bytes or the exact intended
    /// object; unrelated concurrent bytes fail closed and leave the marker available for explicit recovery instead of being silently overwritten.
    func reconcilePendingSurfaceConfigurationLocked() async throws {
        guard FileManager.default.fileExists(atPath: surfaceTransactionPath.path) else { return }
        let raw = try Self.loadProviderStateObjectChecked(
            at: surfaceTransactionPath,
            description: "pending provider selection"
        )
        let pending: PendingSurfaceConfiguration
        do { pending = try PendingSurfaceConfiguration(json: raw) }
        catch { throw Self.providerStateFailure(at: surfaceTransactionPath, description: "pending provider selection", detail: error.localizedDescription) }
        let surfacesAtBase = try Self.fileSHA256(surfacesPath) == pending.surfacesBaseHash
        let activeAtBase = try Self.fileSHA256(activeProviderPath) == pending.activeBaseHash
        let surfacesAtTarget = try surfacesAtBase || Self.loadProviderStateObjectChecked(
            at: surfacesPath, description: "surface preference") == pending.surfaces
        let activeAtTarget = try activeAtBase || Self.loadProviderStateObjectChecked(
            at: activeProviderPath, description: "active-provider") == pending.active
        guard surfacesAtTarget, activeAtTarget else {
            throw Self.providerStateFailure(at: surfaceTransactionPath, description: "pending provider selection", detail: "conflicts with newer provider state")
        }
        if surfacesAtBase {
            try await SwiftNativePersistenceCore.withFileLock(surfacesPath) {
                try await SwiftNativePersistenceCore.writeJSON(.object(pending.surfaces), to: self.surfacesPath)
            }
        }
        if activeAtBase {
            try await SwiftNativePersistenceCore.withFileLock(activeProviderPath) {
                try await SwiftNativePersistenceCore.writeJSON(.object(pending.active), to: self.activeProviderPath)
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
    func reconciledPickerState() async throws -> (
        surfaces: [String: JSONValue],
        active: [String: String], revision: Double
    ) {
        try await SwiftNativePersistenceCore.withFileLock(surfaceTransactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            return try self.checkedPickerStateLocked()
        }
    }
    /// The transaction lock still guards recovery and both fresh byte reads. Only decoding/canonicalization carries across identical checked bytes; a read failure can never serve the previous generation.
    nonisolated func checkedPickerStateLocked() throws -> (
        surfaces: [String: JSONValue], active: [String: String], revision: Double
    ) {
        let surfacesBytes = try Self.providerStateBytesChecked(at: surfacesPath, description: "surface preference")
        let activeBytes = try Self.providerStateBytesChecked(at: activeProviderPath, description: "active-provider")
        // Source revision is read under the same transaction lock as both picker files. Arrival, request order and a later serialization are not the revision of these recovered bytes.
        var revision: Double = 0
        for (url, bytes) in [(surfacesPath, surfacesBytes), (activeProviderPath, activeBytes)] where bytes != nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let modified = attributes[.modificationDate] as? Date else {
                throw ProviderRoutingError.underlying("Provider selection has no source revision.")
            }
            revision = max(revision, modified.timeIntervalSince1970)
        }
        return try pickerGeneration.withLock { [revision] generation in
            if let generation, generation.surfacesBytes == surfacesBytes, generation.activeBytes == activeBytes {
                return (generation.surfaces, generation.active, revision)
            }
            let surfaces = try Self.decodeProviderStateObjectChecked(
                surfacesBytes, at: surfacesPath, description: "surface preference"
            )
            let rawActive = try Self.decodeProviderStateObjectChecked(
                activeBytes, at: activeProviderPath, description: "active-provider"
            )
            let active: [String: String]
            do { active = try Self.loadActiveProviderObjectChecked(rawActive) }
            catch { throw Self.providerStateFailure(at: activeProviderPath, description: "active-provider", detail: error.localizedDescription) }
            // Both files enter memory through one vocabulary; only a write migrates their bytes.
            let checked = PickerGeneration(
                surfacesBytes: surfacesBytes, activeBytes: activeBytes,
                surfaces: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(surfaces),
                active: WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(active)
            )
            generation = checked
            return (checked.surfaces, checked.active, revision)
        }
    }
    /// Read Swift-native provider picker state and seed every MODEL_SURFACE. Surface models/efforts come from `providers/surfaces.json`; active provider hints come from `providers/active.json`.
    public func computeModelPreferences() async throws -> [String: SurfacePreference] {
        try await checkedRoutingSnapshot().preferences
    }
    /// Preferences, active-provider hints, and explicit pins derived from one recovered tuple while the common transaction lock is held by `reconciledPickerState()`. No caller can observe a model from one picker commit paired with the
    /// provider from another.
    public func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        let pickerState = try await reconciledPickerState()
        return selectionRoutingSnapshot(
            surfaces: pickerState.surfaces,
            active: pickerState.active, revision: pickerState.revision
        )
    }
    /// Checked diagnostic view of the picker that never repairs or writes its authority files. A pending two-file selection is intentionally adverse here: execution may resume its exact recovery transaction, but a read-only CLI must not
    /// turn a request to inspect routing into a write.  Hold the writer's transaction lock across both reads without running recovery. Marker absence alone cannot rule out a complete save between the reads. The lock may create a sidecar,
    /// but never writes authority.
    public func checkedRoutingSnapshotReadOnly() async throws -> ProviderRoutingSnapshot {
        let transactionPath = surfaceTransactionPath
        let (surfaces, active, revision) = try await SwiftNativePersistenceCore.withFileLock(transactionPath) {
            guard !FileManager.default.fileExists(atPath: transactionPath.path) else {
                throw ProviderRoutingError.underlying(
                    "provider selection is pending recovery; the read-only preference probe will not reconcile it"
                )
            }
            return try self.checkedPickerStateLocked()
        }
        return selectionRoutingSnapshot(
            surfaces: surfaces, active: active, revision: revision
        )
    }
    /// Every route this build can connect: the ids the provider list always shows, and the ids the sole-connected probe walks. ONE list, because the probe used to carry its own copy and `kimi-code` was missing from it — a Kimi Code-only
    /// install with nothing saved resolved no model at all.
    static let connectableProviderIds = [
        "anthropic", "anthropic_oauth_direct",
        "openai", "openai_oauth_direct", "codex",
        "xai_oauth_direct", "moonshot", "kimi-code", "openrouter",
    ]
    /// The provider ids the sole-connected probe walks. Named so the routing snapshot can pre-read exactly these config files once.
    static var soleConnectedProbeIds: [String] { connectableProviderIds }
    /// The exact route of one connected account, or nil when none or several are ready.
    func soleConnectedProviderID(cache: ProviderConfigCache? = nil) -> String? {
        var connected: [String] = []
        for id in Self.soleConnectedProbeIds where providerReadiness(id: id, cache: cache).ready {
            connected.append(id)
        }
        if connected.count == 1 { return connected.first }
        // One ChatGPT sign-in makes TWO ids ready — `openai_oauth_direct` and `codex` both read `codex_home/auth.json`. That is one account, so it still answers, with the in-app adapter's id (the transport a turn takes unless a person
        // picks the CLI row). Any other pair is genuinely two accounts and stays ambiguous.
        if Set(connected) == ["openai_oauth_direct", "codex"] { return "openai_oauth_direct" }
        return nil
    }
    /// Read `<dataRoot>/providers/active.json`, returning the surface→providerId map. Missing is empty; the throwing preference path rejects corruption. This nonthrowing compatibility view stays conservative on corruption. Surfaces the
    /// value the user's picker writes via `setActiveProvider(surface:providerId:)` so the dispatch layer can honor it as a tiebreaker when a model id is ambiguous.
    public func activeProvidersForSurfaces() async -> [String: String] {
        (try? await activeProvidersForSurfacesChecked()) ?? [:]
    }
    public func readActiveProvidersChecked() async throws -> [String: String] {
        try await activeProvidersForSurfacesChecked()
    }
    public func activeProvidersForSurfacesChecked() async throws -> [String: String] {
        try await checkedRoutingSnapshot().activeProviders
    }
}
