import Foundation
import Testing
@testable import PersistenceCore

struct DeskNagUpgradeTests {
    @Test func unsupportedSettingsSurviveEveryWritePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeskNagConfigStore(dataRoot: root)
        try FileManager.default.createDirectory(at: store.configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixtures = [
            #"{"version":2,"enabled":true,"windowId":9}"#,
            #"{"version":1,"enabled":true,"quietHours":[22,8]}"#,
            #"{"version":1,"enabled":true,"scopes":[{"kind":"project","id":"work","future":true}]}"#,
            #"{"version":1,"enabled":true,"scopes":[{"kind":"workspace","id":"work","enabled":false}]}"#,
            #"{"version":1,"enabled":true,"observed":{"a":{"future":true}}}"#,
            #"{"version":"2","enabled":true}"#,
            #"{"enabled":true"#,
            "null"
        ]
        for fixture in fixtures {
            let bytes = Data(fixture.utf8)
            try bytes.write(to: store.configPath)
            #expect(await store.load().enabled == false)
            await #expect(throws: (any Error).self) { try await store.save(DeskNagConfig()) }
            await #expect(throws: (any Error).self) { try await store.update { $0.unmuted() } }
            #expect(try Data(contentsOf: store.configPath) == bytes)
        }
    }

    @Test func legacySettingsStillUpgrade() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeskNagConfigStore(dataRoot: root)
        try await store.save(DeskNagConfig())
        try Data(#"{"enabled":true,"windowId":9,"mutedUntil":"forever","ledger":{"a":8}}"#.utf8)
            .write(to: store.configPath)
        let updated = try await store.update { $0.unmuted() }
        #expect(updated.enabled)
        #expect(updated.windowId == 10)
        #expect(updated.ledger["a"] == 8)
        #expect(await store.load() == updated)
    }
}
