import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import SenseCore
import MacNerves
import ProviderRouting
import MindCore
import NativeAgentShared
// Blueprint: | `AppActions+Contracts.swift` | Argument shapes, dependency flags and canonical live contracts |

extension AppActions {
    /// Authored actions derive flags from canonical dependencies or their own schema; conditional reads remain changing dependencies.
    public static func authored(dataRoot: URL = PersistenceCore.defaultDataRoot(), turn: Turn?) throws -> [AppAction] {
        try checkedInventory(dataRoot: dataRoot, turn: turn).authored
    }

    static func authored(catalog: [AppAction], snapshot: SwiftToolDispatcher.AuthoredCatalog,
                                 requested: String? = nil) throws -> [AppAction] {
        // A part that answers verbs is offered only as those verbs; a verb a native declaration still holds stays the native one.
        let tools = snapshot.tools.filter { tool in
            (!tool.answering || tool.answer != nil) && (tool.action.map { id in !catalog.contains { $0.id == id } } ?? true)
        }
        let toolsByID = Dictionary(tools.map { ($0.action ?? ToolNameAliases.authoredAction($0.schema.name), $0) },
                                   uniquingKeysWith: { first, _ in first })
        let actionByTool = Dictionary(toolsByID.map { ($0.value.schema.name, $0.key) }, uniquingKeysWith: { first, _ in first })
        // Resolve strongly connected tools together so a back edge cannot hide another member's screen effects.
        var classified = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dependenciesByID = try toolsByID.mapValues { tool in
            try tool.actions.map { dependency in
                let key = dependency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if classified[key] != nil || toolsByID[key] != nil { return key }
                return ToolNameAliases.authoredTool(key).flatMap { actionByTool[$0] } ?? key
            }
        }
        var indices: [String: Int] = [:]
        var lowLinks: [String: Int] = [:]
        var stack: [String] = []
        var visiting: Set<String> = []
        func classify(_ id: String) throws {
            guard classified[id] == nil, indices[id] == nil, toolsByID[id] != nil,
                  let outgoing = dependenciesByID[id] else { return }
            let index = indices.count
            indices[id] = index
            var lowLink = index
            stack.append(id)
            visiting.insert(id)
            for dependency in outgoing {
                if indices[dependency] == nil {
                    try classify(dependency)
                    if let dependencyLink = lowLinks[dependency] { lowLink = min(lowLink, dependencyLink) }
                } else if visiting.contains(dependency), let dependencyIndex = indices[dependency] {
                    lowLink = min(lowLink, dependencyIndex)
                }
            }
            lowLinks[id] = lowLink
            guard lowLink == index else { return }
            var members: [String] = []
            while let member = stack.popLast() {
                visiting.remove(member)
                members.append(member)
                if member == id { break }
            }
            let memberIDs = Set(members)
            let nodes = members.compactMap { member in
                toolsByID[member].flatMap { tool in dependenciesByID[member].map { (id: member, tool: tool, dependencies: $0) } }
            }
            let cyclic = members.count > 1 || outgoing.contains(id)
            let dependencies = nodes.flatMap { $0.dependencies }
                .filter { !memberIDs.contains($0) }.map { classified[$0] }
            let dependenciesRead = dependencies.allSatisfy { $0?.read == true }
            let dependenciesIrreversible = dependencies.contains { $0?.irreversible == true }
            let dependenciesScreen = dependencies.contains { $0?.screen == true }
            let authoredIrreversible = nodes.contains {
                !Set($0.tool.permissions).isDisjoint(with: ["shell", "arbitrary_file_write"])
            }
            // A part's effect is the strongest reach declared by its calls or permissions.
            let reach = (dependencies.map { $0?.reaches ?? .write }
                + nodes.flatMap { $0.tool.permissions }.map(PermissionLaw.permissionClass)).max() ?? .read
            // User reach includes non-read dependencies outside the core and permissions beyond agent-owned data/model.
            let reachesPerson = dependencies.contains { dependency in
                guard let dependency else { return true }
                if dependency.read { return false }
                if dependency.authored { return dependency.reach == .person }
                guard dependency.isFold else { return false }
                return ![.core, .alwaysOn, .browser].contains(dependency.binding.descriptor?.bucket ?? .unclassified)
            } || PermissionLaw.reach(ofPermissions: nodes.flatMap { $0.tool.permissions }) == .person
            // Unavailable or cyclic dependencies cannot certify a read.
            for node in nodes {
                let member = node.id, tool = node.tool
                let declaredRead = if case .object(let schema)? = try? JSONValue.parse(tool.schema.parametersJSON) { schema["readOnly"] == .bool(
                    true) } else { false }
                // readOnly describes intent, never authority. Watches consume the complete permission/dependency closure's canonical binding.
                // An answered verb's declared read is enforced at its run (read-confined); its other classes only raise the closure's.
                let answered = tool.answer
                let read = answered.map { _ in tool.schema.toolClass == .read } ?? (!cyclic && reach == .read && dependenciesRead
                    && (node.dependencies.isEmpty ? declaredRead : true))
                let toolClass: ToolClass = read ? .read : max(.write, reach, tool.schema.toolClass ?? .write)
                let capabilities = read ? toolClass.baseCapabilities : tool.schema.capabilities.subtracting(.safeRead).union(toolClass.baseCapabilities)
                let schema = LLMToolSchema(name: tool.schema.name, toolClass: toolClass, reach: reachesPerson ? .person : .agent,
                    capabilities: capabilities, macIntegration: tool.schema.macIntegration, description: tool.schema.description,
                    parametersJSON: tool.schema.parametersJSON)
                classified[member] = AppAction(member, tool.page ?? "diagnostics",
                             answered?["summary"]?.stringValue ?? firstSentence(tool.schema.description),
                             try ToolSignature.doorArgs(tool.schema.parametersJSON).map(DoorActionArguments.Field.init(admitted:)),
                             irreversible: cyclic || dependenciesIrreversible || authoredIrreversible || answered?["irreversible"] == .bool(true),
                             toolClass: toolClass, reach: reachesPerson ? .person : .agent,
                             capabilities: capabilities, screen: dependenciesScreen || answered?["screen"] == .bool(true),
                             // A verb a part answers says only its own words; an ability's line names its resolved class and primitives.
                             warn: answered.map { $0["warn"]?.stringValue ?? "" }
                                ?? "Resolved class: \(toolClass); reach: \(reachesPerson ? "person" : "agent") (includes action dependencies). "
                                + "Declared primitives: "
                                + (tool.permissions.isEmpty ? "none" : tool.permissions.joined(separator: ", "))
                                + "; actions: " + (tool.actions.isEmpty ? "none" : tool.actions.joined(separator: ", ")),
                             // It executes its pinned contract, not a diagnostics-page edit.
                             tool: tool.schema.name, input: answered == nil ? [:] : ["verb": .string(member)], read: read, versionExempt: true,
                             schema: schema, partAction: tool.action != nil, folded: false, bundled: tool.bundled)
            }
        }
        let selected = requested.map { key in
            toolsByID[key] != nil ? [key] : ToolNameAliases.authoredTool(key).flatMap { actionByTool[$0] }.map { [$0] } ?? []
        } ?? Array(toolsByID.keys)
        for id in selected { try classify(id) }
        return selected.sorted().compactMap { classified[$0] }
    }

    /// Domain fields refine the app door's shared envelope.
    static let resultEnvelope: JSONValue = .object(["type": .string("object"), "properties": .object([
        "read_only": .object(["type": .string("boolean")]), "irreversible": .object(["type": .string("boolean")]),
        "effect": .object(["type": .string("string")]), "execution": .object(["type": .string("string")]),
        "argument_form": .object(["type": .string("string")]), "understood": .object(["type": .string("string")])
    ]), "required": .array(["read_only", "irreversible", "effect", "execution"].map(JSONValue.string))])

    static var personaReadResultSchema: JSONValue {
        var schema: [String: JSONValue] = if case .object(let fields) = resultEnvelope { fields } else { [:] }
        var properties: [String: JSONValue] = if case .object(let fields)? = schema["properties"] { fields } else { [:] }
        for name in ["status", "kind", "path", "content"] { properties[name] = .object(["type": .string("string")]) }
        properties["ok"] = .object(["type": .string("boolean")])
        properties["size_bytes"] = .object(["type": .string("integer")])
        schema["properties"] = .object(properties)
        return .object(schema)
    }

    static var trashResultSchema: JSONValue {
        var schema = resultEnvelope.objectValue ?? [:]
        var properties = schema["properties"]?.objectValue ?? [:]
        properties["ok"] = .object(["type": .string("boolean")])
        properties["trash_path"] = .object(["type": .array([.string("string"), .string("null")])])
        schema["properties"] = .object(properties)
        return .object(schema)
    }

    /// Schema annotation removal must preserve argument names and enum/const data.
    static func contractSchema(_ value: JSONValue) -> JSONValue {
        guard case .object(let schema) = value else { return value }
        let annotations: Set<String> = ["description", "title", "$comment", "examples", "deprecated"]
        let maps: Set<String> = ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]
        let children: Set<String> = ["items", "additionalProperties", "not", "if", "then", "else", "contains", "propertyNames", "unevaluatedProperties",
            "unevaluatedItems"]
        let arrays: Set<String> = ["allOf", "anyOf", "oneOf", "prefixItems"]
        var result = schema.filter { !annotations.contains($0.key) }
        for (key, child) in result {
            if maps.contains(key), case .object(let fields) = child { result[key] = .object(fields.mapValues(contractSchema)) }
            else if children.contains(key) {
                if case .array(let fields) = child { result[key] = .array(fields.map(contractSchema)) }
                else { result[key] = contractSchema(child) }
            }
            else if arrays.contains(key), case .array(let fields) = child { result[key] = .array(fields.map(contractSchema)) }
        }
        // An unconstrained scalar already accepts the enum variant of the same type.
        if case .array(let variants)? = result["anyOf"], variants.contains(.object(["type": .string("string")])),
           variants.allSatisfy({ if case .object(let fields) = $0 { fields["type"] == .string("string") } else { false } }) {
            result.removeValue(forKey: "anyOf"); result["type"] = .string("string")
        }
        return .object(result)
    }

    static func dependencyContract(_ action: AppAction) throws -> JSONValue {
        let args: JSONValue = if case .object(let fields) = try discovery(action) { fields["args_schema"] ?? .null } else { .null }
        return .object(["id": .string(action.id), "args_schema": contractSchema(args),
            "result_schema": contractSchema(action.resultSchema), "revision": .int(Int64(action.revision)),
            "read": .bool(action.read), "readWhen": .object(action.readWhen),
            "irreversible": .bool(action.irreversible), "owner": .bool(action.isPersonOwned)])
    }

}
