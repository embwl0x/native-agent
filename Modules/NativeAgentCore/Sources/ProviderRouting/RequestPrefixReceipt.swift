import Foundation
import CryptoKit
import PersistenceCore
import NativeAgentShared

// Blueprint: | `RequestPrefixReceipt.swift` | `RequestPrefixReceipt`: hashes exact encoded request byte slices without reserializing tools or exposing request text |

/// Hash slices of the encoded request, never a second serialization of its tools.
/// No request text leaves this value. Turn/history facts stay in the turn receipt.
enum RequestPrefixReceipt {
    static func payload(_ data: Data, prefix: ConversationPrefixTelemetrySnapshot) throws -> [String: JSONValue] {
        let bytes = Array(data)
        func members(_ range: Range<Int>) throws -> [String: Range<Int>] {
            guard bytes.indices.contains(range.lowerBound), bytes[range.lowerBound] == 123 else { return [:] }
            return try JSONByteScanner.members(bytes, from: range.lowerBound).members.reduce(into: [:]) {
                $0[$1.key] = $1.valueStart..<$1.end
            }
        }
        let root = try members(0..<bytes.count)
        let tools = root["tools"].map { Data(bytes[$0]) } ?? Data()
        var stable: [Range<Int>] = []
        if let system = root["system"] {
            let blocks = try JSONByteScanner.elements(bytes, from: system.lowerBound)
            // Anthropic's last system breakpoint ends the stable block. The
            // following dynamic block is deliberately outside this measurement.
            if let end = try blocks.lastIndex(where: { try members($0)["cache_control"] != nil }) {
                stable = Array(blocks[...end])
            } else {
                stable = [system]
            }
        } else if let instructions = root["instructions"] {
            stable = [instructions]
        } else if let messages = root["messages"],
                  let first = try JSONByteScanner.elements(bytes, from: messages.lowerBound).first,
                  let role = try members(first)["role"],
                  ["system", "developer"].contains((try? JSONSerialization.jsonObject(with: Data(bytes[role]), options: .fragmentsAllowed)) as? String ?? "") {
            stable = [first]
        }
        let stableHash = digest(stable.map { Data(bytes[$0]) })
        let toolsHash = digest([tools])
        // Each conversation item exactly as sent (Responses `input`, Messages
        // `messages`), 12 hex each: the first one that differs between two
        // turns is where a provider's cache stops matching.
        let items = try (root["input"] ?? root["messages"]).map {
            try JSONByteScanner.elements(bytes, from: $0.lowerBound)
        } ?? []
        let wireItems = items.prefix(400).map { JSONValue.string(String(digest([Data(bytes[$0])]).prefix(12))) }
        return [
            "wireItemDigests": .array(Array(wireItems)),
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
}
