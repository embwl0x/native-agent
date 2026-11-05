import Foundation
import PersistenceCore
// Blueprint: | `OwnedProgramCalls.swift` | Static prelude call and argument inspection; unknown expressions retain runtime validation |

extension OwnedProgram {
    public struct Calls: Sendable {
        /// Do not evaluate unknown expressions; known keys still establish supplied fields.
        public indirect enum Argument: Sendable {
            case unknown
            case value(JSONValue)
            case object([String: Argument])
            case array([Argument])

            public var value: JSONValue? {
                switch self {
                case .unknown: return nil
                case .value(let value): return value
                case .object(let fields):
                    var values: [String: JSONValue] = [:]
                    for (key, field) in fields { guard let value = field.value else { return nil }; values[key] = value }
                    return .object(values)
                case .array(let fields):
                    var values: [JSONValue] = []
                    for field in fields { guard let value = field.value else { return nil }; values.append(value) }
                    return .array(values)
                }
            }

            /// Refuse only proven mismatches; unknown values retain point-of-call validation rather than dummy values.
            public func problem(schema: JSONValue, path: String = "args") -> String? {
                if case .unknown = self { return nil }
                if let value { return value.schemaProblem(schema: schema, path: path).map(\.words) }
                let rules = schema.objectValue ?? [:]
                for key in ["anyOf", "oneOf"] {
                    if let choices = rules[key]?.arrayValue {
                        let problems = choices.compactMap { problem(schema: $0, path: path) }
                        if problems.count == choices.count { return problems.joined(separator: " or ") }
                    }
                }
                if let choices = rules["allOf"]?.arrayValue {
                    for choice in choices { if let problem = problem(schema: choice, path: path) { return problem } }
                }
                let kind: String
                switch self { case .object: kind = "object"; case .array: kind = "array"; default: return nil }
                if schema == .bool(false) { return "\(path) is no longer accepted" }
                if let type = rules["type"] {
                    let types = type.arrayValue ?? [type]
                    if !types.contains(.string(kind)) { return "\(path) passes \(kind); live type is \(type)" }
                }
                switch self {
                case .object(let fields):
                    for required in rules["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[required] == nil {
                        return "\(path).\(required) is required by the live schema but is absent"
                    }
                    let properties = rules["properties"]?.objectValue ?? [:]
                    for key in fields.keys.sorted() {
                        guard let child = properties[key] ?? rules["additionalProperties"] else { continue }
                        if child == .bool(false), properties[key] == nil { return "\(path).\(key) is no longer an accepted field" }
                        if let problem = fields[key]?.problem(schema: child, path: path + "." + key) { return problem }
                    }
                case .array(let fields):
                    if let items = rules["items"] {
                        for (i, field) in fields.enumerated() {
                            let item = items.arrayValue.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? (items.arrayValue == nil ? items : .bool(true))
                            if let problem = field.problem(schema: item, path: "\(path)[\(i)]") { return problem }
                        }
                    }
                default: break
                }
                return nil
            }
        }
        public struct Literal: Sendable {
            public let id: String
            /// Preserve primitive dispatch's case and whitespace sensitivity before app-door canonicalization.
            public let spelling: String
            public let primitive: Bool
            /// Indirect calls must declare dependencies because only literal door requests and direct app members can derive them.
            public let inferred: Bool
            public let line: Int
            /// Nil means the argument list is computed, so its fields cannot be inferred.
            public let given: [Argument]?
        }
        public var literal: [Literal] = []
        public var refusals: [String] = []
        public var warnings: [String] = []
        public var usesStrictVerbs = false
    }

    /// Static inspection cannot prove arbitrary JavaScript; nonliteral names retain runtime gates, while template expressions remain inspectable code.
    public static func calls(_ source: String) -> Calls {
        struct Token {
            let text: String
            let literal: String?
            let line: Int
        }
        let scanned = lexed(source), original = Array(source.utf16), code = Array(scanned.code.utf16)
        let literals = Dictionary(uniqueKeysWithValues: scanned.literals.map { ($0.lowerBound, $0) })
        var tokens: [Token] = [], offset = 0, line = 1
        func word(_ c: UInt16) -> Bool {
            c >= 128 || (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 95 || c == 36
        }
        while offset < code.count {
            let start = offset, startLine = line
            if let span = literals[offset] {
                let raw = Array(original[span])
                tokens.append(Token(text: "literal", literal: callLiteral(raw), line: line))
                line += raw.filter { $0 == 10 }.count; offset = span.upperBound
            } else if code[offset] <= 32 {
                if code[offset] == 10 { line += 1 }; offset += 1
            } else if word(code[offset]) {
                while offset < code.count, word(code[offset]) { offset += 1 }
                tokens.append(Token(text: String(decoding: code[start..<offset], as: UTF16.self), literal: nil, line: startLine))
            } else {
                offset += 1
                tokens.append(Token(text: String(decoding: code[start..<offset], as: UTF16.self), literal: nil, line: startLine))
            }
        }
        func text(_ i: Int) -> String { tokens.indices.contains(i) ? tokens[i].text : "" }
        func literal(_ i: Int) -> String? { tokens.indices.contains(i) ? tokens[i].literal : nil }
        // Respect lexical bindings so authored helpers named part or screen are not mistaken for prelude calls.
        let roots: Set<String> = ["app", "host", "part", "screen", "hand"]
        var pairs: [Int: Int] = [:], stack: [Int] = []
        for i in tokens.indices {
            if ["(", "[", "{"].contains(text(i)) { stack.append(i) }
            else if [")", "]", "}"].contains(text(i)), let open = stack.popLast() {
                pairs[open] = i; pairs[i] = open
            }
        }
        var functions: [Range<Int>] = [], bindings: [(name: String, scope: Range<Int>)] = []
        let blocks = pairs.keys.filter { text($0) == "{" }.map { $0..<(pairs[$0]! + 1) }
        func scope(_ i: Int, function: Bool = false) -> Range<Int> {
            (function ? functions : blocks).filter { $0.contains(i) }.min { $0.count < $1.count } ?? tokens.indices
        }
        for i in tokens.indices where text(i) == "function" || (text(i) == "=" && text(i + 1) == ">") {
            let arrow = text(i) == "="
            let open = arrow ? (text(i - 1) == ")" ? pairs[i - 1] : nil) : (text(i + 1) == "(" ? i + 1 : i + 2)
            let close = open.flatMap { pairs[$0] }
            let body = arrow ? i + 2 : (close.map { $0 + 1 } ?? tokens.count)
            let end: Int
            if text(body) == "{", let closed = pairs[body] { end = closed + 1 }
            else if arrow {
                var cursor = body
                while cursor < tokens.count, ![",", ";", ")", "]", "}"].contains(text(cursor)) {
                    cursor = (pairs[cursor].flatMap { $0 > cursor ? $0 + 1 : nil }) ?? cursor + 1
                }
                end = cursor
            } else { continue }
            let range = body..<end
            functions.append(range)
            let parameters = open.flatMap { start in close.map { (start + 1)..<$0 } } ?? (arrow ? (i - 1)..<i : i..<i)
            for p in parameters where roots.contains(text(p)) { bindings.append((text(p), range)) }
        }
        // Method and catch parameters bind locally; if/while expressions do not declare the names they read.
        for open in pairs.keys where text(open) == "(" {
            guard let close = pairs[open], text(close + 1) == "{", let end = pairs[close + 1],
                  !["if", "while", "for", "with", "switch"].contains(text(open - 1)) else { continue }
            let range = (close + 1)..<(end + 1)
            if text(open - 1) != "catch" { functions.append(range) }
            for p in (open + 1)..<close where roots.contains(text(p)) { bindings.append((text(p), range)) }
        }
        for i in tokens.indices {
            if text(i) == "function", roots.contains(text(i + 1)) {
                // Function expressions bind only their body; declarations bind the enclosing scope, including forward calls.
                let expression = ["=", "(", ",", ":", "return"].contains(text(i - 1))
                if expression, let close = pairs[i + 2], let end = pairs[close + 1] {
                    bindings.append((text(i + 1), (close + 1)..<(end + 1)))
                } else { bindings.append((text(i + 1), scope(i))) }
            }
            guard ["var", "let", "const"].contains(text(i)) else { continue }
            var cursor = i + 1, binding = true
            while cursor < tokens.count, ![";", ")", "in", "of"].contains(text(cursor)) {
                if binding, roots.contains(text(cursor)) { bindings.append((text(cursor), scope(i, function: text(i) == "var"))) }
                binding = text(cursor) == ","
                if let close = pairs[cursor], close > cursor { cursor = close + 1 }
                else { cursor += 1 }
            }
        }
        // Only an entire single-string expression is a literal name; concatenated prefixes cannot identify an action.
        func argument(_ i: Int) -> String? {
            guard [",", ")"].contains(text(i + 1)) else { return nil }
            return literal(i)
        }
        var result = Calls()
        func dynamic(_ name: String, _ line: Int) {
            result.warnings.append("\(name) at line \(line) computes a name; it remains checked at run time against declared actions and reach.")
        }
        func add(_ id: String, primitive: Bool = false, inferred: Bool = false, line: Int, given: [Calls.Argument]? = nil) {
            result.literal.append(.init(id: id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), spelling: id,
                                        primitive: primitive, inferred: inferred, line: line, given: given))
        }
        func segments(_ start: Int, _ end: Int) -> [Range<Int>] {
            var ranges: [Range<Int>] = [], first = start, cursor = start
            while cursor < end {
                if text(cursor) == "," { ranges.append(first..<cursor); first = cursor + 1 }
                cursor = pairs[cursor].flatMap { $0 > cursor ? $0 + 1 : nil } ?? cursor + 1
            }
            if first < end { ranges.append(first..<end) }
            return ranges
        }
        func argumentShape(_ range: Range<Int>) -> Calls.Argument {
            guard let first = range.first else { return .unknown }
            if range.count == 1 {
                if let value = literal(first) { return .value(.string(value)) }
                switch text(first) {
                case "true": return .value(.bool(true));
                case "false": return .value(.bool(false));
                case "null": return .value(.null);
                default: break
                }
            }
            let number = range.map { text($0) }.joined()
            if let value = Int64(number) { return .value(.int(value)) }
            if let value = Double(number), value.isFinite { return .value(.double(value)) }
            if text(first) == "{", pairs[first] == range.upperBound - 1 {
                var fields: [String: Calls.Argument] = [:]
                for field in segments(first + 1, range.upperBound - 1) {
                    guard let keyAt = field.first, text(keyAt) != ".", text(keyAt) != "[" else { return .unknown }
                    let key = literal(keyAt) ?? text(keyAt)
                    if field.count == 1 { fields[key] = .unknown }
                    else if text(keyAt + 1) == ":" { fields[key] = argumentShape((keyAt + 2)..<field.upperBound) }
                    else { return .unknown }
                }
                return .object(fields)
            }
            if text(first) == "[", pairs[first] == range.upperBound - 1 {
                let elements = segments(first + 1, range.upperBound - 1)
                if elements.contains(where: { $0.first.map { text($0) == "." } ?? false }) { return .unknown }
                return .array(elements.map(argumentShape))
            }
            return .unknown
        }
        func given(_ open: Int, dropping: Int = 0) -> [Calls.Argument]? {
            guard let end = pairs[open] else { return nil }
            let ranges = segments(open + 1, end)
            guard !ranges.contains(where: { $0.first.map { text($0) == "." } ?? false }) else { return nil }
            return ranges.dropFirst(dropping).map(argumentShape)
        }
        // Inspect only a request's own fields; action-looking nested data is not a call.
        func property(_ name: String, in object: Int) -> Int? {
            guard text(object) == "{", let end = pairs[object] else { return nil }
            var cursor = object + 1, found: Int?
            while cursor < end {
                if (text(cursor) == name || literal(cursor) == name), text(cursor + 1) == ":" { found = cursor + 2 }
                cursor = pairs[cursor].flatMap { $0 > cursor ? $0 + 1 : nil } ?? cursor + 1
            }
            return found
        }
        func doorAction(_ object: Int, line: Int) {
            if let value = property("action", in: object), let id = literal(value), [",", "}"].contains(text(value + 1)) {
                let args: Calls.Argument
                if let start = property("args", in: object), let end = pairs[object] {
                    let stop = segments(object + 1, end).first { $0.contains(start) }?.upperBound ?? start
                    args = argumentShape(start..<stop)
                } else { args = .object([:]) }
                // Spreads and computed requests can replace action/args, so their shape is unknown.
                let opaque = pairs[object].map { end in
                    segments(object + 1, end).contains { $0.first.map { text($0) == "." || text($0) == "[" } ?? false }
                } ?? true
                add(id, inferred: true, line: tokens[value].line, given: opaque ? nil : [args])
            } else { dynamic("app({action:…})", line) }
        }
        func doorRequest(_ object: Int, line: Int) {
            guard text(object) == "{", let requestEnd = pairs[object], [",", ")"].contains(text(requestEnd + 1)) else {
                dynamic("app(request)", line); return
            }
            if property("action", in: object) != nil { doorAction(object, line: line); return }
            guard let batch = property("actions", in: object) else { return }
            guard text(batch) == "[", let end = pairs[batch], [",", "}"].contains(text(end + 1)) else {
                dynamic("app({actions:…})", line); return
            }
            var cursor = batch + 1
            while cursor < end {
                if text(cursor) == "," { cursor += 1; continue }
                guard text(cursor) == "{", let close = pairs[cursor], [",", "]"].contains(text(close + 1)) else {
                    dynamic("app({actions:…})", line); return
                }
                doorAction(cursor, line: tokens[cursor].line)
                cursor = close + 1
            }
        }
        for start in tokens.indices where roots.contains(text(start)) {
            // A property named app is not the bound app object.
            if start > 0, [".", "?"].contains(text(start - 1)) { continue }
            if bindings.contains(where: { $0.name == text(start) && $0.scope.contains(start) }) { continue }
            let root = text(start), line = tokens[start].line
            var members: [String] = [], cursor = start + 1, computed = false
            while cursor < tokens.count {
                if text(cursor) == "?", text(cursor + 1) == "." {
                    cursor += 2
                    if text(cursor) == "(" { break }
                    if text(cursor) != "[" { members.append(text(cursor)); cursor += 1; continue }
                }
                if text(cursor) == ".", !text(cursor + 1).isEmpty, text(cursor + 1) != "(" {
                    members.append(text(cursor + 1)); cursor += 2
                } else if text(cursor) == "[" {
                    let first = cursor + 1
                    var depth = 1; cursor += 1
                    while cursor < tokens.count, depth > 0 {
                        if text(cursor) == "[" { depth += 1 }
                        if text(cursor) == "]" { depth -= 1 }
                        cursor += 1
                    }
                    if cursor == first + 2, let key = literal(first) { members.append(key) }
                    else { computed = true; members.append("<computed>") }
                } else { break }
            }
            guard text(cursor) == "(" else { continue }
            // A following body marks a declaration, so it cannot become a call dependency.
            if let close = pairs[cursor], text(close + 1) == "{" { continue }
            let spelling = ([root] + members).joined(separator: ".")
            if computed { dynamic(spelling, line); continue }
            if members.isEmpty {
                if root == "app" { doorRequest(cursor + 1, line: line); continue }
                result.refusals.append("\(root) is an object, so \(root)(…) at line \(line) cannot run. Use "
                    + "\(root).<method>(args), as exposed by the program prelude.")
                continue
            }
            if root == "app" {
                if members == ["call"] {
                    if let id = argument(cursor + 1) { add(id, line: line, given: given(cursor, dropping: 1)) } else { dynamic(spelling, line) }
                } else if members == ["read"] {
                    if let id = argument(cursor + 1) {
                        if id.contains(".") { add(id, line: line, given: []) }
                    } else { dynamic(spelling, line) }
                } else if members.count == 1, verbs.contains(members[0]) {
                    if ["step", "decide", "expect", "expect_fail"].contains(members[0]) { result.usesStrictVerbs = true }
                    continue
                } else if members.count == 1, members[0].contains(".") {
                    add(members[0], inferred: true, line: line, given: given(cursor))
                } else if members.count == 2, !verbs.contains(members[0]), members[0] != "call", !members[0].contains(".") {
                    add(members.joined(separator: "."), inferred: true, line: line, given: given(cursor))
                } else {
                    result.refusals.append("""
                        \(spelling)(…) at line \(line) is not a callable app binding. Use app.<page>.<action>(args), app[\"page.action\"](args), or \
                        app.call(actionID,args).
                        """)
                }
            } else if root == "host" {
                let operation: String?
                if members == ["call"] { operation = argument(cursor + 1) }
                else if members == ["fetch"] { operation = "fetch" }
                else if members.count == 2, members[0] == "state", ["get", "set"].contains(members[1]) { continue }
                else if members.count == 2, OwnedProgramRunner.hostPrimitiveNamespaces.contains(members[0]) {
                    operation = members.joined(separator: ".")
                } else if OwnedProgramRunner.hostDoorActions.contains(members.joined(separator: ".")) {
                    add(members.joined(separator: "."), line: line, given: given(cursor)); continue
                } else {
                    result.refusals.append("""
                        \(spelling)(…) at line \(line) is not exposed by the program prelude. Use app.<page>.<action>(args) for app actions or \
                        host.call(operation,args) for host primitives.
                        """)
                    continue
                }
                if let operation {
                    var arguments = given(cursor, dropping: members == ["call"] ? 1 : 0)
                    // The host prelude consumes root before files.* dispatch, so root is not a door field.
                    if operation.hasPrefix("files."), var list = arguments,
                       case .object(var fields)? = list.first, fields["root"] != nil {
                        fields.removeValue(forKey: "root")
                        fields["path"] = .unknown
                        list[0] = .object(fields); arguments = list
                    }
                    add(operation, primitive: !operation.hasPrefix("files."), line: line, given: arguments)
                    if operation == "part.call" {
                        if case .object(let request)? = arguments?.first,
                           case .value(.string(let id))? = request["id"] {
                            add("authored." + id, line: line, given: request["input"].map { [$0] })
                        }
                        else { dynamic("host.call(part.call)", line) }
                    }
                }
                else { dynamic(spelling, line) }
            } else if root == "part", members == ["call"] {
                if let id = argument(cursor + 1) { add("authored." + id, line: line, given: given(cursor, dropping: 1)) }
                else { dynamic(spelling, line) }
            } else if root == "screen", members.count == 1, ["watch", "next"].contains(members[0]) {
                add(spelling, primitive: true, line: line)
            } else if root == "hand", members.count == 1 {
                add(spelling, primitive: true, line: line)
            } else {
                result.refusals.append("\(spelling)(…) at line \(line) is not exposed by the program prelude.")
            }
        }
        return result
    }

    /// Decode names without executing source; interpolated templates are not literals, while escaped delimiters and Unicode still identify names.
    private static func callLiteral(_ raw: [UInt16]) -> String? {
        guard let quote = raw.first, [34, 39, 96].contains(quote), raw.count >= 2, raw.last == quote else { return nil }
        var decoded: [UInt16] = [], i = 1
        func hex(_ count: Int) -> UInt16? {
            guard i + count <= raw.count - 1,
                  let value = UInt16(String(decoding: raw[i..<(i + count)], as: UTF16.self), radix: 16) else { return nil }
            i += count; return value
        }
        while i < raw.count - 1 {
            let c = raw[i]; i += 1
            if quote == 96, c == 36, raw[i] == 123 { return nil }
            guard c == 92 else { decoded.append(c); continue }
            guard i < raw.count - 1 else { return nil }
            let escaped = raw[i]; i += 1
            switch escaped {
            case 10: continue
            case 13: if i < raw.count - 1, raw[i] == 10 { i += 1 }
            case 98: decoded.append(8)
            case 102: decoded.append(12)
            case 110: decoded.append(10)
            case 114: decoded.append(13)
            case 116: decoded.append(9)
            case 118: decoded.append(11)
            case 48: decoded.append(0)
            case 120: guard let value = hex(2) else { return nil }; decoded.append(value)
            case 117:
                if i < raw.count - 1, raw[i] == 123 {
                    i += 1; let start = i
                    while i < raw.count - 1, raw[i] != 125 { i += 1 }
                    guard i < raw.count - 1, let value = UInt32(String(decoding: raw[start..<i], as: UTF16.self), radix: 16),
                          let scalar = UnicodeScalar(value) else { return nil }
                    decoded.append(contentsOf: String(scalar).utf16); i += 1
                } else { guard let value = hex(4) else { return nil }; decoded.append(value) }
            default: decoded.append(escaped)
            }
        }
        return String(decoding: decoded, as: UTF16.self)
    }
}
