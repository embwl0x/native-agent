import Foundation
import Synchronization
import PersistenceCore
import CryptoKit
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ModelCatalogCache.swift` | Credential-bound catalog reads and explicitly refreshed, ordered publication |

/// Catalog freshness records where the rows came from and whether the response is complete.
public enum ModelCatalogFreshness: String, Sendable, Equatable {
    /// Only a complete live envelope establishes the whole catalog.
    case live
    /// A live partial response is cached and stamped but cannot prune omitted rows.
    case liveIncomplete = "live_incomplete"
    /// Cached rows carry no claim that the network was reached.
    case cached
    /// Aggregate readers retain refresh-failure provenance; stale rows are never selectable here.
    case staleAfterFailedRefresh = "stale"
    /// No cached provider rows are available; the picker stays empty and names the cause.
    case unavailable

    /// Only a complete live response can authorize pruning omitted rows.
    public var isLive: Bool { self == .live }
}

/// Missing files permit bootstrap; all other unavailable account-catalog reads retain a fault.
func modelCatalogFault(at url: URL, read: Bool, owner: String) -> String? {
    guard !read else { return nil }
    do {
        _ = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
    } catch CocoaError.fileReadNoSuchFile { return nil }
    catch { return "Could not inspect \(owner)'s model catalog at \(url.path): \(error.localizedDescription). Refresh its models in Providers." }
    return "The saved model catalog at \(url.path) could not be decoded for \(owner). Refresh its models in Providers."
}

final class ModelCatalogDecodeCache: Sendable {
    private struct Entry: Sendable {
        let modifiedAt: Date
        let catalog: DecodedModelCatalog
    }

    private let entries = Mutex<[String: Entry]>([:])

    func read(
        url: URL,
        decode: (Data) throws -> DecodedModelCatalog
    ) throws -> DecodedModelCatalog? {
        // Stat and read the same target when the catalog path is a symlink.
        let url = url.resolvingSymlinksInPath()
        let key = url.path
        let modifiedAt: Date
        do { modifiedAt = try modificationDate(url) }
        catch CocoaError.fileReadNoSuchFile {
            entries.withLock { $0.removeValue(forKey: key) }
            return nil
        }
        if let cached = entries.withLock({ $0[key] }), cached.modifiedAt == modifiedAt { return cached.catalog }
        let decoded = try decode(Data(contentsOf: url))
        guard try modificationDate(url) == modifiedAt else {
            throw ProviderRoutingError.configurationFailed("The model catalog changed while it was being read. Read it again in Providers.")
        }
        entries.withLock { entries in
            if entries[key] == nil, entries.count >= 64 { entries.removeAll(keepingCapacity: true) }
            entries[key] = Entry(modifiedAt: modifiedAt, catalog: decoded)
        }
        return decoded
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            throw ProviderRoutingError.configurationFailed("The model catalog is not a readable regular file: \(url.path).")
        }
        return modifiedAt
    }
}

/// Rows travel with their provenance.
public struct ModelCatalogRead: Sendable {
    public let models: [ProviderModelInfo]
    public let freshness: ModelCatalogFreshness
    public var failure: String? = nil
    public var fetchedAt: Date? = nil

    /// The picker must name why rows are not the provider's current answer.
    public var note: String? {
        switch freshness {
        case .unavailable:
            return "Couldn't load models: \(failure ?? "no list has been fetched yet"). Refresh to try again."
        case .staleAfterFailedRefresh:
            let when = fetchedAt.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return "Couldn't load models: \(failure ?? "the refresh failed"). The saved list\(when) is historical; refresh before choosing a model."
        case .live, .liveIncomplete, .cached:
            return nil
        }
    }
}

/// Live rows must carry an explicit completeness verdict.
public struct ModelCatalogFetch: Sendable {
    public let models: [ProviderModelInfo]
    /// Completeness depends only on the response envelope, never the cached row count.
    public let isComplete: Bool

    public init(models: [ProviderModelInfo], isComplete: Bool) {
        self.models = models
        self.isComplete = isComplete
    }
}

/// Rows and authority stamps from the same cached bytes. A missing completeness stamp cannot establish that an absent model is unavailable.
struct DecodedModelCatalog: Sendable {
    let models: [ProviderModelInfo]
    let isComplete: Bool?
    let fetchedAt: Date?
    let credentialBinding: String?
}

/// Credential locks, decoding and durable catalog commits never occupy the UI actor.
@globalActor private actor ModelCatalogRefreshActor {
    static let shared = ModelCatalogRefreshActor()
}

struct ModelCatalogCache: Sendable {
    /// The cache path scopes refresh ownership and its latest failure.
    var cachePath: @Sendable (URL) -> URL
    var endpoint: URL?
    /// Decode rows and authority stamps from the same bytes.
    var readCache: @Sendable (URL) throws -> DecodedModelCatalog?
    var providerConfigFile: String
    /// Fetch failures must stay visible to the cache owner.
    var fetchLive: @Sendable (String?, URLSession) async throws -> ModelCatalogFetch

    private static let lastFailedByPath = Mutex<[String: String]>([:])
    @ModelCatalogRefreshActor private static var refreshOwners: [String: RefreshOwner] = [:]

    @ModelCatalogRefreshActor private final class RefreshOwner {
        let reads = LatestRead()
        var flights: [String: Task<Result<ModelCatalogFetch, FetchFailure>, Never>] = [:]
        func publish(_ fetched: ModelCatalogFetch, cache: ModelCatalogCache,
                     credential: String, dataRoot: URL) -> Result<ModelCatalogFetch, FetchFailure> {
            let result = cache.commit(.success(fetched), credential: credential, dataRoot: dataRoot)
            // Only a committed write advances the publication boundary.
            if case .success = result { reads.write {} }
            return result
        }

        func refresh(_ cache: ModelCatalogCache, dataRoot: URL, session: URLSession) async -> Result<ModelCatalogFetch, FetchFailure> {
            let credential: String?
            do {
                credential = try CredentialFileLock.withLock(cache.configPath(dataRoot)) {
                    try LLMCredentialResolver.checkedAPIKey(providerConfigFile: cache.providerConfigFile, dataRoot: dataRoot)
                }
            } catch { return .failure(FetchFailure(error.localizedDescription)) }
            let fingerprint = SHA256.hash(data: Data((credential ?? "").utf8)).description
            if let flight = flights[fingerprint] {
                return await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
            }
            let flight = Task<Result<ModelCatalogFetch, FetchFailure>, Never> {
                defer { flights.removeValue(forKey: fingerprint) }
                var committed: Result<ModelCatalogFetch, FetchFailure>?
                let fetched = await reads.read({
                    await cache.fetch(credential: credential, session: session)
                }, publish: { result in
                    committed = cache.commit(result, credential: credential, dataRoot: dataRoot)
                })
                // Even a read whose publication was superseded must not return another credential's list as this account's live answer.
                do {
                    let current = try CredentialFileLock.withLock(cache.configPath(dataRoot)) {
                        try LLMCredentialResolver.checkedAPIKey(providerConfigFile: cache.providerConfigFile, dataRoot: dataRoot)
                    }
                    guard current == credential else { return .failure(FetchFailure.supersededRefresh) }
                } catch { return .failure(FetchFailure(ProviderFailure.diagnosticDescription(error))) }
                // Superseded readers still return their own fetched result.
                return committed ?? fetched
            }
            flights[fingerprint] = flight
            return await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
        }
    }

    @ModelCatalogRefreshActor private static func refreshOwner(key: String) -> RefreshOwner {
        if let owner = refreshOwners[key] { return owner }
        if refreshOwners.count >= 64, let idle = refreshOwners.first(where: { $0.value.flights.isEmpty }) {
            refreshOwners.removeValue(forKey: idle.key)
        }
        let owner = RefreshOwner()
        refreshOwners[key] = owner
        return owner
    }

    private func configPath(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("providers/\(providerConfigFile)")
    }

    private static func credentialBinding(_ credential: String?) -> String {
        credential.map { "api_key:" + LLMProviderStatusFeed.fingerprint($0) } ?? "unauthenticated"
    }

    /// Rows never outlive their credential authority, even across a restart. Read the binding under the same credential lock as fetch publication.
    private func checkedCache(dataRoot: URL) throws -> DecodedModelCatalog? {
        try CredentialFileLock.withLock(configPath(dataRoot)) {
            let credential = try LLMCredentialResolver.checkedAPIKey(providerConfigFile: providerConfigFile, dataRoot: dataRoot)
            guard let decoded = try readCache(dataRoot) else { return nil }
            guard decoded.credentialBinding == Self.credentialBinding(credential) else {
                throw ProviderRoutingError.configurationFailed(
                    "The saved model catalog has no evidence for the current credential. Refresh its models in Providers.")
            }
            return decoded
        }
    }

    /// Synchronous routing and passive reads share credential binding and refresh-failure provenance. Nil is confirmed absence.
    func currentCache(dataRoot: URL) throws -> DecodedModelCatalog? {
        let decoded = try checkedCache(dataRoot: dataRoot)
        if let reason = lastFailureReason(dataRoot: dataRoot) {
            throw ProviderRoutingError.configurationFailed(reason)
        }
        return decoded
    }

    private func ownerKey(_ dataRoot: URL) -> String {
        cachePath(dataRoot).standardizedFileURL.path
    }

    func lastFailureReason(dataRoot: URL) -> String? {
        let key = ownerKey(dataRoot)
        return Self.lastFailedByPath.withLock { $0[key] }
    }

    func models(
        dataRoot: URL,
        session: URLSession,
        refresh: Bool
    ) async -> [ProviderModelInfo] {
        await modelsWithFreshness(dataRoot: dataRoot, session: session, refresh: refresh).models
    }

    /// Unavailable rows retain the failure reason rather than becoming an empty successful catalog.
    func modelsWithFreshness(
        dataRoot: URL,
        session: URLSession,
        refresh: Bool
    ) async -> ModelCatalogRead {
        let decoded: DecodedModelCatalog?
        let cacheFailure: String?
        do {
            decoded = try checkedCache(dataRoot: dataRoot)
            cacheFailure = nil
        } catch {
            decoded = nil
            cacheFailure = error.localizedDescription
        }
        let fetchedAt = decoded?.fetchedAt
        if !refresh {
            if let reason = cacheFailure ?? lastFailureReason(dataRoot: dataRoot) {
                return ModelCatalogRead(models: [], freshness: .unavailable, failure: reason, fetchedAt: fetchedAt)
            }
            guard let decoded else { return ModelCatalogRead(models: [], freshness: .unavailable) }
            return ModelCatalogRead(models: decoded.models, freshness: .cached, fetchedAt: fetchedAt)
        }
        switch await Self.refreshOwner(key: ownerKey(dataRoot)).refresh(self, dataRoot: dataRoot, session: session) {
        case .success(let live):
            // Only complete live responses grant authority to prune.
            return ModelCatalogRead(
                models: live.models,
                freshness: live.isComplete ? .live : .liveIncomplete)
        case .failure(let failure):
            return ModelCatalogRead(
                models: [], freshness: .unavailable,
                failure: failure.reason, fetchedAt: fetchedAt)
        }
    }

    /// A probe already fetched these bytes with this credential. Publication shares refresh ordering and checks that the saved key is still the same.
    func publish(_ fetched: ModelCatalogFetch, credential: String, dataRoot: URL) async -> Result<ModelCatalogFetch, FetchFailure> {
        await Self.refreshOwner(key: ownerKey(dataRoot)).publish(fetched, cache: self, credential: credential, dataRoot: dataRoot)
    }

    private func fetch(credential: String?, session: URLSession) async -> Result<ModelCatalogFetch, FetchFailure> {
        let result: Result<ModelCatalogFetch, FetchFailure>
        do {
            let fetched = try await fetchLive(credential, session)
            result = .success(fetched)
        } catch LLMError.notConfigured {
            result = .failure(FetchFailure("no API key is saved for this provider"))
        } catch ProviderRoutingError.invalidResponse(let status) {
            result = .failure(FetchFailure("the provider answered HTTP \(status)"))
        } catch {
            result = .failure(FetchFailure(error.localizedDescription))
        }
        return result
    }

    private func commit(_ result: Result<ModelCatalogFetch, FetchFailure>, credential: String?, dataRoot: URL) -> Result<ModelCatalogFetch, FetchFailure> {
        let key = ownerKey(dataRoot)
        do {
            // LatestRead orders publication; the credential lock binds it to the selected key.
            return try CredentialFileLock.withLock(configPath(dataRoot)) {
                try Self.lastFailedByPath.withLock { failures in
                    let current = try LLMCredentialResolver.checkedAPIKey(providerConfigFile: providerConfigFile, dataRoot: dataRoot)
                    guard current == credential else { return .failure(.supersededRefresh) }
                    switch result {
                    case .success(let fetched):
                        do { try writeCache(fetched.models, dataRoot: dataRoot, credential: credential, isComplete: fetched.isComplete) }
                        catch {
                            let failure = FetchFailure("Could not save \(cachePath(dataRoot).path): \(error.localizedDescription)")
                            failures[key] = failure.reason
                            return .failure(failure)
                        }
                        failures.removeValue(forKey: key)
                    case .failure(let failure):
                        failures[key] = failure.reason
                    }
                    return result
                }
            }
        } catch {
            return .failure(FetchFailure(error.localizedDescription))
        }
    }

    struct FetchFailure: Error {
        let reason: String
        var superseded = false
        init(_ reason: String) { self.reason = reason }
        static var supersededRefresh: FetchFailure {
            var failure = FetchFailure("The model refresh was superseded by a newer request or changed credentials.")
            failure.superseded = true
            return failure
        }
    }

    /// Persist completeness alongside rows so later reads cannot mistake omissions for absence.
    func writeCache(
        _ models: [ProviderModelInfo],
        dataRoot: URL,
        credential: String?,
        isComplete: Bool = true
    ) throws {
        let path = cachePath(dataRoot)
        guard let endpoint else { throw URLError(.badURL) }
        let payload: JSONValue = .object([
            "schema_version": .int(1),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
            "source": .string(endpoint.absoluteString),
            "credential_binding": .string(Self.credentialBinding(credential)),
            "complete": .bool(isComplete),
            "models": .array(models.map { .object($0.providerJSON()) }),
        ])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(payload.serializedData(pretty: true), to: path)
    }
}
