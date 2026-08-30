import Foundation
import Testing
@testable import ProviderRouting

/// Sweep item A9: `ContextBudgetPolicy.resolve` reaches the OpenRouter catalog
/// through `verifiedContextLength` at four points in ONE chat turn (history
/// window, packet budget, turn budget, cognitive capsule). Before the mtime
/// cache each of those re-read and re-parsed the whole catalog file.
///
/// These pin OPERATION COUNTS, not wall clock: the win is "one decode per turn
/// instead of four", and a count is deterministic under parallel load where an
/// elapsed-time bound is not.
private struct A9CacheFixture {
    let root: URL
    let cacheFile: URL

    init(rows: [(id: String, window: Int)]) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a9-budget-\(UUID().uuidString)")
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providers, withIntermediateDirectories: true)
        cacheFile = providers.appendingPathComponent("openrouter-models-cache.json")
        try write(rows: rows)
        OpenRouterModelCatalog._resetCacheForTesting(dataRoot: root)
    }

    func write(rows: [(id: String, window: Int)], mtime: Date? = nil) throws {
        let models = rows.map {
            "{\"id\":\"\($0.id)\",\"name\":\"\($0.id)\",\"context_length\":\($0.window)}"
        }.joined(separator: ",")
        let json = "{\"updated_at\":\"2026-08-28T00:00:00Z\",\"models\":[\(models)]}"
        try Data(json.utf8).write(to: cacheFile)
        // Stamp an explicit mtime rather than sleeping: the cache key is the
        // modification date, so a distinct stamp is what "the file changed"
        // means here, and it keeps the test free of wall-clock waits.
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: cacheFile.path)
        }
    }

    func window(_ model: String) -> Int? {
        ProviderRouting.verifiedContextLength(
            forModel: model, providerID: "openrouter", dataRoot: root)
    }

    func stats() -> OpenRouterModelCatalog.CacheStats {
        OpenRouterModelCatalog._testCacheStats(dataRoot: root)
    }

    func tearDown() {
        OpenRouterModelCatalog._resetCacheForTesting(dataRoot: root)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func a9_fourBudgetReadsInOneTurnDecodeTheCatalogOnce() throws {
    let fixture = try A9CacheFixture(rows: [("anthropic/claude-sonnet-5", 1_000_000)])
    defer { fixture.tearDown() }

    // The four per-turn budget-policy call sites.
    for _ in 0..<4 {
        #expect(fixture.window("anthropic/claude-sonnet-5") == 1_000_000)
    }
    #expect(fixture.stats() == OpenRouterModelCatalog.CacheStats(decodeAttempts: 1, hits: 3))
}

@Test func a9_rewrittenCatalogIsVisibleOnTheNextRead() throws {
    let fixture = try A9CacheFixture(rows: [("anthropic/claude-sonnet-5", 1_000_000)])
    defer { fixture.tearDown() }

    #expect(fixture.window("anthropic/claude-sonnet-5") == 1_000_000)
    #expect(fixture.stats().decodeAttempts == 1)

    // A refresh that narrows the published window must NOT be masked by the
    // cache — an over-optimistic window is exactly what overfills a prompt.
    try fixture.write(
        rows: [("anthropic/claude-sonnet-5", 200_000)],
        mtime: Date(timeIntervalSince1970: 2_000_000_000))
    #expect(fixture.window("anthropic/claude-sonnet-5") == 200_000)
    #expect(fixture.stats().decodeAttempts == 2)
}

@Test func a9_removedCatalogFailsClosedAndRedecodesWhenRestored() throws {
    let fixture = try A9CacheFixture(rows: [("anthropic/claude-sonnet-5", 1_000_000)])
    defer { fixture.tearDown() }

    #expect(fixture.window("anthropic/claude-sonnet-5") == 1_000_000)

    try FileManager.default.removeItem(at: fixture.cacheFile)
    // No cached descriptor: `verifiedContextLength` falls through to the
    // hardcoded verified table, exactly as it did before the cache existed.
    #expect(fixture.window("meta-llama/llama-3.3-70b-instruct") == 131_072)
    #expect(fixture.window("openrouter/only-in-the-file") == nil)

    try fixture.write(
        rows: [("openrouter/only-in-the-file", 64_000)],
        mtime: Date(timeIntervalSince1970: 2_000_000_001))
    #expect(fixture.window("openrouter/only-in-the-file") == 64_000)
}

@Test func a9_corruptCatalogCachesTheNilResultWithoutRetryingEveryRead() throws {
    let fixture = try A9CacheFixture(rows: [("anthropic/claude-sonnet-5", 1_000_000)])
    defer { fixture.tearDown() }

    try Data("not json".utf8).write(to: fixture.cacheFile)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 2_000_000_002)],
        ofItemAtPath: fixture.cacheFile.path)

    for _ in 0..<4 {
        #expect(fixture.window("openrouter/only-in-the-file") == nil)
    }
    #expect(fixture.stats().decodeAttempts == 1)
    #expect(fixture.stats().hits == 3)
}
