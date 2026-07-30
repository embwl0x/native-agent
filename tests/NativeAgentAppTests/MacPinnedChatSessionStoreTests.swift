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
}
