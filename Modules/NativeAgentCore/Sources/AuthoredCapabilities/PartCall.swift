import Foundation
@_exported import NativeAgentShared
import PersistenceCore
// Blueprint: | `PartCall.swift` | Shared part/face wire contracts; editable content cannot forge status |

extension PartFace {
    /// Validate before decode so editable prose cannot forge native status and ids stay unambiguous across UIs.
    public static func decode(_ value: JSONValue) throws -> PartFace {
        func object(_ value: JSONValue, keys: Set<String>) throws -> [String: JSONValue] {
            guard case .object(let fields) = value, Set(fields.keys).isSubset(of: keys) else {
                throw PartCallError(code: "bad_face", message: "A face holds title, line and sections; a section id, title, style, footer and rows; "
                    + "a row id, title, detail, value, at, symbol, tone, open, actions and control.")
            }
            return fields
        }
        func list(_ value: JSONValue?, at most: Int, _ what: String) throws -> [JSONValue] {
            guard let value else { return [] }
            guard case .array(let items) = value, items.count <= most else {
                throw PartCallError(code: "bad_face", message: "A face's \(what) is a list of at most \(most).")
            }
            return items
        }
        let fields = try object(value, keys: ["title", "line", "sections"])
        guard fields["sections"] != nil else { throw PartCallError(code: "bad_face", message: "A face has sections.") }
        for section in try list(fields["sections"], at: 64, "sections") {
            let fields = try object(section, keys: ["id", "title", "style", "footer", "rows"])
            for row in try list(fields["rows"], at: 256, "section rows") {
                let fields = try object(row, keys: ["id", "title", "detail", "value", "at", "symbol", "tone", "open", "actions", "control"])
                if case .string(let link)? = fields["open"], !Self.isLink(link) {
                    throw PartCallError(code: "bad_face", message: "A row opens chat:, page:, approval:, card:, dream:, url:https:// or url:http:// only.")
                }
                for action in try list(fields["actions"], at: 4, "row actions") { _ = try object(action, keys: ["id", "label", "role"]) }
                if let control = fields["control"] {
                    let fields = try object(control, keys: ["on", "options", "selected", "confirm", "text", "placeholder"])
                    for option in try list(fields["options"], at: 32, "control options") { _ = try object(option, keys: ["id", "label"]) }
                }
            }
        }
        let face = try JSONDecoder().decode(PartFace.self, from: value.serializedData(pretty: false))
        guard Set(face.sections.map(\.id)).count == face.sections.count,
              face.sections.allSatisfy({ !$0.id.isEmpty && Set($0.rows.map(\.id)).count == $0.rows.count && $0.rows.allSatisfy({ !$0.id.isEmpty }) }) else {
            throw PartCallError(code: "bad_face", message: "Face section ids and each section's row ids must be nonempty and unique.")
        }
        return face
    }

}
