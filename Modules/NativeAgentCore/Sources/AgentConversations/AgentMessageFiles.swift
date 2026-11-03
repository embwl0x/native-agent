import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentMessageFiles.swift` | Outgoing contact file argument and transport admission; absent files preserve text sends, unsupported routes refuse before sending |

package enum AgentMessageFiles {
    package static func paths(_ value: JSONValue?) throws -> [String] {
        guard let value, value != .null else { return [] }
        guard case .array(let files) = value, files.count <= 4 else {
            throw refusal("files must be an array of at most four attachment objects, each with path.")
        }
        return try files.map { file in
            guard case .object(let fields) = file, Set(fields.keys) == ["path"],
                  case .string(let path)? = fields["path"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  path.utf8.count <= 4096, !path.contains("\0") else {
                throw refusal("Each file must be {path: <nonempty local file path>}. Names, sizes and MIME types come from the file.")
            }
            return path
        }
    }

    package static func requireSupported(_ input: [String: JSONValue], dataRoot: URL?) throws {
        guard !(try paths(input["files"])).isEmpty else { return }
        if HelperContact.matches(input) { throw unsupported() }
        guard let dataRoot, case .string(let agent)? = input["agent"] else {
            throw refusal("The file route is unresolved without a contact and its data root. Nothing was sent; read agent.contacts before choosing a file-capable contact.")
        }
        guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: {
                  "peer:" + $0.id == agent || ($0.handles ?? []).contains(agent)
              }) else {
            throw refusal("No saved peer route was resolved for this file send. Nothing was sent; read agent.contacts and choose an exact A2A peer. This does not establish whether an unknown contact supports files.")
        }
        guard peer.transport == .a2a, peer.ability == nil,
              try AgentConversationDelivery.door(for: agent, dataRoot: dataRoot) == nil else { throw unsupported() }
    }

    private static func unsupported() -> ToolFailureError {
        refusal("This contact's adapter cannot send files. File sends currently require an A2A contact; MCP bridge/command hosts, NativeAgent bridge, desktop chat, Grok, ACP, inboxes, helpers and ability routes accept text only. Nothing was sent. Keep the files; choose an A2A contact or a file-capable action explicitly.")
    }

    package static func refusal(_ message: String) -> ToolFailureError {
        ToolFailureError(message, argumentPath: "files", effects: .none)
    }
}
