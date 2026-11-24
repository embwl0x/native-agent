import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentMessageFiles.swift` | Admit outgoing files before sending. |

package enum AgentMessageFiles {
    struct Attachment: DoorObjectSchema {
        static let filePath = DoorFieldDescriptor.string("path", "Local file path, resolved through the ordinary attachment fence.", required: true)
        static let doorFields = NonEmptyFields(filePath)
        let path: String

        init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
            guard let path = try door.string(Self.filePath), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  path.utf8.count <= 4096, !path.contains("\0") else {
                throw DoorDecodeError(path: "$.path", accepted: "a nonempty local file path")
            }
            self.path = path
        }
    }

    private static func paths(_ value: JSONValue?) throws -> [String] {
        guard let value, value != .null else { return [] }
        guard case .array(let files) = value, files.count <= 4 else {
            throw refusal("files must be an array of at most four attachment objects, each with path.")
        }
        return try files.map { file in
            do { return try DoorDecoder.object(Attachment.self, from: file).path }
            catch {
                throw refusal("Each file must be {path: <nonempty local file path>}. Names, sizes and MIME types come from the file.")
            }
        }
    }

    static func admit(conversation: AgentConversationContext, input: inout [String: JSONValue], dataRoot: URL?) throws {
        let hasFiles = try !paths(input["files"]).isEmpty
        try requireSupported(conversation: conversation, input, hasFiles: hasFiles, dataRoot: dataRoot)
        if !hasFiles { input.removeValue(forKey: "files") }
    }

    static func requireSupported(conversation: AgentConversationContext, _ input: [String: JSONValue], hasFiles: Bool, dataRoot: URL?) throws {
        guard hasFiles else { return }
        if HelperContact.matches(conversation: conversation, input) { throw unsupported() }
        guard let dataRoot, case .string(let agent)? = input["agent"] else {
            throw refusal("""
                The file route is unresolved without a contact and its data root. Nothing was sent; read agent.contacts before choosing a \
                file-capable contact.
                """)
        }
        guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: {
                  "peer:" + $0.id == agent || ($0.handles ?? []).contains(agent)
              }) else {
            throw refusal("""
                No saved peer route was resolved for this file send. Nothing was sent; read agent.contacts and choose an exact A2A peer. This does \
                not establish whether an unknown contact supports files.
                """)
        }
        guard peer.transport == .a2a, peer.ability == nil else { throw unsupported() }
    }

    private static func unsupported() -> ToolFailureError {
        refusal("""
            This contact's adapter cannot send files. File sends currently require an A2A contact; MCP bridge/command hosts, NativeAgent bridge, \
            desktop chat, Grok, ACP, inboxes, helpers and ability routes accept text only. Nothing was sent. Keep the files; choose an A2A contact \
            or a file-capable action explicitly.
            """)
    }

    package static func refusal(_ message: String) -> ToolFailureError {
        ToolFailureError(message, argumentPath: "files", effects: .none)
    }
}
