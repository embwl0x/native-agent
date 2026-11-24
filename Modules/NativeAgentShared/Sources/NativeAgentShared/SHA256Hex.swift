import CryptoKit
import Foundation
// Blueprint: | `SHA256Hex.swift` | `SHA256Hex`: the full lowercase hexadecimal SHA-256 of bytes or of UTF-8 text |

/// The full 64-character lowercase hex digest. Shortened identity digests (12 bytes, 12 hex characters) and FNV keys keep their own helpers:
/// their length is part of the identity they name.
public enum SHA256Hex {
    public static func of(_ data: Data) -> String {
        let digits: InlineArray<16, UInt8> = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 98, 99, 100, 101, 102]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func of(utf8 text: String) -> String {
        of(Data(text.utf8))
    }
}
