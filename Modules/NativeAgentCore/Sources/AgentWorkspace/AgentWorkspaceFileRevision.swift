import Foundation
import CryptoKit
import PersistenceCore

/// A selected file, never an editable target. Reading the whole bounded source
/// prepares the ordinary file form; the file owner checks its content again at
/// replacement time using the immutable hash carried by that form.
struct AgentWorkspaceFileRevision: Sendable {
    let path: String
    let title: String
    private let version: String?
    private let selectedHash: String?

    init?(input: [String: JSONValue], title: String, result original: JSONValue) {
        // The installed action readback wraps a complete legacy string beside
        // its receipt. Preserve the same revision action after a successful save.
        let result: JSONValue = {
            if case .object(let row) = original, Set(row.keys).isSubset(of: ["content", "action_receipt"]),
               row["action_receipt"] != nil, case .string(let content)? = row["content"] { return .string(content) }
            return original
        }()
        guard case .string(let path)? = input["path"], !path.isEmpty, path.count <= 8192,
              !path.contains("\0") else { return nil }
        self.title = title
        if case .string(let content) = result {
            // The legacy plain-text reader omits its resolved target. A relative
            // read may mean the development repo while writes mean workspace.
            guard path.hasPrefix("/"), input["offset"] == nil || input["offset"] == .int(0),
                  Self.isEditable(content) else { return nil }
            self.path = path
            version = nil
            selectedHash = Self.hash(content)
        } else if case .object(let row) = result,
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
        var input: [String: JSONValue] = ["path": .string(path), "offset": .int(0), "max_bytes": .int(65_536)]
        if let version { input["version"] = .string(version) }
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
        if case .string(let content) = result { return isEditable(content) ? content : nil }
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
