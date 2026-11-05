import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ToolSignature.swift` | `call`, `doorArgs`: checked argument shapes |
// Required object names remain renderable without properties; explicit open-object door shapes preserve unconstrained arguments.

/// Required fields lead, session fields stay hidden, and the rendered argument line remains copyable.
public enum ToolSignature {
    private static func properties(_ data: Data) throws -> (props: [String: [String: Any]], required: Set<String>) {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolFailureError("The tool's parameter schema is not an object. Repair its schema before reading its arguments or running it.",
                effects: .none, code: "tool_schema_unavailable")
        }
        // JSON Schema permits an object without named property declarations, including a required list whose values are otherwise unconstrained.
        let props: [String: Any]
        if let value = raw["properties"] {
            guard let declared = value as? [String: Any] else {
                throw ToolFailureError("The tool's parameter schema properties are not an object. Repair its schema before using it.", effects: .none,
                    code: "tool_schema_unavailable")
            }
            props = declared
        } else { props = [:] }
        let required: Set<String>
        if let value = raw["required"] {
            guard let names = value as? [String] else {
                throw ToolFailureError("The tool's required-argument schema is not a list of names. Repair its schema before using it.", effects: .none,
                    code: "tool_schema_unavailable")
            }
            required = Set(names)
        } else { required = [] }
        var visible: [String: [String: Any]] = [:]
        for (key, value) in props {
            guard let property = value as? [String: Any] else {
                throw ToolFailureError("The tool's parameter schema property \(key) is not an object. Repair its schema before using it.", effects: .none,
                    code: "tool_schema_unavailable")
            }
            let about = (property["description"] as? String ?? "").lowercased()
            if key == "__session_id" || about.contains("auto-fill") || about.contains("supplied automatically") { continue }
            visible[key] = property
        }
        for key in required where props[key] == nil && key != "__session_id" {
            visible[key] = [:] // A required name with no property schema accepts any value.
        }
        return (visible, required)
    }

    private static func ordered(_ props: [String: [String: Any]], _ required: Set<String>) -> [String] {
        props.keys.sorted { a, b in required.contains(a) != required.contains(b) ? required.contains(a) : a < b }
    }

    private static func type(_ property: [String: Any]) -> String? {
        if let type = property["type"] as? String { return type }
        if let types = property["type"] as? [String] { return types.first { $0 != "null" } }
        if let any = (property["anyOf"] ?? property["oneOf"]) as? [[String: Any]] {
            return any.compactMap(type).first { $0 != "null" }
        }
        return nil
    }

    private static func shape(_ property: [String: Any], depth: Int = 0) -> String {
        if let alternatives = (property["anyOf"] ?? property["oneOf"]) as? [[String: Any]] {
            let shapes = alternatives.filter { type($0) != "null" }.map { shape($0, depth: depth) }
            if !shapes.isEmpty { return shapes.joined(separator: "|") }
        }
        switch type(property) {
        case "integer": return "int"
        case "number": return "num"
        case "boolean": return "bool"
        case "array":
            let items = property["items"] as? [String: Any] ?? [:]
            return "[" + (depth > 1 ? "…" : shape(items, depth: depth + 1)) + "]"
        case "object":
            if (property["properties"] as? [String: Any])?.isEmpty != false,
               property["additionalProperties"] as? Bool == true { return "object*" }
            guard depth <= 1, let props = property["properties"] as? [String: Any], !props.isEmpty else { return "{}" }
            let required = Set(property["required"] as? [String] ?? [])
            let keys = props.keys.sorted { a, b in required.contains(a) != required.contains(b) ? required.contains(a) : a < b }
            return "{" + keys.map { $0 + (required.contains($0) ? "*" : "") }.joined(separator: ",") + "}"
        default:
            if let values = property["enum"] as? [String], (1...8).contains(values.count) { return values.joined(separator: "|") }
            return type(property) == nil ? "any" : "str"
        }
    }

    public static func call(_ name: String, _ parametersJSON: Data) throws -> String {
        let (props, required) = try properties(parametersJSON)
        let parts = ordered(props, required).map { key -> String in
            let property = props[key] ?? [:]
            let mark = required.contains(key) ? "*" : ""
            let form = shape(property)
            if form == "str" { return key + mark }
            if property["enum"] != nil, !form.hasPrefix("[") { return key + mark + "=" + form }
            return key + mark + ":" + form
        }
        return name + "(" + parts.joined(separator: ", ") + ")"
    }

    /// Use `?` only for omittable/null fields and omit `:str` to keep action signatures compact.
    public static func doorArgs(_ parametersJSON: Data) throws -> [String] {
        let (props, required) = try properties(parametersJSON)
        return ordered(props, required).map { key in
            let property = props[key] ?? [:]
            let nullable = (property["type"] as? [String])?.contains("null") == true
            let form = shape(property)
            return key + (required.contains(key) && !nullable ? "" : "?") + (form == "str" ? "" : ":" + form)
        }
    }

    /// Use explicit door shapes when buttons have no native parameter schema.
    public static func doorProperty(_ shape: String) -> JSONValue {
        if shape == "any" { return .object([:]) }
        if shape == "list" { return .object(["type": .string("array")]) }
        if shape == "object*" { return .object(["type": .string("object"), "additionalProperties": .bool(true)]) }
        if shape.hasPrefix("["), shape.hasSuffix("]") {
            return .object(["type": .string("array"),
                "items": doorProperty(String(shape.dropFirst().dropLast()))])
        }
        if shape.hasPrefix("{") {
            return .object(["type": .string("object")])
        }
        if shape.contains("|") {
            return .object(["type": .string("string"),
                "enum": .array(shape.split(separator: "|").map { .string(String($0)) })])
        }
        // Short names and JSON Schema's own both name a type; an unlisted name silently made offset?:number a string ("0").
        let type = ["int": "integer", "integer": "integer", "num": "number", "number": "number", "bool": "boolean", "boolean": "boolean",
                    "object": "object", "array": "array"][shape] ?? "string"
        return .object(["type": .string(type)])
    }

    /// Examples use angle brackets to distinguish caller-supplied values.
    public static func example(_ schema: JSONValue, name: String) -> JSONValue {
        guard case .object(let props) = schema else { return .string("<\(name)>") }
        if let value = props["const"] { return value }
        if case .array(let values)? = props["enum"], let value = values.first(where: { $0 != .null }) { return value }
        for key in ["anyOf", "oneOf"] {
            if case .array(let variants)? = props[key], let first = variants.first(where: {
                if case .object(let fields) = $0 { return fields["type"] != .string("null") }
                return false
            }) { return example(first, name: name) }
        }
        let type: String = if case .string(let value)? = props["type"] { value }
            else if case .array(let values)? = props["type"] {
                values.compactMap { if case .string(let value) = $0, value != "null" { value } else { nil } }.first ?? "string"
            } else { "string" }
        switch type {
        case "boolean": return .bool(false)
        case "integer", "number": return props["minimum"] ?? .int(0)
        case "array": return .array([example(props["items"] ?? .object([:]), name: name)])
        case "object":
            let fields = if case .object(let fields)? = props["properties"] { fields } else { [String: JSONValue]() }
            let required = if case .array(let required)? = props["required"] { required } else { [JSONValue]() }
            return .object(Dictionary(required.compactMap {
                guard case .string(let key) = $0 else { return nil }
                return (key, example(fields[key] ?? .object([:]), name: key))
            }, uniquingKeysWith: { first, _ in first }))
        default: return .string("<\(name)>")
        }
    }

    /// Match signature argument order and omit auto-filled fields so field help agrees with callable input.
    public static func argumentNames(_ parametersJSON: Data) throws -> (required: [String], optional: [String]) {
        let (props, required) = try properties(parametersJSON)
        let all = ordered(props, required)
        return (all.filter(required.contains), all.filter { !required.contains($0) })
    }

    public static func params(_ parametersJSON: Data, limit: Int = 90) throws -> [String] {
        let (props, required) = try properties(parametersJSON)
        return ordered(props, required).compactMap { key in
            guard let about = (props[key]?["description"] as? String)?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces), !about.isEmpty else { return nil }
            return key + ": " + (about.count > limit ? String(about.prefix(limit - 1)) + "…" : about)
        }
    }
}
