import CryptoKit
import Foundation
// Blueprint: | `StableHash.swift` | SHA-256 identity UUIDs over exact UTF-8, full hex over sorted JSONEncoder output, and FNV-1a-64 |

public enum StableHash {
    public static let fnv1a64OffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325

    public static func sortedJSONSHA256<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256Hex.of(try encoder.encode(value))
    }

    /// Uses the name-based UUID layout with the existing SHA-256 derivation.
    public static func sha256UUID(utf8 text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Callers own normalization and output formatting.
    public static func fnv1a64(_ text: String, seed: UInt64 = fnv1a64OffsetBasis) -> UInt64 {
        var hash = seed
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
