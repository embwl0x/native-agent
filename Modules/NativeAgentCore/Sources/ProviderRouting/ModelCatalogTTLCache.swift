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
        let cached = readCache(dataRoot)
        if refresh {
            if let live = await attemptLiveRefresh(dataRoot: dataRoot, session: session) {
                // R-L5 (b): an explicit successful refresh clears any stale
                // failure stamp so the passive stale path isn't still backed off.
                noteStaleRefreshSucceeded(dataRoot: dataRoot)
                return live
            }
            if let cached, !cached.isEmpty { return cached }
            return fallback()
        }
        if let cached, !cached.isEmpty {
            if !cacheIsStale(dataRoot: dataRoot) { return cached }
            // TTL expired: try to freshen, but never block the caller — serve the
            // stale copy if the network/credentials are unavailable, and back off
            // failed attempts so a dead network isn't re-probed on every read.
            guard staleRefreshAllowed(dataRoot: dataRoot) else { return cached }
            if let live = await attemptLiveRefresh(dataRoot: dataRoot, session: session) {
                noteStaleRefreshSucceeded(dataRoot: dataRoot)
                return live
            }
            noteStaleRefreshFailed(dataRoot: dataRoot)
            return cached
        }
        return fallback()
    }

    /// Fetch live models and update the disk cache. Returns the live list on
    /// success, `nil` on any failure — swallowing the error so `models()` never
    /// throws. Writing the cache changes the file's mtime, which is what
    /// invalidates the catalogs' stat()-keyed membership memo.
    private func attemptLiveRefresh(
        dataRoot: URL,
        session: URLSession
    ) async -> [ProviderModelDescriptor]? {
        do {
            let live = try await fetchLive(dataRoot, session)
            if !live.isEmpty {
                writeCache(live, dataRoot: dataRoot)
                return live
            }
        } catch {
            // The catalog must remain usable offline; callers fall back to the
            // (possibly stale) cache or the explicit fallback list.
        }
        return nil
    }

    func writeCache(_ models: [ProviderModelDescriptor], dataRoot: URL) {
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
                "models": .array(models.map { .object($0.providerJSON()) }),
            ])
            try payload.serializedData(pretty: true).write(to: path, options: .atomic)
        } catch {
            // A model cache is rebuildable and must never block provider use.
        }
    }
}
