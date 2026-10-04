import Foundation
import NativeAgentCore
import PersistenceCore

/// Canonical context-expand descriptor, folded into `app` (`context.expand`)
/// on the resident agent's requests and retained for lanes declaring their own tools.
public struct TurnToolSchemaCatalogSeed: Sendable {
    package static let canonicalContextExpandSchema = LLMToolSchema(
        name: "context_expand",
        description: "Read deeper context by its offered atom id or a history: id from a replayed receipt. Context atoms are pinned to this turn's generation; history receipts are read from the current conversation.",
        parametersJSON: (try? JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "atom_id": .object([
                    "type": .string("string"),
                    "description": .string("Offered context atom id or history: id from a replayed receipt."),
                ]),
                "max_characters": .object([
                    "type": .string("integer"),
                    "description": .string("Optional bounded character limit."),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "description": .string("Optional character offset, default 0. Continue with next_offset until null."),
                ]),
            ]),
            "required": .array([.string("atom_id")]),
        ]).serializedData(pretty: false)) ?? Data("{}".utf8)
    )
}
