import Foundation
import NativeAgentCore
import PersistenceCore

/// A schema catalog already read for this turn before ContextFlow preparation.
///
/// `context_expand` is ALWAYS in this catalog (2026-09-01). It used to be
/// added or dropped per turn depending on whether that turn's packet happened
/// to carry expandable pointers — which meant the advertised contract, and
/// therefore the cached prompt prefix, changed shape for a reason the model
/// never asked about. It is in `alwaysOnCoreNames`; the floor is the floor.
/// When there is nothing to expand the tool simply says so at dispatch, which
/// is cheaper than rewriting the prefix.
public struct TurnToolSchemaCatalogSeed: Sendable {
    public let schemas: [LLMToolSchema]

    package static let canonicalContextExpandSchema = LLMToolSchema(
        name: "context_expand",
        description: "Read one deeper context section offered for this turn. The atom id must come from the current context pointer list; expansion is read-only and pinned to this turn's immutable generation.",
        parametersJSON: (try? JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "atom_id": .object([
                    "type": .string("string"),
                    "description": .string("Atom id from the current turn's offered context pointers."),
                ]),
                "max_characters": .object([
                    "type": .string("integer"),
                    "description": .string("Optional bounded character limit."),
                ]),
            ]),
            "required": .array([.string("atom_id")]),
        ]).serializedData(pretty: false)) ?? Data("{}".utf8)
    )

    public init(schemas: [LLMToolSchema]) {
        guard !schemas.contains(where: { $0.name == "context_expand" }) else {
            self.schemas = schemas
            return
        }
        // Canonical built-in order places context_expand directly after
        // read_file. Retain that order so provider tool arrays and prompt
        // cache prefixes do not change merely because this path reused a
        // preload built before the packet existed.
        var seeded = schemas
        let insertion = seeded.firstIndex { $0.name == "read_file" }.map { $0 + 1 }
            ?? seeded.count
        seeded.insert(Self.canonicalContextExpandSchema, at: insertion)
        self.schemas = seeded
    }
}
