import Foundation
import ChatToolParsing
import CryptoKit
import PersistenceCore
import ChatSessionWork
import NativeAgentCore
import ApprovalInbox
import MemoryV2
import NotificationInbox
import Desk
import StandingBots
import WorkshopExecution
import SwarmRuns
import NativeAgentShared
// Blueprint: | `AgentWorkspaceLocation.swift` | Navigation references, action and page values; `AgentWorkspaceDocument` binds shared evidence to its source fingerprint |

/// References only; owners supply fresh reads and actions through the dispatcher and permission chain.
indirect enum AgentWorkspaceLocation: Sendable, Equatable {
    case home
    case openPlaces
    case savedWorkspaces
    case workOverview
    case arrivals
    case find(String)
    case browserBookmark(url: String, title: String, tabID: Int64? = nil)
    case work(String)
    case documents(String)
    case people(page: Int)
    case conversations(page: Int)
    case area(String)
    case capabilities(query: String)
    case form(AgentWorkspaceForm)
    case page(AgentWorkspaceLocation, Int)
    case receipt(tool: String, title: String, value: JSONValue, readback: AgentWorkspaceLocation? = nil)
    case record(tool: String, input: [String: JSONValue], title: String)

    var title: String {
        switch self {
        case .home: return "Home"
        case .openPlaces: return "Open places"
        case .savedWorkspaces: return "Saved workspaces"
        case .workOverview: return "This work"
        case .arrivals: return "Arrivals"
        case .find(let query): return "Find: " + query
        case .browserBookmark(_, let title, _): return title
        case .work(let topic): return topic
        case .documents(let topic): return "Documents: " + topic
        case .people: return "People and agents"
        case .conversations: return "Conversations"
        case .area(let id): return AgentWorkspaceEnvironment.destinations.first { $0.id == id }?.title ?? "Workspace"
        case .capabilities: return "Available actions"
        case .form(let form): return form.title
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
    case returnFromArrival
    case open(AgentWorkspaceLocation)
    /// A window from the strip: a neighbour of the current one, never nested under it.
    indirect case window(AgentWorkspaceAction)
    case findWork
    case findDocument
    case find
    case workspaceControls
    case message(agent: String, conversation: String?, name: String? = nil, document: AgentWorkspaceDocument? = nil)
    case followUpSavedReply(AgentWorkspaceSavedReply)
    case back
    case returnToWork
    case findCapability
    case perform(tool: String, input: [String: JSONValue], title: String, textField: String?, isEffect: Bool)
    case configure(tool: String, input: [String: JSONValue], title: String)
    case submit(AgentWorkspaceForm)
    case saveForm(AgentWorkspaceForm)
    case editFormField(AgentWorkspaceForm, field: String)
    case reviewDraft(AgentWorkspaceForm)
    case discardDraft(AgentWorkspaceForm)
    case clearSource
    case searchWeb
    case createFile(directory: String)
    case reviseFile(AgentWorkspaceFileRevision)
    case saveWorkspace
    case newWorkspace
    case restoreWorkspace(String)
    case renameWorkspace(String)
    case forgetWorkspace(String)
    case closePlace(AgentWorkspaceLocation)
    case keepWorkPlace(AgentWorkspaceLocation)
    case removeWorkPlace(AgentWorkspaceLocation)
    case updateWorkNote
    case focusWork
}

struct AgentWorkspaceDocument: Sendable {
    var location: AgentWorkspaceLocation
    var fingerprint: String

    static func evidence(_ value: JSONValue) -> (text: String, fingerprint: String)? {
        guard ChatToolOutcome.hasReadEvidence(value),
              let full = value.stringValue ?? value.objectValue?["content"]?.stringValue else { return nil }
        let row = value.objectValue
        let version = row?["version"]?.stringValue ?? row?["next"]?.objectValue?["version"]?.stringValue ?? ""
        // Compare the full returned window, even when only an excerpt is shared.
        let hash = SHA256.hash(data: Data((full + "\u{0}" + version).utf8)).map { String(format: "%02x", $0) }.joined()
        return (String(full.prefix(12000)), hash)
    }

    static func evidence(location: AgentWorkspaceLocation, value: JSONValue) -> (text: String, fingerprint: String)? {
        if case .page(let source, _) = location { return evidence(location: source, value: value) }
        guard case .record(let tool, let input, _) = location else { return nil }
        if tool == "read_file" || tool == "read_skill" { return evidence(value) }
        guard case .object(let row) = value, ChatToolOutcome.hasReadEvidence(value) else { return nil }
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
        var identity: [String: JSONValue] = ["content": .string(content)]
        for key in ["content_sha256", "has_more", "coverage", "url", "title"] { identity[key] = row[key] }
        guard let data = try? JSONValue.object(identity).serializedData(pretty: false), data.count <= 512 * 1024 else { return nil }
        return (String(content.prefix(12_000)), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

struct AgentWorkspaceButton: Sendable {
    var label: String
    var action: AgentWorkspaceAction
    var needsText: Bool = false
    var consumed = false
    var retired = false
    var viewName: String?
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
