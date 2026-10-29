import Foundation
import NativeAgentShared
// Blueprint: | `JSONEntrySplice.swift` | Byte-preserving JSON/JSONC member splicing, validation and duplicate-key refusal over shared JSONByteScanner spans |

/// Splice one member without re-encoding the rest. Validate the complete object
/// before shared lexical scanning; refuse unreadable or ambiguous settings.
enum JSONEntrySplice {

    /// THE ONE member of this name, or none. JSON permits duplicate keys and
    /// readers disagree about which of them wins, so a file carrying two is
    /// ambiguous: we would edit the copy the host is going to ignore, and the
    /// person would see a connection that does not work. Refuse before
    /// splicing rather than guess which one is live.
    static func unique(_ members: [JSONByteScanner.Member], named key: String, called what: String) throws -> JSONByteScanner.Member? {
        let matches = members.filter { $0.key == key }
        guard matches.count <= 1 else {
            throw AgentHostConfigWriter.Failure.unparsable(
                "it has more than one \(what) named \"\(key)\", so which one the app actually uses is ambiguous")
        }
        return matches.first
    }

    static func upsert(_ data: Data, name: String, entryJSON: String,
                       containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true,
                       originalMember: String? = nil, fragment: Bool = false) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let bytes = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas)
        _ = try validatedBytes(Data((fragment ? "{\"value\":" + entryJSON + "}" : entryJSON).utf8), comments: comments, trailingCommas: trailingCommas)
        func validated(_ output: Data, replaced: Bool) throws -> (data: Data, replaced: Bool, removed: Bool) {
            _ = try validatedBytes(output, comments: comments, trailingCommas: trailingCommas)
            return (output, replaced, false)
        }
        let original = [UInt8](data)
        let root = try JSONByteScanner.members(bytes, from: try objectStart(bytes))
        guard let container = try unique(root.members, named: containerKey, called: "section") else {
            // No servers configured yet: add the whole container as one new
            // top-level member, leaving every existing member untouched.
            let indent = indentation(bytes, memberStart: root.members.first?.start)
            let member = originalMember ?? (quoted(name) + ": " + reindented(entryJSON, by: indent + indent))
            let body = "\"\(containerKey)\": {\n\(indent)\(indent)" + member + "\n\(indent)}"
            return try validated(insertMember(original, into: root, text: body, indent: indent), replaced: false)
        }
        let valueStart = container.valueStart
        guard bytes[valueStart] == UInt8(ascii: "{") else {
            throw AgentHostConfigWriter.Failure.unparsable("\"\(containerKey)\" is not an object")
        }
        let inner = try JSONByteScanner.members(bytes, from: valueStart)
        let indent = indentation(bytes, memberStart: inner.members.first?.start)
        if let existing = try unique(inner.members, named: name, called: "server") {
            let replacement = originalMember ?? (quoted(name) + ": " + reindented(entryJSON, by: indent))
            return try validated(splice(original, range: existing.start..<existing.end, with: replacement), replaced: true)
        }
        let body = originalMember ?? (quoted(name) + ": " + reindented(entryJSON, by: indent))
        return try validated(insertMember(original, into: inner, text: body, indent: indent), replaced: false)
    }

    static func remove(_ data: Data, name: String, containerKey: String = "mcpServers", comments: Bool = false, trailingCommas: Bool = true) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let bytes = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas)
        let root = try JSONByteScanner.members(bytes, from: try objectStart(bytes))
        guard let container = try unique(root.members, named: containerKey, called: "section") else { return nil }
        let valueStart = container.valueStart
        guard bytes[valueStart] == UInt8(ascii: "{") else { return nil }
        let inner = try JSONByteScanner.members(bytes, from: valueStart)
        guard let existing = try unique(inner.members, named: name, called: "server") else { return nil }
        let separators = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas, preservingTrailingCommas: true)
        let output = splice([UInt8](data), range: deletionRange(separators, of: existing, in: inner), with: "")
        _ = try validatedBytes(output, comments: comments, trailingCommas: trailingCommas)
        return (output, false, true)
    }

    static func entry(_ data: Data, name: String, containerKey: String, comments: Bool,
                      trailingCommas: Bool) throws -> (value: String, member: String)? {
        let bytes = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas)
        let root = try JSONByteScanner.members(bytes, from: objectStart(bytes))
        guard let container = try unique(root.members, named: containerKey, called: "section") else { return nil }
        let start = container.valueStart
        guard bytes[start] == 123 else { throw AgentHostConfigWriter.Failure.unparsable("server section is not an object") }
        guard let member = try unique(JSONByteScanner.members(bytes, from: start).members, named: name, called: "server") else { return nil }
        let original = Array(data)
        return (String(decoding: original[member.valueStart..<member.end], as: UTF8.self),
                String(decoding: original[member.start..<member.end], as: UTF8.self))
    }

    /// Find our command AND connection id throughout the document, including
    /// renamed or relocated members. A same-name foreign member is never ours.
    static func disconnect(_ data: Data, owner: AgentHostConfigWriter.JSONOwnership,
                           containerKey: String, comments: Bool, trailingCommas: Bool) throws
        -> (data: Data, replaced: Bool, removed: Bool)? {
        let bytes = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas)
        let separators = try validatedBytes(data, comments: comments, trailingCommas: trailingCommas, preservingTrailingCommas: true)
        var ranges: [Range<Int>] = []
        func walk(_ start: Int) throws {
            if bytes[start] == 123 {
                let scan = try JSONByteScanner.members(bytes, from: start)
                for member in scan.members {
                    _ = try unique(scan.members, named: member.key, called: "member")
                    let value = member.valueStart
                    let object = try? JSONSerialization.jsonObject(with: Data(bytes[value..<member.end])) as? [String: Any]
                    let env = object?["env"] as? [String: Any]
                    if object?["command"] as? String == owner.command,
                       env?[AgentHostDirectory.peerIDVariable] as? String == owner.peerID {
                        ranges.append(deletionRange(separators, of: member, in: scan))
                    } else { try walk(value) }
                }
            } else if bytes[start] == 91 {
                for element in try JSONByteScanner.elements(bytes, from: start) {
                    try walk(element.lowerBound)
                }
            }
        }
        try walk(objectStart(bytes))
        // Delete one member then rescan: adjacent members share separators.
        var output = data
        if let range = ranges.first {
            output = splice(Array(data), range: range, with: "")
            if ranges.count > 1 {
                output = try disconnect(output, owner: .init(command: owner.command, peerID: owner.peerID,
                    name: owner.name, original: nil), containerKey: containerKey,
                    comments: comments, trailingCommas: trailingCommas)?.data ?? output
            }
        }
        if let original = owner.original {
            if let current = try entry(output, name: owner.name, containerKey: containerKey,
                                       comments: comments, trailingCommas: trailingCommas)?.value {
                let lhs = try JSONSerialization.jsonObject(with: Data(validatedBytes(Data(current.utf8), comments: comments, trailingCommas: trailingCommas))) as? NSDictionary
                let rhs = try JSONSerialization.jsonObject(with: Data(validatedBytes(Data(original.utf8), comments: comments, trailingCommas: trailingCommas))) as? NSDictionary
                guard lhs == rhs else { throw AgentHostConfigWriter.Failure.unparsable("the original entry's name is occupied; resolve the collision before disconnecting") }
            } else {
                output = try upsert(output, name: owner.name, entryJSON: original,
                    containerKey: containerKey, comments: comments, trailingCommas: trailingCommas,
                    originalMember: owner.originalMember)!.data
            }
        }
        _ = try validatedBytes(output, comments: comments, trailingCommas: trailingCommas)
        return output == data ? nil : (output, false, !ranges.isEmpty)
    }

    // MARK: Scanning

    /// Mask JSONC trivia with spaces, keeping every byte offset into the original.
    /// Foundation validates the entire document, including nested values and EOF.
    static func validatedBytes(_ data: Data, comments: Bool, trailingCommas: Bool = true,
                               preservingTrailingCommas: Bool = false) throws -> [UInt8] {
        do {
            var bytes = [UInt8](data)
            guard String(data: data, encoding: .utf8) != nil else {
                throw AgentHostConfigWriter.Failure.unparsable("the file is not valid text")
            }
            if comments {
                var i = 0
                while i < bytes.count {
                    if bytes[i] == 34 { _ = try JSONByteScanner.string(bytes, &i); continue }
                    if bytes[i] == 47, i + 1 < bytes.count, bytes[i + 1] == 47 {
                        while i < bytes.count, bytes[i] != 10, bytes[i] != 13 { bytes[i] = 32; i += 1 }
                    } else if bytes[i] == 47, i + 1 < bytes.count, bytes[i + 1] == 42 {
                        bytes[i] = 32; bytes[i + 1] = 32; i += 2
                        var closed = false
                        while i < bytes.count {
                            if bytes[i] == 42, i + 1 < bytes.count, bytes[i + 1] == 47 {
                                bytes[i] = 32; bytes[i + 1] = 32; i += 2; closed = true; break
                            }
                            if bytes[i] != 10, bytes[i] != 13 { bytes[i] = 32 }
                            i += 1
                        }
                        guard closed else { throw AgentHostConfigWriter.Failure.unparsable("a comment is never closed") }
                    } else { i += 1 }
                }
            }
            let withoutComments = bytes
            var i = 0
            while i < bytes.count {
                if bytes[i] == 34 { _ = try JSONByteScanner.string(bytes, &i); continue }
                if bytes[i] == 44 {
                    var next = i + 1
                    JSONByteScanner.skipWhitespace(bytes, &next)
                    if next < bytes.count, bytes[next] == 125 || bytes[next] == 93 {
                        guard comments && trailingCommas else { throw AgentHostConfigWriter.Failure.unparsable("a trailing comma is not allowed") }
                        var previous = i - 1
                        while previous >= 0, [UInt8(32), 9, 10, 13].contains(bytes[previous]) { previous -= 1 }
                        guard previous >= 0, ![UInt8(123), 91, 44, 58].contains(bytes[previous]) else {
                            throw AgentHostConfigWriter.Failure.unparsable("a value is missing")
                        }
                        bytes[i] = 32
                    }
                }
                i += 1
            }
            guard (try? JSONSerialization.jsonObject(with: Data(bytes))) is [String: Any] else {
                throw AgentHostConfigWriter.Failure.unparsable("the settings are not a complete object")
            }
            return preservingTrailingCommas ? withoutComments : bytes
        } catch let failure as JSONByteScanner.Failure {
            throw AgentHostConfigWriter.Failure.unparsable(failure.detail)
        }
    }

    private static func objectStart(_ bytes: [UInt8]) throws -> Int {
        var index = 0
        JSONByteScanner.skipWhitespace(bytes, &index)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else {
            throw AgentHostConfigWriter.Failure.unparsable("its top level is not a JSON object")
        }
        return index
    }

    // MARK: Splicing

    private static func splice(_ bytes: [UInt8], range: Range<Int>, with text: String) -> Data {
        var output = Data(bytes[bytes.startIndex..<range.lowerBound])
        output.append(contentsOf: Array(text.utf8))
        output.append(contentsOf: bytes[range.upperBound..<bytes.endIndex])
        return output
    }

    /// A removed member takes its own separating comma with it, so the object
    /// is still valid JSON and no other member's bytes move.
    private static func deletionRange(_ bytes: [UInt8], of member: JSONByteScanner.Member, in scan: JSONByteScanner.Scan) -> Range<Int> {
        guard let position = scan.members.firstIndex(where: { $0.start == member.start }) else {
            return member.start..<member.end
        }
        if position > 0 {
            // Take everything from the end of the previous member: the comma,
            // and the whitespace that belonged to this row.
            return scan.members[position - 1].end..<member.end
        }
        if scan.members.count > 1 {
            // First of several: take up to the start of the next member.
            return member.start..<scan.members[1].start
        }
        var end = member.end
        JSONByteScanner.skipWhitespace(bytes, &end)
        if end < scan.close, bytes[end] == UInt8(ascii: ",") {
            return member.start..<(end + 1)
        }
        return member.start..<member.end
    }

    private static func insertMember(_ bytes: [UInt8], into scan: JSONByteScanner.Scan, text: String, indent: String) -> Data {
        if let last = scan.members.last {
            return splice(bytes, range: last.end..<last.end, with: ",\n" + indent + text)
        }
        // An empty object: put the first member between its braces.
        return splice(bytes, range: (scan.open + 1)..<(scan.open + 1), with: text)
    }

    /// The indentation the file already uses for members of this object, so an
    /// inserted row looks like the rows around it. Two spaces when the object
    /// is empty or written on one line.
    private static func indentation(_ bytes: [UInt8], memberStart: Int?) -> String {
        guard let memberStart else { return "  " }
        var index = memberStart - 1
        var run: [UInt8] = []
        while index >= 0, bytes[index] == 0x20 || bytes[index] == 0x09 {
            run.append(bytes[index]); index -= 1
        }
        guard index >= 0, bytes[index] == 0x0a, !run.isEmpty else { return "  " }
        return String(decoding: run.reversed(), as: UTF8.self)
    }

    /// Our entry is authored with two-space indents at depth zero; push every
    /// line after the first out to where it is being pasted.
    private static func reindented(_ text: String, by indent: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { $0.offset == 0 ? String($0.element) : indent + $0.element }
            .joined(separator: "\n")
    }

    /// A JSON string literal. Slashes stay slashes: this file is one the person
    /// opens and reads, and a path written as `\/Users\/…` is legal JSON that
    /// looks like a mistake.
    static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let literal = String(data: data, encoding: .utf8) else { return "\"\(text)\"" }
        return literal
    }
}
