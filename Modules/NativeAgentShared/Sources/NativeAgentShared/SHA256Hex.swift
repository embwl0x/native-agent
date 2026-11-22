import CryptoKit
import Foundation
// Blueprint: | `SHA256Hex.swift` | `SHA256Hex`: the full lowercase hexadecimal SHA-256 of bytes or of UTF-8 text |

/// The full 64-character lowercase hex digest. Shortened identity digests (12 bytes, 12 hex characters) and FNV keys keep their own helpers:
/// their length is part of the identity they name.
public enum SHA256Hex {
    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func of(utf8 text: String) -> String {
        of(Data(text.utf8))
    }
}
