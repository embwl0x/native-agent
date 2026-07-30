import PersistenceCore
import Testing
@testable import NativeAgentApp

@MainActor
@Test func capabilitiesStoreLoadsTheInProcessDispatcherManifest() async throws {
    let manifest: JSONValue = .object([
        "tools": .array([
            .object([
                "name": .string("time_now"),
                "description": .string("Read current time"),
                "autonomy": .string("auto"),
                "effective_autonomy": .string("auto"),
                "autonomy_source": .string("trust_center"),
                "side_effects": .bool(false),
                "available_now": .bool(true),
                "input_schema": .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([]),
                ]),
            ]),
            .object([
                "name": .string("messages_send"),
                "description": .string("Send a message"),
                "autonomy": .string("confirm"),
                "effective_autonomy": .string("confirm"),
                "autonomy_source": .string("trust_center"),
                "side_effects": .bool(true),
                "available_now": .bool(true),
                "input_schema": .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([]),
                ]),
            ]),
        ]),
    ])
    let store = CapabilitiesStore(manifestLoader: { manifest })

    await store.forceRefresh()

    #expect(store.fetchError == nil)
    #expect(store.tools.map(\.name) == ["messages_send", "time_now"])
    #expect(store.slashCommandTools().map(\.name) == ["time_now"])
}

@MainActor
@Test func capabilitiesStoreSurfacesManifestFailureInsteadOfFabricatingEmptySuccess() async {
    struct FixtureError: Error {}
    let store = CapabilitiesStore(manifestLoader: { throw FixtureError() })

    await store.forceRefresh()

    #expect(store.tools.isEmpty)
    #expect(store.fetchError?.contains("Tool manifest unavailable") == true)
    #expect(store.lastFetchedAt == nil)
}
