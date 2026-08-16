import Foundation
import Testing
@testable import MemoryV2

#if canImport(CoreML) && !os(Linux)
import CoreML

@Suite("CoreML compiled model cache")
struct CoreMLCompileCacheTests {
    @Test("cache identity includes model digest and operating system")
    func cacheIdentityIncludesDigestAndOperatingSystem() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("coreml-cache-path-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("minilm.mlpackage", isDirectory: true)
        let first = CoreMLEmbeddingProvider.compileCacheDirectory(
            packageURL: package,
            artifactDigest: "digest-a",
            cacheRoot: root,
            osKey: "macOS 26.5 (build A/B)"
        )
        let otherDigest = CoreMLEmbeddingProvider.compileCacheDirectory(
            packageURL: package,
            artifactDigest: "digest-b",
            cacheRoot: root,
            osKey: "macOS 26.5 (build A/B)"
        )
        let otherOS = CoreMLEmbeddingProvider.compileCacheDirectory(
            packageURL: package,
            artifactDigest: "digest-a",
            cacheRoot: root,
            osKey: "macOS 27.0"
        )

        #expect(first != otherDigest)
        #expect(first != otherOS)
        #expect(first.lastPathComponent == "digest-a.mlmodelc")
        #expect(!first.path.contains("A/B"))
    }

    @Test("eviction keeps current model and newest sibling")
    func evictionKeepsCurrentAndNewestSibling() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("coreml-cache-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let current = root.appendingPathComponent("current.mlmodelc", isDirectory: true)
        let newest = root.appendingPathComponent("newest.mlmodelc", isDirectory: true)
        let stale = root.appendingPathComponent("stale.mlmodelc", isDirectory: true)
        for entry in [current, newest, stale] {
            try fm.createDirectory(at: entry, withIntermediateDirectories: false)
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: current.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: newest.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: stale.path)

        CoreMLEmbeddingProvider.pruneCompileCache(
            cacheDir: root,
            keeping: current,
            maximumEntries: 2
        )

        #expect(fm.fileExists(atPath: current.path))
        #expect(fm.fileExists(atPath: newest.path))
        #expect(!fm.fileExists(atPath: stale.path))
    }

    @Test("operating system eviction remains bounded across upgrades")
    func operatingSystemEvictionRemainsBoundedAcrossUpgrades() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("coreml-os-cache-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let current = root.appendingPathComponent("macos-current", isDirectory: true)
        let newestPrior = root.appendingPathComponent("macos-prior", isDirectory: true)
        let stale = root.appendingPathComponent("macos-stale", isDirectory: true)
        for entry in [current, newestPrior, stale] {
            try fm.createDirectory(at: entry, withIntermediateDirectories: false)
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: current.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: newestPrior.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: stale.path)

        CoreMLEmbeddingProvider.pruneOperatingSystemCaches(
            modelRoot: root,
            keeping: current,
            maximumEntries: 2
        )

        #expect(fm.fileExists(atPath: current.path))
        #expect(fm.fileExists(atPath: newestPrior.path))
        #expect(!fm.fileExists(atPath: stale.path))
    }

    @Test("compiled model publishes atomically and reuses the digest slot")
    func compiledModelPublishesAtomicallyAndReusesDigestSlot() throws {
        guard let package = Bundle.module.url(forResource: "minilm", withExtension: "mlpackage") else {
            Issue.record("minilm.mlpackage missing from test resources")
            return
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("coreml-atomic-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let digest = try MemoryEmbeddingEpoch.sha256(directory: package)

        let first = try CoreMLEmbeddingProvider.compileAndCache(
            packageURL: package,
            artifactDigest: digest,
            cacheRoot: root,
            osKey: "test-os"
        )
        let firstMtime = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try MLModel(contentsOf: first)
        let second = try CoreMLEmbeddingProvider.compileAndCache(
            packageURL: package,
            artifactDigest: digest,
            cacheRoot: root,
            osKey: "test-os"
        )
        let secondMtime = try second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        #expect(first == second)
        #expect(firstMtime == secondMtime)
        let hiddenStaging = try fm.contentsOfDirectory(atPath: first.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".") && $0.hasSuffix(".mlmodelc") }
        #expect(hiddenStaging.isEmpty)
    }
}
#endif
