import AgentWorkspace
import ChatToolRuntime
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TrustCenter
import AgentConversations
import AuthoredCapabilities
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
import ChatTurnContracts
import ChromeControl
import MemoryV2
import StandingBots
import TurnTrace
import Studio
// Blueprint: | `AppActions+Contracts.swift` | AppActions authored dependency classification, canonical contracts and persisted pin compatibility |

extension AppActions {
    /// Each tool she wrote that is active in her registry, as `authored.<id>` on its face page (diagnostics by default), flagged by the
    /// dependencies' canonical action flags, or its schema without dependencies. Admitted tools are scriptable; each call retains its
    /// ordinary gates. Conditional reads are changing dependencies: tool code chooses their args.
    public static func authored(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [AppAction] {
        guard let snapshot = try? SwiftToolDispatcher.checkedAuthoredCatalog(dataRoot: dataRoot).get() else { return [] }
        return authored(dataRoot: dataRoot, catalog: available(dataRoot: dataRoot) + senses(), snapshot: snapshot)
    }

    static func authored(dataRoot: URL, catalog: [AppAction], snapshot: SwiftToolDispatcher.AuthoredCatalog,
                                 requested: String? = nil) -> [AppAction] {
        let tools = snapshot.tools.filter { tool in
            tool.action.map { id in !catalog.contains { $0.id == id } } ?? true
        }
        let toolsByID = Dictionary(tools.map { ($0.action ?? ToolNameAliases.authoredAction($0.schema.name), $0) },
                                   uniquingKeysWith: { first, _ in first })
        let actionByTool = Dictionary(toolsByID.map { ($0.value.schema.name, $0.key) }, uniquingKeysWith: { first, _ in first })
        // This pass owns all memoized results. Resolve strongly connected tools together so a back edge cannot hide another member's screen
        // effects.
        var classified = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dependenciesByID = toolsByID.mapValues { tool in
            tool.actions.map { dependency in
                let key = dependency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if classified[key] != nil || toolsByID[key] != nil { return key }
                // An older door classifies as the one form's door that answers it; skill.run is a part's run, as ability.resume is.
                if let alias = AppToolExecutor.partAlias(key, [:], root: dataRoot, aliases: snapshot.aliases) {
                    let target = alias.id == "authored." ? "ability.resume" : alias.id
                    if classified[target] != nil || toolsByID[target] != nil { return target }
                }
                return ToolNameAliases.authoredTool(key).flatMap { actionByTool[$0] } ?? key
            }
        }
        var indices: [String: Int] = [:]
        var lowLinks: [String: Int] = [:]
        var stack: [String] = []
        var visiting: Set<String> = []
        func classify(_ id: String) {
            guard classified[id] == nil, indices[id] == nil, toolsByID[id] != nil,
                  let outgoing = dependenciesByID[id] else { return }
            let index = indices.count
            indices[id] = index
            var lowLink = index
            stack.append(id)
            visiting.insert(id)
            for dependency in outgoing {
                if indices[dependency] == nil {
                    classify(dependency)
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
            // A part is the most any call or permission it declares reaches.
            let reach = (dependencies.map { $0?.reaches ?? .write }
                + nodes.flatMap { $0.tool.permissions }.map(PermissionLaw.permissionClass)).max() ?? .read
            // His reach includes non-read dependencies outside her core and permissions beyond her own data/model.
            let reachesHim = dependencies.contains { dependency in
                guard let dependency else { return true }
                if dependency.read { return false }
                if dependency.authored { return dependency.reach == .his }
                guard dependency.isFold else { return false }
                return ![.core, .alwaysOn, .browser].contains(dependency.binding.descriptor?.bucket ?? .unclassified)
            } || PermissionLaw.reach(ofPermissions: nodes.flatMap { $0.tool.permissions }) == .his
            // Unavailable or cyclic dependencies cannot certify a read.
            for node in nodes {
                let member = node.id, tool = node.tool
                let declaredRead = if case .object(let schema)? = try? JSONValue.parse(tool.schema.parametersJSON) { schema["readOnly"] == .bool(true) } else { false }
                // readOnly describes intent, never authority. The complete permission/dependency closure must also be read-only; both
                // watches and expansion consume this canonical binding.
                let read = !cyclic && reach == .read && dependenciesRead
                    && (node.dependencies.isEmpty ? declaredRead : true)
                let toolClass: ToolClass = read ? .read : max(.write, reach)
                let capabilities = read ? toolClass.baseCapabilities : tool.schema.capabilities.subtracting(["safe_read"]).union(toolClass.baseCapabilities)
                let schema = LLMToolSchema(name: tool.schema.name, toolClass: toolClass, reach: reachesHim ? .his : .hers,
                    capabilities: capabilities, description: tool.schema.description,
                    parametersJSON: tool.schema.parametersJSON)
                classified[member] = AppAction(member, tool.page ?? "diagnostics",
                             firstSentence(tool.schema.description), ToolSignature.doorArgs(tool.schema.parametersJSON),
                             irreversible: cyclic || dependenciesIrreversible || authoredIrreversible,
                             toolClass: toolClass, reach: reachesHim ? .his : .hers,
                             capabilities: capabilities, screen: dependenciesScreen,
                             warn: "Resolved class: \(toolClass); reach: \(reachesHim ? "his" : "hers") (includes action dependencies). Declared primitives: "
                                + (tool.permissions.isEmpty ? "none" : tool.permissions.joined(separator: ", "))
                                + "; actions: " + (tool.actions.isEmpty ? "none" : tool.actions.joined(separator: ", ")),
                             // It executes its pinned contract, not a diagnostics-page edit.
                             tool: tool.schema.name, read: read, versionExempt: true, schema: schema, partAction: tool.action != nil,
                             folded: false)
            }
        }
        let selected = requested.map { key in
            toolsByID[key] != nil ? [key] : ToolNameAliases.authoredTool(key).flatMap { actionByTool[$0] }.map { [$0] } ?? []
        } ?? Array(toolsByID.keys)
        for id in selected { classify(id) }
        return selected.sorted().compactMap { classified[$0] }
    }

    /// The app door always returns this envelope. Domain fields refine it below.
    static let resultEnvelope: JSONValue = .object(["type": .string("object"), "properties": .object([
        "read_only": .object(["type": .string("boolean")]), "irreversible": .object(["type": .string("boolean")]),
        "effect": .object(["type": .string("string")]), "execution": .object(["type": .string("string")])
    ]), "required": .array(["read_only", "irreversible", "effect", "execution"].map(JSONValue.string))])

    /// Frozen result contracts for the pre-cutover pin transition, independent of current declarations.
    static func legacyResultSchema(_ id: String) -> JSONValue {
        var schema: [String: JSONValue] = if case .object(let fields) = resultEnvelope { fields } else { [:] }
        var properties: [String: JSONValue] = if case .object(let fields)? = schema["properties"] { fields } else { [:] }
        if id == "persona.read" {
            for name in ["status", "kind", "path", "content"] { properties[name] = .object(["type": .string("string")]) }
            properties["ok"] = .object(["type": .string("boolean")])
            properties["size_bytes"] = .object(["type": .string("integer")])
        }
        if id == "skill.read" {
            properties["script"] = .object(["type": .string("object"), "properties": .object([
                "status": .object(["type": .string("string")]), "runnable": .object(["type": .string("boolean")]),
                "digest": .object(["type": .array([.string("string"), .string("null")])]),
                "admission": .object(["type": .array([.string("object"), .string("null")])]),
                "source": .object(["type": .string("string")])
            ])])
        }
        schema["properties"] = .object(properties)
        return .object(schema)
    }

    /// Remove schema annotations, never argument names or data inside enum/const.
    static func contractSchema(_ value: JSONValue) -> JSONValue {
        guard case .object(let schema) = value else { return value }
        let annotations: Set<String> = ["description", "title", "$comment", "examples", "deprecated"]
        let maps: Set<String> = ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]
        let children: Set<String> = ["items", "additionalProperties", "not", "if", "then", "else", "contains", "propertyNames", "unevaluatedProperties", "unevaluatedItems"]
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

    static func dependencyContract(_ action: AppAction, dataRoot: URL) -> JSONValue {
        let args: JSONValue = if case .object(let fields) = discovery(action, dataRoot: dataRoot) { fields["args_schema"] ?? .null } else { .null }
        return .object(["id": .string(action.id), "args_schema": contractSchema(args),
            "result_schema": contractSchema(action.resultSchema), "revision": .int(Int64(action.revision)),
            "read": .bool(action.read), "readWhen": .object(action.readWhen),
            "irreversible": .bool(action.irreversible), "owner": .bool(action.isHis)])
    }

    /// The current contract still accepts every call the saved one did: all else equal, each saved argument still accepted, nothing newly
    /// required. Optional arguments, extra union alternatives and removed array bounds fit; unproven schema changes do not.
    static func acceptsEveryCall(_ current: JSONValue, of saved: JSONValue) -> Bool {
        guard case .object(var now) = current, case .object(var was) = saved,
              case .object(var nowArgs)? = now.removeValue(forKey: "args_schema"),
              case .object(var wasArgs)? = was.removeValue(forKey: "args_schema") else { return false }
        // Saved contracts can predate unconditional script callability.
        was.removeValue(forKey: "scriptable")
        guard now == was,
              case .object(let nowProperties)? = nowArgs.removeValue(forKey: "properties"),
              case .object(let wasProperties)? = wasArgs.removeValue(forKey: "properties"),
              case .array(let nowRequired)? = nowArgs.removeValue(forKey: "required"),
              case .array(let wasRequired)? = wasArgs.removeValue(forKey: "required"), nowArgs == wasArgs else { return false }
        return wasProperties.allSatisfy { key, schema in
            guard let current = nowProperties[key] else { return false }
            return schemaAcceptsEveryValue(current, of: schema)
        } && nowRequired.allSatisfy(wasRequired.contains)
    }

    /// Prove widening structurally; retain exact comparison for other constraints.
    /// Words never change what a call may send; a list may gain values, a
    /// lower bound may drop, an upper bound may rise, an object may gain
    /// optional fields. Removing, renaming, narrowing or newly requiring is a
    /// change her calls could break on, and stays one.
    private static func schemaAcceptsEveryValue(_ current: JSONValue, of saved: JSONValue) -> Bool {
        if current == saved { return true }
        guard case .object(var now) = current, case .object(var was) = saved else { return false }
        for key in ["description", "title", "examples"] {
            now.removeValue(forKey: key); was.removeValue(forKey: key)
        }
        if now == was { return true }
        // Only a pure union can be split without losing sibling constraints.
        if was.count == 1, case .array(let alternatives)? = was["anyOf"] {
            return alternatives.allSatisfy { schemaAcceptsEveryValue(.object(now), of: $0) }
        }
        if now.count == 1, case .array(let alternatives)? = now["anyOf"] {
            return alternatives.contains { schemaAcceptsEveryValue($0, of: .object(was)) }
        }
        let currentItems = now.removeValue(forKey: "items")
        let savedItems = was.removeValue(forKey: "items")
        if let savedItems {
            guard let currentItems, schemaAcceptsEveryValue(currentItems, of: savedItems) else { return false }
        } else if currentItems != nil { return false }
        // Every saved value is still allowed.
        if let savedEnum = was.removeValue(forKey: "enum") {
            if let currentEnum = now.removeValue(forKey: "enum") {
                guard case .array(let kept) = savedEnum, case .array(let allowed) = currentEnum,
                      kept.allSatisfy(allowed.contains) else { return false }
            }
        } else if now["enum"] != nil { return false }
        guard boundWidens(now: &now, was: &was, inclusive: "minimum", exclusive: "exclusiveMinimum", lower: true),
              boundWidens(now: &now, was: &was, inclusive: "maximum", exclusive: "exclusiveMaximum", lower: false)
        else { return false }
        for (key, lower) in [("minLength", true), ("maxLength", false), ("minItems", true), ("maxItems", false),
                             ("minProperties", true), ("maxProperties", false)] {
            let nowLimit = now.removeValue(forKey: key).flatMap(number)
            let wasLimit = was.removeValue(forKey: key).flatMap(number)
            if let nowLimit {
                guard let wasLimit, lower ? nowLimit <= wasLimit : nowLimit >= wasLimit else { return false }
            }
        }
        // An object keeps every saved field acceptable and requires nothing new.
        if case .object(let savedFields)? = was.removeValue(forKey: "properties") {
            guard case .object(let currentFields)? = now.removeValue(forKey: "properties"),
                  savedFields.allSatisfy({ key, schema in currentFields[key].map { schemaAcceptsEveryValue($0, of: schema) } ?? false })
            else { return false }
        } else if now.removeValue(forKey: "properties") != nil, now["additionalProperties"] == .bool(false) { return false }
        let nowRequired = now.removeValue(forKey: "required")?.arrayValue ?? []
        let wasRequired = was.removeValue(forKey: "required")?.arrayValue ?? []
        guard nowRequired.allSatisfy(wasRequired.contains) else { return false }
        return now == was
    }

    /// One side's bound, inclusive or exclusive: the current one must admit
    /// every value the saved one did. No current bound always does.
    private static func boundWidens(now: inout [String: JSONValue], was: inout [String: JSONValue],
                                    inclusive: String, exclusive: String, lower: Bool) -> Bool {
        func bound(_ fields: inout [String: JSONValue]) -> (value: Double, exclusive: Bool)? {
            let inc = fields.removeValue(forKey: inclusive).flatMap(number)
            let exc = fields.removeValue(forKey: exclusive).flatMap(number)
            switch (inc, exc) {
            case (nil, nil): return nil
            case (let i?, nil): return (i, false)
            case (nil, let e?): return (e, true)
            case (let i?, let e?):
                // The tighter of the two binds.
                if lower { return e >= i ? (e, true) : (i, false) }
                return e <= i ? (e, true) : (i, false)
            }
        }
        let current = bound(&now), saved = bound(&was)
        guard let current else { return true }
        guard let saved else { return false }
        if current.value == saved.value { return !current.exclusive || saved.exclusive }
        return lower ? current.value < saved.value : current.value > saved.value
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let n): return Double(n)
        case .double(let n): return n
        default: return nil
        }
    }

    static func legacyDependencyContract(_ shape: JSONValue) -> JSONValue? {
        guard case .object(var fields) = shape, case .object(let discovery)? = fields.removeValue(forKey: "discovery"),
              case .object(let example)? = discovery["example"], case .string(let id)? = example["action"],
              let args = discovery["args_schema"] else { return nil }
        fields["id"] = .string(id); fields["args_schema"] = contractSchema(args)
        fields["result_schema"] = legacyResultSchema(id)
        return .object(fields)
    }

    // Exact pre-cutover contract fingerprints retain their admitted pin identities. No discovery text is hashed at runtime, and a changed
    // contract cannot use an alias.
    static let legacyContractPins: [String: String] = [
        "ce3825b73675c1d53f5b45c9bca3ecf1f3043582b0900922ae5b5e04c4850364": "3d78648a7ca4a32306fcb5f3631cc8d178b5901f1bf6e85ec42ffd4ca27498cb", // agent.jobs
        "a1a16f5e986804861511def60d9cc4b28b6f2c5c1817b7007201c511fffb3aed": "153f0e2f7f3793bcbc71e4405c012205b4027d3247355e8ae16619a219a4885a", // desk.read
        "343ad78c843823f7298634ec0f4d065ed1c3c2b50f0739bce012e7137d5e1ffb": "56e4b2d0ff89373d4cd6d1a054bbd9f46692efcd127c6ca40deb5c8ea511a433", // files.list
        "40dde8fb0bc022317df4cb78fd4c78331520c5cc0997c55e91bb1c7b4cf88c70": "7cad6403590eb1450e23ba513d813e15672c069b8891e208a4bfadbdec95ab45", // files.read
        "390f91383d07d954a1af9bf5de68de5b329037f523f21ebef4b331271660d72e": "f53da60c71207cbf435d39728baa40a2382e73e68e154e3d48e4d64ac1d1bdd0", // ledger.list
        "5a2d5206a2cfbacaa2772736c92b132fb934f733787415f6e07b1abc24e8ac87": "a3ac19b978557c4d9a7a9fd181b4410b19474c9be0c6c44d5e27efe3842e2e55", // mac.look
        "880715d531def25bd807f3ba673f786ecfa2c39b379cfe40229adba45ed41d9e": "07ef5c2e309de0c7f75a2e917a6b45fe712f49b2e1b027878123b3a878db84a6", // mac.menu, find added (accepts every earlier call)
        "b6c69e223c5b25a8a2a3aef810802dc150f79d25e7d94d8ba53b16f2a9e11114": "06e314e6342019acc87f2adedd4e1e779ab1f960e84cc8c5f4f47786e914ac77", // memory.recall
        "7e84c2196834b9f19027308d2bf233486625990e7d06c063c9cf50c012d5aea6": "2799e5ebcb0ad6f07ff8362d0ca85833e1999088d2989dfcbddc7779cd65b239", // persona.read
        "6cca69c51bba9f797b5cc29c046860c63d51f7ef8e1a09dec82e5e93d3e6f8da": "e7213b4e88830c6adedcc30e02e96d4cbb4ae03fc66d13ebf578fcab9ed9a545", // provider.test
        "15d61c1ef72f4b07cce6a627f0533de72849c658ccc445035ce798192d8918cd": "2aab7e6579c7e3439c2ca86d160a75d26dffc12b3977d0a3d6102cb0b2fff871", // skill.read
    ]
}
