import Foundation

/// Independently implemented from wire-format facts documented by the format's
/// reverse engineer, Christopher Sardegna:
/// https://chrissardegna.com/blog/reverse-engineering-apples-typedstream-format/
/// No imessage-exporter/crabstep implementation is copied or linked (both GPL).
/// Reads only the leading Foundation string, never instantiates archived classes
/// or interprets attributes, selectors, attachments, or executable objects.
enum MacMessagesTypedString {
    static let maximumArchiveBytes = 64 * 1024

    static func decode(_ data: Data, deadline: TimeInterval) -> String? {
        guard !data.isEmpty, data.count <= maximumArchiveBytes,
              ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else { return nil }
        var reader = Reader(bytes: Array(data), deadline: deadline)
        return try? reader.body()
    }

    private enum Invalid: Error { case unsupported }
    private struct ClassDescription: Equatable {
        let name: String
        let version: Int
    }

    private struct Reader {
        let bytes: [UInt8]
        let deadline: TimeInterval
        var offset = 0
        var strings: [String] = []
        // nil slots belong to object instances, not classes. This makes an
        // object reference invalid wherever the grammar requires a class.
        var classes: [[ClassDescription]?] = []

        mutating func body() throws -> String {
            try expect(4)
            try expect(11)
            guard try rawString(count: 11) == "streamtyped", try length() == 1000 else { throw Invalid.unsupported }
            guard try sharedString() == "@" else { throw Invalid.unsupported }
            let root = try objectClasses()
            let stringClass = ClassDescription(name: "NSString", version: 1)
            let mutableString = ClassDescription(name: "NSMutableString", version: 1)
            let base = ClassDescription(name: "NSObject", version: 0)
            let attributed = ClassDescription(name: "NSAttributedString", version: 0)
            let mutableAttributed = ClassDescription(name: "NSMutableAttributedString", version: 0)
            let attributedRoot = root == [attributed, base] || root == [mutableAttributed, attributed, base]
            if attributedRoot {
                guard try sharedString() == "@" else { throw Invalid.unsupported }
                let wrapped = try objectClasses()
                guard wrapped == [stringClass, base] || wrapped == [mutableString, stringClass, base] else { throw Invalid.unsupported }
            } else {
                guard root == [stringClass, base] || root == [mutableString, stringClass, base] else { throw Invalid.unsupported }
            }
            guard try sharedString() == "+" else { throw Invalid.unsupported }
            let bodyLength = try length()
            let text = try rawString(count: bodyLength)
            // The exact byte length determines the body boundary. A literal
            // marker within the text cannot stop this read or become metadata.
            try expect(0x86)
            if attributedRoot {
                // Only the string prefix is decoded. Attribute contents remain
                // uninterpreted; never search them for another plausible string.
                guard offset < bytes.count, bytes.last == 0x86 else { throw Invalid.unsupported }
            } else if offset != bytes.count { throw Invalid.unsupported }
            try checkBudget()
            return text
        }

        private mutating func objectClasses() throws -> [ClassDescription] {
            try expect(0x84)
            guard classes.count < 12 else { throw Invalid.unsupported }
            classes.append(nil)
            let result = try classChain(depth: 0)
            guard !result.isEmpty else { throw Invalid.unsupported }
            return result
        }

        private mutating func classChain(depth: Int) throws -> [ClassDescription] {
            guard depth < 4 else { throw Invalid.unsupported }
            let marker = try byte()
            if marker == 0x85 { return [] }
            if marker != 0x84 {
                let index = Int(marker) - 0x92
                guard index >= 0, index < classes.count, let value = classes[index] else { throw Invalid.unsupported }
                return value
            }
            let name = try sharedString()
            let version = try length()
            guard ["NSObject", "NSString", "NSMutableString", "NSAttributedString", "NSMutableAttributedString"].contains(name),
                  version <= 1, classes.count < 12 else { throw Invalid.unsupported }
            let index = classes.count
            classes.append(nil)
            let parents = try classChain(depth: depth + 1)
            let chain = [ClassDescription(name: name, version: version)] + parents
            guard chain.count <= 3 else { throw Invalid.unsupported }
            classes[index] = chain
            return chain
        }

        private mutating func sharedString() throws -> String {
            let marker = try byte()
            if marker == 0x84 {
                let count = try length()
                guard count <= 64, strings.count < 16 else { throw Invalid.unsupported }
                let value = try rawString(count: count)
                strings.append(value)
                return value
            }
            let index = Int(marker) - 0x92
            guard index >= 0, index < strings.count else { throw Invalid.unsupported }
            return strings[index]
        }

        /// Only unsigned lengths needed here. Reserved markers, 64-bit numbers,
        /// negative lengths and lengths exceeding the archive budget are refused.
        private mutating func length() throws -> Int {
            let marker = try byte()
            let width: Int
            switch marker {
            case 0x81: width = 2
            case 0x82: width = 4
            case 0...0x7f, 0x92...0xff: return Int(marker)
            default: throw Invalid.unsupported
            }
            var value: UInt32 = 0
            for shift in 0..<width { value |= UInt32(try byte()) << (shift * 8) }
            guard value <= UInt32(maximumArchiveBytes) else { throw Invalid.unsupported }
            return Int(value)
        }

        private mutating func rawString(count: Int) throws -> String {
            try checkBudget()
            guard count >= 0, count <= bytes.count - offset,
                  let value = String(bytes: bytes[offset..<(offset + count)], encoding: .utf8) else { throw Invalid.unsupported }
            offset += count
            return value
        }
        private mutating func expect(_ expected: UInt8) throws {
            guard try byte() == expected else { throw Invalid.unsupported }
        }
        private mutating func byte() throws -> UInt8 {
            try checkBudget()
            guard offset < bytes.count else { throw Invalid.unsupported }
            defer { offset += 1 }
            return bytes[offset]
        }
        private func checkBudget() throws {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw Invalid.unsupported }
        }
    }
}
