import Foundation
import MacNerves
import PersistenceCore
import NativeAgentCore
import MindCore
import DeskCore
import NativeAgentShared
// Blueprint: | `AgentWorkspaceLocation.swift` | Owner locations, named actions, returned text evidence and page rows |

indirect enum AgentWorkspaceLocation: Sendable, Equatable {
    case home
    case arrivals
    case browserBookmark(url: String, title: String, tabID: Int64? = nil)
    case documents(String)
    case people(page: Int)
    case conversations(page: Int)
    case area(String)
    case page(AgentWorkspaceLocation, Int)
    case receipt(tool: String, title: String, value: JSONValue, readback: AgentWorkspaceLocation? = nil)
    case record(tool: String, input: [String: JSONValue], title: String)

    var title: String {
        switch self {
        case .home: return "Home"
        case .arrivals: return "Arrivals"
        case .browserBookmark(_, let title, _): return title
        case .documents(let topic): return "Documents: " + topic
        case .people: return "People and agents"
        case .conversations: return "Conversations"
        case .area(let id): return AgentWorkspaceEnvironment.destinations.first { $0.id == id }?.title ?? "Workspace"
        case .page(let source, _): return source.title
        case .receipt(_, let title, _, _): return title
        case .record(let tool, let input, let title):
            if tool == "work_context", case .string(let query)? = input["query"] { return query }
            if ["recall_memory", "recall_search"].contains(tool), case .string(let query)? = input["query"], !query.isEmpty {
                return "Recall: " + String(query.prefix(160))
            }
            if tool == "read_page", ["Read Page", "Web source"].contains(title),
               case .string(let url)? = input["url"], let parts = URLComponents(string: url), let host = parts.host {
                return "Web: " + String((host + parts.path).prefix(160))
            }
            if ["Open file", "Open folder"].contains(title), ["read_file", "list_dir"].contains(tool),
               case .string(let path)? = input["path"] {
                return (tool == "read_file" ? "File: " : "Folder: ") + URL(fileURLWithPath: path).lastPathComponent
            }
            return title
        }
    }
}

enum AgentWorkspaceAction: Sendable {
    case openArrival(String)
    case dismissArrival(String)
    case open(AgentWorkspaceLocation)
    case message(agent: String, conversation: String?, name: String? = nil)
    case followUpSavedReply(AgentWorkspaceSavedReply)
    case perform(tool: String, input: [String: JSONValue], title: String, textField: String?, isEffect: Bool)
    case searchWeb
}

struct AgentWorkspaceDocument: Sendable {
    static func evidence(_ value: JSONValue) -> String? {
        let reply = ToolResult(value)
        guard reply.hasReadEvidence(),
              let full = value.stringValue ?? value.objectValue?["content"]?.stringValue else { return nil }
        return String(full.prefix(12000))
    }

    static func evidence(location: AgentWorkspaceLocation, value: JSONValue) -> String? {
        if case .page(let source, _) = location { return evidence(location: source, value: value) }
        guard case .record(let tool, let input, _) = location else { return nil }
        if tool == "read_file" || tool == "read_skill" { return evidence(value) }
        let reply = ToolResult(value)
        guard case .object(let row) = value, reply.hasReadEvidence() else { return nil }
        let content: String
        switch tool {
        case "recall_memory":
            guard input["memory_id"] != nil, row["id"] == input["memory_id"], row["status"] == .string("ok"),
                  case .string(let text)? = row["content"] else { return nil }
            content = text
        case "read_page":
            guard case .string(let text)? = row["content"] ?? row["text"] ?? row["markdown"] else { return nil }
            content = text
        case "read_chat_message":
            guard row["status"] == .string("ok"), row["session_id"] == input["session_id"],
                  row["message_id"] == input["message_id"],
                  case .string(let text)? = row["content"] ?? row["text"] else { return nil }
            content = text
        default: return nil
        }
        guard !content.isEmpty else { return nil }
        return String(content.prefix(12_000))
    }
}

struct AgentWorkspaceButton: Sendable {
    var label: String
    var action: AgentWorkspaceAction
    var needsText: Bool = false
}

struct AgentWorkspaceItem: Sendable {
    var title: String
    var content: JSONValue
    var actions: [AgentWorkspaceButton]
}

struct WorkspacePage: Sendable {
    var title: String
    var content: JSONValue
    var items: [AgentWorkspaceItem]
    var actions: [AgentWorkspaceButton]
    var page: Int = 0
}
