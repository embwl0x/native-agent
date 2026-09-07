import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

/// Per-request schema construction; descriptions and parameters stay lazy.
struct BuiltInToolSchemaFactory {
    let requestedNames: Set<String>?

    func requestedSchema(
        name: String,
        description: @autoclosure () -> String,
        parametersJSON: @autoclosure () -> Data
    ) -> LLMToolSchema? {
        guard requestedNames?.contains(name) != false else { return nil }
        return LLMToolSchema(
            name: name,
            description: description(),
            parametersJSON: parametersJSON()
        )
    }

    func obj(_ pairs: [(String, JSONValue)]) -> JSONValue {
        var d: [String: JSONValue] = [:]
        for (k, v) in pairs { d[k] = v }
        return .object(d)
    }
    func strSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [("type", .string("string"))]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
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
    func enumStringSchema(_ values: [String], _ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("type", .string("string")),
            ("enum", .array(values.map(JSONValue.string))),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    /// An enum field that may also be null: `type` admits null AND `null`
    /// is a member of `enum`, because a JSON Schema `enum` is exhaustive —
    /// widening `type` alone would still reject null.
    func nullableEnumStringSchema(_ values: [String], _ desc: String) -> JSONValue {
        obj([
            ("type", .array([.string("string"), .string("null")])),
            ("enum", .array(values.map(JSONValue.string) + [.null])),
            ("description", .string(desc)),
        ])
    }
    func intSchema(
        _ desc: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONValue {
        var props: [(String, JSONValue)] = [("type", .string("integer"))]
        if let minimum { props.append(("minimum", .int(Int64(minimum)))) }
        if let maximum { props.append(("maximum", .int(Int64(maximum)))) }
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    func boolSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [("type", .string("boolean"))]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
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
        return obj(props)
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
            ("items", obj(itemProps)),
        ]
        // A bound the validator enforces must also be a bound the schema
        // STATES, or the model only discovers it by being refused.
        if let minItems { props.append(("minItems", .int(Int64(minItems)))) }
        if let maxItems { props.append(("maxItems", .int(Int64(maxItems)))) }
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    // Mail and notification recipients accept either a string or an array.
    func stringOrStringArraySchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("anyOf", .array([
                obj([("type", .string("string"))]),
                obj([
                    ("type", .string("array")),
                    ("items", obj([("type", .string("string"))])),
                ]),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    // Date fields accept ISO-8601 strings or epoch integers.
    func stringOrIntSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("anyOf", .array([
                obj([("type", .string("string"))]),
                obj([("type", .string("integer"))]),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    func looseObjectSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("type", .string("object")),
            ("additionalProperties", .bool(true)),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    func looseObjectArraySchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("type", .string("array")),
            ("items", obj([
                ("type", .string("object")),
                ("additionalProperties", .bool(true)),
            ])),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    // Encode parameters once per requested tool.
    func params(properties: [(String, JSONValue)], required: [String]) -> Data {
        let v = obj([
            ("type", .string("object")),
            ("properties", obj(properties)),
            ("required", .array(required.map { .string($0) })),
        ])
        // serializedData throws only on un-serializable JSONValue payloads;
        // ours are plain string/array/object literals, so this never throws
        // in practice. Fail-soft to `{}` to avoid crashing the chat turn.
        return (try? v.serializedData(pretty: false)) ?? Data("{}".utf8)
    }
    func nonEmptyStringSchema(_ description: String) -> JSONValue {
        obj([
            ("type", .string("string")),
            ("minLength", .int(1)),
            ("description", .string(description)),
        ])
    }
    func conversationModeSchema() -> JSONValue {
        enumStringSchema(
            ["new", "resume"],
            "Choose new for unrelated work and omit conversation_id. Choose resume only for a contextual follow-up and pass the exact conversationId returned by this same tool. Omit this field for backward-compatible inference."
        )
    }
    func conversationReferenceSchema(_ agent: String, _ tool: String) -> JSONValue {
        strSchema(
            "Resume only: exact \(agent):… conversationId returned by an earlier \(tool). "
            + "For new work omit this field, or send an empty string when the caller serializes every optional field. "
            + "Never invent a placeholder and never pass the originating chat session id."
        )
    }

    func recallParameters() -> Data {
        params(
            properties: [
                ("query", nullableRecallField(strSchema("Search text; null in ID page mode."))),
                ("k", nullableRecallField(intSchema("Search result count, default 5; null in ID page mode."))),
                ("memory_id", nullableRecallField(strSchema("Exact id from a recall hit; null in search mode. Set query/k to null when paging."))),
                ("offset", nullableRecallField(intSchema("ID mode only: character offset, default 0; follow next_offset. Null in search mode."))),
                ("max_characters", nullableRecallField(intSchema("ID mode only: positive page size, capped at 2000. Null in search mode."))),
                ("expected_content_sha256", nullableRecallField(strSchema("ID mode: content_sha256 from the previous page, supplied by read_more. Null for a first page or search. A mismatch returns record_changed without text."))),
            ],
            required: []
        )
    }

    func schemas(
        includeFullMacFileTools: Bool,
        includeFullMacSystemTools: Bool,
        includeFullMacAppTools: Bool,
        includeFullMacAccessibilityReadTools: Bool,
        includeFullMacAccessibilityInjectionTools: Bool,
        includeActivityQueryTool: Bool
    ) -> [LLMToolSchema] {
        var schemas = coreSchemas()
        appendOptionalSchemas(
            to: &schemas,
            includeFullMacFileTools: includeFullMacFileTools,
            includeFullMacSystemTools: includeFullMacSystemTools,
            includeFullMacAppTools: includeFullMacAppTools,
            includeFullMacAccessibilityReadTools: includeFullMacAccessibilityReadTools,
            includeFullMacAccessibilityInjectionTools: includeFullMacAccessibilityInjectionTools,
            includeActivityQueryTool: includeActivityQueryTool
        )
        return schemas.compactMap { $0 }
    }
}
