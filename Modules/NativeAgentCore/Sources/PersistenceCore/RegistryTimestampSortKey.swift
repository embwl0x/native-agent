import Foundation
import NativeAgentShared
// Blueprint: | `RegistryTimestampSortKey.swift` | Checked current ISO-8601 registry timestamps; absent optional dates remain undated; no coercion or read-side repair |

package enum RegistryTimestampSortKey {
    /// Both supplied fields must be valid. Omission is undated, never an epoch
    /// or a stringified non-date. The current updatedAt field orders first.
    package static func sortKey(_ value: JSONValue) throws -> String? {
        let row = try JSONRow(value)
        func stamp(_ key: String) throws -> String? {
            guard let value = row.fields[key] else { return nil }
            guard case .string(let text) = value,
                  NativeTimestampFormat.parseISO8601(text) != nil else {
                throw JSONRow.Malformed.field(key)
            }
            return text
        }
        let created = try stamp("createdAt")
        let updated = try stamp("updatedAt")
        return updated ?? created
    }
}
