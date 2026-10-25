import Foundation
@_exported import NativeAgentShared
import PersistenceCore
// Blueprint: | `PartCall.swift` | Re-exports the shared Mac/iPhone part result and face wire types; strict face shape and identifier validation excludes native availability, failure and owed fields from editable content |

extension PartFace {
    /// Validate the wire shape before decoding: editable prose cannot forge
    /// native status fields, and identifiers remain unambiguous to both UIs.
    public static func decode(_ value: JSONValue) throws -> PartFace {
        func object(_ value: JSONValue, keys: Set<String>) throws -> [String: JSONValue] {
            guard case .object(let fields) = value, Set(fields.keys).isSubset(of: keys) else {
                throw PartCallError(code: "bad_face", message: "A face contains only sections, with id/title/rows and id/title/detail/value rows.")
            }
            return fields
        }
        let fields = try object(value, keys: ["sections"])
        guard case .array(let sections)? = fields["sections"], sections.count <= 64 else {
            throw PartCallError(code: "bad_face", message: "A face has at most 64 sections.")
        }
        for section in sections {
            let fields = try object(section, keys: ["id", "title", "rows"])
            guard case .array(let rows)? = fields["rows"], rows.count <= 256 else {
                throw PartCallError(code: "bad_face", message: "A face section has at most 256 rows.")
            }
            for row in rows { _ = try object(row, keys: ["id", "title", "detail", "value"]) }
        }
        let face = try JSONDecoder().decode(PartFace.self, from: value.serializedData(pretty: false))
        guard Set(face.sections.map(\.id)).count == face.sections.count,
              face.sections.allSatisfy({ !$0.id.isEmpty && Set($0.rows.map(\.id)).count == $0.rows.count && $0.rows.allSatisfy({ !$0.id.isEmpty }) }) else {
            throw PartCallError(code: "bad_face", message: "Face section ids and each section's row ids must be nonempty and unique.")
        }
        return face
    }
}
