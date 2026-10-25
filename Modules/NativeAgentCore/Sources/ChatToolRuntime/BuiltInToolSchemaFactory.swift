import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory.swift` | `BuiltInToolSchemaFactory` struct; `requestedSchema`; common constructors come from `PersistenceCore.ToolSchema` |

/// Per-request schema construction; descriptions and parameters stay lazy.
package struct BuiltInToolSchemaFactory {
    let requestedNames: Set<String>?
    let standingBotMinimumInterval: TimeInterval

    package init(requestedNames: Set<String>?, standingBotMinimumInterval: TimeInterval = BotRunLimits.minimumInterval) {
        self.requestedNames = requestedNames
        self.standingBotMinimumInterval = standingBotMinimumInterval
    }

    func requestedSchema(
        name: String,
        toolClass: ToolClass,
        reach: ToolReach = .hers,
        capabilities: Set<String>? = nil,
        effectInputPolicy: ToolEffectInputPolicy = .fixed,
        description: @autoclosure () -> String,
        parametersJSON: @autoclosure () -> Data
    ) -> LLMToolSchema? {
        guard requestedNames?.contains(name) != false else { return nil }
        return LLMToolSchema(
            name: name,
            toolClass: toolClass,
            reach: reach,
            capabilities: capabilities ?? toolClass.baseCapabilities,
            effectInputPolicy: effectInputPolicy,
            description: description(),
            parametersJSON: parametersJSON()
        )
    }



    // Recall has mutually exclusive search/page fields. Responses may
    // require every property on the wire, so unused fields must admit
    // null rather than forcing invented strings or integer placeholders.
    func nullableRecallField(_ schema: JSONValue) -> JSONValue {
        guard case .object(var properties) = schema,
              case .string(let type)? = properties["type"] else { return schema }
        properties["type"] = .array([.string(type), .string("null")])
        return .object(properties)
    }

    /// An enum field that may also be null: `type` admits null AND `null`
    /// is a member of `enum`, because a JSON Schema `enum` is exhaustive —
    /// widening `type` alone would still reject null.
    func nullableEnumStringSchema(_ values: [String], _ desc: String) -> JSONValue {
        ToolSchema.obj([
            ("type", .array([.string("string"), .string("null")])),
            ("enum", .array(values.map(JSONValue.string) + [.null])),
            ("description", .string(desc)),
        ])
    }


    func numSchema(
        _ desc: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONValue {
        var props: [(String, JSONValue)] = [("type", .string("number"))]
        if let minimum { props.append(("minimum", .double(minimum))) }
        if let maximum { props.append(("maximum", .double(maximum))) }
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    func stringArraySchema(
        _ desc: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        maxItemLength: Int? = nil
    ) -> JSONValue {
        var itemProps: [(String, JSONValue)] = [("type", .string("string"))]
        if let maxItemLength { itemProps.append(("maxLength", .int(Int64(maxItemLength)))) }
        var props: [(String, JSONValue)] = [
            ("type", .string("array")),
            ("items", ToolSchema.obj(itemProps)),
        ]
        // A bound the validator enforces must also be a bound the schema
        // STATES, or the model only discovers it by being refused.
        if let minItems { props.append(("minItems", .int(Int64(minItems)))) }
        if let maxItems { props.append(("maxItems", .int(Int64(maxItems)))) }
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    // Mail and notification recipients accept either a string or an array.
    func stringOrStringArraySchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("anyOf", .array([
                ToolSchema.obj([("type", .string("string"))]),
                ToolSchema.obj([
                    ("type", .string("array")),
                    ("items", ToolSchema.obj([("type", .string("string"))])),
                ]),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    // Date fields accept ISO-8601 strings or epoch integers.
    func stringOrIntSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("anyOf", .array([
                ToolSchema.obj([("type", .string("string"))]),
                ToolSchema.obj([("type", .string("integer"))]),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    func looseObjectSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("type", .string("object")),
            ("additionalProperties", .bool(true)),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    func stringOrLooseObjectSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("anyOf", .array([ToolSchema.strSchema(), looseObjectSchema(), ToolSchema.obj([("type", .string("null"))])])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }
    func looseObjectArraySchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("type", .string("array")),
            ("items", ToolSchema.obj([
                ("type", .string("object")),
                ("additionalProperties", .bool(true)),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return ToolSchema.obj(props)
    }

    func nonEmptyStringSchema(_ description: String) -> JSONValue {
        ToolSchema.obj([
            ("type", .string("string")),
            ("minLength", .int(1)),
            ("description", .string(description)),
        ])
    }
    func conversationModeSchema() -> JSONValue {
        ToolSchema.enumStringSchema(
            ["new", "resume"],
            "Choose new for unrelated work and omit conversation_id. Choose resume only for a contextual follow-up and pass the exact conversationId returned by this same tool. Omit this field for backward-compatible inference."
        )
    }
    func conversationReferenceSchema(_ agent: String, _ tool: String) -> JSONValue {
        ToolSchema.strSchema(
            "Resume only: exact \(agent):… conversationId returned by an earlier \(tool). "
            + "For new work omit this field, or send an empty string when the caller serializes every optional field. "
            + "Never invent a placeholder or pass this NativeAgent conversation's session_id."
        )
    }

    func recallParameters() -> Data {
        ToolSchema.params(
            properties: [
                ("query", nullableRecallField(ToolSchema.strSchema("Search text; null in ID page mode."))),
                ("k", nullableRecallField(ToolSchema.intSchema("Search result count, default 5; null in ID page mode."))),
                ("memory_id", nullableRecallField(ToolSchema.strSchema("Exact id from a recall hit; null in search mode. Set query/k to null when paging."))),
                ("offset", nullableRecallField(ToolSchema.intSchema("ID mode only: character offset, default 0; follow next_offset. Null in search mode."))),
                ("max_characters", nullableRecallField(ToolSchema.intSchema("ID mode only: positive page size, capped at 2000. Null in search mode."))),
                ("expected_content_sha256", nullableRecallField(ToolSchema.strSchema("ID mode: content_sha256 from the previous page, supplied by read_more. Null for a first page or search. A mismatch returns record_changed without text."))),
            ],
            required: []
        )
    }

    package func schemas(
        includeFullMacFileTools: Bool,
        includeFullMacSystemTools: Bool,
        includeFullMacAccessibilityReadTools: Bool,
        includeFullMacAccessibilityInjectionTools: Bool,
        includeActivityQueryTool: Bool
    ) -> [LLMToolSchema] {
        var schemas = coreSchemas()
        schemas.append(contentsOf: standingBotSchemas())
        schemas.append(contentsOf: agentCommunicationSchemas())
        appendOptionalSchemas(
            to: &schemas,
            includeFullMacFileTools: includeFullMacFileTools,
            includeFullMacSystemTools: includeFullMacSystemTools,
            includeFullMacAccessibilityReadTools: includeFullMacAccessibilityReadTools,
            includeFullMacAccessibilityInjectionTools: includeFullMacAccessibilityInjectionTools,
            includeActivityQueryTool: includeActivityQueryTool
        )
        return schemas.compactMap { $0 }
    }
}
