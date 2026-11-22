import Foundation
// Blueprint: | `Base64URL.swift` | `Data.base64URLEncodedString`: unpadded base64url (RFC 4648 §5) for tokens and credentials |

extension Data {
    /// Base64 with `+` → `-`, `/` → `_` and the `=` padding removed.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
