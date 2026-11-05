import Foundation
import Synchronization
import PersistenceCore
import CryptoKit
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ModelCatalogTTLCache.swift` | `ModelCatalogDecodeCache`: credential-bound cache; ordered publication |

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

/// Stat the exact file on every read so replacement/removal invalidates decoded bytes. Cache only against the observed mtime and reject a concurrent-write
/// mismatch.
func modelCatalogFault(at url: URL, read: Bool, owner: String) -> String? {
    guard !read, !modelCatalogIsAbsent(at: url) else { return nil }
    return """
        \(url.path) could not be read as \(owner)'s model list, so its models and windows are unknown; move that file aside on the Mac and the next \
        refresh fetches it again.
        """
}

/// Only an actual not-found result permits catalog bootstrap. A denied stat is an unreadable catalog, including when its parent cannot be searched.
func modelCatalogIsAbsent(at url: URL) -> Bool {
    do {
        _ = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return false
    } catch CocoaError.fileReadNoSuchFile { return true }
    catch { return false }
}

final class ModelCatalogDecodeCache: @unchecked Sendable {
    private struct Entry {
        let modifiedAt: Date
        let catalog: DecodedModelCatalog?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func read(
        url: URL,
        decode: (Data) -> DecodedModelCatalog?
    ) -> DecodedModelCatalog? {
        // `attributesOfItem` does NOT follow symlinks, but `Data(contentsOf:)` does. Resolve first so a symlinked cache path stats as the regular file it
        // points at instead of silently reading as "no catalog".
        let url = url.resolvingSymlinksInPath()
        let key = url.path
        lock.lock()
        defer { lock.unlock() }

        // Retry once if a writer replaces the file between the first stat and the read. Never associate bytes with a stale mtime key.
        for _ in 0..<2 {
            guard let modifiedAt = modificationDate(url) else {
                entries.removeValue(forKey: key)
                return nil
            }
            if let entry = entries[key], entry.modifiedAt == modifiedAt {
                return entry.catalog
            }

            let decoded = (try? Data(contentsOf: url)).flatMap(decode)
            guard modificationDate(url) == modifiedAt else { continue }

            if entries[key] == nil, entries.count >= 64 {
                entries.remove(at: entries.startIndex)
            }
            entries[key] = Entry(modifiedAt: modifiedAt, catalog: decoded)
            return decoded
        }

        // A continuously changing file is not a safe source to memoize.
        entries.removeValue(forKey: key)
        return nil
    }

    private func modificationDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else { return nil }
        return attributes?[.modificationDate] as? Date
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

struct ModelCatalogTTLCache: Sendable {
    /// A cached list older than this is unavailable until its live refresh succeeds; stale bytes remain on disk as historical evidence.
    var cacheTTL: TimeInterval = 24 * 60 * 60
    /// Failed stale refreshes cool down to avoid a network probe on every read; explicit refresh bypasses cooldown.
    var staleRefreshRetryBackoff: TimeInterval = 15 * 60

    /// The cache path also scopes failure backoff.
    var cachePath: @Sendable (URL) -> URL
    var endpoint: URL
    /// Decode rows and authority stamps from the same bytes.
    var readCache: @Sendable (URL) -> DecodedModelCatalog?
    var providerConfigFile: String
    /// Fetch failures must stay visible to the cache owner.
    var fetchLive: @Sendable (String?, URLSession) async throws -> ModelCatalogFetch

    // Backoff is keyed by cache-file path and retains the failure reason for last-known reads.
    private static let lastFailedByPath = Mutex<[String: (at: Date, reason: String)]>([:])
    @MainActor private static var refreshOwners: [String: RefreshOwner] = [:]

    @MainActor private final class RefreshOwner {
        let reads = LatestRead()
        var flights: [String: Task<Result<ModelCatalogFetch, FetchFailure>, Never>] = [:]
        var background: Task<Void, Never>?

        func schedule(_ cache: ModelCatalogTTLCache, dataRoot: URL, session: URLSession) {
            guard background == nil else { return }
            background = Task {
                defer { background = nil }
                _ = await refresh(cache, dataRoot: dataRoot, session: session)
            }
        }

        func publish(_ fetched: ModelCatalogFetch, cache: ModelCatalogTTLCache, credential: String, dataRoot: URL) -> Result<ModelCatalogFetch, FetchFailure> {
            let result = cache.commit(.success(fetched), credential: credential, dataRoot: dataRoot)
            // Only a committed write advances the publication boundary.
            if case .success = result { reads.write {} }
            return result
        }

        func refresh(_ cache: ModelCatalogTTLCache, dataRoot: URL, session: URLSession) async -> Result<ModelCatalogFetch, FetchFailure> {
            let credential: String?
            do {
                credential = try CredentialFileLock.withLock(cache.configPath(dataRoot)) {
                    try LLMCredentialResolver.checkedAPIKey(providerConfigFile: cache.providerConfigFile, dataRoot: dataRoot)
                }
            } catch { return .failure(FetchFailure(error.localizedDescription)) }
            let fingerprint = SHA256.hash(data: Data((credential ?? "").utf8)).description
            if let flight = flights[fingerprint] { return await flight.value }
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
            return await flight.value
        }
    }

    @MainActor private static func refreshOwner(key: String) -> RefreshOwner {
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
            guard let decoded = readCache(dataRoot) else { return nil }
            guard decoded.credentialBinding == Self.credentialBinding(credential) else {
                throw ProviderRoutingError.configurationFailed(
                    "The saved model catalog has no evidence for the current credential. Refresh its models in Providers.")
            }
            return decoded
        }
    }

    /// Synchronous routing and availability admission share the passive read's binding, failed-refresh and freshness checks. Nil is confirmed absence.
    func currentCache(dataRoot: URL, now: Date = Date()) throws -> DecodedModelCatalog? {
        let decoded = try checkedCache(dataRoot: dataRoot)
        if let reason = lastFailureReason(dataRoot: dataRoot) {
            throw ProviderRoutingError.configurationFailed(reason)
        }
        guard let decoded else {
            if let fault = modelCatalogFault(at: cachePath(dataRoot), read: false, owner: endpoint.host ?? "this provider") {
                throw ProviderRoutingError.configurationFailed(fault)
            }
            return nil
        }
        guard !cacheIsStale(fetchedAt: decoded.fetchedAt, now: now) else {
            throw ProviderRoutingError.configurationFailed("The model catalog is out of date. Refresh its models in Providers.")
        }
        return decoded
    }

    private func backoffKey(_ dataRoot: URL) -> String {
        cachePath(dataRoot).standardizedFileURL.path
    }

    func staleRefreshAllowed(dataRoot: URL, now: Date = Date()) -> Bool {
        let key = backoffKey(dataRoot)
        return Self.lastFailedByPath.withLock {
            guard let last = $0[key] else { return true }
            return now.timeIntervalSince(last.at) >= staleRefreshRetryBackoff
        }
    }

    func lastFailureReason(dataRoot: URL) -> String? {
        let key = backoffKey(dataRoot)
        return Self.lastFailedByPath.withLock { $0[key]?.reason }
    }

    private static func noteFailure(_ failures: inout [String: (at: Date, reason: String)], key: String, reason: String, now: Date = Date()) {
        failures[key] = (now, reason)
        // Evict the oldest failure stamp when the per-path backoff dictionary exceeds its cap.
        if failures.count > 64,
           let oldest = failures.min(by: { $0.value.at < $1.value.at }) {
            failures.removeValue(forKey: oldest.key)
        }
    }

    func cacheIsStale(fetchedAt: Date?, now: Date = Date()) -> Bool {
        guard let updated = fetchedAt else { return true }
        return now.timeIntervalSince(updated) >= cacheTTL
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
        let cached = decoded.flatMap { $0.models.isEmpty ? nil : $0.models }
        let fetchedAt = decoded?.fetchedAt
        if !refresh {
            // A passive read without cached rows never reaches the network.
            guard let cached else {
                return ModelCatalogRead(
                    models: [], freshness: .unavailable,
                    failure: cacheFailure ?? lastFailureReason(dataRoot: dataRoot)
                        ?? modelCatalogFault(at: cachePath(dataRoot), read: false, owner: endpoint.host ?? "this provider"))
            }
            // The last attempt failed (a success clears the stamp): the list is last-known and says so until a fetch succeeds, fresh TTL or not.
            if let reason = lastFailureReason(dataRoot: dataRoot) {
                guard cacheIsStale(fetchedAt: fetchedAt), staleRefreshAllowed(dataRoot: dataRoot) else {
                    return ModelCatalogRead(
                        models: [], freshness: .unavailable,
                        failure: reason, fetchedAt: fetchedAt)
                }
            } else if !cacheIsStale(fetchedAt: fetchedAt) {
                return ModelCatalogRead(models: cached, freshness: .cached, fetchedAt: fetchedAt)
            }
            // A stale list remains historical bytes, never current selections.
            await Self.refreshOwner(key: backoffKey(dataRoot)).schedule(self, dataRoot: dataRoot, session: session)
            let reason = lastFailureReason(dataRoot: dataRoot)
            return ModelCatalogRead(models: [], freshness: .unavailable,
                failure: reason ?? "The model catalog is out of date; its owner is refreshing it. Wait for refresh before choosing a model.",
                    fetchedAt: fetchedAt)
        }
        switch await attemptLiveRefresh(dataRoot: dataRoot, session: session) {
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

    /// Successful writes change mtime and invalidate membership decodes; fetch failures return their reason without exposing stale rows as current.
    private func attemptLiveRefresh(
        dataRoot: URL,
        session: URLSession
    ) async -> Result<ModelCatalogFetch, FetchFailure> {
        await Self.refreshOwner(key: backoffKey(dataRoot)).refresh(self, dataRoot: dataRoot, session: session)
    }

    /// A probe already fetched these bytes with this credential. Publication shares refresh ordering and checks that the saved key is still the same.
    func publish(_ fetched: ModelCatalogFetch, credential: String, dataRoot: URL) async -> Result<ModelCatalogFetch, FetchFailure> {
        await Self.refreshOwner(key: backoffKey(dataRoot)).publish(fetched, cache: self, credential: credential, dataRoot: dataRoot)
    }

    private func fetch(credential: String?, session: URLSession) async -> Result<ModelCatalogFetch, FetchFailure> {
        let result: Result<ModelCatalogFetch, FetchFailure>
        do {
            let fetched = try await fetchLive(credential, session)
            // Partial responses start the cache TTL while retaining their incomplete verdict.
            result = fetched.models.isEmpty
                ? .failure(FetchFailure("the provider returned no models")) : .success(fetched)
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
        let key = backoffKey(dataRoot)
        do {
            // LatestRead admitted this publication. The credential lock binds its cache write and backoff verdict to the still-selected key.
            return try CredentialFileLock.withLock(configPath(dataRoot)) {
                try Self.lastFailedByPath.withLock { failures in
                    let current = try LLMCredentialResolver.checkedAPIKey(providerConfigFile: providerConfigFile, dataRoot: dataRoot)
                    guard current == credential else { return .failure(.supersededRefresh) }
                    switch result {
                    case .success(let fetched):
                        do { try writeCache(fetched.models, dataRoot: dataRoot, credential: credential, isComplete: fetched.isComplete) }
                        catch {
                            let failure = FetchFailure("Could not save \(cachePath(dataRoot).path): \(error.localizedDescription)")
                            Self.noteFailure(&failures, key: key, reason: failure.reason)
                            return .failure(failure)
                        }
                        failures.removeValue(forKey: key)
                    case .failure(let failure):
                        Self.noteFailure(&failures, key: key, reason: failure.reason)
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
