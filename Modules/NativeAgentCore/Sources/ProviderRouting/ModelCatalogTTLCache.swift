import Foundation
import Synchronization
import PersistenceCore
import CryptoKit
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ModelCatalogTTLCache.swift` | shared live fetch and TTL/backoff state machine; a path-bound LatestRead orders publication and coalesces equal-credential fetches; unchanged credentials and checked persistence own cache/backoff commits; `ModelCatalogDecodeCache` memoizes decoded rows and authority stamps by canonical file path and mtime |

/// Catalog freshness records where the rows came from and whether the response is complete.
public enum ModelCatalogFreshness: String, Sendable, Equatable {
    /// Fetched from the provider on this call, and the envelope said nothing
    /// about a further page — the whole catalogue.
    case live
    /// A live partial response is cached and stamped but cannot prune omitted rows.
    case liveIncomplete = "live_incomplete"
    /// Served from the on-disk cache without attempting the network.
    case cached
    /// The network was attempted and FAILED; this is the last list the
    /// provider gave, served labelled as such with the time it was fetched.
    case staleAfterFailedRefresh = "stale"
    /// No cached provider rows are available; the picker stays empty and names the cause.
    case unavailable

    /// True when this read reached the provider AND carried the whole list —
    /// the only case a caller may treat as authoritative enough to prune rows
    /// the provider no longer has.
    public var isLive: Bool { self == .live }
}

/// Process-local decoded cache keyed by canonical path and file mtime.
///
/// Every read still stats the exact file, so removal and atomic replacement are
/// visible on the next read. Missing, unreadable, empty, or undecodable bytes
/// cache only the nil result for that observed mtime; a later mtime always
/// retries the decode. Mirrors `REMPinsDecodedCache` in DreamREMCycle — same
/// invariant, same retry-on-concurrent-write guard.
/// A saved model list that is there but cannot be read: the receipt that
/// replaces its rows, never the shipped rows. Nil when absent or read.
func modelCatalogFault(at url: URL, read: Bool, owner: String) -> String? {
    guard !read, FileManager.default.fileExists(atPath: url.resolvingSymlinksInPath().path) else { return nil }
    return "\(url.path) could not be read as \(owner)'s model list, so its models and windows are unknown; move that file aside on the Mac and the next refresh fetches it again."
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
        // `attributesOfItem` does NOT follow symlinks, but `Data(contentsOf:)`
        // does. Resolve first so a symlinked cache path stats as the regular
        // file it points at instead of silently reading as "no catalog".
        let url = url.resolvingSymlinksInPath()
        let key = url.path
        lock.lock()
        defer { lock.unlock() }

        // Retry once if a writer replaces the file between the first stat and
        // the read. Never associate bytes with a stale mtime key.
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

/// One catalog read: the list, and where it came from.
public struct ModelCatalogRead: Sendable {
    public let models: [ProviderModelInfo]
    public let freshness: ModelCatalogFreshness
    /// Why the provider's list could not be fetched (`stale`, `unavailable`).
    public var failure: String? = nil
    /// When the served list was fetched from the provider (`cached`, `stale`).
    public var fetchedAt: Date? = nil

    /// The line the Providers page shows beside this provider's models; nil
    /// when the list is the provider's current answer.
    public var note: String? {
        switch freshness {
        case .unavailable:
            return "Couldn't load models: \(failure ?? "no list has been fetched yet"). Refresh to try again."
        case .staleAfterFailedRefresh:
            let when = fetchedAt.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return "Couldn't load models: \(failure ?? "the refresh failed"). Showing the last-known list\(when)."
        case .live, .liveIncomplete, .cached:
            return nil
        }
    }
}

/// A live fetch carries rows and an explicit completeness verdict.
public struct ModelCatalogFetch: Sendable {
    public let models: [ProviderModelInfo]
    /// Completeness depends only on the response envelope, never the cached row count.
    public let isComplete: Bool

    public init(models: [ProviderModelInfo], isComplete: Bool) {
        self.models = models
        self.isComplete = isComplete
    }
}

/// Rows and authority stamps from the same cached bytes. A missing
/// completeness stamp cannot establish that an absent model is unavailable.
struct DecodedModelCatalog: Sendable {
    let models: [ProviderModelInfo]
    let isComplete: Bool?
    let fetchedAt: Date?
}

struct ModelCatalogTTLCache: Sendable {
    /// A cached list older than this is stale on the next read: a live refresh
    /// is attempted, but the stale copy is still served if that refresh fails.
    var cacheTTL: TimeInterval = 24 * 60 * 60
    /// After a FAILED stale-path refresh, don't re-probe the network on every
    /// subsequent read for this long. Explicit `refresh: true` always bypasses.
    var staleRefreshRetryBackoff: TimeInterval = 15 * 60

    /// The cache file for a data root (its `.path` is the backoff key).
    var cachePath: @Sendable (URL) -> URL
    /// Source URL stamped into the written cache payload.
    var endpoint: URL
    /// Decode rows and authority stamps together (`nil` when absent/empty).
    var readCache: @Sendable (URL) -> DecodedModelCatalog?
    var providerConfigFile: String
    /// Fetch the live list; throws on any failure (network/credentials).
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
                // Even a read whose publication was superseded must not return
                // another credential's list as this account's live answer.
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

    private func lastFailureReason(dataRoot: URL) -> String? {
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

    /// True when the cache is missing its `updated_at` stamp or that stamp is
    /// older than `cacheTTL`.
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

    /// Reads return provider rows with freshness and failure reasons, or unavailable when no rows exist.
    func modelsWithFreshness(
        dataRoot: URL,
        session: URLSession,
        refresh: Bool
    ) async -> ModelCatalogRead {
        let decoded = readCache(dataRoot)
        let cached = decoded.flatMap { $0.models.isEmpty ? nil : $0.models }
        let fetchedAt = decoded?.fetchedAt
        if !refresh {
            // A passive read without cached rows never reaches the network.
            guard let cached else {
                return ModelCatalogRead(
                    models: [], freshness: .unavailable,
                    failure: lastFailureReason(dataRoot: dataRoot))
            }
            // The last attempt failed (a success clears the stamp): the list is
            // last-known and says so until a fetch succeeds, fresh TTL or not.
            if let reason = lastFailureReason(dataRoot: dataRoot) {
                guard cacheIsStale(fetchedAt: fetchedAt), staleRefreshAllowed(dataRoot: dataRoot) else {
                    return ModelCatalogRead(
                        models: cached, freshness: .staleAfterFailedRefresh,
                        failure: reason, fetchedAt: fetchedAt)
                }
            } else if !cacheIsStale(fetchedAt: fetchedAt) {
                return ModelCatalogRead(models: cached, freshness: .cached, fetchedAt: fetchedAt)
            }
            // Return the dated rows immediately. The path owner retains and
            // coalesces refresh; its atomic file write invalidates consumers'
            // existing providers-directory observations.
            await Self.refreshOwner(key: backoffKey(dataRoot)).schedule(self, dataRoot: dataRoot, session: session)
            let reason = lastFailureReason(dataRoot: dataRoot)
            return ModelCatalogRead(models: cached,
                freshness: reason == nil ? .cached : .staleAfterFailedRefresh,
                failure: reason, fetchedAt: fetchedAt)
        }
        switch await attemptLiveRefresh(dataRoot: dataRoot, session: session) {
        case .success(let live):
            // Only complete live responses grant authority to prune.
            return ModelCatalogRead(
                models: live.models,
                freshness: live.isComplete ? .live : .liveIncomplete)
        case .failure(let failure):
            if failure.superseded {
                // Never publish the old request's rows or its captured fallback.
                let current = readCache(dataRoot)
                return ModelCatalogRead(
                    models: current?.models ?? [], freshness: current == nil ? .unavailable : .cached,
                    failure: failure.reason, fetchedAt: current?.fetchedAt)
            }
            guard let cached else {
                return ModelCatalogRead(models: [], freshness: .unavailable, failure: failure.reason)
            }
            return ModelCatalogRead(
                models: cached, freshness: .staleAfterFailedRefresh,
                failure: failure.reason, fetchedAt: fetchedAt)
        }
    }

    /// Fetch live models and update the disk cache. Returns the live list on
    /// success, or the reason it could not be fetched — `models()` never
    /// throws. Writing the cache changes the file's mtime, which is what
    /// invalidates the catalogs' stat()-keyed membership memo.
    private func attemptLiveRefresh(
        dataRoot: URL,
        session: URLSession
    ) async -> Result<ModelCatalogFetch, FetchFailure> {
        await Self.refreshOwner(key: backoffKey(dataRoot)).refresh(self, dataRoot: dataRoot, session: session)
    }

    /// A probe already fetched these bytes with this credential. Publication
    /// shares refresh ordering and checks that the saved key is still the same.
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
            // LatestRead admitted this publication. The credential lock binds
            // its cache write and backoff verdict to the still-selected key.
            return try CredentialFileLock.withLock(configPath(dataRoot)) {
                try Self.lastFailedByPath.withLock { failures in
                    let current = try LLMCredentialResolver.checkedAPIKey(providerConfigFile: providerConfigFile, dataRoot: dataRoot)
                    guard current == credential else { return .failure(.supersededRefresh) }
                    switch result {
                    case .success(let fetched):
                        do { try writeCache(fetched.models, dataRoot: dataRoot, isComplete: fetched.isComplete) }
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
        isComplete: Bool = true
    ) throws {
        let path = cachePath(dataRoot)
        let payload: JSONValue = .object([
            "schema_version": .int(1),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
            "source": .string(endpoint.absoluteString),
            "complete": .bool(isComplete),
            "models": .array(models.map { .object($0.providerJSON()) }),
        ])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(payload.serializedData(pretty: true), to: path)
    }
}
