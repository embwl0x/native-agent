import AgentWorkspace
import AuthoredCapabilities
import ChatToolRuntime
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import AgentConversations
import MacIntegration
import PersonaEngine
import Senses
import MultimodalTTS
import ChatSessionWork
import Cognition
import Context
import AttentionRouting
import NativeAgentShared
import ProviderRouting
import DeviceSync
import TrustCenter
import ChatTurnContracts
import ChromeControl
import MemoryV2
import StandingBots
import TurnTrace
import Studio
// Blueprint: | `AppActions+Discovery.swift` | Guides, schema constraints, examples and scalar-list discovery |

extension AppActions {
    /// Guides that carry their arguments' own words. Every folded action's guide is an item read (guide:<id>) its refusals point to.
    public static let guided: Set<String> = ["mac.act", "files.read", "result.page", "memory.commit", "chat.new", "chat.list"]

    private static let guideArgs: [String: Set<String>] = ["files.read": ["offset", "version"],
        "result.page": ["continue"], "memory.commit": ["provenance", "provenance_by", "since"]]

    private static func argumentGuide(_ action: AppAction, schema: LLMToolSchema) throws -> [String] {
        let lines = try ToolSignature.params(schema.parametersJSON, limit: .max)
        guard let names = guideArgs[action.id] else { return guided.contains(action.id) ? lines : [] }
        return lines.filter { names.contains(String($0.prefix { $0 != ":" })) }
    }

    /// Switched-off abilities remain readable, without runnable suggestions.
    static func disabledTools(_ asked: [String], dataRoot: URL) throws -> [JSONValue] {
        let states: Set<String> = ["off", "disabled", "stopped"]
        guard asked.contains(where: states.contains) else { return [] }
        let subject = asked.filter { !states.contains($0) }
        guard case .array(let rows) = try AbilityStore(dataRoot: dataRoot).registry(kind: .part) else { return [] }
        return rows.compactMap { value in
            guard case .object(let row) = value, row["status"] == .string("disabled"),
                  case .string(let id)? = row["id"] else { return nil }
            let description: String = if case .string(let text)? = row["description"] { text } else { "" }
            guard subject.isEmpty || hits(wordSet("authored tools abilities " + id + " " + description), subject) > 0 else { return nil }
            return .object(["page": .string("tools"), "item": .string(id), "status": .string("disabled"),
                "runnable": .bool(false), "description": .string(description)])
        }
    }

    /// The folded tools' own schemas, built once: a fold's args and label are its tool's, and its whole description answers a call that went wrong.
    static let foldSchemas: [String: LLMToolSchema] = Dictionary(uniqueKeysWithValues:
        SwiftToolDispatcher.nativeToolDescriptors.values.filter { ToolNameAliases.foldedTools[$0.name] != nil }
            .map { ($0.name, $0.schema) } + AppToolExecutor.appToolSchemas(includeDoor: false).map { ($0.name, $0) })

    /// Project parameter references once, using the door's accepted names. Common words such as "by name" or "a path" retain their prose meaning.
    static func argumentProse(_ text: String, tool: String) -> String {
        if let names = ToolNameAliases.doorArgNames[tool] {
            let words = try! NSRegularExpression(pattern: #"\b[a-z][a-z0-9_]*\b"#)
            let result = NSMutableString(string: text)
            for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                let range = Range(match.range, in: text)!
                let key = String(text[range])
                if let name = names[key] {
                    let before = text[..<range.lowerBound], after = text[range.upperBound...]
                    let quoted = (before.last == "\"" && after.first == "\"")
                        || (before.last == "`" && after.first == "`")
                    let argument = quoted || after.hasPrefix(":") || after.hasPrefix("=")
                        || after.hasPrefix(" only (") || after.hasPrefix(" peer:")
                    if !["name", "path"].contains(key) || argument {
                        result.replaceCharacters(in: match.range, with: name)
                    }
                }
            }
            return result as String
        }
        return text
    }

    /// Guides translate folded tool names to action ids and retain every guided argument's description.
    public static func about(_ action: AppAction) throws -> String? {
        // Native guides use their declaration so behavior, arguments and admission notes have one owner.
        let warn = action.warn.isEmpty ? "" : "\nBefore running: " + action.warn
        let declared = action.args.isEmpty ? "" : "\nArgs: " + action.args.joined(separator: ", ")
        guard let schema = schema(action) else { return action.label + declared + warn }
        // A fold with fixed input and declared args is its own narrower door over the host (permissions.request over card requests), so its
        // declaration guides it; one with no args (phone.location, trace.model_calls) keeps the fold guide, which lists none.
        guard action.isFold, action.input.isEmpty || action.args.isEmpty else {
            let doorNames = Set(action.args.flatMap { arg in
                String(arg.prefix { $0 != ":" && $0 != "?" }).split(separator: "|").map(String.init)
            })
            let doorName = Dictionary(action.rename.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            let lines = try ToolSignature.params(schema.parametersJSON, limit: .max).compactMap { line -> String? in
                let host = String(line.prefix { $0 != ":" && $0 != " " })
                let name = doorName[host] ?? host
                guard doorNames.isEmpty || doorNames.contains(name) else { return nil }
                return name + line.dropFirst(host.count)
            }
            let args = lines.isEmpty ? declared : "\nArgs:\n" + lines.joined(separator: "\n")
            return ToolNameAliases.foldedProse(argumentProse(action.label + args, tool: action.tool)) + warn
        }
        let lines = try argumentGuide(action, schema: schema)
        let args = lines.isEmpty ? "" : "\nArgs:\n" + lines.joined(separator: "\n")
        return ToolNameAliases.foldedProse(argumentProse(schema.description + args, tool: action.tool))
    }

    static func schema(_ action: AppAction) -> LLMToolSchema? {
        // Folded/native contracts are captured at declaration; explicit door argument shapes may intentionally have no executor schema.
        action.schema
    }

    static func pluralKeys(_ action: AppAction, properties: [String: JSONValue]) -> [String] {
        func scalar(_ schema: JSONValue) -> Bool {
            guard case .object(let property) = schema else { return false }
            let scalarTypes: Set<String> = ["string", "boolean", "integer", "number", "null"]
            if case .string(let type)? = property["type"] { return scalarTypes.contains(type) }
            if case .array(let types)? = property["type"] {
                return types.contains { if case .string(let type) = $0 { scalarTypes.contains(type) } else { false } }
            }
            for key in ["anyOf", "oneOf"] {
                if case .array(let variants)? = property[key] { return variants.contains(where: scalar) }
            }
            if case .array(let variants)? = property["allOf"] { return variants.contains(where: scalar) }
            let values = if case .array(let values)? = property["enum"] { values } else { property["const"].map { [$0] } ?? [] }
            return values.contains { if case .array = $0 { false } else if case .object = $0 { false } else { true } }
        }
        // A list accepted by the schema is one value; malformed values must fail whole instead of fanning out.
        func takesList(_ schema: JSONValue) -> Bool {
            guard case .object(let property) = schema else { return false }
            if property["type"] == .string("array") { return true }
            if case .array(let types)? = property["type"], types.contains(.string("array")) { return true }
            for key in ["anyOf", "oneOf", "allOf"] {
                if case .array(let variants)? = property[key], variants.contains(where: takesList) { return true }
            }
            return false
        }
        return properties.filter { key, value in !action.secretArgs.contains(key) && scalar(value) && !takesList(value) }.keys.sorted()
    }

    /// Retain the native schema's descriptions, enums and nested constraints.
    static func discovery(_ action: AppAction, blocker: String? = nil, dataRoot: URL = PersistenceCore.defaultDataRoot()) throws -> JSONValue {
        let native = try schema(action).map { try JSONValue.parse($0.parametersJSON) }
        let properties: [String: JSONValue]
        if let native {
            guard case .object(let root) = native else {
                throw ToolFailureError("""
                    \(action.id)'s declared parameter schema is not an object. Repair its owning schema before using this action.
                    """, effects: .none, code: "action_schema_unavailable")
            }
            if let value = root["properties"] {
                guard case .object(let props) = value else {
                    throw ToolFailureError("""
                        \(action.id)'s declared parameter schema properties are not an object. Repair its owning schema before using this action.
                        """, effects: .none, code: "action_schema_unavailable")
                }
                properties = props
            } else { properties = [:] }
        } else { properties = [:] }
        var props: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        var alternatives: [JSONValue] = []
        var example: [String: JSONValue] = [:]
        for (raw, spec) in zip(action.args, action.argSpecs) {
            let shape = raw.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? "string"
            for name in spec.names {
                if native != nil {
                    // Folded names may project one schema argument to the door, but an unavailable property is never a synthesized contract.
                    let nativeName = action.rename[name] ?? name
                    let property: JSONValue
                    if let declared = properties[nativeName] { property = declared }
                    else if case .object(let root)? = native,
                            case .array(let required)? = root["required"], required.contains(.string(nativeName)) {
                        // Required does not imply a property/type declaration.
                        property = .object([:])
                    } else {
                        throw ToolFailureError("""
                            \(action.id)'s schema does not declare \(name). Repair its owning action/schema declaration before using it.
                            """, effects: .none, code: "action_schema_unavailable")
                    }
                    props[name] = property
                } else { props[name] = ToolSignature.doorProperty(shape) }
                if !spec.optional, name == "id" || name.hasSuffix("_id"), case .object(var property)? = props[name] {
                    property["minLength"] = .int(1)
                    props[name] = .object(property)
                }
                if spec.names.count > 1, name == "ids" {
                    props[name] = .object(["type": .string("array"), "items": .object(["type": .string("string")])])
                }
            }
            if !spec.optional, let name = spec.names.first {
                if spec.names.count == 1 { required.append(.string(name)) }
                else {
                    alternatives.append(.object(["anyOf": .array(spec.names.map {
                        .object(["required": .array([.string($0)])])
                    })]))
                }
                example[name] = ToolSignature.example(props[name] ?? .object([:]), name: name)
            }
        }
        if ["mail.read", "mail.triage"].contains(action.id) {
            var item: [String: JSONValue] = ["name": .string("<observed mail name>")]
            if action.id == "mail.triage" { item["mark_read"] = .bool(true) }
            example["items"] = .array([.object(item)])
        }
        if ["mail.mark_read", "mail.archive", "mail.delete", "mail.reply", "mail.draft"].contains(action.id) {
            example["subject"] = .string("<observed subject>")
        }
        if action.id == "mac.act", example.isEmpty {
            // Each act step is checked against the screen left by the preceding step.
            example = ["app": .string("<app>"), "steps": .array([.string("<button>"), .object(["verb": .string("type"), "target": .string("<field>"),
                "text": .string("<text>")]), .string("return")])]
        }
        if action.id == "mac.look" { example["app"] = .string("<app name or bundle ID>") }
        if action.id == "ability.validate", example["input"] == nil { example["input"] = .object([:]) }
        if action.id == "bot.list" { example["details"] = .bool(true) }
        if action.id == "chat.new" { example["title"] = .string("<title>") }
        if action.id == "chat.list" { example["pinned"] = .bool(true) }
        if action.id == "schedule.create" {
            example = ["kind": .string("connector_action"), "payload": .object(["actionId": .string("<a read>"), "input": .object([:])]),
                "schedule": .object(["type": .string("every"), "minutes": .int(30)])]
        }
        // Authored contracts retain required names and additionalProperties; bound forms supply fixed executor args outside the public call.
        var args: [String: JSONValue] = if action.folded, action.input.isEmpty, let native,
            case .object(let fields) = ToolNameAliases.doorSchema(action.tool, native) { fields }
        else if action.authored || action.argSpecs.isEmpty && action.input.isEmpty, case .object(let fields)? = native { fields }
        else { ["type": .string("object"), "properties": .object(props),
            "required": .array(required),
            "additionalProperties": .bool(action.argSpecs.isEmpty &&
                (action.partAction || ToolNameAliases.authoredTool(action.id) != nil))] }
        if action.folded, args["additionalProperties"] == nil { args["additionalProperties"] = .bool(false) }
        if !alternatives.isEmpty {
            let declared = if case .array(let forms)? = args["allOf"] { forms } else { [JSONValue]() }
            args["allOf"] = .array(declared + alternatives)
        }
        // Root alternatives constrain the whole call even when each argument is individually optional. Use the published schema's first alternative.
        if case .array(let variants)? = args["anyOf"],
           case .object(let first)? = variants.first,
           case .array(let required)? = first["required"],
           case .object(let properties)? = args["properties"] {
            for case .string(let name) in required where example[name] == nil {
                example[name] = ToolSignature.example(properties[name] ?? .object([:]), name: name)
            }
        }
        let bound = action.input.filter { action.argSpecs.flatMap(\.names).contains($0.key) }
        var call: [String: JSONValue] = ["action": .string(action.id), "args": .object(example.merging(bound) { _, bound in bound })]
        if action.irreversible { call["preview"] = .bool(true) }
        var result: [String: JSONValue] = action.effectFields().merging(["page": .string(action.page), "action": .string(action.line),
            "args_schema": .object(args),
            "read_when": .object(action.readWhen),
            "example": .object(call)]) { _, value in value }
        let plural = pluralKeys(action, properties: props)
        if !plural.isEmpty, action.isFold || action.read || !action.readWhen.isEmpty {
            result["door_expansion"] = .object(["scalar_arguments": .array(plural.map(JSONValue.string)),
                "max_list_arguments": .int(1),
                "note": .string("""
                    For a folded action or read call, one eligible scalar may be a nonempty list: runs once per value with each child's validation and gates. \
                    After a failure or person wait, only later read values run. Native array arguments stay arrays.
                    """)])
        }
        if !action.returnedScope.isEmpty { result["scope"] = .string(action.returnedScope) }
        if !action.read { result["version_note"] = .string("""
            expected_version is optional. Chain versioned calls with the latest receipt's page_version; a change can replace the prior version.
            """) }
        if let blocker {
            result["availability"] = .string("unavailable")
            result["blocker"] = .string(blocker)
        }
        return .object(result)
    }

    /// Bind only a unique meaning at the door; a collision or an unresolved name leaves the whole call for admission to refuse.
    static func boundArguments(_ action: AppAction, _ given: [String: JSONValue], schema: JSONValue?)
        -> (args: [String: JSONValue], understood: [String]) {
        boundArguments(action, given, schema: schema, known: { $0 }, make: { $0 },
            accepts: { $0.schemaProblem(schema: $1) == nil })
    }

    /// Unknown expressions retain their supplied names and structural constraints; only their runtime values remain unjudged.
    static func boundArguments<Value>(_ action: AppAction, _ given: [String: Value], schema: JSONValue?,
        known: (Value) -> JSONValue?, make: (JSONValue) -> Value, accepts: (Value, JSONValue) -> Bool)
        -> (args: [String: Value], understood: [String]) {
        guard let schema, case .object(let properties)? = schema.objectValue?["properties"] else { return (given, []) }
        let address = ToolArguments.itemAddress(given, schema: schema)
        let given = address.args
        let unknown = given.keys.filter { properties[$0] == nil }.sorted { left, right in
            let leftNamed = action.argumentReferences[left] != nil || action.argumentNames.values.contains { $0.contains(left) }
            let rightNamed = action.argumentReferences[right] != nil || action.argumentNames.values.contains { $0.contains(right) }
            return leftNamed == rightNamed ? left < right : leftNamed
        }
        guard !unknown.isEmpty, schema.objectValue?["additionalProperties"] == .bool(false) else { return (given, address.understood) }
        func requiredNames(_ schema: JSONValue, in args: [String: Value]) -> Set<String> {
            let fields = schema.objectValue ?? [:]
            var names = Set((fields["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            for child in fields["allOf"]?.arrayValue ?? [] { names.formUnion(requiredNames(child, in: args)) }
            for key in ["anyOf", "oneOf"] {
                if let variants = fields[key]?.arrayValue {
                    let missing = variants.map { requiredNames($0, in: args) }
                    if !missing.contains(where: \.isEmpty) { for form in missing { names.formUnion(form) } }
                }
            }
            return names.filter { args[$0] == nil }
        }
        func declaresType(_ schema: JSONValue, value: Value) -> Bool {
            guard let fields = schema.objectValue else { return false }
            if fields["type"] != nil || fields["const"] != nil || fields["enum"] != nil { return true }
            return ["anyOf", "oneOf", "allOf"].contains { key in
                (fields[key]?.arrayValue ?? []).contains { declaresType($0, value: value) && accepts(value, $0) }
            }
        }
        var bound = given, understood = address.understood
        for key in unknown {
            if bound[key] == nil { continue }
            guard !key.hasPrefix("__"), let argument = given[key], known(argument) != .null else { return (given, address.understood) }
            let reference = action.argumentReferences[key]
            let declared = reference.map { [$0.parameter] }
                ?? action.argumentNames.keys.filter { action.argumentNames[$0]?.contains(key) == true }
            let translated: Value
            if let reference, let value = known(argument) {
                guard let text = value.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return (given, address.understood)
                }
                translated = make(.string(text.hasPrefix(reference.prefix) ? text : reference.prefix + text))
            } else { translated = argument }
            let candidates = (declared.isEmpty ? Array(requiredNames(schema, in: bound)) : declared).filter { name in
                guard bound[name] == nil, let property = properties[name] else { return false }
                let meaning: Value
                if let meanings = action.argumentValues[name], let value = known(argument) {
                    guard let spelling = value.stringValue, let translated = meanings[spelling] else { return false }
                    meaning = make(translated)
                } else { meaning = translated }
                return declaresType(property, value: meaning) && accepts(meaning, property)
            }
            guard candidates.count == 1, let name = candidates.first else { return (given, address.understood) }
            if let meanings = action.argumentValues[name], let spelling = known(argument)?.stringValue, let translated = meanings[spelling] {
                bound[name] = make(translated)
            } else { bound[name] = translated }
            bound.removeValue(forKey: key)
            understood.append("understood \(key) as \(name)")
            for qualifier in reference?.qualifiers ?? [] {
                guard let value = bound[qualifier] else { continue }
                guard properties[qualifier] == nil, !qualifier.hasPrefix("__"),
                      accepts(value, .object(["type": .string("string"), "minLength": .int(1)])) else { return (given, address.understood) }
                bound.removeValue(forKey: qualifier)
                understood.append("understood \(qualifier) as context for \(key); the exact reference identifies its source")
            }
        }
        return (bound, understood)
    }

    /// The closest declared form is one explicit next call; unresolved values remain beside it, never become an automatic dispatch.
    static func advisedCall(_ advice: JSONValue) -> [String: JSONValue]? {
        if let fields = advice.objectValue {
            if fields["action"]?.stringValue != nil, fields["args"]?.objectValue != nil { return fields }
            if let next = fields["next_call"]?.objectValue { return next }
            if let example = fields["example"]?.objectValue { return example }
            if let actions = fields["actions"] { return advisedCall(actions) }
        }
        if let forms = advice.arrayValue {
            for form in forms { if let call = advisedCall(form) { return call } }
        }
        return nil
    }

    /// Preserve supplied values in an exact call when it fits, otherwise show one proposed form beside the unresolved input.
    static func callAdvice(_ action: AppAction, input: [String: JSONValue], discovery: [String: JSONValue],
                           requiresChange: Bool = false) -> JSONValue {
        let schema = discovery["args_schema"]
        let properties = schema?.objectValue?["properties"]?.objectValue ?? [:]
        if case .object(let given) = input["args"] ?? .object([:]) {
            var corrected = boundArguments(action, given, schema: schema).args
            if let schema {
                corrected = AppToolExecutor.normalizedCallArguments(action, corrected, schema: schema, recordShims: false)
                if (!requiresChange || corrected != given),
                   JSONValue.object(AppToolExecutor.doorValidationArgs(action, corrected)).schemaProblem(schema: schema) == nil {
                    var call: [String: JSONValue] = ["action": .string(action.id), "args": .object(corrected)]
                    for key in ["preview", "expected_version"] { call[key] = input[key] }
                    return .object(call)
                }
            }
        }
        // Missing values and collisions cannot justify a guessed call. This is explicitly a shape, with the original values kept beside it.
        var shape: [String: JSONValue] = ["action": .string(action.id), "args_schema": schema ?? .null]
        if !requiresChange { shape["example"] = discovery["example"] ?? .null }
        shape["supplied_args"] = input["args"]
        if var call = discovery["example"]?.objectValue {
            var args = call["args"]?.objectValue ?? [:]
            for (key, value) in input["args"]?.objectValue ?? [:] {
                if let property = properties[key], value.schemaProblem(schema: property) == nil { args[key] = value }
            }
            if requiresChange, call["action"] == .string(action.id), args == input["args"]?.objectValue {
                shape["next_call"] = .object(["find": .string(action.id)])
                shape["instruction"] = .string("""
                    The supplied arguments already match this form. Read the action and correct the reported cause before calling again.
                    """)
            } else {
                call["args"] = .object(args)
                for key in ["preview", "expected_version"] { if let value = input[key] { call[key] = value } }
                shape["next_call"] = .object(call)
                shape["instruction"] = .string("Review this proposed form against supplied_args; fill missing values before sending it. Nothing ran.")
            }
        }
        return .array([.object(shape)])
    }

    /// Read an unknown id as intent words, using discovery's one checked action index. Advice never dispatches a suggestion.
    static func callAdvice(_ id: String, input: [String: JSONValue], pages: [String: QuietToolPage], dataRoot: URL,
                           memory: SwiftNativeMemoryV2, turn: Turn?) async throws -> JSONValue {
        if let action = try action(id, dataRoot: dataRoot, turn: turn) {
            return callAdvice(action, input: input, discovery: try discovery(action, dataRoot: dataRoot).objectValue ?? [:])
        }
        let intent = words(id).joined(separator: " ")
        let ranking = try await ranked(intent, pages: pages, dataRoot: dataRoot, memory: memory, intentOnly: true, turn: turn)
        // A guess is never steered into an effect: read-only actions rank first, each suggestion says which it is,
        // so a caller that takes the first entry cannot post, send or change anything by accident.
        // Reads lead only among the closest by meaning, so a weak read never outranks the near match.
        let close = Array(matchedActions(ranking.actions).prefix(6))
        let nearest = close.filter(\.read) + close.filter { !$0.read }
        var suggestions: [JSONValue] = [], gaps: [JSONValue] = []
        // A family that names a page is answered first by reading that page: its summary names its item reads and actions.
        if let family = id.split(separator: ".").first.map({ AppDoorNames.resolve(String($0)) }), let page = pages[family] {
            suggestions.append(.object(["page": .string(page.id), "effects": .string("read"), "summary": .string(page.summary),
                                        "example": .object(["page": .string(page.id)])]))
        }
        for (id, reason) in ranking.gaps.sorted(by: { $0.key < $1.key }) {
            gaps.append(.object(["action": .string(id), "ranking_gap": .string(reason)]))
        }
        for action in nearest {
            do {
                let contract = try discovery(action, dataRoot: dataRoot).objectValue ?? [:]
                suggestions.append(.object(["action": .string(action.id), "effects": .string(action.read ? "read" : "changes something"),
                    "args_schema": contract["args_schema"] ?? .null, "example": contract["example"] ?? .null]))
            } catch {
                gaps.append(.object(["action": .string(action.id),
                    "schema_gap": ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)]))
            }
            if suggestions.count >= 3 { break }
        }
        // A gap is never a runnable suggestion and cannot consume one of the three usable shapes.
        if !gaps.isEmpty { return .object(["actions": .array(suggestions), "schema_gaps": .array(gaps)]) }
        return .array(suggestions)
    }

    static func firstSentence(_ text: String) -> String {
        guard let end = text.range(of: ". ") else {
            return text.hasSuffix(".") ? String(text.dropLast()) : text
        }
        return String(text[..<end.lowerBound])
    }
}
