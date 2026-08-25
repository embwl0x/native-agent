import Foundation
import Testing

@testable import NativeAgentApp

@MainActor
@Suite("Mac pinned chat session store")
struct MacPinnedChatSessionStoreTests {
    @Test
    func legacyAndJSONValuesNormalizeToOneOrderedList() {
        #expect(MacPinnedChatSessionStore.decode(" first | second | first |  ") == [
            "first", "second",
        ])
        #expect(MacPinnedChatSessionStore.decode("[\" second \",\"first\",\"second\"]") == [
            "second", "first",
        ])
    }

    @Test
    func savePublishesTheSameOrderedValueToUIAndRetentionMirror() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-pinned-store-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "MacPinnedChatSessionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let encoded = try MacPinnedChatSessionStore.save(
            [" first ", "second", "first", ""],
            defaults: defaults,
            dataRoot: root
        )

        #expect(encoded == "[\"first\",\"second\"]")
        #expect(MacPinnedChatSessionStore.load(defaults: defaults) == ["first", "second"])
        let mirror = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("pinned_session_ids.json")
        let mirroredIDs = try JSONDecoder().decode([String].self, from: Data(contentsOf: mirror))
        #expect(mirroredIDs == ["first", "second"])
    }

    @Test
    func closePinnedTabUpdatesTheMountedValueAndRetentionMirrorAcrossReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-pinned-close-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "MacPinnedChatSessionStoreCloseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        try MacPinnedChatSessionStore.save(
            ["first", "second"],
            defaults: defaults,
            dataRoot: root
        )

        let result = try MacPinnedChatSessionStore.closePinnedTab(
            sessionID: " second ",
            defaults: defaults,
            dataRoot: root
        )

        #expect(result == .closed(encoded: "[\"first\"]"))
        // Fresh reads match the @AppStorage strip and retention owner after
        // the application is relaunched.
        #expect(MacPinnedChatSessionStore.load(defaults: defaults) == ["first"])
        let mirror = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("pinned_session_ids.json")
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: mirror)) == ["first"])
    }

    @Test
    func closePinnedTabRefusesInvalidOrAlreadyRemovedTabsWithoutChangingDurableState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-pinned-close-refusal-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "MacPinnedChatSessionStoreCloseRefusalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        try MacPinnedChatSessionStore.save(["first"], defaults: defaults, dataRoot: root)

        #expect(try MacPinnedChatSessionStore.closePinnedTab(
            sessionID: "   ", defaults: defaults, dataRoot: root
        ) == .refusedInvalidSessionID)
        #expect(try MacPinnedChatSessionStore.closePinnedTab(
            sessionID: "missing", defaults: defaults, dataRoot: root
        ) == .refusedAlreadyUnpinned)
        #expect(MacPinnedChatSessionStore.load(defaults: defaults) == ["first"])
    }

    @Test
    func closePinnedTabLeavesTheTabPinnedWhenTheRetentionMirrorCannotBeWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-pinned-close-failure-\(UUID().uuidString)", isDirectory: true)
        let blockedRoot = root.appendingPathComponent("not-a-directory")
        let suiteName = "MacPinnedChatSessionStoreCloseFailureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        try MacPinnedChatSessionStore.save(["first"], defaults: defaults, dataRoot: root)
        try Data("block".utf8).write(to: blockedRoot)

        #expect(throws: (any Error).self) {
            try MacPinnedChatSessionStore.closePinnedTab(
                sessionID: "first", defaults: defaults, dataRoot: blockedRoot
            )
        }

        // A fresh defaults read is the mounted tab strip's reload source; the
        // original retention mirror also still protects the pin.
        #expect(MacPinnedChatSessionStore.load(defaults: defaults) == ["first"])
        let mirror = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("pinned_session_ids.json")
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: mirror)) == ["first"])
    }
}
