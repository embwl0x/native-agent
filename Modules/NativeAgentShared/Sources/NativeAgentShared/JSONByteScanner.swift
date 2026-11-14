import Foundation
// Blueprint: | `JSONByteScanner.swift` | JSON byte spans; callers own validation and duplicate keys |

/// Lexical spans in caller-validated bytes, including offset-preserving JSONC masks.
public enum JSONByteScanner {
    public struct Failure: Error, LocalizedError {
        public let detail: String
        public var errorDescription: String? { detail }
    }

    public struct Member {
        public let start: Int
        public let valueStart: Int
        public let end: Int
        public let key: String
        public let comma: Int?
    }

    public struct Scan {
        public let members: [Member]
        public let open: Int
        public let close: Int
    }

    public static func members(_ bytes: [UInt8], from open: Int) throws -> Scan {
        guard bytes.indices.contains(open), bytes[open] == UInt8(ascii: "{") else {
            throw Failure(detail: "its top level is not a JSON object")
        }
        var index = open + 1
        var found: [Member] = []
        skipWhitespace(bytes, &index)
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            return Scan(members: [], open: open, close: index)
        }
        while true {
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw Failure(detail: "an object member has no name")
            }
            let start = index
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[string(bytes, &index)]))
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw Failure(detail: "an object member has no value")
            }
            index += 1
            skipWhitespace(bytes, &index)
            let valueStart = index
            try skipValue(bytes, &index)
            let end = index
            skipWhitespace(bytes, &index)
            guard index < bytes.count else { throw Failure(detail: "an object is never closed") }
            let comma = bytes[index] == UInt8(ascii: ",") ? index : nil
            found.append(Member(start: start, valueStart: valueStart, end: end, key: key, comma: comma))
            if comma != nil { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") {
                return Scan(members: found, open: open, close: index)
            }
            throw Failure(detail: "an object member is not followed by ',' or '}'")
        }
    }

    public static func elements(_ bytes: [UInt8], from open: Int) throws -> [Range<Int>] {
        guard bytes.indices.contains(open), bytes[open] == UInt8(ascii: "[") else { return [] }
        var index = open + 1
        var found: [Range<Int>] = []
        skipWhitespace(bytes, &index)
        while index < bytes.count, bytes[index] != UInt8(ascii: "]") {
            let start = index
            try skipValue(bytes, &index)
            found.append(start..<index)
            skipWhitespace(bytes, &index)
            if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                index += 1
                skipWhitespace(bytes, &index)
            } else { break }
        }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "]") else {
            throw Failure(detail: "an array is never closed")
        }
        return found
    }

    /// Text that opens with one JSON object, read lexically: strings and their escapes are content, never structure. Offsets are UTF-16, as
    /// marker text is measured.
    public enum ObjectRead: Equatable {
        /// Still being written: nothing but whitespace yet, or a string or container left open where the text ends.
        case open
        /// The object ends at `objectEnd`; `closer` is the first of the given closers written right after it, past whitespace, if one is.
        case closed(objectEnd: Int, closer: Range<Int>?)
    }

    /// How `text` reads as one JSON object followed by one of `closers`; nil when no object opens it. Callers own validation.
    public static func objectRead(_ text: some StringProtocol, closers: [String]) -> ObjectRead? {
        let bytes = Array(text.utf8)
        var index = 0
        skipWhitespace(bytes, &index)
        guard index < bytes.count else { return .open }
        guard bytes[index] == UInt8(ascii: "{") else { return nil }
        guard (try? skipValue(bytes, &index)) != nil else { return .open }
        let objectEnd = index
        skipWhitespace(bytes, &index)
        let rest = bytes[index...]
        // Structure is ASCII, so every offset here falls between whole characters.
        func units(_ offset: Int) -> Int { String(decoding: bytes[..<offset], as: UTF8.self).utf16.count }
        let closer = closers.first { rest.starts(with: $0.utf8) }.map { units(index)..<units(index + $0.utf8.count) }
        return .closed(objectEnd: units(objectEnd), closer: closer)
    }

    public static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
            || bytes[index] == 0x0a || bytes[index] == 0x0d { index += 1 }
    }

    public static func string(_ bytes: [UInt8], _ index: inout Int) throws -> Range<Int> {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
            throw Failure(detail: "a string does not start with a quote")
        }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                guard index + 1 < bytes.count else { break }
                index += 2; continue
            }
            if byte == UInt8(ascii: "\"") {
                index += 1
                return start..<index
            }
            index += 1
        }
        throw Failure(detail: "a string is never closed")
    }

    private static func skipValue(_ bytes: [UInt8], _ index: inout Int) throws {
        guard index < bytes.count else { throw Failure(detail: "a value is missing") }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            _ = try string(bytes, &index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { _ = try string(bytes, &index); continue }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
                if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1; index += 1
                    if depth == 0 { return }
                    continue
                }
                index += 1
            }
            throw Failure(detail: "a container is never closed")
        default:
            let terminators: Set<UInt8> = [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                                           0x20, 0x09, 0x0a, 0x0d]
            let start = index
            while index < bytes.count, !terminators.contains(bytes[index]) { index += 1 }
            guard index > start else { throw Failure(detail: "a value is empty") }
        }
    }
}
