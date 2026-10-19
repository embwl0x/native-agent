import Foundation
import PersistenceCore

/// Shared 24h-TTL + failed-refresh-backoff machinery for the provider model
/// catalogs (R-M3). Moonshot and OpenRouter both maintain a bounded offline
/// disk cache with the IDENTICAL read/refresh/backoff orchestration — the
/// `models()` state machine, `cacheIsStale`, `writeCache`, and the
/// `staleRefresh*` backoff lock were byte-duplicated ~90 lines apart. Only the
/// parse/fetch/cache-path specifics differ, and those arrive as the config's
/// closures; each catalog keeps its own parse/fetch/capabilities.
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
    /// The network was attempted and FAILED; this is the last list the
    /// provider gave, served labelled as such with the time it was fetched.
    case staleAfterFailedRefresh = "stale"
    /// No list at all: nothing was ever fetched, or the fetch failed with
    /// nothing cached. S12a: a compiled-in list used to be served here as if
    /// it were the provider's; now the picker is empty and says why.
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
    public let models: [ProviderModelDescriptor]
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

/// Rows and authority stamps from the same cached bytes. A missing
/// completeness stamp cannot establish that an absent model is unavailable.
struct DecodedModelCatalog: Sendable {
    let models: [ProviderModelDescriptor]
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
    /// Fetch the live list; throws on any failure (network/credentials).
    var fetchLive: @Sendable (URL, URLSession) async throws -> ModelCatalogFetch

    // R-L5 (a): backoff state keyed per cache-file path. One dict serves both
    // catalogs because the cache filenames differ per provider. S12a: the
    // stamp carries the failure's reason so a backed-off read can still say
    // why its list is last-known.
    private static let backoffLock = NSLock()
    nonisolated(unsafe) private static var lastFailedByPath: [String: (at: Date, reason: String)] = [:]

    private func backoffKey(_ dataRoot: URL) -> String {
        cachePath(dataRoot).standardizedFileURL.path
    }

    func staleRefreshAllowed(dataRoot: URL, now: Date = Date()) -> Bool {
        let key = backoffKey(dataRoot)
        Self.backoffLock.lock()
        defer { Self.backoffLock.unlock() }
        guard let last = Self.lastFailedByPath[key] else { return true }
        return now.timeIntervalSince(last.at) >= staleRefreshRetryBackoff
    }

    private func lastFailureReason(dataRoot: URL) -> String? {
        let key = backoffKey(dataRoot)
        Self.backoffLock.lock()
        defer { Self.backoffLock.unlock() }
        return Self.lastFailedByPath[key]?.reason
    }

    func noteStaleRefreshFailed(dataRoot: URL, reason: String = "the refresh failed", now: Date = Date()) {
        let key = backoffKey(dataRoot)
        Self.backoffLock.lock()
        Self.lastFailedByPath[key] = (now, reason)
        // Bound the per-path dict: entries otherwise clear only on a SUCCESSFUL
        // refresh of the same path, so many transient roots (tests, secondary
        // runtimes) grow it for process lifetime (gpt-5.5 fix round, LOW).
        // Evicting the OLDEST stamp on overflow just re-allows one stale
        // refresh early — safe direction. Production uses 2 paths.
        if Self.lastFailedByPath.count > 64,
           let oldest = Self.lastFailedByPath.min(by: { $0.value.at < $1.value.at }) {
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
    func cacheIsStale(fetchedAt: Date?, now: Date = Date()) -> Bool {
        guard let updated = fetchedAt else { return true }
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
    ///
    /// S12a: there is no built-in list any more. A read serves the provider's
    /// own answer — live, or the last one it gave, labelled with its time and
    /// the reason the refresh failed — or nothing, `.unavailable`, with why.
    func modelsWithFreshness(
        dataRoot: URL,
        session: URLSession,
        refresh: Bool
    ) async -> ModelCatalogRead {
        let decoded = readCache(dataRoot)
        let cached = decoded.flatMap { $0.models.isEmpty ? nil : $0.models }
        let fetchedAt = decoded?.fetchedAt
        if !refresh {
            // A passive read never reaches the network without a cache — the
            // same as before; the list arrives on Refresh or a key save.
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
            // TTL expired: try to freshen, but never block the caller — serve the
            // stale copy if the network/credentials are unavailable, and back off
            // failed attempts so a dead network isn't re-probed on every read
            // (a backed-off read returned just above).
        }
        switch await attemptLiveRefresh(dataRoot: dataRoot, session: session) {
        case .success(let live):
            // R-L5 (b): a successful refresh clears any stale failure stamp so
            // the passive stale path isn't still backed off.
            noteStaleRefreshSucceeded(dataRoot: dataRoot)
            // User, 2026-09-06: a partial page is still a live read — it is
            // labelled `liveIncomplete` rather than `cached`, which claimed
            // no network had happened. Only `.live` grants the standing to
            // prune.
            return ModelCatalogRead(
                models: live.models,
                freshness: live.isComplete ? .live : .liveIncomplete)
        case .failure(let failure):
            noteStaleRefreshFailed(dataRoot: dataRoot, reason: failure.reason)
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
        do {
            let fetched = try await fetchLive(dataRoot, session)
            guard !fetched.models.isEmpty else {
                return .failure(FetchFailure("the provider returned no models"))
            }
            // User, 2026-09-06: an incomplete list IS cached and stamped.
            // Withholding it meant a partial answer was re-fetched on every
            // single read — no TTL ever started — while the completeness
            // verdict no longer depends on the cached row count, so there is
            // no baseline to ratchet. What incompleteness costs is the
            // standing to prune, which lives in the freshness label.
            writeCache(fetched.models, dataRoot: dataRoot, isComplete: fetched.isComplete)
            return .success(fetched)
        } catch LLMError.notConfigured {
            return .failure(FetchFailure("no API key is saved for this provider"))
        } catch ProviderRoutingError.invalidResponse(let status) {
            return .failure(FetchFailure("the provider answered HTTP \(status)"))
        } catch {
            return .failure(FetchFailure(error.localizedDescription))
        }
    }

    struct FetchFailure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
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
