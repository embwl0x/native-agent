import Foundation
import NativeAgentShared
// Blueprint: | `TOMLEntrySplice.swift` | `TOMLEntrySplice` enum; byte-preserving TOML table splicing and ownership fields |

/// Line-delimited tables permit byte splicing without a full parser. Refuse multiline strings because their contents can mimic table headers.
enum TOMLEntrySplice {
    static let tablePrefix = "mcp_servers"

    static func entry(_ data: Data, name: String) throws -> String? {
        let text = try readable(data)
        return try range(of: name, in: text).map { String(text[$0]) }
    }

    /// Ownership needs both fields; staleness needs only the command.
    static func identity(_ data: Data, name: String) throws -> (command: String, peerID: String)? {
        let found = try fields(data, name: name)
        guard let command = found.command, let peerID = found.peerID else { return nil }
        return (command, peerID)
    }

    static func fields(_ data: Data, name: String) throws -> (command: String?, peerID: String?) {
        guard let block = try entry(data, name: name) else { return (nil, nil) }
        var section = ""
        var values: [String: String] = [:]
        for raw in block.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let header = try tableHeader(in: line) { section = header; continue }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let wanted = (section == "[mcp_servers.\(name)]" && key == "command")
                || (section == "[mcp_servers.\(name).env]" && key == AgentHostDirectory.peerIDVariable)
            guard wanted else { continue }
            guard values[key] == nil else { throw AgentHostConfigWriter.Failure.unparsable("duplicate ownership field") }
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            // Decode scalar strings while excluding trailing TOML comments from their values.
            let pattern = #"^("(?:[^"\\]|\\.)*"|'[^']*')\s*(?:#.*)?$"#
            guard let match = value.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(value[match])
            if matched.first == "'", let end = matched.dropFirst().firstIndex(of: "'") {
                values[key] = String(matched[matched.index(after: matched.startIndex)..<end])
            } else {
                let bytes = Array(matched.utf8)
                var index = 0
                values[key] = try JSONDecoder().decode(String.self, from: Data(bytes[JSONByteScanner.string(bytes, &index)]))
            }
        }
        return (values["command"], values[AgentHostDirectory.peerIDVariable])
    }

    static func disconnect(_ data: Data, owner: AgentHostConfigWriter.JSONOwnership) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let text = try readable(data)
        var names = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            guard let line = try tableHeader(in: raw.trimmingCharacters(in: .whitespaces)),
                  line.hasPrefix("[mcp_servers.") else { continue }
            let name = String(line.dropFirst("[mcp_servers.".count).dropLast())
            guard !name.contains(".") else { continue }
            guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw AgentHostConfigWriter.Failure.unparsable("a server table uses an unsupported spelling")
            }
            names.insert(name)
        }
        var output = data
        var removed = false
        for name in names.sorted() {
            if let identity = try identity(output, name: name),
               identity.command == owner.command, identity.peerID == owner.peerID {
                output = try remove(output, name: name)!.data
                removed = true
            }
        }
        if let original = owner.original {
            if let current = try entry(output, name: owner.name) {
                guard current == original else {
                    throw AgentHostConfigWriter.Failure.unparsable("the original entry's name is occupied; resolve the collision before disconnecting")
                }
            } else {
                output = try upsert(output, name: owner.name, entryTOML: original)!.data
            }
        }
        return output == data ? nil : (output, false, removed)
    }

    static func upsert(_ data: Data, name: String, entryTOML: String) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let text = try readable(data)
        let block = try range(of: name, in: text)
        let body = entryTOML.hasSuffix("\n") ? entryTOML : entryTOML + "\n"
        if let block {
            return (Data((text.replacingCharacters(in: block, with: body)).utf8), true, false)
        }
        // Append only the owned block and final newline; extra separators could not be removed without changing foreign bytes.
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        return (Data((text + separator + body).utf8), false, false)
    }

    static func remove(_ data: Data, name: String) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let text = try readable(data)
        guard let block = try range(of: name, in: text) else { return nil }
        return (Data(text.replacingCharacters(in: block, with: "").utf8), false, true)
    }

    private static func readable(_ data: Data) throws -> String {
        // Check the raw BOM before Foundation decoding drops it, or rewriting can change foreign bytes and duplicate the first header.
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else {
                    throw AgentHostConfigWriter.Failure.unparsable(
                "it starts with a byte-order mark, which this writer will not edit around")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentHostConfigWriter.Failure.unparsable("it is not valid UTF-8")
        }
        guard !text.contains("\"\"\""), !text.contains("'''") else {
                    throw AgentHostConfigWriter.Failure.unparsable(
                "it contains a multi-line string, which this writer will not edit around")
        }
        return text
    }

    /// Refuse equivalent noncanonical table spellings because appending beside them would duplicate the same logical table.
    private static func rejectEquivalentSpelling(_ line: String, name: String) throws {
        let canonical = "[\(tablePrefix).\(name)]"
        guard line != canonical, !line.hasPrefix("[\(tablePrefix).\(name).") else { return }
        let bare = line.filter { $0 != " " && $0 != "\t" && $0 != "\"" && $0 != "'" }
        let ours = "[\(tablePrefix).\(name)"
        guard bare == ours + "]" || bare.hasPrefix(ours + ".") else { return }
                    throw AgentHostConfigWriter.Failure.unparsable(
            "it already names this app's table as \(line), which is the same table written a "
            + "different way; this writer only edits the plain \(canonical) form")
    }

    /// Include nested env tables in the owned block, stopping at the next unrelated header.
    private static func range(of name: String, in text: String) throws -> Range<String.Index>? {
        let header = "[\(tablePrefix).\(name)]"
        let nested = "[\(tablePrefix).\(name)."
        var start: String.Index?
        var end = text.endIndex
        var cursor = text.startIndex
        var blocks = 0
        var section = ""
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = text[cursor..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if let line = try tableHeader(in: line) {
                guard !line.contains("\\") else { throw AgentHostConfigWriter.Failure.unparsable(
                    "an escaped table key cannot be spliced safely; use plain table keys before connecting") }
                section = line.filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
                try rejectEquivalentSpelling(line, name: name)
                let isOurs = line == header || line.hasPrefix(nested)
                guard !isOurs || end == text.endIndex else {
                    throw AgentHostConfigWriter.Failure.unparsable(
                        "this app's table has a subtable after an unrelated table; keep its tables together before editing")
                }
                if line == header { blocks += 1 }
                if isOurs, start == nil { start = cursor }
                if !isOurs, start != nil, end == text.endIndex { end = cursor }
            } else if !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") {
                let key = line[..<equal].filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
                guard !key.contains("\\") else { throw AgentHostConfigWriter.Failure.unparsable(
                    "an escaped assignment key cannot be spliced safely; use plain keys before connecting") }
                let qualified = section.isEmpty ? key : String(section.dropFirst().dropLast()) + "." + key
                if qualified == tablePrefix || qualified == tablePrefix + "." + name || qualified.hasPrefix(tablePrefix + "." + name + ".")
                    && !section.hasPrefix(header.dropLast()) {
                    throw AgentHostConfigWriter.Failure.unparsable("""
                        existing inline/dotted assignment \(qualified); review it before connecting. Only an absent [\(tablePrefix).\(name)] entry \
                        can be added
                        """)
                }
            }
            cursor = lineEnd
        }
        // Scan headers through EOF so duplicate or equivalent headers beyond our block cannot escape refusal.
        guard blocks <= 1 else {
                    throw AgentHostConfigWriter.Failure.unparsable(
                "it already has more than one \(header) table, so which one is live is ambiguous")
        }
        guard let start else { return nil }
        return start..<end
    }

    // Parse only the header; splice ranges still refer to the untouched text.
    private static func tableHeader(in line: String) throws -> String? {
        guard line.hasPrefix("[") else { return nil }
        let pattern = #"^\[(?:[^\"'#]|\"(?:[^\"\\]|\\.)*\"|'[^']*')*\](?=\s*(?:#.*)?$)"#
        guard let match = line.range(of: pattern, options: .regularExpression) else {
            throw AgentHostConfigWriter.Failure.unparsable("a table header is malformed")
        }
        return String(line[match])
    }

    static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 { output += String(format: "\\u%04X", scalar.value) }
                else { output.unicodeScalars.append(scalar) }
            }
        }
        return output + "\""
    }
}
