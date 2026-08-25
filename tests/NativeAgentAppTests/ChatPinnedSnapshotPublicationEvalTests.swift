import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / store.chat.pinnedSnapshotPublication
@Suite("Chat pinned snapshot publication", .serialized)
struct ChatPinnedSnapshotPublicationEvalTests {
    private func isolatedDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "nativeagent.chat.pinned-snapshot.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @MainActor
    @Test("published pins equal the durable list that a relaunch reads")
    func successfulSavePublishesOnlyThePersistedCanonicalList() throws {
        let (defaults, suite) = try isolatedDefaults()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let encoded = try MacPinnedChatSessionStore.save(
            ["first", " second ", "first"],
            defaults: defaults,
            dataRoot: root
        )
        var published: [[String]] = []
        #expect(ChatPinnedSnapshotPublication.request(
            encodedPinnedIDs: encoded,
            defaults: defaults,
            publish: { published.append($0) }
        ))

        let relaunchValue = MacPinnedChatSessionStore.load(defaults: defaults)
        #expect(relaunchValue == ["first", "second"])
        #expect(published == [relaunchValue])
    }

    @MainActor
    @Test("stale or half-applied encoded pins publish nothing")
    func mismatchedPersistedValueRefusesPublication() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("[\"last-proven\"]", forKey: MacPinnedChatSessionStore.defaultsKey)
        var published: [[String]] = []
        let didPublish = ChatPinnedSnapshotPublication.request(
            encodedPinnedIDs: "[\"partially-applied\"]",
            defaults: defaults,
            publish: { published.append($0) }
        )

        #expect(!didPublish)
        #expect(published.isEmpty)
        #expect(MacPinnedChatSessionStore.load(defaults: defaults) == ["last-proven"])
    }

    @MainActor
    @Test("pin and unpin snapshot requests publish each route's persisted list")
    func pinAndUnpinRouteEncodingsUseTheProductionPublicationGate() throws {
        let (defaults, suite) = try isolatedDefaults()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-snapshot-routes-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        // The pin route persists the expanded list, then asks the production
        // gate to issue the snapshot request with that exact durable value.
        let encodedAfterPin = try MacPinnedChatSessionStore.save(
            ["first", "second"],
            defaults: defaults,
            dataRoot: root
        )
        var pinSnapshots: [[String]] = []
        #expect(ChatPinnedSnapshotPublication.request(
            encodedPinnedIDs: encodedAfterPin,
            defaults: defaults,
            publish: { pinSnapshots.append($0) }
        ))
        #expect(pinSnapshots == [["first", "second"]])

        // The unpin route persists the reduced list. It must publish that new
        // canonical snapshot, rather than the previous in-memory list.
        let encodedAfterUnpin = try MacPinnedChatSessionStore.save(
            ["second"],
            defaults: defaults,
            dataRoot: root
        )
        var unpinSnapshots: [[String]] = []
        #expect(ChatPinnedSnapshotPublication.request(
            encodedPinnedIDs: encodedAfterUnpin,
            defaults: defaults,
            publish: { unpinSnapshots.append($0) }
        ))
        #expect(unpinSnapshots == [["second"]])
        #expect(MacPinnedChatSessionStore.load(defaults: defaults) == ["second"])
    }
}
