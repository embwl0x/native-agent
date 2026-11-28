import Foundation
import PersistenceCore
// Blueprint: | `OwnedProgramCalls.swift` | Static prelude call and argument inspection; unknown expressions retain runtime validation |

extension OwnedProgram {
    public struct Calls: Codable, Equatable, Sendable {
        /// Do not evaluate unknown expressions; known keys still establish supplied fields.
        public indirect enum Argument: Codable, Equatable, Sendable {
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
        public struct Literal: Codable, Equatable, Sendable {
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
        public static let optionKeys = ["preview", "expected_version", "because"]
        public static let requestKeys = ["action", "args"] + optionKeys
        public var literal: [Literal] = []
        public var refusals: [String] = []
        public var warnings: [String] = []
        public var usesStrictVerbs = false
    }

    public struct Analysis: Codable, Equatable, Sendable {
        private let facts: Facts
        public var entries: [String] { facts.entries }
        public var functions: [String: [Int]] { facts.functions }
        public var callLines: [String: Int]? { facts.callLines }
        package let secretLines: [String: Int]
        public let calls: Calls
        public let steps: [Step]

        public func names(_ entry: String) -> Bool { entries.contains(entry) || entries.contains("*") }

        public func presence(_ name: String) -> JSONValue {
            if entries.contains(name) { return .bool(true) }
            return entries.contains("*") ? .null : .bool(false)
        }

        public func partEntry(header: [String: JSONValue]) throws -> Entry {
            if entries.contains("run") { return .run }
            if entries.contains("verbs"), header["answers"]?.objectValue?.isEmpty == false { return .verbs }
            if header["face"]?.objectValue?["projection"] == .bool(true) {
                guard names("face") else { throw SenseFailure(code: "bad_input", message: "A page needs face(input).") }
                return .face
            }
            if names("run") { return .run }
            throw SenseFailure(code: "bad_input", message: "A callable part needs run(input) or handlers for its declared answers in verbs.")
        }

        public struct Step: Codable, Equatable, Sendable {
            public let line: Int
            public let label: String?
            public let guidance: String?
        }

        public static func lines(_ source: String) -> [String] {
            source.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}"))
        }

        package init(data: Data, source: String) throws {
            let fresh = try JSONDecoder().decode(FreshFacts.self, from: data)
            let facts = fresh.facts
            let length = source.utf16.count, lineCount = Self.lines(source).count
            guard facts.functions.values.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[0] <= $0[1] && $0[1] <= length }),
                  facts.calls.allSatisfy({ (1...lineCount).contains($0.line) }),
                  facts.callLines?.values.allSatisfy({ (0...lineCount).contains($0) }) != false,
                  fresh.secretLines.values.allSatisfy({ (1...lineCount).contains($0) }) else {
                throw SenseFailure(code: "bad_output", message: "The analyzer returned a location outside the submitted source.")
            }
            try self.init(facts: facts, secretLines: fresh.secretLines)
        }

        public init(from decoder: Decoder) throws { try self.init(facts: Facts(from: decoder)) }
        public func encode(to encoder: Encoder) throws { try facts.encode(to: encoder) }
        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.facts == rhs.facts }

        private init(facts: Facts, secretLines: [String: Int] = [:]) throws {
            self.facts = facts
            self.secretLines = secretLines
            var shapes: [Calls.Argument] = []
            func argument(_ index: Int) throws -> Calls.Argument {
                guard shapes.indices.contains(index) else {
                    throw SenseFailure(code: "bad_output", message: "Invalid analyzer argument reference.")
                }
                return shapes[index]
            }
            for node in facts.shapes {
                let value: Calls.Argument
                switch node {
                case .unknown: value = .unknown
                case .value(let literal): value = .value(literal)
                case .object(let fields): value = .object(try fields.mapValues(argument))
                case .array(let elements): value = .array(try elements.map(argument))
                }
                shapes.append(value)
            }
            let invocations = try facts.calls.map { call in
                Invocation(root: call.root, members: call.members, line: call.line, first: call.first,
                           given: try call.given.map { try $0.map(argument) })
            }
            let reader = Reader()
            reader.collect(invocations)
            calls = reader.result
            steps = invocations.compactMap { call in
                guard call.root == "app", call.members == ["step"] else { return nil }
                return Step(line: call.line, label: call.first, guidance: call.given?.dropFirst().first?.value?.stringValue)
            }
        }
    }

    private enum Shape: Codable, Equatable, Sendable {
        case unknown, value(JSONValue), array([Int]), object([String: Int])
    }
    private struct FreshFacts: Decodable {
        private enum CodingKeys: String, CodingKey { case secretLines }
        let facts: Facts
        let secretLines: [String: Int]

        init(from decoder: Decoder) throws {
            facts = try Facts(from: decoder)
            secretLines = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([String: Int].self, forKey: .secretLines) ?? [:]
        }
    }
    private struct Facts: Codable, Equatable, Sendable {
        let callLines: [String: Int]?
        let entries: [String]
        let functions: [String: [Int]]
        let shapes: [Shape]
        let calls: [RawInvocation]
    }
    private struct RawInvocation: Codable, Equatable, Sendable {
        let root: String
        let members: [String?]
        let line: Int
        let first: String?
        let given: [Int]?
    }
    private struct Invocation {
        let root: String
        let members: [String?]
        let line: Int
        let first: String?
        let given: [Calls.Argument]?
    }
    private final class Reader {
        var result = Calls()
        func dynamic(_ name: String, _ line: Int) {
            result.warnings.append("\(name) at line \(line) computes a name; it remains checked at run time against declared actions and reach.")
        }
        func unknownShape(_ name: String, _ line: Int) {
            result.warnings.append("\(name) at line \(line) has unknown shape; its actual value remains checked at the app door at run time.")
        }
        func add(_ id: String, primitive: Bool = false, inferred: Bool = false, line: Int, given: [Calls.Argument]? = nil) {
            result.literal.append(.init(id: id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), spelling: id,
                                        primitive: primitive, inferred: inferred, line: line, given: given))
        }
        func doorAction(_ request: Calls.Argument, line: Int) {
            guard case .object(let fields) = request,
                  case .string(let id)? = fields["action"]?.value else {
                unknownShape("app(request)", line); return
            }
            let others = fields.filter { !Calls.requestKeys.contains($0.key) }
            let args: Calls.Argument
            switch fields["args"] {
            case nil, .value(.null)?: args = .object(others)
            case .unknown?: args = .unknown
            case let given?:
                if !others.isEmpty {
                    result.refusals.append("""
                        app({action, args}) at line \(line) takes \(others.keys.sorted().joined(separator: ", ")) inside args, or beside action when \
                        there is no args.
                        """)
                }
                args = given
            }
            if case .unknown = args { unknownShape("app args", line) }
            add(id, inferred: true, line: line, given: [args])
        }
        func doorRequest(_ call: Invocation, line: Int) {
            guard let request = call.given?.first else { return }
            guard case .object(let fields) = request else { unknownShape("app(request)", line); return }
            if fields["action"] != nil { doorAction(request, line: line); return }
            guard let batch = fields["actions"] else { return }
            let extra = fields.keys.filter { $0 != "actions" && !Calls.optionKeys.contains($0) }.sorted()
            if !extra.isEmpty {
                result.refusals.append("invalid_actions at line \(line): app batch does not take \(extra.joined(separator: ", ")) beside actions.")
                return
            }
            guard case .array(let requests) = batch else { unknownShape("app actions", line); return }
            // An entry is read as a lone request is: an action is a call; a page, item or find entry is a read.
            for request in requests {
                if case .object(let fields) = request, fields["action"] == nil { continue }
                doorAction(request, line: line)
            }
        }

        func collect(_ calls: [Invocation]) {
            for call in calls {
                let root = call.root, line = call.line, members = call.members.compactMap { $0 }
                let spelling = ([root] + call.members.map { $0 ?? "<computed>" }).joined(separator: ".")
                if call.members.contains(nil) { dynamic(spelling, line); continue }
                if members.isEmpty {
                    if root == "app" { doorRequest(call, line: line); continue }
                    result.refusals.append("\(root) is an object, so \(root)(…) at line \(line) cannot run. Use "
                        + "\(root).<method>(args), as exposed by the program prelude.")
                    continue
                }
                if root == "app" {
                    appCall(members, spelling: spelling, call: call, line: line)
                } else if root == "host" {
                    hostCall(members, spelling: spelling, call: call, line: line)
                } else if root == "part", members == ["call"] {
                    if let id = call.first { add("authored." + id, line: line, given: call.given.map { Array($0.dropFirst()) }) }
                    else { dynamic(spelling, line) }
                } else if root == "screen", members.count == 1, ["watch", "next"].contains(members[0]) {
                    add(spelling, primitive: true, line: line)
                } else if root == "hand", members.count == 1 {
                    add(spelling, primitive: true, line: line)
                } else {
                    result.refusals.append("\(spelling)(…) at line \(line) is not exposed by the program prelude.")
                }
            }
        }

        func appCall(_ members: [String], spelling: String, call: Invocation, line: Int) {
            if members == ["call"] {
                if let id = call.first { add(id, line: line, given: call.given.map { Array($0.dropFirst()) }) } else { dynamic(spelling, line) }
            } else if members == ["read"] {
                if let id = call.first {
                    if id.contains(".") { add(id, line: line, given: []) }
                } else { dynamic(spelling, line) }
            } else if members.count == 1, OwnedProgram.verbs.contains(members[0]) {
                if ["step", "decide", "expect", "expect_fail"].contains(members[0]) { result.usesStrictVerbs = true }
                return
            } else if members.count == 1, members[0].contains(".") {
                add(members[0], inferred: true, line: line, given: call.given)
            } else if !OwnedProgram.verbs.contains(members[0]), members[0] != "call", !members[0].contains(".") {
                // Every form the prelude binds names the id its members join to: the full-segment chain (app.undo(), app.desk.read(),
                // app.studio.intake.read()) and a namespace's bracket member, whose dots the namespace dispatches (app.studio["intake.read"]()).
                add(members.joined(separator: "."), inferred: true, line: line, given: call.given)
            } else {
                result.refusals.append("""
                    \(spelling)(…) at line \(line) is not a callable app binding. Use app.<action id's segments>(args) such as app.desk.read(args), \
                    app[\"page.action\"](args), or app.call(actionID,args).
                    """)
            }
        }

        func hostCall(_ members: [String], spelling: String, call: Invocation, line: Int) {
            let operation: String?
            if members == ["call"] { operation = call.first }
            else if members == ["fetch"] { operation = "fetch" }
            else if OwnedProgramRunner.layeredHostPrimitives.contains(members.joined(separator: ".")) { operation = members.joined(separator: ".") }
            else if members == ["app", "openURL"] { operation = PartOpenURLRequest.operation }
            else if members.count == 2, members[0] == "state", ["get", "set", "delete", "list", "cas"].contains(members[1]) { return }
            else if members.count == 2, OwnedProgramRunner.hostPrimitiveNamespaces.contains(members[0]) {
                operation = members.joined(separator: ".")
            } else if OwnedProgramRunner.hostDoorActions.contains(members.joined(separator: ".")) {
                add(members.joined(separator: "."), line: line, given: call.given); return
            } else {
                result.refusals.append("""
                    \(spelling)(…) at line \(line) is not exposed by the program prelude. Use app.<page>.<action>(args) for app actions or \
                    host.call(operation,args) for host primitives.
                    """)
                return
            }
            if let operation {
                var arguments = call.given.map { Array($0.dropFirst(members == ["call"] ? 1 : 0)) }
                // The host prelude consumes root before files.* dispatch, so root is not a door field.
                let filePrimitive = OwnedProgramRunner.hostFilePrimitives.contains(operation)
                if operation.hasPrefix("files."), !filePrimitive, var list = arguments,
                   case .object(var fields)? = list.first, fields["root"] != nil {
                    fields.removeValue(forKey: "root")
                    fields["path"] = .unknown
                    list[0] = .object(fields); arguments = list
                }
                add(operation, primitive: !operation.hasPrefix("files.") || filePrimitive, line: line, given: arguments)
                if operation == "part.call" {
                    if case .object(let request)? = arguments?.first,
                       case .value(.string(let id))? = request["id"] {
                        add("authored." + id, line: line, given: request["input"].map { [$0] })
                    }
                    else { dynamic("host.call(part.call)", line) }
                }
            }
            else { dynamic(spelling, line) }
        }
    }

}
