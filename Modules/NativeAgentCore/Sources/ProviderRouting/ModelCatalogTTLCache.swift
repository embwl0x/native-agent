import Foundation
import PersistenceCore

/// Shared 24h-TTL + failed-refresh-backoff machinery for the provider model
/// catalogs (R-M3). Moonshot and OpenRouter both maintain a bounded offline
/// disk cache with the IDENTICAL read/refresh/backoff orchestration — the
/// `models()` state machine, `cacheIsStale`, `writeCache`, and the
/// `staleRefresh*` backoff lock were byte-duplicated ~90 lines apart. Only the
/// parse/fetch/fallback/cache-path specifics differ, and those arrive as the
/// config's closures; each catalog keeps its own parse/fetch/capabilities.
///
/// Two behavior fixes rode in with the extraction:
///  - R-L5 (a): the failed-refresh backoff state is keyed PER cache-file path
///    (which is per-provider AND per-dataRoot) rather than one process-global
///    stamp. A dead network under one data root can no longer suppress the
///    refresh under another (e.g. a test's isolated root vs. the live default).
///  - R-L5 (b): an explicit `refresh: true` that SUCCEEDS now clears any prior
///    failure stamp (`noteStaleRefreshSucceeded`). Previously a stale failure
///    stamp survived an explicit successful refresh and kept suppressing the
///    passive stale-path refresh until the 15-minute backoff elapsed.
/// Where a catalog read's list actually came from (User, 2026-09-06).
public enum ModelCatalogFreshness: String, Sendable, Equatable {
    /// Fetched from the provider on this call, and the envelope said nothing
    /// about a further page — the whole catalogue.
    case live
    /// Fetched from the provider on this call, but the envelope carried a
    /// marker saying there is MORE (User, 2026-09-06). The rows are real and
    /// fresh — they are served, cached and stamped like any other live read —
    /// but a partial list has no standing to prune the rows it omits.
    case liveIncomplete = "live_incomplete"
    /// Served from the on-disk cache without attempting the network.
    case cached
    /// The network was attempted and FAILED; this is the cached copy.
    case staleAfterFailedRefresh = "stale"
    /// Nothing usable was cached and no refresh was attempted.
    case builtIn = "built_in"
    /// The network was attempted and FAILED, and nothing was cached.
    case builtInAfterFailedRefresh = "built_in_stale"

    /// True when this read reached the provider AND carried the whole list —
    /// the only case a caller may treat as authoritative enough to prune rows
    /// the provider no longer has.
    public var isLive: Bool { self == .live }

    /// True when this read reached the provider, complete or not. Rows from a
    /// partial page are still fresh data; they may be added, never pruned on.
    public var reachedProvider: Bool { self == .live || self == .liveIncomplete }

    /// True when a refresh was attempted and did not reach the provider.
    public var refreshFailed: Bool {
        self == .staleAfterFailedRefresh || self == .builtInAfterFailedRefresh
    }
}

/// One catalog read: the list, and where it came from.
public struct ModelCatalogRead: Sendable {
    public let models: [ProviderModelDescriptor]
    public let freshness: ModelCatalogFreshness
}

/// One live fetch: the rows, and whether the fetcher could establish that they
/// are the WHOLE catalogue. User, 2026-09-06: `.live` used to mean nothing more
/// than "the response was nonempty", and a caller was pruning rows against it
/// — a truncated first page reads as a perfectly valid short list, so a
/// partial answer could delete every model it failed to mention.
public struct ModelCatalogFetch: Sendable {
    public let models: [ProviderModelDescriptor]
    /// True when the envelope carried no marker saying there is MORE. User,
    /// 2026-09-06: this used ALSO to compare the row count against the disk
    /// cache, which wedged a legitimately shrunk catalogue as incomplete
    /// forever — the shrunk list was never persisted, so every later fetch
    /// compared against the same tall baseline and could never look whole
    /// again. Completeness is now a property of the response alone.
    public let isComplete: Bool

    public init(models: [ProviderModelDescriptor], isComplete: Bool) {
        self.models = models
        self.isComplete = isComplete
    }
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
    /// Decode the on-disk cache into descriptors (`nil` when absent/empty).
    var readCache: @Sendable (URL) -> [ProviderModelDescriptor]?
    /// Read the cache's `updated_at` stamp (`nil` when missing/unparseable →
    /// treated as stale so it refreshes once).
    var cacheUpdatedAt: @Sendable (URL) -> Date?
    /// Fetch the live list; throws on any failure (network/credentials).
    var fetchLive: @Sendable (URL, URLSession) async throws -> [ProviderModelDescriptor]
    /// The same fetch, carrying the completeness verdict a pruning caller
    /// needs (User, 2026-09-06). `nil` for a catalogue that arrives whole or
    /// not at all — then a successful fetch is complete by construction.
    var fetchLiveComplete: (@Sendable (URL, URLSession) async throws -> ModelCatalogFetch)?
    /// The explicit built-in fallback list when nothing cached is usable.
    var fallback: @Sendable () -> [ProviderModelDescriptor]

    // R-L5 (a): backoff state keyed per cache-file path. One dict serves both
    // catalogs because the cache filenames differ per provider.
    private static let backoffLock = NSLock()
    nonisolated(unsafe) private static var lastFailedByPath: [String: Date] = [:]

    private func backoffKey(_ dataRoot: URL) -> String {
        cachePath(dataRoot).standardizedFileURL.path
    }

    func staleRefreshAllowed(dataRoot: URL, now: Date = Date()) -> Bool {
        let key = backoffKey(dataRoot)
        Self.backoffLock.lock()
        defer { Self.backoffLock.unlock() }
        guard let last = Self.lastFailedByPath[key] else { return true }
        return now.timeIntervalSince(last) >= staleRefreshRetryBackoff
    }

    func noteStaleRefreshFailed(dataRoot: URL, now: Date = Date()) {
        let key = backoffKey(dataRoot)
        Self.backoffLock.lock()
        Self.lastFailedByPath[key] = now
        // Bound the per-path dict: entries otherwise clear only on a SUCCESSFUL
        // refresh of the same path, so many transient roots (tests, secondary
        // runtimes) grow it for process lifetime (gpt-5.5 fix round, LOW).
        // Evicting the OLDEST stamp on overflow just re-allows one stale
        // refresh early — safe direction. Production uses 2 paths.
        if Self.lastFailedByPath.count > 64,
           let oldest = Self.lastFailedByPath.min(by: { $0.value < $1.value }) {
            Self.lastFailedByPath.removeValue(forKey: oldest.key)
        }
        Self.backoffLock.unlock()
    }

    func noteStaleRefreshSucceeded(dataRoot: URL) {
        let key = backoffKey(dataRoot)
        Self.backoffLock.lock()
        Self.lastFailedByPath.removeValue(forKey: key)
        Self.backoffLock.unlock()
    }

    /// True when the cache is missing its `updated_at` stamp or that stamp is
    /// older than `cacheTTL`.
    func cacheIsStale(dataRoot: URL, now: Date = Date()) -> Bool {
        guard let updated = cacheUpdatedAt(dataRoot) else { return true }
        return now.timeIntervalSince(updated) >= cacheTTL
    }

    func models(
        dataRoot: URL,
        session: URLSession,
        refresh: Bool
    ) async -> [ProviderModelDescriptor] {
        await modelsWithFreshness(dataRoot: dataRoot, session: session, refresh: refresh).models
    }

    /// User, 2026-09-06: the same state machine, but saying WHERE the list came
    /// from. `models()` returned the cached or built-in list after a failed
    /// refresh with no way to tell it apart from a live one, so the Providers
    /// UI reported "Model catalog refreshed" for a refresh that never reached
    /// the network — and a caller could not know whether its list was
    /// authoritative enough to prune obsolete rows against.
    func modelsWithFreshness(
        dataRoot: URL,
        session: URLSession,
        refresh: Bool
    ) async -> ModelCatalogRead {
        let cached = readCache(dataRoot)
        if refresh {
            if let live = await attemptLiveRefresh(dataRoot: dataRoot, session: session) {
                // R-L5 (b): an explicit successful refresh clears any stale
                // failure stamp so the passive stale path isn't still backed off.
                noteStaleRefreshSucceeded(dataRoot: dataRoot)
                // User, 2026-09-06: a partial page is still a live read — it is
                // labelled `liveIncomplete` rather than `cached`, which claimed
                // no network had happened. Only `.live` grants the standing to
                // prune.
                return ModelCatalogRead(
                    models: live.models,
                    freshness: live.isComplete ? .live : .liveIncomplete)
            }
            if let cached, !cached.isEmpty {
                return ModelCatalogRead(models: cached, freshness: .staleAfterFailedRefresh)
            }
            return ModelCatalogRead(models: fallback(), freshness: .builtInAfterFailedRefresh)
        }
        if let cached, !cached.isEmpty {
            if !cacheIsStale(dataRoot: dataRoot) {
                return ModelCatalogRead(models: cached, freshness: .cached)
            }
            // TTL expired: try to freshen, but never block the caller — serve the
            // stale copy if the network/credentials are unavailable, and back off
            // failed attempts so a dead network isn't re-probed on every read.
            guard staleRefreshAllowed(dataRoot: dataRoot) else {
                return ModelCatalogRead(models: cached, freshness: .cached)
            }
            if let live = await attemptLiveRefresh(dataRoot: dataRoot, session: session) {
                noteStaleRefreshSucceeded(dataRoot: dataRoot)
                return ModelCatalogRead(
                    models: live.models,
                    freshness: live.isComplete ? .live : .liveIncomplete)
            }
            noteStaleRefreshFailed(dataRoot: dataRoot)
            return ModelCatalogRead(models: cached, freshness: .staleAfterFailedRefresh)
        }
        return ModelCatalogRead(models: fallback(), freshness: .builtIn)
    }

    /// Fetch live models and update the disk cache. Returns the live list on
    /// success, `nil` on any failure — swallowing the error so `models()` never
    /// throws. Writing the cache changes the file's mtime, which is what
    /// invalidates the catalogs' stat()-keyed membership memo.
    private func attemptLiveRefresh(
        dataRoot: URL,
        session: URLSession
    ) async -> ModelCatalogFetch? {
        do {
            let fetched: ModelCatalogFetch
            if let fetchLiveComplete {
                fetched = try await fetchLiveComplete(dataRoot, session)
            } else {
                fetched = ModelCatalogFetch(
                    models: try await fetchLive(dataRoot, session), isComplete: true)
            }
            if !fetched.models.isEmpty {
                // User, 2026-09-06: an incomplete list IS cached and stamped.
                // Withholding it meant a partial answer was re-fetched on every
                // single read — no TTL ever started — while the completeness
                // verdict no longer depends on the cached row count, so there is
                // no baseline to ratchet. What incompleteness costs is the
                // standing to prune, which lives in the freshness label.
                writeCache(fetched.models, dataRoot: dataRoot, isComplete: fetched.isComplete)
                return fetched
            }
        } catch {
            // The catalog must remain usable offline; callers fall back to the
            // (possibly stale) cache or the explicit fallback list.
        }
        return nil
    }

    /// User, 2026-09-06: the completeness verdict is PERSISTED alongside the
    /// rows. It used to live only in the in-memory freshness label, so the very
    /// next read served a partial page as a plain `.cached` list and an
    /// availability check against it declared every omitted model absent. A
    /// cache written from a truncated page can now say so on later reads.
    func writeCache(
        _ models: [ProviderModelDescriptor],
        dataRoot: URL,
        isComplete: Bool = true
    ) {
        let path = cachePath(dataRoot)
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload: JSONValue = .object([
                "schema_version": .int(1),
                "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
                "source": .string(endpoint.absoluteString),
                "complete": .bool(isComplete),
                "models": .array(models.map { .object($0.providerJSON()) }),
            ])
            try payload.serializedData(pretty: true).write(to: path, options: .atomic)
        } catch {
            // A model cache is rebuildable and must never block provider use.
        }
    }
}
