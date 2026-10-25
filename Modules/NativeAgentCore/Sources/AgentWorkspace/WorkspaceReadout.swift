import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `WorkspaceReadout.swift` | Frozen workspace facts and exact native item/action bindings; typed `workspace-readout.js` decisions select existing keys and labels, never manufacture targets, permissions or source status; selected helper details retain native identity and content |

/// Parts select opaque source and action keys. Native identities, exact
/// arguments, permissions and the actual read status never come back from JS.
enum WorkspaceReadout {
    struct Action: Codable { let key: String; let label: String? }
    struct Item: Codable {
        let key: String
        let title: String
        let content: [String:JSONValue]?
        let actions: [Action]
    }
    struct Decision: Codable {
        let title: String
        let content: [String:JSONValue]
        let items: [Item]
        let actions: [Action]
    }

    static func project(input: JSONValue, dataRoot: URL, items: [String: AgentWorkspaceItem],
                        actions: [String: AgentWorkspaceButton], native: [String: JSONValue] = [:]) async -> AgentWorkspaceProjection {
        do {
            let value = try await AgentWorkspacePorts.current.tools.readout(input, dataRoot: dataRoot)
            let decision = try JSONDecoder().decode(Decision.self, from: value.serializedData(pretty: false))
            func buttons(_ choices: [Action]) throws -> [AgentWorkspaceButton] {
                try choices.map { choice in
                    if var button = actions[choice.key] {
                        let sourceLabel = button.label
                        if let label = choice.label { button.label = label }
                        switch button.action {
                        case .open(.record(let tool,let input,let title)) where title == sourceLabel:
                            button.action = .open(.record(tool:tool,input:input,title:button.label))
                        case .perform(let tool, let input, _, let field, let effect):
                            button.action = .perform(tool:tool,input:input,title:button.label,textField:field,isEffect:effect)
                        case .configure(let tool, let input, _): button.action = .configure(tool:tool,input:input,title:button.label)
                        default: break
                        }
                        return button
                    }
                    throw AgentWorkspaceFailure(message: "Workspace part named an unbound action: " + choice.key)
                }
            }
            let selected = try decision.items.map { item -> AgentWorkspaceItem in
                if let source = items[item.key] {
                    return .init(title: item.title, content: item.content.map(JSONValue.object) ?? source.content, actions: try buttons(item.actions))
                }
                throw AgentWorkspaceFailure(message: "Workspace part named an unbound item: " + item.key)
            }
            let content = decision.content.merging(native) { _, truth in truth }
            return .init(title: decision.title, content: .object(content), items: selected, actions: try buttons(decision.actions))
        } catch {
            return .init(title: "Workspace unavailable", content: .object(["status": .string("unavailable"),
                "detail": .string(error.localizedDescription),"source":.object(native)]), items: [], actions: [])
        }
    }

    static func bots(input: [String: JSONValue], result: JSONValue, dataRoot: URL) async -> AgentWorkspaceProjection {
        let selected = input["id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil
        if result.objectValue?["bots"]?.arrayValue == nil {
            return .init(title:"My helpers",content:.object(["status":.string("unavailable"),"source":result]),items:[],actions:[])
        }
        let rows = result.objectValue!["bots"]!.arrayValue!
        var items: [String: AgentWorkspaceItem] = [:], actions: [String: AgentWorkspaceButton] = [:]
        var facts: [JSONValue] = []
        func read(_ label: String, _ tool: String, _ input: [String: JSONValue] = [:], _ title: String? = nil) -> AgentWorkspaceButton {
            .init(label: label, action: .open(.record(tool: tool, input: input, title: title ?? label)))
        }
        actions["create"] = .init(label: "create", action: .configure(tool: "bot_create", input: [:], title: "create"))
        actions["replies"] = read("replies","shelf_read",["limit": .int(16),"include_read": .bool(true),"newest_first": .bool(true)])
        actions["all"] = read("all","bot_list")
        for (index,value) in rows.enumerated() {
            let row = value.objectValue ?? [:], key = "bot:" + String(index)
            let name = row["name"]?.stringValue ?? "Helper"
            var keys: [String] = []
            if let raw = row["id"]?.stringValue, let id = UUID(uuidString: raw)?.uuidString {
                let agent = "bot:" + id
                let candidates: [(String,AgentWorkspaceButton)] = [
                    ("open",read("open","bot_list",["id": .string(id)],name)),
                    ("talk",.init(label:"talk",action:.message(agent:agent,conversation:nil,name:name),needsText:true)),
                    ("conversation",read("conversation","agent_read",["agent": .string(agent)],name)),
                    ("run",.init(label:"run",action:.perform(tool:"bot_run_once",input:["id": .string(id)],title:"run",textField:nil,isEffect:true))),
                    ("settings",.init(label:"settings",action:.configure(tool:"bot_update",input:["id": .string(id)],title:"settings")))
                ]
                for (verb,button) in candidates { actions[key+":"+verb] = button; keys.append(key+":"+verb) }
                if case .bool(let paused)? = row["paused"] {
                    actions[key+":pause"] = .init(label:"pause",
                        action:.perform(tool:"bot_pause",input:["id": .string(id),"paused":.bool(!paused)],
                            title:"pause",textField:nil,isEffect:true))
                    keys.append(key+":pause")
                }
            }
            items[key] = .init(title:name,content:.object(row.filter { !["actions","session_id","cadence"].contains($0.key) }),actions:[])
            facts.append(.object(["key":.string(key),"name":.string(name),"paused":row["paused"] ?? .null,"actions":.array(keys.map(JSONValue.string))]))
        }
        var native = result.objectValue!
        native.removeValue(forKey:"bots")
        native["returned_count"] = .int(Int64(rows.count))
        var projection = await project(input:.object(["mode":.string("bots"),"state":.string("available"),"selected":.bool(selected),"rows":.array(facts)]),
            dataRoot:dataRoot,items:items,actions:actions,native:native)
        if selected, let item = projection.items.first {
            projection.title = item.title; projection.content = item.content
            projection.actions = item.actions + (projection.actions.filter { if case .open(.record("bot_list",_,_)) = $0.action { return true }; return false })
            projection.items = []
        }
        return projection
    }
}
