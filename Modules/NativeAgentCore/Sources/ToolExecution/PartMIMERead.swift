import Foundation
import PersistenceCore
import UniformTypeIdentifiers
// Blueprint: | `PartMIMERead.swift` | `PartMIMERead`: pure saved-message reader behind `files.mime` and the native attachment save |

/// Reads one saved message as Mail keeps it: an `.emlx` (byte-count line, RFC 822 message, plist trailer) or a plain RFC 822 file. Pure: reach,
/// admission and anything shown to the agent belong to the caller. A `.partial.emlx` keeps its downloaded parts in `../Attachments/<id>/` beside
/// its shard, and those files are its attachments too.
package enum PartMIMERead {
    package struct Part: Sendable {
        package let part: String
        package let type: String
        package let charset: String?
        package let disposition: String?
        package let filename: String?
        /// Decoded bytes; nil when not downloaded or when only attachment metadata was requested.
        package let data: Data?
        /// Decoded text of a body part (text/plain or text/html, not an attachment); HTML stays HTML.
        package let text: String?
        /// Downloaded attachment size, available without reading its contents.
        package var byteCount: Int64? = nil
    }

    /// `{headers, parts:[{part, type, charset?, disposition?, filename?, bytes, text?}], partial}`; attachments carry metadata only. Body text past
    /// maxTextBytes (UTF-8) is cut at a character and `partial` says so.
    package static func read(_ url: URL, maxTextBytes: Int) throws -> JSONValue {
        let message = try message(url, loadAttachments: false)
        var budget = max(0, maxTextBytes), partial = false
        let parts: [JSONValue] = message.parts.map { part in
            var fields: [String: JSONValue] = ["part": .string(part.part), "type": .string(part.type),
                                               "bytes": (part.byteCount ?? part.data.map { Int64($0.count) }).map(JSONValue.int) ?? .null]
            if let charset = part.charset { fields["charset"] = .string(charset) }
            if let disposition = part.disposition { fields["disposition"] = .string(disposition) }
            if let filename = part.filename { fields["filename"] = .string(filename) }
            if let text = part.text {
                var cut = text.startIndex, used = 0
                for index in text.indices {
                    let size = text[index].utf8.count
                    if used + size > budget { break }
                    used += size
                    cut = text.index(after: index)
                }
                if cut < text.endIndex { partial = true }
                fields["text"] = .string(String(text[..<cut]))
                budget -= used
            }
            return .object(fields)
        }
        return .object(["headers": .object(message.headers.mapValues(JSONValue.string)), "parts": .array(parts), "partial": .bool(partial)])
    }

    /// Lowercased top-level header names (the last of a repeated name), and every body text and attachment part in MIME order, downloaded parts last.
    package static func message(_ url: URL, loadAttachments: Bool) throws -> (headers: [String: String], parts: [Part]) {
        let data = try Data(contentsOf: url)
        let source: Data
        if url.pathExtension == "emlx" {
            guard let newline = data.firstIndex(of: 10),
                  let count = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  count >= 0, count <= data.count - newline - 1 else { throw failure() }
            source = data.subdata(in: (newline + 1)..<(newline + 1 + count))
        } else { source = data }
        let suffix = ".partial.emlx", name = url.lastPathComponent
        let attachmentsRoot = name.hasSuffix(suffix)
            ? url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Attachments/" + name.dropLast(suffix.count)) : nil
        var parts = try mimeParts(source, attachmentsRoot: attachmentsRoot, loadAttachments: loadAttachments)
        if let root = attachmentsRoot, FileManager.default.fileExists(atPath: root.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard !parts.contains(where: { $0.part == folder.lastPathComponent && $0.filename == file.lastPathComponent }) else { continue }
                    try requireInside(file, root: root)
                    let content = try attachment(file, load: loadAttachments)
                    parts.append(Part(part: folder.lastPathComponent,
                        type: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                        charset: nil, disposition: nil, filename: file.lastPathComponent, data: content.data, text: nil, byteCount: content.bytes))
                }
            }
        }
        return (headers(String(decoding: source, as: UTF8.self)), parts)
    }

    private static func attachment(_ file: URL, load: Bool) throws -> (data: Data?, bytes: Int64) {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else { throw failure() }
        return (load ? try Data(contentsOf: file) : nil, Int64(size))
    }

    private static func failure() -> NSError {
        NSError(domain: "PartMIMERead", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The saved message could not be parsed: its local copy has incomplete or unsupported MIME content."])
    }

    /// A downloaded part is a regular file inside its message's own Attachments folder; a link out of it is refused.
    private static func requireInside(_ file: URL, root: URL) throws {
        guard NativeAgentWorkspaceRoot.relativePath(file.resolvingSymlinksInPath().path, under: root.resolvingSymlinksInPath().path)
                .map({ !$0.isEmpty }) == true,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw failure() }
    }

    private static func headers(_ source: String) -> [String: String] {
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
    private static func mimeParts(_ source: Data, depth: Int = 0, partNumber: String = "", attachmentsRoot: URL?, loadAttachments: Bool) throws -> [Part] {
        guard depth < 20, let raw = String(data: source, encoding: .isoLatin1),
              let end = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") else { throw failure() }
        let fields = headers(String(raw[..<end.lowerBound]))
        let type = fields["content-type"] ?? "text/plain"
        let kind = type.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        let disposition = fields["content-disposition"].map { $0.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased() }
        let body = String(raw[end.upperBound...])
        let number = partNumber.isEmpty ? "1" : partNumber
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
        if let filename = parameter("filename", in: fields["content-disposition"] ?? "") ?? parameter("name"), !filename.isEmpty {
            let file = attachmentsRoot?.appendingPathComponent(number).appendingPathComponent(filename)
            let data: Data?
            var bytes: Int64?
            if let file, let root = attachmentsRoot, FileManager.default.fileExists(atPath: file.path) {
                try requireInside(file, root: root)
                let content = try attachment(file, load: loadAttachments)
                data = content.data; bytes = content.bytes
            } else if attachmentsRoot != nil && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                data = nil
            } else { data = try decode(body, encoding: fields["content-transfer-encoding"]) }
            return [Part(part: number, type: kind, charset: nil, disposition: disposition, filename: filename, data: data, text: nil, byteCount: bytes)]
        }
        if fields["content-disposition"]?.lowercased().hasPrefix("attachment") == true { return [] }
        if kind.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary"), !boundary.isEmpty else { throw failure() }
            var result: [Part] = [], lines: [String] = [], started = false, closed = false, count = 0
            for line in body.components(separatedBy: "\n") {
                let marker = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if marker == "--" + boundary || marker == "--" + boundary + "--" {
                    if started {
                        var source = lines.joined(separator: "\n")
                        if source.hasSuffix("\r") { source.removeLast() }
                        guard let data = source.data(using: .isoLatin1) else { throw failure() }
                        count += 1
                        result += try mimeParts(data, depth: depth + 1, partNumber: partNumber.isEmpty ? "\(count)" : "\(partNumber).\(count)",
                            attachmentsRoot: attachmentsRoot, loadAttachments: loadAttachments)
                    }
                    lines = []; started = true
                    if marker == "--" + boundary + "--" { closed = true; break }
                } else if started { lines.append(line) }
            }
            guard closed else { throw failure() }
            return result
        }
        guard ["text/plain", "text/html"].contains(kind) else { return [] }
        let data = try decode(body, encoding: fields["content-transfer-encoding"])
        let charset = parameter("charset") ?? "us-ascii"
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(charset as CFString))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) else { throw failure() }
        return [Part(part: number, type: kind, charset: charset, disposition: disposition, filename: nil, data: data, text: text)]
    }

    private static func decode(_ body: String, encoding: String?) throws -> Data {
        let data: Data?
        switch encoding?.lowercased() ?? "7bit" {
        case "base64":
            data = Data(base64Encoded: body.filter { !$0.isWhitespace })
        case "quoted-printable":
            guard let encoded = body.replacingOccurrences(of: "=\r\n", with: "")
                .replacingOccurrences(of: "=\n", with: "")
                .data(using: .isoLatin1) else { throw failure() }
            let input = Array(encoded)
            var bytes: [UInt8] = [], i = 0
            while i < input.count {
                if input[i] == UInt8(ascii: "=") {
                    guard i + 2 < input.count,
                          let byte = UInt8(String(decoding: input[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) else { throw failure() }
                    bytes.append(byte); i += 3
                } else { bytes.append(input[i]); i += 1 }
            }
            data = Data(bytes)
        case "7bit", "8bit", "binary": data = body.data(using: .isoLatin1)
        default: throw failure()
        }
        guard let data else { throw failure() }
        return data
    }
}
