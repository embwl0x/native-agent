import Foundation
import NativeAgentShared
// Blueprint: | `TOMLEntrySplice.swift` | `TOMLEntrySplice` enum; byte-preserving TOML table splicing and ownership fields |

/// TOML tables are line-delimited, which is what makes a splice possible
/// without a full parser: `[mcp_servers.<name>]` and every line up to the next
/// header at the start of a line is our block, and nothing else in the file is
/// read or rewritten.
///
/// The one construct that would break that reading is a multi-line string,
/// whose body can contain a line that LOOKS like a header. A file containing
/// one is refused rather than guessed at.
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
            // Decode the basic/literal strings used by these scalar fields,
            // allowing trailing TOML comments without interpreting their text.
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
        // Append exactly the block and a closing newline, and nothing else: a
        // blank separator line would be a byte OUTSIDE our entry that a later
        // disconnect could not take back, so removing us would not restore the
        // file the person had.
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
        // THE RAW BYTES, before decoding: Foundation quietly drops a leading
        // byte-order mark, so a check on the decoded string sees nothing and
        // the mark would then vanish from what we write back — a byte changed
        // outside our own entry. It also means the first table header no longer
        // compares equal, so we would append a SECOND copy of our table beside
        // the one already there.
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

    /// TOML spells one table many ways: `[mcp_servers."nativeagent"]`,
    /// `[ mcp_servers . nativeagent ]`, single quotes. This writer understands
    /// exactly ONE spelling, and a file using another would get a duplicate
    /// table appended beside the one it already has. So an equivalent header
    /// that is not our canonical spelling is REFUSED, not taught — the person
    /// reads why and decides what to do with their own file.
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

    /// Our table header, plus its key/value lines and any nested
    /// `[mcp_servers.<name>.env]` sub-table, up to the next unrelated header.
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
                guard !line.contains("\\") else { throw AgentHostConfigWriter.Failure.unparsable("an escaped table key cannot be spliced safely; use plain table keys before connecting") }
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
                guard !key.contains("\\") else { throw AgentHostConfigWriter.Failure.unparsable("an escaped assignment key cannot be spliced safely; use plain keys before connecting") }
                let qualified = section.isEmpty ? key : String(section.dropFirst().dropLast()) + "." + key
                if qualified == tablePrefix || qualified == tablePrefix + "." + name || qualified.hasPrefix(tablePrefix + "." + name + ".") && !section.hasPrefix(header.dropLast()) {
                    throw AgentHostConfigWriter.Failure.unparsable("existing inline/dotted assignment \(qualified); review it before connecting. Only an absent [\(tablePrefix).\(name)] entry can be added")
                }
            }
            cursor = lineEnd
        }
        // Every header is read to the end of the file, not just up to where our
        // block stops: an equivalent spelling — or a second copy of our own
        // table — further down must still be refused rather than left to become
        // a duplicate.
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

    /// TOML basic-string escaping for a value this app puts in the file.
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
