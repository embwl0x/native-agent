import Foundation
import Testing
@testable import Browser

@Suite struct BrowserCaptureCacheTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("native_power/browser")
    }

    @Test func countLimitEvictsWholeCaptureAndPreservesCurrentPairs() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let cache = BrowserCaptureCache(policy: .init(maxBytes: 100, maxGroups: 1, maxAge: 100,
                                                     maxArtifactBytes: 50, maxGroupBytes: 100))
        let old = UUID().uuidString
        let paths = try await cache.store(id: old, artifacts: [.text: Data("text".utf8), .links: Data("[]".utf8)],
                                          browserRoot: root, now: Date(timeIntervalSince1970: 100))
        let current = UUID().uuidString
        let currentPaths = try await cache.store(id: current, artifacts: [.text: Data("current".utf8)], browserRoot: root)
        _ = try await cache.store(id: current, artifacts: [.links: Data("[]".utf8), .screenshot: Data([1, 2])], browserRoot: root)
        for path in paths.values { #expect(!FileManager.default.fileExists(atPath: path.path)) }
        #expect(try String(contentsOf: #require(currentPaths[.text]), encoding: .utf8) == "current")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sources/\(current)-links.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("screenshots/\(current).png").path))
    }

    @Test func byteLimitIsSharedAcrossSourcesAndScreenshots() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let cache = BrowserCaptureCache(policy: .init(maxBytes: 10, maxGroups: 20, maxAge: 100_000,
                                                     maxArtifactBytes: 10, maxGroupBytes: 10))
        let source = try await cache.store(id: UUID().uuidString, artifacts: [.text: Data(repeating: 1, count: 6)], browserRoot: root)
        let screenshot = try await cache.store(id: UUID().uuidString, artifacts: [.screenshot: Data(repeating: 2, count: 6)], browserRoot: root)
        #expect(!FileManager.default.fileExists(atPath: try #require(source[.text]).path))
        #expect(try Data(contentsOf: #require(screenshot[.screenshot])).count == 6)
    }

    @Test func expiresKnownCapturesButDoesNotDeleteForeignNamesOrFollowSymlinks() async throws {
        let root = try root()
        let outer = root.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: outer) }
        let cache = BrowserCaptureCache(policy: .init(maxAge: 10))
        let old = try await cache.store(id: "browser-text-" + UUID().uuidString.lowercased(),
                                        artifacts: [.text: Data([1])], browserRoot: root)
        let oldPath = try #require(old[.text])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: oldPath.path)
        let document = root.appendingPathComponent("sources/my-saved-document.txt")
        try Data([42]).write(to: document)
        let target = outer.appendingPathComponent("user-document.txt")
        try Data([7]).write(to: target)
        let link = root.appendingPathComponent("sources/\(UUID().uuidString).txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = try await cache.store(id: UUID().uuidString, artifacts: [.links: Data([2])],
                                  browserRoot: root, now: Date(timeIntervalSince1970: 200))
        #expect(!FileManager.default.fileExists(atPath: oldPath.path))
        #expect(try Data(contentsOf: document) == Data([42]))
        #expect(try Data(contentsOf: target) == Data([7]))
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func oversizedOrRepeatedCaptureFailsBeforeEvictingExistingObservations() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let cache = BrowserCaptureCache(policy: .init(maxBytes: 10, maxGroups: 1, maxAge: 100,
                                                     maxArtifactBytes: 5, maxGroupBytes: 8))
        let id = UUID().uuidString
        let saved = try await cache.store(id: id, artifacts: [.text: Data([1, 2, 3, 4])], browserRoot: root)
        await #expect(throws: (any Error).self) {
            _ = try await cache.store(id: UUID().uuidString, artifacts: [.screenshot: Data(repeating: 1, count: 6)], browserRoot: root)
        }
        await #expect(throws: (any Error).self) {
            _ = try await cache.store(id: id, artifacts: [.links: Data(repeating: 1, count: 5)], browserRoot: root)
        }
        await #expect(throws: (any Error).self) {
            _ = try await cache.store(id: id, artifacts: [.text: Data([9])], browserRoot: root)
        }
        #expect(try Data(contentsOf: #require(saved[.text])) == Data([1, 2, 3, 4]))
    }

    @Test func refusesRedirectedCaptureDirectory() async throws {
        let root = try root()
        let outer = root.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: outer) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = outer.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sources"), withDestinationURL: outside)
        await #expect(throws: (any Error).self) {
            _ = try await BrowserCaptureCache().store(id: UUID().uuidString, artifacts: [.text: Data([1])], browserRoot: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
