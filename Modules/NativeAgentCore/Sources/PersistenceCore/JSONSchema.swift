import Foundation
// Blueprint: | `JSONSchema.swift` | `JSONValue.SchemaProblem`, `validate`, `schemaProblem`, `ToolSchema`; Validate complete schemas. |

extension JSONValue {
    public struct SchemaProblem: Sendable {
        public let path: String
        public let keyword: String
        /// The accepted shape, in words.
        public let expected: String
        /// The whole refusal in words: every problem with the value, each once, with its accepted shape.
        public let words: String
    }

    public func validate(schema: JSONValue) throws {
        if let problem = schemaProblem(schema: schema) {
            throw PersistenceCoreError.ioFailure("JSON schema: \(problem.words)")
        }
    }

    /// Check the entire schema before matching values, including unused branches. Unknown keywords are ignored; enforced rules must be valid.
    /// One problem names every fault in the value at once, each once: `words` is the refusal, `expected` the accepted shape, `path` where it applies.
    public func schemaProblem(schema: JSONValue, path: String = "") -> SchemaProblem? {
        func number(_ value: JSONValue?) -> Double? {
            switch value { case .int(let n)?: Double(n); case .double(let n)?: n; default: nil }
        }
        func list(_ value: JSONValue) -> [JSONValue] { if case .array(let values) = value { values } else { [value] } }
        func numeral(_ n: Double) -> String { Int64(exactly: n).map(String.init) ?? String(n) }
        func unique(_ items: [String]) -> [String] {
            var seen = Set<String>()
            return items.filter { seen.insert($0).inserted }
        }
        func named(_ at: String) -> String { at.isEmpty ? "value" : at }
        // A path's depth counts its steps, so the alternative whose problems reach deepest into the value is the closest one.
        func depth(_ at: String) -> Int { at.filter { $0 == "." || $0 == "[" }.count }
        func literal(_ value: JSONValue, quoted: Bool) -> String {
            switch value {
            case .string(let text): quoted ? "\"\(text)\"" : text
            case .int(let n): String(n)
            case .double(let n): numeral(n)
            case .bool(let flag): String(flag)
            case .null: "null"
            case .array: "a list"
            case .object: "an object"
            }
        }
        // A refusal says what it got as well as what it takes.
        func found(_ value: JSONValue) -> String {
            if case .string(let text) = value { return text.count <= 40 ? "\"\(text)\"" : "a string" }
            return literal(value, quoted: true)
        }
        // The accepted shape as a short example: enum values listed, an object's fields named (optional ones with ?), alternatives deduplicated.
        func shape(_ schema: JSONValue, _ level: Int = 0) -> String {
            guard case .object(let rules) = schema else { return schema == .bool(false) ? "nothing" : "any value" }
            if let fixed = rules["const"] { return literal(fixed, quoted: true) }
            if case .array(let options)? = rules["enum"] {
                let names = unique(options.map { literal($0, quoted: false) })
                if names.count == 1 { return names[0] }
                return level > 1 && names.count > 5 ? "one of \(names.count) names" : "one of: " + names.joined(separator: ", ")
            }
            for key in ["anyOf", "oneOf"] {
                if case .array(let choices)? = rules[key] {
                    let forms = unique(choices.map { shape($0, level + 1) }).joined(separator: " or ")
                    return level > 0 ? "(\(forms))" : forms
                }
            }
            if rules["type"] == nil, case .array(let parts)? = rules["allOf"] {
                return unique(parts.map { shape($0, level) }).joined(separator: " and ")
            }
            var types: [String] = list(rules["type"] ?? .array([])).compactMap { if case .string(let type) = $0 { type } else { nil } }
            if types.isEmpty, rules["properties"] != nil || rules["additionalProperties"] != nil { types = ["object"] }
            if types.isEmpty, rules["items"] != nil { types = ["array"] }
            guard !types.isEmpty else { return "any value" }
            return unique(types.map { type -> String in
                switch type {
                case "string": return "a string"
                case "integer": return "an integer"
                case "number": return "a number"
                case "boolean": return "true or false"
                case "null": return "null"
                case "array":
                    guard level < 3, let items = rules["items"], case .object = items else { return "a list" }
                    return "a list, each " + shape(items, level + 1)
                default:
                    if case .object(let fields)? = rules["properties"], !fields.isEmpty {
                        guard level < 3 else { return "an object" }
                        let required = list(rules["required"] ?? .array([])).compactMap { name -> String? in
                            if case .string(let key) = name, fields[key] != nil { return key }
                            return nil
                        }
                        func field(_ key: String, _ mark: String) -> String {
                            if case .object(let rule)? = fields[key], let fixed = rule["const"] { return key + mark + ":" + literal(fixed, quoted: true) }
                            return key + mark
                        }
                        let optional = fields.keys.filter { !required.contains($0) }.sorted()
                        return "{" + (unique(required).map { field($0, "") } + optional.map { field($0, "?") }).joined(separator: ", ") + "}"
                    }
                    if let extra = rules["additionalProperties"], case .object = extra, level < 3 {
                        return "an object of name → " + shape(extra, level + 1)
                    }
                    return "an object"
                }
            }).joined(separator: " or ")
        }
        func schemaError(_ schema: JSONValue, _ at: String) -> SchemaProblem? {
            func bad(_ expected: String) -> SchemaProblem {
                .init(path: at, keyword: "schema", expected: expected, words: "the schema at \(at.isEmpty ? "its root" : at) must be \(expected)")
            }
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
                    guard case .string(let pattern) = rule, (try? NSRegularExpression(pattern: pattern)) != nil else { return bad(
                        "a valid regular expression") }
                default: break
                }
            }
            return nil
        }
        // Every problem in the value, each where it applies: a node whose form fails says so once; its fields and items are judged together.
        func check(_ value: JSONValue, _ schema: JSONValue, _ at: String) -> [SchemaProblem] {
            let here = named(at)
            func bad(_ key: String, _ expected: String, _ words: String, at child: String? = nil) -> [SchemaProblem] {
                [.init(path: child ?? at, keyword: key, expected: expected, words: words)]
            }
            func childPath(_ key: String) -> String { at.isEmpty ? key : at + "." + key }
            if case .bool(let allowed) = schema { return allowed ? [] : bad("false", "absent", "\(here) is not accepted here") }
            guard case .object(let rules) = schema else { return [] }
            if case .array(let choices)? = rules["allOf"] {
                let problems = choices.flatMap { check(value, $0, at) }
                if !problems.isEmpty { return problems }
            }
            for key in ["anyOf", "oneOf"] {
                guard case .array(let choices)? = rules[key] else { continue }
                let results = choices.map { check(value, $0, at) }
                let accepted = results.filter(\.isEmpty).count
                // Alternatives are named once each by their shape, never by a dump of every alternative's own refusal.
                let forms = unique(choices.map { shape($0) }).joined(separator: " or ")
                if accepted == 0 {
                    var words = "\(here) is none of its accepted forms: \(forms)"
                    let reach = results.map { $0.map { depth($0.path) }.max() ?? 0 }
                    if let deepest = reach.max(), deepest > depth(at), reach.filter({ $0 == deepest }).count == 1,
                       let closest = reach.firstIndex(of: deepest) {
                        words += ". In the closest form, " + results[closest].map(\.words).joined(separator: "; ")
                    }
                    return bad(key, forms, words)
                }
                if key == "oneOf", accepted != 1 {
                    return bad(key, "exactly one of: \(forms)", "\(here) matches \(accepted) of its forms; it must match exactly one of: \(forms)")
                }
            }
            if let child = rules["not"], check(value, child, at).isEmpty {
                return bad("not", "outside the forbidden combination", "\(here) must be outside the forbidden combination")
            }
            if let fixed = rules["const"], fixed != value {
                let expected = literal(fixed, quoted: true)
                return bad("const", expected, "\(here) must be \(expected); got \(found(value))")
            }
            if case .array(let options)? = rules["enum"], !options.contains(value) {
                let expected = "one of: " + unique(options.map { literal($0, quoted: false) }).joined(separator: ", ")
                return bad("enum", expected, "\(here) must be \(expected); got \(found(value))")
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
                if !matches {
                    let expected = shape(schema)
                    return bad("type", expected, "\(here) must be \(expected); got \(found(value))")
                }
            }
            var problems: [SchemaProblem] = []
            func bounds(_ count: Int, _ minimum: String, _ maximum: String, _ unit: String) {
                if let n = number(rules[minimum]), Double(count) < n {
                    problems += bad(minimum, "at least \(numeral(n)) \(unit)", "\(here) must have at least \(numeral(n)) \(unit); got \(count)")
                }
                if let n = number(rules[maximum]), Double(count) > n {
                    problems += bad(maximum, "at most \(numeral(n)) \(unit)", "\(here) must have at most \(numeral(n)) \(unit); got \(count)")
                }
            }
            switch value {
            case .object(let object):
                bounds(object.count, "minProperties", "maxProperties", "properties")
                let properties: [String: JSONValue] = if case .object(let fields)? = rules["properties"] { fields } else { [:] }
                if case .array(let required)? = rules["required"] {
                    for case .string(let key) in required where object[key] == nil {
                        let expected = properties[key].map { shape($0) } ?? "a value"
                        problems += bad("required", expected, "\(childPath(key)) is missing; it takes \(expected)", at: childPath(key))
                    }
                }
                let names = properties.keys.sorted().joined(separator: ", ")
                for key in object.keys.sorted() {
                    // An unknown key is answered with what is accepted, so the caller can correct it without another read.
                    if properties[key] == nil, rules["additionalProperties"] == .bool(false) {
                        problems += properties.isEmpty
                            ? bad("additionalProperties", "absent: no field is accepted here", "\(childPath(key)) is not accepted: no field is accepted here",
                                at: childPath(key))
                            : bad("additionalProperties", "one of: " + names, "\(childPath(key)) is not accepted here; accepted: " + names, at: childPath(key))
                    } else if let rule = properties[key] ?? rules["additionalProperties"] {
                        problems += check(object[key]!, rule, childPath(key))
                    }
                }
            case .array(let items):
                bounds(items.count, "minItems", "maxItems", "items")
                if rules["uniqueItems"] == .bool(true), Set(items).count != items.count {
                    problems += bad("uniqueItems", "unique items", "\(here) must hold unique items")
                }
                if case .array(let positions)? = rules["items"] {
                    for (index, item) in items.enumerated() where index < positions.count { problems += check(item, positions[index], "\(at)[\(index)]") }
                } else if let rule = rules["items"] {
                    for (index, item) in items.enumerated() { problems += check(item, rule, "\(at)[\(index)]") }
                }
            case .string(let text):
                bounds(text.unicodeScalars.count, "minLength", "maxLength", "characters")
                if case .string(let pattern)? = rules["pattern"], let regex = try? NSRegularExpression(pattern: pattern),
                   regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
                    problems += bad("pattern", "matching \(pattern)", "\(here) must match \(pattern); got \(found(value))")
                }
            case .int, .double:
                let n = number(value)!
                for (key, failed, relation) in [("minimum", n < (number(rules["minimum"]) ?? -.infinity), "at least"),
                    ("maximum", n > (number(rules["maximum"]) ?? .infinity), "at most"),
                    ("exclusiveMinimum", n <= (number(rules["exclusiveMinimum"]) ?? -.infinity), "more than"),
                    ("exclusiveMaximum", n >= (number(rules["exclusiveMaximum"]) ?? .infinity), "less than")] where failed {
                    let expected = number(rules[key]).map { "\(relation) \(numeral($0))" } ?? "a finite number"
                    problems += bad(key, expected, "\(here) must be \(expected); got \(numeral(n))")
                }
                if let step = number(rules["multipleOf"]), abs(n / step - (n / step).rounded()) > 1e-10 {
                    problems += bad("multipleOf", "a multiple of \(numeral(step))", "\(here) must be a multiple of \(numeral(step)); got \(numeral(n))")
                }
            default: break
            }
            return problems
        }
        if let problem = schemaError(schema, path) { return problem }
        var seen = Set<String>()
        let problems = check(self, schema, path).filter { seen.insert($0.path + "\u{1}" + $0.keyword + "\u{1}" + $0.words).inserted }
        guard let first = problems.first else { return nil }
        if problems.count == 1 { return first }
        // Several problems answer as one refusal at the checked root, each named once in words with its accepted shape.
        let keywords = unique(problems.map(\.keyword))
        return SchemaProblem(path: path, keyword: keywords.count == 1 ? keywords[0] : "several",
            expected: problems.map { "\(named($0.path)): \($0.expected)" }.joined(separator: "; "),
            words: problems.map(\.words).joined(separator: "; "))
    }
}

package enum ToolSchema {
    package static let senseViewProperties: [(String, JSONValue)] = [
        ("raw", boolSchema("Read the original view instead of its sense.")),
        ("wrong", boolSchema("Read the original view and offer sense repair after a successful read.")),
        ("why", strSchema("Optional explanation of what is wrong with the sense view.")),
    ]

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
    /// An owner-issued version (a row stamp, a digest) is one token: copied, never written.
    package static func versionSchema(_ desc: String) -> JSONValue {
        obj([("type", .string("string")), ("pattern", .string("^\\S+$")), ("description", .string(desc))])
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
        // Literal schema constructors contain only serializable JSON values; serialization failure must not crash the turn.
        return (try? v.serializedData(pretty: false)) ?? Data("{}".utf8)
    }
}
