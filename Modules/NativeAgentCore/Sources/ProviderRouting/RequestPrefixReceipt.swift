import Foundation
import CryptoKit
import PersistenceCore

/// Hash slices of the encoded request, never a second serialization of its tools.
/// No request text leaves this value. Turn/history facts stay in the turn receipt.
enum RequestPrefixReceipt {
    static func payload(_ data: Data, prefix: ConversationPrefixTelemetrySnapshot) -> [String: JSONValue] {
        let json = Slices(bytes: Array(data))
        let root = json.members(0..<json.bytes.count)
        let tools = root["tools"].map { Data(json.bytes[$0]) } ?? Data()
        var stable: [Range<Int>] = []
        if let system = root["system"] {
            let blocks = json.elements(system)
            // Anthropic's last system breakpoint ends the stable block. The
            // following dynamic block is deliberately outside this measurement.
            if let end = blocks.lastIndex(where: { json.members($0)["cache_control"] != nil }) {
                stable = Array(blocks[...end])
            } else {
                stable = [system]
            }
        } else if let instructions = root["instructions"] {
            stable = [instructions]
        } else if let messages = root["messages"], let first = json.elements(messages).first,
                  let role = json.members(first)["role"],
                  ["system", "developer"].contains(json.string(role)) {
            stable = [first]
        }
        let stableHash = digest(stable.map { Data(json.bytes[$0]) })
        let toolsHash = digest([tools])
        return [
            "component.toolsSHA256": .string(toolsHash),
            "tools.wireSchemaBytes": .int(Int64(tools.count)),
            "component.stablePrefixSHA256": .string(stableHash),
            "prefixFingerprintSHA256": .string(digest(
                [Data(stableHash.utf8), Data(toolsHash.utf8)]
                    + prefix.prefixMessageDigests.map { Data($0.utf8) }
            )),
        ]
    }

    private static func digest(_ parts: [Data]) -> String {
        var hash = SHA256()
        for part in parts {
            hash.update(data: Data("\(part.count):".utf8))
            hash.update(data: part)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The input is JSON already encoded by the adapter. Walk values to retain
    /// their exact byte ranges, including escaped quotes and nested schemas.
    private struct Slices {
        let bytes: [UInt8]

        func skipSpace(_ i: inout Int) {
            while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
        }

        func value(_ i: inout Int) -> Range<Int> {
            skipSpace(&i)
            let start = i
            guard i < bytes.count else { return start..<i }
            if bytes[i] == 34 {
                i += 1
                while i < bytes.count {
                    let byte = bytes[i]
                    i += 1
                    if byte == 92 { i = min(i + 1, bytes.count) }
                    else if byte == 34 { break }
                }
            } else if bytes[i] == 91 || bytes[i] == 123 {
                let end: UInt8 = bytes[i] == 91 ? 93 : 125
                i += 1
                while i < bytes.count {
                    skipSpace(&i)
                    guard i < bytes.count else { break }
                    if bytes[i] == end { i += 1; break }
                    if bytes[i] == 44 || bytes[i] == 58 { i += 1 }
                    else { _ = value(&i) }
                }
            } else {
                while i < bytes.count && ![9, 10, 13, 32, 44, 58, 93, 125].contains(bytes[i]) { i += 1 }
            }
            return start..<i
        }

        func string(_ range: Range<Int>) -> String {
            (try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed)) as? String ?? ""
        }

        func members(_ range: Range<Int>) -> [String: Range<Int>] {
            guard bytes.indices.contains(range.lowerBound), bytes[range.lowerBound] == 123 else { return [:] }
            var i = range.lowerBound + 1
            var result: [String: Range<Int>] = [:]
            while i < range.upperBound {
                skipSpace(&i)
                guard i < range.upperBound, bytes[i] == 34 else { break }
                let key = string(value(&i))
                skipSpace(&i)
                i += 1 // colon
                result[key] = value(&i)
                skipSpace(&i)
                if i < range.upperBound, bytes[i] == 44 { i += 1 } else { break }
            }
            return result
        }

        func elements(_ range: Range<Int>) -> [Range<Int>] {
            guard bytes.indices.contains(range.lowerBound), bytes[range.lowerBound] == 91 else { return [] }
            var i = range.lowerBound + 1
            var result: [Range<Int>] = []
            while i < range.upperBound {
                skipSpace(&i)
                guard i < range.upperBound, bytes[i] != 93 else { break }
                result.append(value(&i))
                skipSpace(&i)
                if i < range.upperBound, bytes[i] == 44 { i += 1 } else { break }
            }
            return result
        }
    }
}
