import Foundation
import SQLite3
import PersistenceCore
import UniformTypeIdentifiers
// Blueprint: | `MacAppleScriptBridge+MailMessageBytes.swift` | `MacAppleScriptBridge`: paired-identity .emlx reads, contained attachments and bounded MIME/HTML decoding |

extension MacAppleScriptBridge {
    /// Single and batch reads refuse account mismatches and report other local failures as attachment status.
    static func mailLocalRead(_ input: [String: JSONValue], batch: Bool = false) -> (row: [String: JSONValue]?, attachments: String, accountMismatch: String?) {
        do {
            return (try mailFileRead(input: input, batch: batch), "", nil)
        } catch let error as NSError where error.domain == "MailFileRead" && error.code == 10 {
            return (nil, "", error.localizedDescription)
        } catch {
            return (nil, "Attachments unavailable: \(error.localizedDescription)", nil)
        }
    }

    /// ROWID locates the file; the index and RFC header must both match the paired identity.
    static func mailFileRead(input: [String: JSONValue], batch: Bool = false) throws -> [String: JSONValue] {
        let message = try mailFileMessage(input: input)
        let parts = try mailMessageParts(message.source, attachmentsRoot: message.attachmentsRoot)
        let plain = parts.plain.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard let body = plain ?? parts.html.map(mailHTMLText) ?? (parts.attachments.isEmpty ? nil : "") else { throw mailMIMEError() }
        let offset = clampedInt(input["body_offset"], defaultValue: 0, min: 0, max: 2_000_000)
        let end = min(body.count, offset + (batch ? 4000 : 16000))
        var row = message.row
        row.merge(["body": .string(offset < end ? String(body.dropFirst(offset).prefix(end - offset)) : ""),
            "body_offset": .int(Int64(offset)), "body_end": .int(Int64(end)), "body_total": .int(Int64(body.count)),
            "truncated": .bool(end < body.count), "attachments": .array(parts.attachments.enumerated().map { index, part in
                .object(["filename": .string(part.filename), "content_type": .string(part.contentType),
                    "size": part.data.map { .int(Int64($0.count)) } ?? .null, "index": .int(Int64(index + 1))])
            })]) { _, new in new }
        let tables = mailHTMLTables(html: parts.html)
        if !tables.isEmpty { row["body_tables"] = .array(tables) }
        return row
    }

    public static func mailAttachment(input: [String: JSONValue]) throws -> (filename: String, data: Data) {
        guard mailReadScope(input) != nil, MailReadLocator.parse(input) != nil else {
            throw NSError(domain: "MailFileRead", code: 3, userInfo: [NSLocalizedDescriptionKey: "Use the scope and paired message identity from a Mail read."])
        }
        let message = try mailFileMessage(input: input)
        let parts = try mailMessageParts(message.source, attachmentsRoot: message.attachmentsRoot).attachments
        let matches = parts.enumerated().filter { index, part in
            (input["index"] == nil || input["index"] == .int(Int64(index + 1)))
                && (input["filename"] == nil || input["filename"] == .string(part.filename))
        }
        guard input["index"] != nil || input["filename"] != nil, matches.count == 1 else {
            throw NSError(domain: "MailFileRead", code: 5, userInfo: [NSLocalizedDescriptionKey: "Select one attachment by its 1-based index or unique filename from the Mail read."])
        }
        let part = matches[0].element
        guard let data = part.data else { throw mailFileError(4, "This attachment is not on disk. Download the message in Mail, then save it again.") }
        return (part.filename, data)
    }

    /// Distinguishes missing index entries, identity mismatches, unreadable storage and undownloaded messages.
    private static func mailFileMessage(input: [String: JSONValue]) throws -> (row: [String: JSONValue], source: Data, attachmentsRoot: URL?) {
        guard let locator = MailReadLocator.parse(input, allowMissingMessageID: true), !locator.messageID.isEmpty, let accountID = locator.accountID else {
            // A supplied id the locator could not take is refused, never read as absent.
            if let supplied = input["expected_account_id"], supplied != .null {
                throw mailFileError(10, "expected_account_id is not a Mail account id; copy it from a fresh mail_list_recent row.")
            }
            throw mailFileError(6, "The local read needs expected_message_id and expected_account_id from a mail_list_recent row.")
        }
        let mismatch = mailFileError(7, "Mismatch: message_id \(locator.id) is a different email than expected_message_id names. Use the identifiers from one fresh mail_list_recent row.")
        let indexError = NSError(domain: "MailFileRead", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Mail's index is unavailable. Check Mail's index and Full Disk Access."])
        guard let database = mailIndexDatabase() else { throw indexError }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = """
            SELECT b.url, g.message_id_header, coalesce(m.subject_prefix, '') || coalesce(s.subject, ''),
                   a.comment, a.address, m.date_received, m.read
            FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox
            LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
            LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender
            WHERE m.ROWID = ? AND m.deleted = 0
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw indexError }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, locator.id)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE {
            throw mailFileError(8, "Mail's index has no message \(locator.id); it was deleted or moved. Call mail_list_recent again and use one fresh row.")
        }
        guard step == SQLITE_ROW else { throw indexError }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func identity(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>"))) }
        guard let mailbox = URL(string: text(0)), let indexPath = sqlite3_db_filename(database, "main") else { throw indexError }
        // The index names an account by its id, the host of the mailbox URL, never by name.
        let host = mailbox.host ?? ""
        guard host.caseInsensitiveCompare(accountID) == .orderedSame else {
            throw mailFileError(10, "Mismatch: Mail's index files message_id \(locator.id) under account id \(host.isEmpty ? "(none)" : host), not expected_account_id \(accountID). Use the identifiers from one fresh mail_list_recent row.")
        }
        guard identity(text(1)) == identity(locator.messageID) else { throw mismatch }
        let root = URL(fileURLWithPath: String(cString: indexPath)).deletingLastPathComponent().deletingLastPathComponent()
        let components = mailbox.path.split(separator: "/").map { String($0) + ".mbox" }
        var boxes = [mailbox.isFileURL ? mailbox : components.reduce(root.appendingPathComponent(mailbox.host ?? "")) { $0.appendingPathComponent($1) }]
        // Mail can put a label's backing store in a differently named directory.
        // Search directory names only, never the messages in a huge mailbox.
        if !FileManager.default.fileExists(atPath: boxes[0].path), let name = components.last {
            var pending = [(root, 0)], visited = 0
            while let (directory, depth) = pending.popLast(), visited < 2048 {
                visited += 1
                for entry in try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    if entry.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame { boxes.append(entry) }
                    else if depth < 8, !["Data", "Messages", "MailData"].contains(entry.lastPathComponent) { pending.append((entry, depth + 1)) }
                }
            }
        }
        let shard = String(locator.id / 1000).reversed().map(String.init).joined(separator: "/")
        var otherEmail = false
        for box in boxes where FileManager.default.fileExists(atPath: box.path) {
            let stores = try FileManager.default.contentsOfDirectory(at: box, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            for store in stores {
                let directory = store.appendingPathComponent("Data/\(shard)/Messages")
                for suffix in ["emlx", "partial.emlx"] {
                    let file = directory.appendingPathComponent("\(locator.id).\(suffix)")
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    let data = try Data(contentsOf: file)
                    guard let newline = data.firstIndex(of: 10),
                          let count = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                          count >= 0, count <= data.count - newline - 1 else { throw mailMIMEError() }
                    let source = data.subdata(in: (newline + 1)..<(newline + 1 + count))
                    let headers = mailMIMEHeaders(String(decoding: source, as: UTF8.self))
                    guard identity(headers["message-id"] ?? "") == identity(locator.messageID) else { otherEmail = true; continue }
                    let iso = ISO8601DateFormatter()
                    iso.timeZone = .current  // Mail displays local time.
                    var row: [String: JSONValue] = ["message_id": .int(locator.id), "expected_message_id": .string(locator.messageID),
                        "subject": .string(text(2)), "sender": .string(mailSenderText(comment: text(3), address: text(4))),
                        "date": .string(sqlite3_column_type(statement, 5) == SQLITE_NULL ? ""
                            : iso.string(from: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5))))),
                        "unread": .bool(sqlite3_column_int(statement, 6) == 0), "scope": .string(mailReadScope(input) ?? "inbox")]
                    if let account = locator.account { row["expected_account"] = .string(account) }
                    row["expected_account_id"] = .string(accountID)
                    if let position = locator.position { row["position"] = .int(Int64(position)) }
                    // The locator names no mailbox, so scope is the one passed in.
                    row["verification"] = .string("Account verified by the local read against Mail's index; scope is the one passed in.")
                    return (row, source, suffix == "partial.emlx"
                        ? directory.deletingLastPathComponent().appendingPathComponent("Attachments/\(locator.id)") : nil)
                }
            }
        }
        if otherEmail { throw mismatch }
        throw mailFileError(9, "No local copy of this message is on disk. Download the message in Mail to list or save attachments.")
    }

    /// `body_tables` accompanies the unchanged body: uniform width 2–10, at most 30 rows and 200 cells; multiline cells omit the table.
    static func mailHTMLTables(source: String) -> [JSONValue] {
        mailHTMLTables(html: (try? mailMIMEParts(Data(source.utf8)))?.html)
    }

    private static func mailHTMLTables(html: String?) -> [JSONValue] {
        guard let html else { return [] }
        func matches(_ pattern: String, _ text: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
            }
        }
        var tables: [JSONValue] = [], cells = 0
        for table in matches(#"<table\b[^>]*>((?:(?!<table\b)[\s\S])*?)</table>"#, html) {
            var rows: [[String]] = [], heads: [Bool] = [], simple = true
            for tr in matches(#"<tr\b[^>]*>([\s\S]*?)</tr>"#, table[1]) {
                let found = matches(#"<t(h|d)\b[^>]*>([\s\S]*?)</t[hd]\s*>"#, tr[1])
                let texts = found.map { mailCellText($0[2]) }
                if texts.contains(where: { $0 == nil }) { simple = false; break }
                let row = texts.compactMap { $0 }
                if row.allSatisfy(\.isEmpty) { continue }
                rows.append(row); heads.append(found.allSatisfy { $0[1].lowercased() == "h" })
            }
            guard simple, rows.count >= 2, rows.count <= 30, let width = rows.first?.count, (2...10).contains(width),
                  rows.allSatisfy({ $0.count == width }), cells + rows.count * width <= 200 else { continue }
            cells += rows.count * width
            tables.append(.object(["header": .bool(heads[0]), "rows": .array(rows.map { .array($0.map(JSONValue.string)) })]))
        }
        return tables
    }

    /// A cell's text on one line, or nil when it breaks over lines or runs long.
    private static func mailCellText(_ inner: String) -> String? {
        // One block (a <p> or <div> around the text) is still one line; a break or a second block is not.
        if inner.range(of: #"<(br|li|tr|h[1-6])\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            || inner.components(separatedBy: "<").filter({ $0.range(of: #"^(p|div)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }).count > 1 {
            return nil
        }
        let line = mailHTMLText(inner).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 120 ? nil : line
    }

    private static func mailHTMLText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\b[^>]*>|</(?:p|div|tr|li|h[1-6])\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        while let range = text.range(of: #"&#(x?)([0-9a-fA-F]{1,6});"#, options: .regularExpression) {
            let code = text[range].dropFirst(2).dropLast()
            let scalar = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            text.replaceSubrange(range, with: scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? " ")
        }
        // Marketing preheaders pad with invisible characters; they are not text.
        text.unicodeScalars.removeAll { [0x00AD, 0x034F, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF].contains($0.value) }
        return text.components(separatedBy: "\n").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mailMIMEError() -> NSError {
        mailFileError(2, "The saved message could not be parsed: its local copy has incomplete or unsupported MIME content.")
    }

    private static func mailFileError(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "MailFileRead", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private static func mailMIMEHeaders(_ source: String) -> [String: String] {
        let raw = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let header = String(raw.components(separatedBy: "\n\n")[0])
            .replacingOccurrences(of: #"\n[ \t]+"#, with: " ", options: .regularExpression)
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// Latin-1 preserves MIME boundary bytes; charset conversion follows transfer decoding each text part.
    private typealias MailMIMEAttachment = (filename: String, contentType: String, data: Data?, part: String)

    private static func mailMessageParts(_ source: Data, attachmentsRoot: URL?) throws
        -> (plain: String?, html: String?, attachments: [MailMIMEAttachment]) {
        var result = try mailMIMEParts(source, attachmentsRoot: attachmentsRoot)
        if let root = attachmentsRoot, FileManager.default.fileExists(atPath: root.path) {
            for part in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard try part.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                for file in try FileManager.default.contentsOfDirectory(at: part, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard !result.attachments.contains(where: { $0.part == part.lastPathComponent && $0.filename == file.lastPathComponent }) else { continue }
                    guard NativeAgentWorkspaceRoot.relativePath(file.resolvingSymlinksInPath().path, under: root.resolvingSymlinksInPath().path).map({ !$0.isEmpty }) == true,
                          try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw mailMIMEError() }
                    result.attachments.append((file.lastPathComponent,
                        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                        try Data(contentsOf: file), part.lastPathComponent))
                }
            }
        }
        return result
    }

    private static func mailMIMEParts(_ source: Data, depth: Int = 0, partNumber: String = "",
        attachmentsRoot: URL? = nil) throws -> (plain: String?, html: String?, attachments: [MailMIMEAttachment]) {
        guard depth < 20, let raw = String(data: source, encoding: .isoLatin1),
              let end = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") else { throw mailMIMEError() }
        let headers = mailMIMEHeaders(String(raw[..<end.lowerBound]))
        let type = headers["content-type"] ?? "text/plain"
        let kind = type.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        let body = String(raw[end.upperBound...])
        func parameter(_ name: String, in field: String? = nil) -> String? {
            let field = field ?? type
            guard let regex = try? NSRegularExpression(pattern: "(?:^|;)\\s*" + name + #"(\*)?\s*=\s*(?:"([^"]*)"|([^;\s]+))"#, options: .caseInsensitive),
                  let match = regex.firstMatch(in: field, range: NSRange(field.startIndex..., in: field)),
                  let value = [2, 3].compactMap({ Range(match.range(at: $0), in: field).map { String(field[$0]) } }).first else { return nil }
            if match.range(at: 1).location != NSNotFound {
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                return pieces.count == 3 ? String(pieces[2]).removingPercentEncoding : nil
            }
            return value
        }
        let filename = parameter("filename", in: headers["content-disposition"] ?? "") ?? parameter("name")
        if let filename, !filename.isEmpty {
            let file = attachmentsRoot?.appendingPathComponent(partNumber.isEmpty ? "1" : partNumber).appendingPathComponent(filename)
            let data: Data?
            if let file, FileManager.default.fileExists(atPath: file.path) {
                guard NativeAgentWorkspaceRoot.relativePath(file.resolvingSymlinksInPath().path, under: attachmentsRoot!.resolvingSymlinksInPath().path).map({ !$0.isEmpty }) == true,
                      try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw mailMIMEError() }
                data = try Data(contentsOf: file)
            } else if attachmentsRoot != nil && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                data = nil
            } else { data = try mailMIMEDecode(body, encoding: headers["content-transfer-encoding"]) }
            return (nil, nil, [(filename, kind, data, partNumber.isEmpty ? "1" : partNumber)])
        }
        if headers["content-disposition"]?.lowercased().hasPrefix("attachment") == true { return (nil, nil, []) }
        if kind.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary"), !boundary.isEmpty else { throw mailMIMEError() }
            var result: (plain: String?, html: String?, attachments: [MailMIMEAttachment]) = (nil, nil, [])
            var lines: [String] = [], started = false, closed = false, number = 0
            for line in body.components(separatedBy: "\n") {
                let marker = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if marker == "--" + boundary || marker == "--" + boundary + "--" {
                    if started {
                        var source = lines.joined(separator: "\n")
                        if source.hasSuffix("\r") { source.removeLast() }
                        guard let data = source.data(using: .isoLatin1) else { throw mailMIMEError() }
                        number += 1
                        let part = try mailMIMEParts(data, depth: depth + 1,
                            partNumber: partNumber.isEmpty ? "\(number)" : "\(partNumber).\(number)", attachmentsRoot: attachmentsRoot)
                        if let plain = part.plain { result.plain = [result.plain, plain].compactMap { $0 }.joined(separator: "\n") }
                        if let html = part.html { result.html = [result.html, html].compactMap { $0 }.joined(separator: "\n") }
                        result.attachments += part.attachments
                    }
                    lines = []; started = true
                    if marker == "--" + boundary + "--" { closed = true; break }
                } else if started { lines.append(line) }
            }
            guard closed else { throw mailMIMEError() }
            return result
        }
        guard ["text/plain", "text/html"].contains(kind) else { return (nil, nil, []) }
        let data = try mailMIMEDecode(body, encoding: headers["content-transfer-encoding"])
        let charset = parameter("charset") ?? "us-ascii"
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(charset as CFString))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) else { throw mailMIMEError() }
        return kind == "text/plain" ? (text, nil, []) : (nil, text, [])
    }

    private static func mailMIMEDecode(_ body: String, encoding: String?) throws -> Data {
        let data: Data?
        switch encoding?.lowercased() ?? "7bit" {
        case "base64":
            data = Data(base64Encoded: body.filter { !$0.isWhitespace })
        case "quoted-printable":
            guard let encoded = body.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "").data(using: .isoLatin1) else { throw mailMIMEError() }
            let input = Array(encoded)
            var bytes: [UInt8] = [], i = 0
            while i < input.count {
                if input[i] == UInt8(ascii: "=") {
                    guard i + 2 < input.count, let byte = UInt8(String(decoding: input[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) else { throw mailMIMEError() }
                    bytes.append(byte); i += 3
                } else { bytes.append(input[i]); i += 1 }
            }
            data = Data(bytes)
        case "7bit", "8bit", "binary": data = body.data(using: .isoLatin1)
        default: throw mailMIMEError()
        }
        guard let data else { throw mailMIMEError() }
        return data
    }
}
