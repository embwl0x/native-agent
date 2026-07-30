import Foundation
import Testing
@testable import ProviderRouting

// TTL staleness on the catalog READ path (tightness sweep 2026-07-17):
// a fresh cache is served without touching the network; a cache older than
// the 24h TTL triggers a live refresh, and the stale copy is still served
// when that refresh fails so provider settings stay usable offline.

private func writeCatalogCache(
    at path: URL,
    updatedAt: Date,
    ids: [String]
) throws {
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let iso = ISO8601DateFormatter().string(from: updatedAt)
    let rows = ids.map {
        "{\"id\":\"\($0)\",\"name\":\"\($0)\",\"context_length\":128000}"
    }.joined(separator: ",")
    let json = "{\"schema_version\":1,\"updated_at\":\"\(iso)\",\"models\":[\(rows)]}"
    try Data(json.utf8).write(to: path, options: .atomic)
}

// L3 (tightness round 2): ONE file-private URLProtocol that fails every request
// and counts attempts, hoisted from three byte-identical local copies. The
// counter is process-shared, so the tests that assert on it live in a
// `.serialized` suite and each calls `reset()` at entry — otherwise a parallel
// sibling incrementing the shared counter would flake the `== 0` assertions.
private final class CountingFailProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    static func reset() {
        lock.lock(); count = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

// The counter is shared, so these run serially and reset at entry.
@Suite(.serialized)
struct CatalogTTLNetworkCountingTests {

    // MARK: - OpenRouter

    @Test func openRouterFreshCacheServedWithoutNetwork() async throws {
        CountingFailProtocol.reset()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("or-fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("providers/openrouter-models-cache.json")
        try writeCatalogCache(at: cache, updatedAt: Date(), ids: ["vendor/fresh-model"])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingFailProtocol.self]
        let session = URLSession(configuration: config)

        let models = await OpenRouterModelCatalog.models(dataRoot: root, session: session, refresh: false)
        #expect(models.map(\.id) == ["vendor/fresh-model"])
        #expect(CountingFailProtocol.requestCount == 0)
        #expect(!OpenRouterModelCatalog.cacheIsStale(dataRoot: root))
    }

    @Test func openRouterStaleCacheRefreshesAndServesStaleOnFailure() async throws {
        CountingFailProtocol.reset()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("or-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("providers/openrouter-models-cache.json")
        // 48h old → beyond the 24h TTL.
        try writeCatalogCache(
            at: cache,
            updatedAt: Date().addingTimeInterval(-48 * 60 * 60),
            ids: ["vendor/stale-model"]
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingFailProtocol.self]
        let session = URLSession(configuration: config)

        #expect(OpenRouterModelCatalog.cacheIsStale(dataRoot: root))
        let models = await OpenRouterModelCatalog.models(dataRoot: root, session: session, refresh: false)
        // A live refresh was attempted...
        #expect(CountingFailProtocol.requestCount >= 1)
        // ...and the stale cache is still served because the refresh failed.
        #expect(models.map(\.id) == ["vendor/stale-model"])
    }

    // R-L5 fix (a): the failed-refresh backoff is keyed PER cache-file path
    // (per-provider AND per-dataRoot), NOT one process-global stamp. A dead
    // network under one root suppresses re-probes for THAT root only; a
    // different root must still probe.
    @Test func openRouterBackoffIsPerDataRoot() async throws {
        CountingFailProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingFailProtocol.self]
        let session = URLSession(configuration: config)

        func makeStaleRoot(_ tag: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("or-perroot-\(tag)-\(UUID().uuidString)", isDirectory: true)
            let cache = root.appendingPathComponent("providers/openrouter-models-cache.json")
            try writeCatalogCache(
                at: cache,
                updatedAt: Date().addingTimeInterval(-48 * 60 * 60),
                ids: ["vendor/\(tag)"]
            )
            return root
        }

        let rootA = try makeStaleRoot("a")
        let rootB = try makeStaleRoot("b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        // 1. rootA stale + failing network → one probe; stamps a failure for rootA.
        _ = await OpenRouterModelCatalog.models(dataRoot: rootA, session: session, refresh: false)
        let afterA1 = CountingFailProtocol.requestCount
        #expect(afterA1 >= 1)

        // 2. rootA again within the backoff window → suppressed, NO new probe.
        _ = await OpenRouterModelCatalog.models(dataRoot: rootA, session: session, refresh: false)
        #expect(CountingFailProtocol.requestCount == afterA1)

        // 3. rootB (independent cache path) → rootA's backoff must NOT suppress it.
        _ = await OpenRouterModelCatalog.models(dataRoot: rootB, session: session, refresh: false)
        #expect(CountingFailProtocol.requestCount > afterA1)
    }

    // MARK: - Moonshot

    @Test func moonshotFreshCacheServedWithoutNetwork() async throws {
        CountingFailProtocol.reset()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("providers/moonshot-models-cache.json")
        try writeCatalogCache(at: cache, updatedAt: Date(), ids: ["kimi-custom-fresh"])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingFailProtocol.self]
        let session = URLSession(configuration: config)

        let models = await MoonshotModelCatalog.models(dataRoot: root, session: session, refresh: false)
        #expect(models.contains { $0.id == "kimi-custom-fresh" })
        #expect(CountingFailProtocol.requestCount == 0)
        #expect(!MoonshotModelCatalog.cacheIsStale(dataRoot: root))
    }
}

@Test func MoonshotModelCatalog_staleCacheServesStaleWhenOffline() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-stale-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("providers/moonshot-models-cache.json")
    try writeCatalogCache(
        at: cache,
        updatedAt: Date().addingTimeInterval(-48 * 60 * 60),
        ids: ["kimi-custom-stale"]
    )

    #expect(MoonshotModelCatalog.cacheIsStale(dataRoot: root))
    // No MOONSHOT_API_KEY under this isolated root → fetchLiveModels throws
    // notConfigured → attemptLiveRefresh returns nil → the stale copy is served.
    let models = await MoonshotModelCatalog.models(dataRoot: root, refresh: false)
    #expect(models.contains { $0.id == "kimi-custom-stale" })
}

// R-L5 fix (b): an explicit `refresh: true` that SUCCEEDS clears any prior
// failure stamp. Previously the stamp survived, so the passive stale-path
// refresh stayed suppressed until the 15-minute backoff elapsed even though a
// fresh list had just been fetched. Exercised directly against the shared cache
// so the fetch outcome is deterministic (no live network).
@Test func modelCatalogTTLCache_refreshTrueSuccessClearsFailureStamp() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ttl-refresh-clear-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cache = ModelCatalogTTLCache(
        cachePath: { $0.appendingPathComponent("providers/test-cache.json") },
        endpoint: URL(string: "https://example.test/models")!,
        readCache: { _ in nil },
        cacheUpdatedAt: { _ in nil },
        fetchLive: { _, _ in
            [ProviderModelDescriptor(id: "m1", name: "M1", contextLength: 1000)]
        },
        fallback: { [] }
    )

    // Stamp a failure → backoff active for this root.
    cache.noteStaleRefreshFailed(dataRoot: root)
    #expect(!cache.staleRefreshAllowed(dataRoot: root))

    // An explicit successful refresh must clear the stamp.
    let live = await cache.models(dataRoot: root, session: .shared, refresh: true)
    #expect(live.map(\.id) == ["m1"])
    #expect(cache.staleRefreshAllowed(dataRoot: root))
}

// MARK: - Memo-chain pin (M-F3 isKnownCatalogModelID)
//
// isKnownCatalogModelID memoizes on the cache file's mtime. A TTL refresh
// rewrites the cache file, changing its mtime, which must invalidate the memo
// so newly-catalogued ids become recognizable without an async hop. This pins
// that chain: the sync membership check must NOT keep returning a stale answer
// after the underlying cache file is rewritten.

@Test func MoonshotModelCatalog_isKnownCatalogModelID_memoInvalidatesOnCacheRewrite() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-memo-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("providers/moonshot-models-cache.json")

    try writeCatalogCache(at: cache, updatedAt: Date(), ids: ["custom-model-a"])
    #expect(MoonshotModelCatalog.isKnownCatalogModelID("custom-model-a", dataRoot: root))
    // Memoize the negative answer against the first mtime.
    #expect(!MoonshotModelCatalog.isKnownCatalogModelID("custom-model-b", dataRoot: root))

    // Rewrite the cache with a new model and NO manual mtime forcing — the pin
    // must prove the REAL chain (atomic rewrite → filesystem mtime changes →
    // stat()-keyed memo invalidates), exactly what a TTL refresh does through
    // writeCache (gpt-5.5 review LOW: the earlier forced-mtime version pinned
    // a synthetic chain). APFS mtime is nanosecond-granular; the 20ms spacer
    // guards against any coarse-granularity filesystem in CI.
    Thread.sleep(forTimeInterval: 0.02)
    try writeCatalogCache(at: cache, updatedAt: Date(), ids: ["custom-model-b"])

    #expect(MoonshotModelCatalog.isKnownCatalogModelID("custom-model-b", dataRoot: root))
}
