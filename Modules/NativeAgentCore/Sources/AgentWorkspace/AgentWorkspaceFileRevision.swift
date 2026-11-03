import Foundation
import CryptoKit
import PersistenceCore
// Blueprint: | `AgentWorkspaceFileRevision.swift` | `AgentWorkspaceFileRevision` struct; `prepare` |

/// A selected file, never an editable target. Reading the whole bounded source
/// prepares the ordinary file form; the file owner checks its content again at
/// replacement time using the immutable hash carried by that form.
struct AgentWorkspaceFileRevision: Sendable {
    let path: String
    let title: String
    private let version: String
    private let selectedHash: String?

    init?(input: [String: JSONValue], title: String, result: JSONValue) {
        guard case .string(let path)? = input["path"], !path.isEmpty, path.count <= 8192,
              !path.contains("\0") else { return nil }
        self.title = title
        if case .object(let row) = result,
                  row["ok"] == .bool(true), row["error"] == nil, row["error_code"] == nil,
                  case .string(let content)? = row["content"], Self.isEditable(content),
                  case .string(let version)? = row["version"], !version.isEmpty,
                  case .string(let resolved)? = row["path"], resolved.hasPrefix("/") {
            self.path = resolved
            self.version = version
            selectedHash = Self.completeContent(result).map(Self.hash)
        } else { return nil }
    }

    func prepare(catalog: AgentWorkspace.Catalog, perform: AgentWorkspace.Perform) async throws -> AgentWorkspaceForm {
        let input: [String: JSONValue] = ["path": .string(path), "offset": .int(0), "max_bytes": .int(65_536), "version": .string(version)]
        let fresh = try await perform("read_file", input)
        guard let content = Self.completeContent(fresh) else {
            throw AgentWorkspaceForm.Failure(message: "This file could not be read completely as editable text within 64 KiB. Reopen the source to check its current state; no replacement draft was created.")
        }
        let hash = Self.hash(content)
        guard selectedHash == nil || selectedHash == hash else {
            throw AgentWorkspaceForm.Failure(message: "This file changed since you read it. Reopen the file and choose Revise again; nothing was written.")
        }
        let schema = try await AgentWorkspaceEnvironment.schema("write_file", catalog: catalog)
        return try AgentWorkspaceForm(schema: schema, title: "Revise " + title,
            bound: ["path": .string(path), "expected_content_sha256": .string(hash)])
            .editing(field: "content", text: content)
            .withNotice("The complete current text is entered. Edit Content, then Save revision. The file is checked again before replacement; a changed source is refused.")
    }

    private static func completeContent(_ result: JSONValue) -> String? {
        guard case .object(let row) = result, row["ok"] == .bool(true),
              row["error"] == nil, row["error_code"] == nil,
              row["offset"] == .int(0), row["truncated"] == .bool(false), row["has_more"] == .bool(false),
              case .string(let content)? = row["content"], isEditable(content),
              row["returned_bytes"] == .int(Int64(content.utf8.count)),
              row["bytes"] == row["returned_bytes"] else { return nil }
        return content
    }

    private static func isEditable(_ content: String) -> Bool {
        content.utf8.count <= 65_536 && !content.contains("\u{FFFD}")
            && !content.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }
    }

    private static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
