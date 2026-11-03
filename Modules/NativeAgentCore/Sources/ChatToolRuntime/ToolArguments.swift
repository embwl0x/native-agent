import AuthoredCapabilities
import AgentWorkspace
import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import Desk
import MacControl
import SwarmRuns
import MacIntegration
import ToolExecution
import Studio
import Senses
import Research
import TurnTrace
// Blueprint: | `ToolArguments.swift` | Shared checked schema admission for app and native execution, with lossless normalization, transport metadata separation, raw Desk clear/set validation and Contacts owner admission before normalization |
// Normalize optional nulls from the native schema before gates; preserve required nulls and false.
public enum ToolArguments {
    @TaskLocal static var current: (tool: String, input: [String: JSONValue])?

    /// Both doors judge the normalized call against its owner's current schema.
    /// Only the native transport carries private metadata beside public arguments.
    public static func admit(_ input: [String: JSONValue], schema: JSONValue, path: String = "$",
                             transportMetadata: Bool = false, declaredKeysOnly: Bool = false) throws {
        guard case .object(var fields) = schema else {
            throw ToolFailureError("The action's input schema must be an object.", effects: .none,
                owner: "Tool catalog", code: "tool_schema_unavailable",
                instruction: "Repair the registered input schema before calling it again.", recovery: .repair)
        }
        if declaredKeysOnly, fields["additionalProperties"] == nil {
            fields["additionalProperties"] = .bool(false)
        }
        let arguments = transportMetadata ? input.filter { !$0.key.hasPrefix("__") } : input
        if let problem = JSONValue.object(arguments).schemaProblem(schema: .object(fields), path: path) {
            throw ToolFailureError("\(problem.path) must be \(problem.expected). Nothing ran.",
                argumentPath: problem.path, accepted: problem.expected, effects: .none,
                owner: problem.keyword == "schema" ? "Tool catalog" : nil,
                code: problem.keyword == "schema" ? "tool_schema_unavailable" : "invalid_arguments")
        }
    }

    /// Owners with a fixed current input vocabulary reject undeclared names;
    /// transport-owned metadata is not part of their public arguments.
    static func requireDeclaredKeys(_ input: [String: JSONValue], descriptor: LLMToolSchema?) throws {
        guard let descriptor else {
            throw ToolFailureError("The action's input contract is unavailable.", effects: .none,
                owner: "Tool catalog", instruction: "Repair its registered schema before calling it again.")
        }
        try admit(input, schema: descriptor.checkedParameters(), transportMetadata: true, declaredKeysOnly: true)
    }

    public static func normalized(_ input: [String: JSONValue], schema: JSONValue, preserving: Set<String> = [], recordShims: Bool = true) -> [String: JSONValue] {
        guard case .object(let schema) = schema,
              case .object(let properties)? = schema["properties"] else { return input }
        let required: [JSONValue]
        if case .array(let values)? = schema["required"] { required = values } else { required = [] }
        var result = input
        for (key, value) in input {
            guard let field = properties[key] else { continue }
            if preserving.contains(key), case .object(let shape) = field, shape["type"] == nil { continue }
            let normalized = normalizedValue(value, schema: field, recordShims: recordShims)
            if !required.contains(.string(key)), value == .null {
                result.removeValue(forKey: key)
                if recordShims { TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T01"), "site": .string("SwiftToolDispatcher+Dispatch.swift:normalized")])) }
            } else {
                result[key] = normalized
            }
        }
        // A tool that clears a field declares
        // clear_fields: each optional field its enum lists, named there and
        // not also given a value, is passed on as "". Every pass re-applies it, so a second
        // normalization cannot drop the clear.
        if case .object(let clear)? = properties["clear_fields"], case .object(let items)? = clear["items"],
           case .array(let allowed)? = items["enum"], case .array(let names)? = result["clear_fields"] {
            for case .string(let name) in names where allowed.contains(.string(name)) && properties[name] != nil
                && !required.contains(.string(name)) && result[name] == nil {
                result[name] = .string("")
            }
        }
        return result
    }
    // Recurse through the declared shape. Exact protocol forms carry no receipt.
    private static func normalizedValue(_ value: JSONValue, schema: JSONValue, recordShims: Bool = true) -> JSONValue {
        guard case .object(let field) = schema else { return value }
        for key in ["anyOf", "oneOf"] {
            if case .array(let variants)? = field[key] {
                // Preserve an already accepted form. Otherwise only one declared
                // form may accept the normalized value; never choose a union arm.
                if let accepted = variants.first(where: { value.schemaProblem(schema: $0) == nil }) {
                    return normalizedValue(value, schema: accepted, recordShims: recordShims)
                }
                let forms = variants.map { ($0, normalizedValue(value, schema: $0, recordShims: recordShims)) }
                    .filter { $0.1.schemaProblem(schema: $0.0) == nil }
                return forms.count == 1 ? forms[0].1 : value
            }
        }
        if case .object(let object) = value { return .object(normalized(object, schema: schema, recordShims: recordShims)) }
        if case .array(let values) = value, let items = field["items"] {
            return .array(values.map { normalizedValue($0, schema: items, recordShims: recordShims) })
        }
        let types: [JSONValue] = if case .array(let types)? = field["type"] { types }
            else { field["type"].map { [$0] } ?? [] }
        let declared = types.filter { $0 != .string("null") }
        guard declared.count == 1, let type = declared.first else { return value }
        if type == .string("array"), let items = field["items"], case .object(let item) = items {
            let scalar: [JSONValue] = [.string("string"), .string("number"), .string("integer"), .string("boolean")]
            let itemTypes = if case .array(let types)? = item["type"] { types.filter { $0 != .string("null") } }
                else { item["type"].map { [$0] } ?? [] }
            if itemTypes.count == 1, itemTypes.allSatisfy(scalar.contains),
               value != .null {
                let element = normalizedValue(value, schema: items, recordShims: recordShims)
                if element.schemaProblem(schema: items) == nil { return .array([element]) }
            }
        }
        if case .double(let number) = value, type == .string("integer"), let integer = Int64(exactly: number) {
            return .int(integer)
        }
        if type == .string("string") {
            if case .int(let number) = value { return .string(String(number)) }
            if case .double(let number) = value, number.isFinite { return .string(String(number)) }
        }
        if case .string(let text) = value {
            if type == .string("boolean"), text == "true" || text == "false" { return .bool(text == "true") }
            if type == .string("integer") || type == .string("number"),
               let parsed = try? JSONValue.parse(Data(text.utf8)) {
                if case .int(let integer) = parsed,
                   let original = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                   original == Decimal(integer) { return parsed }
                if case .double(let number) = parsed, number.isFinite,
                   // Reject numeric spellings that lose significant digits.
                   let original = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                   let represented = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")),
                   original == represented {
                    if type == .string("number") { return parsed }
                    if let integer = Int64(exactly: number) { return .int(integer) }
                }
            }
        }
        return value
    }
}
public extension ToolDispatchClient {
    func withToolArguments(
        tool: String, input: [String: JSONValue],
        body: ([String: JSONValue]) async throws -> JSONValue
    ) async throws -> JSONValue {
        let canonical = CanonicalToolNameDispatcher.canonical(tool)
        let identity = canonical
        // Contacts owns its raw contract: nulls and numeric entries must not
        // disappear or become strings before the owner can reject them.
        try MacContactsExecutor.validateArguments(tool: canonical, input: input)
        if let current = ToolArguments.current, current.tool == identity, current.input == input { return try await body(input) }
        // Registered native contracts exist independently of whether Trust
        // currently offers their actions. Admission must still reach the
        // action's permission/remedy owner, rather than treat a hidden action
        // as a missing schema. Authored contracts come from their live catalog.
        let declared = AppActionBinding.declaredSchema(canonical)
        let schema: LLMToolSchema?
        if let declared { schema = declared }
        else { schema = try await listAvailableToolSchemas(named: [canonical]).first { $0.name == canonical } }
        let input = ToolNameAliases.hostArgs(canonical, ToolNameAliases.doorArgs(canonical, input, reportShim: true), reportShim: true)
        try SwiftToolDispatcher.validateDeskMutationArguments(canonical, input: input)
        let authoring = canonical == "sense_make" || (canonical == "ability_manage" && input["verb"] == .string("save"))
        // No executor runs without the current catalog contract.
        let normalized: [String: JSONValue]
        if let schema {
            let parameters: JSONValue
            do { parameters = try JSONValue.parse(schema.parametersJSON) }
            catch {
                throw ToolFailureError("The catalog's input schema for \(canonical) could not be read: \(error.localizedDescription). Repair its registered schema before calling it again.",
                    effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                    instruction: "Repair the registered input schema for \(canonical).", recovery: .repair)
            }
            guard case .object = parameters else {
                throw ToolFailureError("The catalog's input schema for \(canonical) must be an object. Repair its registered schema before calling it again.",
                    effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                    instruction: "Repair the registered input schema for \(canonical).", recovery: .repair)
            }
            normalized = MacContactsExecutor.parameters(for: canonical) != nil ? input
                : ToolArguments.normalized(input, schema: parameters, preserving: authoring ? ["learned", "choices"] : [])
            // A wake supplies input.wake, not the authored call's parameters.
            // Native actions reached during that wake still admit their own args.
            let native = SwiftToolDispatcher.nativeCanonicalToolNames.contains(canonical)
                || declared != nil
            if native || OwnedProgramRunner.wake == nil {
                try ToolArguments.admit(normalized, schema: parameters, transportMetadata: true, declaredKeysOnly: native)
            }
        } else if AuthoredToolEffects.isPrimitiveEffect(canonical) {
            // A primitive effect (fetch, apps.call, …) has no catalog row: Trust
            // admits it by its effect identity and its broker checks its arguments.
            normalized = input
        } else {
            throw ToolFailureError("No current input schema is available for \(canonical). Nothing ran.",
                effects: .none, owner: "Tool catalog", code: "tool_schema_unavailable",
                instruction: "Use app find to select an available current action, or repair its registered schema.", recovery: .repair)
        }
        if canonical == "desk_close" { try SwiftToolDispatcher.validateDeskClose(normalized) }
        return try await ToolArguments.$current.withValue((identity, normalized)) { try await body(normalized) }
    }
}
