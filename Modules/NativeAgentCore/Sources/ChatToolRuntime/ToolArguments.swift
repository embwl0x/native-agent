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
// Blueprint: | `ToolArguments.swift` | Canonical named-schema argument admission preserves required nulls, false and the current normalized invocation |
// Normalize optional nulls from the native schema before gates; preserve required nulls and false.
public enum ToolArguments {
    @TaskLocal static var current: (tool: String, input: [String: JSONValue])?

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
    // Recurse through the declared object/array shape for optional nulls.
    private static func normalizedValue(_ value: JSONValue, schema: JSONValue, recordShims: Bool = true) -> JSONValue {
        guard case .object(let field) = schema else { return value }
        if case .object(let object) = value { return .object(normalized(object, schema: schema, recordShims: recordShims)) }
        if case .array(let values) = value, let items = field["items"] {
            return .array(values.map { normalizedValue($0, schema: items, recordShims: recordShims) })
        }
        // JSON has one number type: 1.0 is the integer 1 a declared integer
        // field reads. Protocol, not a model habit, so no receipt.
        if case .double(let number) = value, field["type"] == .string("integer") || field["type"] == .array([.string("integer"), .string("null")]),
           let integer = Int64(exactly: number) {
            return .int(integer)
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
        if let current = ToolArguments.current, current.tool == identity, current.input == input { return try await body(input) }
        let schemas = try await listAvailableToolSchemas(named: [canonical])
        if canonical != tool {
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T04"), "site": .string("SwiftToolDispatcher+Dispatch.swift:canonical")]))
        }
        let input = ToolNameAliases.hostArgs(canonical, ToolNameAliases.doorArgs(canonical, input, reportShim: true), reportShim: true)
        if canonical == "desk_close" {
            try SwiftToolDispatcher.validateDeskClose(input)
            return try await body(input)
        }
        let schema = schemas.first { $0.name == canonical || $0.name.replacingOccurrences(of: ".", with: "_") == canonical }
        let authoring = canonical == "sense_make" || (canonical == "ability_manage" && input["verb"] == .string("save"))
        let normalized = schema.flatMap { try? JSONValue.parse($0.parametersJSON) }
            .map { ToolArguments.normalized(input, schema: $0, preserving: authoring ? ["learned", "choices"] : []) } ?? input
        return try await ToolArguments.$current.withValue((identity, normalized)) { try await body(normalized) }
    }
}
