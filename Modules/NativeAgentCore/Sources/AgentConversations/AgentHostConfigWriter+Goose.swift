import Foundation
import Yams

extension AgentHostConfigWriter {
    static func writeGooseEntry(path: String, name: String, entryJSON: String, backupRecordURL: URL) throws -> Outcome {
        try edit(path: path, backupRecordURL: backupRecordURL, initial: Data("extensions: {}\n".utf8)) {
            guard let result = try GooseEntrySplice.edit($0, name: name, entry: entryJSON) else { return nil }
            // Validate the proposed document too: appending after a YAML end
            // marker must never turn one valid document into two.
            _ = try GooseEntrySplice.edit(result.data, name: name, entry: nil)
            return result
        }
    }

    static func removeGooseEntry(path: String, name: String, backupRecordURL: URL) throws -> Outcome {
        try edit(path: path, backupRecordURL: backupRecordURL, removing: true) {
            try GooseEntrySplice.edit($0, name: name, entry: nil)
        }
    }
}

/// YAML is parsed for validity and source locations, never serialized back.
/// Our value is a single JSON flow mapping (also valid YAML), so its boundary
/// stays unambiguous even when adjacent settings contain multiline strings.
enum GooseEntrySplice {
    static func edit(_ data: Data, name: String, entry: String?) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        func refused() -> AgentHostConfigWriter.Failure {
            .unparsable("these settings cannot be edited safely; nothing was changed")
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.hasPrefix("\u{feff}"),
              // Aliases/merges can make a syntactically local edit affect other
              // sections. Refuse them, including ambiguous quoted spellings.
              text.range(of: #"(^|\s)[&*][^\s]+|<<\s*:"#, options: .regularExpression) == nil else { throw refused() }
        var documents: [Node] = []
        do {
            var stream = try Yams.compose_all(yaml: text)
            while let document = stream.next() { documents.append(document) }
            guard stream.error == nil else { throw refused() }
        } catch { throw refused() }
        guard documents.count == 1, let root = documents[0].mapping,
              let rootMark = root.mark, rootMark.column == 1 else { throw refused() }
        func check(_ node: Node) throws {
            if let mapping = node.mapping {
                var keys: Set<String> = []
                for pair in mapping {
                    guard let key = pair.key.string, keys.insert(key).inserted, key != "<<" else { throw refused() }
                    try check(pair.value)
                }
            } else if let sequence = node.sequence { for value in sequence { try check(value) } }
        }
        try check(documents[0])
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(rootMark.line - 1),
              !lines[rootMark.line - 1].hasPrefix("{") else { throw refused() }
        let section = root.first { $0.key.string == "extensions" }
        guard let section else {
            guard let entry else { return nil }
            let separator = text.hasSuffix("\n") || text.isEmpty ? "" : "\n"
            return (Data((text + separator + "extensions:\n  \(JSONEntrySplice.quoted(name)): \(entry)\n").utf8), false, false)
        }
        guard let servers = section.value.mapping, let sectionMark = section.key.mark else { throw refused() }
        if let ours = servers.first(where: { $0.key.string == name }) {
            guard let mark = ours.key.mark, lines.indices.contains(mark.line - 1) else { throw refused() }
            let index = mark.line - 1
            let line = lines[index]
            // Only replace/remove the single-line flow entry we write. A
            // hand-authored block of our name is a collision, not ours to erase.
            let prefix = String(repeating: " ", count: mark.column - 1) + JSONEntrySplice.quoted(name) + ": "
            guard line.hasPrefix(prefix),
                  (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8))) is [String: Any]
            else { throw refused() }
            if let entry { lines[index] = prefix + entry }
            else { lines.remove(at: index) }
            return (Data(lines.joined(separator: "\n").utf8), entry != nil, entry == nil)
        }
        guard let entry else { return nil }
        let index = sectionMark.line - 1
        guard lines.indices.contains(index) else { throw refused() }
        if servers.isEmpty {
            // Preserve any trailing comment on an empty mapping.
            guard let range = lines[index].range(of: "{}") else { throw refused() }
            lines[index].removeSubrange(range)
        } else {
            // Yams 5.1's mapping style comes from the ending event, so use
            // source positions to recognize the documented block form.
            guard let colon = lines[index].firstIndex(of: ":"),
                  let firstMark = servers.first?.key.mark, firstMark.line > sectionMark.line else { throw refused() }
            let suffix = lines[index][lines[index].index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard suffix.isEmpty || suffix.hasPrefix("#") else { throw refused() }
        }
        let indent = servers.first?.key.mark.map { $0.column - 1 } ?? 2
        lines.insert(String(repeating: " ", count: indent) + JSONEntrySplice.quoted(name) + ": " + entry, at: index + 1)
        return (Data(lines.joined(separator: "\n").utf8), false, false)
    }
}
