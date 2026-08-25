import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / pairing.regenerateControl
@Suite("Pairing regeneration control", .serialized)
struct PairingRegenerateControlEvalTests {
    @Test("failed pairing publication remains a named warning after the pane is recreated")
    func failedPublicationPersistsActionableWarning() throws {
        let suite = "NativeAgentPairingRegenerateControl.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let warning = PairingPublicationHealth.record(
            kvsPublished: false,
            cloudKitPublished: false,
            defaults: defaults
        )
        #expect(warning?.contains("neither KVS nor CloudKit") == true)
        #expect(PairingPublicationHealth.currentWarning(defaults: defaults) == warning)

        // The state owner has no view-local cache: a new pane reads the same
        // durable warning rather than losing the repair instruction on navigation.
        let recreatedDefaults = try #require(UserDefaults(suiteName: suite))
        #expect(PairingPublicationHealth.currentWarning(defaults: recreatedDefaults) == warning)

        #expect(PairingPublicationHealth.record(
            kvsPublished: true,
            cloudKitPublished: true,
            defaults: defaults
        ) == nil)
        #expect(PairingPublicationHealth.currentWarning(defaults: defaults) == nil)
    }
}
