import Testing
import PersistenceCore
@testable import NativeAgentApp

@Test
func chatToolCatalogSnapshotPreservesLiveAvailabilityAndAutonomyFields() throws {
    let envelope: JSONValue = .object([
        "tools": .array([
            .object([
                "name": .string("image_generate"),
                "description": .string("Generate an image."),
                "load_state": .string("discovery_only"),
                "effective_autonomy": .string("confirm"),
                "available_now": .bool(true),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object(["prompt": .object(["type": .string("string")])]),
                ]),
            ]),
        ]),
        "currently_loaded": .array([]),
    ])

    let snapshot = try #require(ChatToolCatalogSnapshot.from(jsonValue: envelope))
    let tool = try #require(snapshot.tools.first)
    #expect(tool.loadState == "discovery_only")
    #expect(tool.effectiveAutonomy == "confirm")
    #expect(tool.availableNow == true)
    #expect(tool.parametersPreview == "prompt")
}
