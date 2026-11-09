import Foundation
import SQLite3
import MacIntegration
import PersistenceCore
import ToolExecution
// Blueprint: | `MailAttachmentRead.swift` | `MailAttachmentRead`: one local Mail attachment's bytes for mail.save_attachment |

/// mail.save_attachment stays native: its bytes reach the person's folder only through the trusted file-mutation path. The message is located by
/// Mail's index and its paired identity, and decoded by the same reader as `files.mime`.
enum MailAttachmentRead {
    static func attachment(input: [String: JSONValue]) throws -> (filename: String, data: Data) {
        let scope = input["scope"] ?? input["mailbox"] ?? .string("inbox")
        guard case .string(let name) = scope, ["inbox", "sent", "drafts"].contains(name),
              input["scope"] == nil || input["mailbox"] == nil || input["scope"] == input["mailbox"],
              MailReadLocator.parse(input) != nil else {
            throw failure(3, "Use the scope and paired message identity from a Mail read.")
        }
        let parts = try message(input: input).parts.filter { $0.filename != nil }
        let matches = parts.enumerated().filter { index, part in
            (input["index"] == nil || input["index"] == .int(Int64(index + 1)))
                && (input["filename"] == nil || input["filename"] == .string(part.filename ?? ""))
        }
        guard input["index"] != nil || input["filename"] != nil, matches.count == 1, let filename = matches[0].element.filename else {
            throw failure(5, "Select one attachment by its 1-based index or unique filename from the Mail read.")
        }
        guard let data = matches[0].element.data else {
            throw failure(4, "This attachment is not on disk. Download the message in Mail, then save it again.")
        }
        return (filename, data)
    }

    /// ROWID locates the file; the index and the RFC header must both match the paired identity.
    private static func message(input: [String: JSONValue]) throws -> (headers: [String: String], parts: [PartMIMERead.Part]) {
        guard let locator = MailReadLocator.parse(input, allowMissingMessageID: true), !locator.messageID.isEmpty,
              let accountID = locator.accountID else {
            // A supplied id the locator could not take is refused, never read as absent.
            if let supplied = input["expected_account_id"], supplied != .null {
                throw failure(10, "expected_account_id is not a Mail account id; copy it from a fresh mail.recent row.")
            }
            throw failure(6, "The local read needs expected_message_id and expected_account_id from a mail.recent row.")
        }
        let mismatch = failure(7, """
            Mismatch: message_id \(locator.id) is a different email than expected_message_id names. Use the identifiers from one fresh mail.recent row.
            """)
        let indexError = failure(1, "Mail's index is unavailable. Check Mail's index and Full Disk Access.")
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        let version = try FileManager.default.contentsOfDirectory(atPath: library.path)
            .compactMap { $0.hasPrefix("V") ? Int($0.dropFirst()) : nil }.max()
        var database: OpaquePointer?
        guard let version, sqlite3_open_v2(library.appendingPathComponent("V\(version)/MailData/Envelope Index").path, &database,
                                           SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw indexError
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        var statement: OpaquePointer?
        let sql = """
            SELECT b.url, g.message_id_header FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox
            LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id WHERE m.ROWID = ? AND m.deleted = 0
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw indexError }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, locator.id)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE {
            throw failure(8, "Mail's index has no message \(locator.id); it was deleted or moved. Call mail.recent again and use one fresh row.")
        }
        guard step == SQLITE_ROW else { throw indexError }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func identity(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>"))) }
        guard let mailbox = URL(string: text(0)), let indexPath = sqlite3_db_filename(database, "main") else { throw indexError }
        // The index names an account by its id, the host of the mailbox URL, never by name.
        let host = mailbox.host ?? ""
        guard host.caseInsensitiveCompare(accountID) == .orderedSame else {
            throw failure(10, """
                Mismatch: Mail's index files message_id \(locator.id) under account id \(host.isEmpty ? "(none)" : host), not expected_account_id \
                \(accountID). Use the identifiers from one fresh mail.recent row.
                """)
        }
        guard identity(text(1)) == identity(locator.messageID) else { throw mismatch }
        let root = URL(fileURLWithPath: String(cString: indexPath)).deletingLastPathComponent().deletingLastPathComponent()
        let box = mailbox.isFileURL ? mailbox
            : mailbox.path.split(separator: "/").map { String($0) + ".mbox" }.reduce(root.appendingPathComponent(host)) { $0.appendingPathComponent($1) }
        let shard = String(locator.id / 1000).reversed().map(String.init).joined(separator: "/")
        var otherEmail = false
        if FileManager.default.fileExists(atPath: box.path) {
            let stores = try FileManager.default.contentsOfDirectory(at: box, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            for store in stores {
                for suffix in ["emlx", "partial.emlx"] {
                    let file = store.appendingPathComponent("Data/\(shard)/Messages/\(locator.id).\(suffix)")
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    let message = try PartMIMERead.message(file, loadAttachments: true)
                    guard identity(message.headers["message-id"] ?? "") == identity(locator.messageID) else { otherEmail = true; continue }
                    return message
                }
            }
        }
        if otherEmail { throw mismatch }
        throw failure(9, """
            No local copy of this message is on disk at its indexed mailbox. Download the message in Mail, then refresh its locator before reading its body \
            or attachments.
            """)
    }

    private static func failure(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "MailFileRead", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
