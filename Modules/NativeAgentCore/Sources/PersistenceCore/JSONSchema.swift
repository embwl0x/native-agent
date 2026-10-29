import Foundation
// Blueprint: | `JSONSchema.swift` | `JSONValue.SchemaProblem`, `validate`, `schemaProblem`: whole-tree schema preflight and value validation, ignoring unknown keywords with caller-owned error formatting; `ToolSchema` shared nullable/object/string/boolean/integer/enum/parameter constructors |

extension JSONValue {
    public struct SchemaProblem: Sendable {
        public let path: String
        public let keyword: String
        public let expected: String
    }

    public func validate(schema: JSONValue) throws {
        if let problem = schemaProblem(schema: schema) {
            throw PersistenceCoreError.ioFailure("JSON schema: \(problem.path.isEmpty ? "value" : problem.path) must be \(problem.expected)")
        }
    }

    /// Check the entire schema before matching values, including unused branches.
    /// Callers own error wording. Unknown keywords are ignored; enforced rules must be valid.
    public func schemaProblem(schema: JSONValue, path: String = "") -> SchemaProblem? {
        func number(_ value: JSONValue?) -> Double? {
            switch value { case .int(let n)?: Double(n); case .double(let n)?: n; default: nil }
        }
        func list(_ value: JSONValue) -> [JSONValue] { if case .array(let values) = value { values } else { [value] } }
        func schemaError(_ schema: JSONValue, _ at: String) -> SchemaProblem? {
            func bad(_ expected: String) -> SchemaProblem { .init(path: at, keyword: "schema", expected: expected) }
            if case .bool = schema { return nil }
            guard case .object(let rules) = schema else { return bad("an object or boolean schema") }
            for key in rules.keys.sorted() {
                let rule = rules[key]!
                switch key {
                case "type":
                    let types = list(rule)
                    guard !types.isEmpty, types.allSatisfy({
                        if case .string(let type) = $0 { return ["string", "boolean", "integer", "number", "object", "array", "null"].contains(type) }
                        return false
                    }) else { return bad("a known type or nonempty type array") }
                case "required", "enum", "allOf", "anyOf", "oneOf":
                    guard case .array(let values) = rule else { return bad("an array for \(key)") }
                    if key == "required", !values.allSatisfy({ if case .string = $0 { true } else { false } }) { return bad("string required names") }
                    if ["allOf", "anyOf", "oneOf"].contains(key) {
                        guard !values.isEmpty else { return bad("nonempty \(key)") }
                        for (index, child) in values.enumerated() {
                            if let error = schemaError(child, "\(at).\(key)[\(index)]") { return error }
                        }
                    }
                case "properties":
                    guard case .object(let properties) = rule else { return bad("an object for properties") }
                    for name in properties.keys.sorted() {
                        if let error = schemaError(properties[name]!, at + ".properties." + name) { return error }
                    }
                case "items", "additionalProperties", "not":
                    // Draft-07 tuple form: items is a list of schemas, one per position.
                    if key == "items", case .array(let positions) = rule {
                        for (index, child) in positions.enumerated() {
                            if let error = schemaError(child, "\(at).items[\(index)]") { return error }
                        }
                    } else if let error = schemaError(rule, at + "." + key) { return error }
                case "minItems", "maxItems", "minLength", "maxLength", "minProperties", "maxProperties":
                    guard let n = number(rule), n.isFinite, n >= 0, n.rounded() == n else { return bad("a nonnegative integer for \(key)") }
                case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf":
                    guard let n = number(rule), n.isFinite, key != "multipleOf" || n > 0 else { return bad("a valid numeric \(key)") }
                case "uniqueItems":
                    guard case .bool = rule else { return bad("a boolean for uniqueItems") }
                case "pattern":
                    guard case .string(let pattern) = rule, (try? NSRegularExpression(pattern: pattern)) != nil else { return bad("a valid regular expression") }
                default: break
                }
            }
            return nil
        }
        func check(_ value: JSONValue, _ schema: JSONValue, _ at: String) -> SchemaProblem? {
            func bad(_ key: String, _ expected: String, at child: String? = nil) -> SchemaProblem {
                .init(path: child ?? at, keyword: key, expected: expected)
            }
            func childPath(_ key: String) -> String { at.isEmpty ? key : at + "." + key }
            if case .bool(let allowed) = schema { return allowed ? nil : bad("false", "allowed by the schema") }
            guard case .object(let rules) = schema else { return nil } // Checked above.
            if case .array(let choices)? = rules["allOf"] {
                for choice in choices { if let problem = check(value, choice, at) { return problem } }
            }
            for key in ["anyOf", "oneOf"] {
                if case .array(let choices)? = rules[key] {
                    let problems = choices.compactMap { check(value, $0, at) }
                    if problems.count == choices.count { return bad(key, problems.map(\.expected).joined(separator: " or ")) }
                    if key == "oneOf", choices.count - problems.count != 1 { return bad(key, "exactly one accepted alternative") }
                }
            }
            if let child = rules["not"], check(value, child, at) == nil { return bad("not", "outside the forbidden combination") }
            if let fixed = rules["const"], fixed != value { return bad("const", "\(fixed)") }
            if case .array(let options)? = rules["enum"], !options.contains(value) {
                return bad("enum", options.map { if case .string(let text) = $0 { text } else { String(describing: $0) } }.joined(separator: " or "))
            }
            if let declared = rules["type"] {
                let types = list(declared)
                let matches = types.contains { type in
                    switch (type, value) {
                    case (.string("string"), .string), (.string("boolean"), .bool), (.string("integer"), .int),
                         (.string("number"), .int), (.string("number"), .double), (.string("object"), .object),
                         (.string("array"), .array), (.string("null"), .null): return true
                    case (.string("integer"), .double(let n)): return n.isFinite && n.rounded() == n
                    default: return false
                    }
                }
                if !matches { return bad("type", types.compactMap { if case .string(let text) = $0 { text } else { nil } }.joined(separator: " or ")) }
            }
            func bounds(_ count: Int, _ minimum: String, _ maximum: String, _ unit: String) -> SchemaProblem? {
                if let n = number(rules[minimum]), Double(count) < n { return bad(minimum, "at least \(Int64(exactly: n).map(String.init) ?? String(n)) \(unit)") }
                if let n = number(rules[maximum]), Double(count) > n { return bad(maximum, "at most \(Int64(exactly: n).map(String.init) ?? String(n)) \(unit)") }
                return nil
            }
            switch value {
            case .object(let object):
                if let problem = bounds(object.count, "minProperties", "maxProperties", "properties") { return problem }
                if case .array(let required)? = rules["required"] {
                    for case .string(let key) in required where object[key] == nil { return bad("required", "present", at: childPath(key)) }
                }
                let properties: [String: JSONValue] = if case .object(let fields)? = rules["properties"] { fields } else { [:] }
                for key in object.keys.sorted() {
                    if properties[key] == nil, rules["additionalProperties"] == .bool(false) { return bad("additionalProperties", "an accepted argument", at: childPath(key)) }
                    if let rule = properties[key] ?? rules["additionalProperties"], let problem = check(object[key]!, rule, childPath(key)) { return problem }
                }
            case .array(let items):
                if let problem = bounds(items.count, "minItems", "maxItems", "items") ?? (rules["uniqueItems"] == .bool(true) && Set(items).count != items.count ? bad("uniqueItems", "unique items") : nil) { return problem }
                if case .array(let positions)? = rules["items"] {
                    for (index, item) in items.enumerated() where index < positions.count {
                        if let problem = check(item, positions[index], "\(at)[\(index)]") { return problem }
                    }
                } else if let rule = rules["items"] {
                    for (index, item) in items.enumerated() { if let problem = check(item, rule, "\(at)[\(index)]") { return problem } }
                }
            case .string(let text):
                if let problem = bounds(text.unicodeScalars.count, "minLength", "maxLength", "characters") { return problem }
                if case .string(let pattern)? = rules["pattern"], let regex = try? NSRegularExpression(pattern: pattern),
                   regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { return bad("pattern", "matching \(pattern)") }
            case .int, .double:
                let n = number(value)!
                for (key, failed) in [("minimum", n < (number(rules["minimum"]) ?? -.infinity)),
                    ("maximum", n > (number(rules["maximum"]) ?? .infinity)),
                    ("exclusiveMinimum", n <= (number(rules["exclusiveMinimum"]) ?? -.infinity)),
                    ("exclusiveMaximum", n >= (number(rules["exclusiveMaximum"]) ?? .infinity))] where failed { return bad(key, "within \(key)") }
                if let step = number(rules["multipleOf"]), abs(n / step - (n / step).rounded()) > 1e-10 { return bad("multipleOf", "a multiple of \(step)") }
            default: break
            }
            return nil
        }
        return schemaError(schema, path) ?? check(self, schema, path)
    }
}

/// Shared JSON-schema constructors; each tool owner still supplies its own schema.
package enum ToolSchema {
    /// Admit null once, preserving constraints and composite alternatives.
    package static func nullable(_ schema: JSONValue) -> JSONValue {
        if JSONValue.null.schemaProblem(schema: schema) == nil { return schema }
        if case .object(var fields) = schema, let type = fields["type"],
           ["anyOf", "oneOf", "allOf", "not", "const"].allSatisfy({ fields[$0] == nil }) {
            var types: [JSONValue] = if case .array(let values) = type { values } else { [type] }
            if !types.contains(.string("null")) { types.append(.string("null")) }
            fields["type"] = .array(types)
            if case .array(var values)? = fields["enum"], !values.contains(.null) {
                values.append(.null)
                fields["enum"] = .array(values)
            }
            return .object(fields)
        }
        return obj([("anyOf", .array([schema, obj([("type", .string("null"))])]))])
    }

    package static func obj(_ pairs: [(String, JSONValue)]) -> JSONValue {
        var d: [String: JSONValue] = [:]
        for (k, v) in pairs { d[k] = v }
        return .object(d)
    }
    package static func strSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [("type", .string("string"))]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    package static func enumStringSchema(_ values: [String], _ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("type", .string("string")),
            ("enum", .array(values.map(JSONValue.string))),
        ]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    package static func intSchema(
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
    package static func boolSchema(_ desc: String? = nil) -> JSONValue {
        var props: [(String, JSONValue)] = [("type", .string("boolean"))]
        if let desc { props.append(("description", .string(desc))) }
        return obj(props)
    }
    package static func params(properties: [(String, JSONValue)], required: [String]) -> Data {
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
}
