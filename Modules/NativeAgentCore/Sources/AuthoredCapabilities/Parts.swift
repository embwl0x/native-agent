import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Parts.swift` | `storedRows`, `rows`; One part reader; display projections never write back; row-local name damage |

/// Store-adjacent shared readers let projections and execution use one catalog.
public struct Parts: Sendable {
    public typealias Outcome = (ok: Bool, text: String, fields: [String: JSONValue])
    public let root: URL
    public init(root: URL = PersistenceCore.defaultDataRoot()) { self.root = root }

    /// Display rows may include all kinds but never write back; execution defaults to executable records.
    public func rows(kind: AbilityStore.Kind? = .part) throws -> [[String: JSONValue]] {
        try storedRows(kind: kind).map { try Self.readRow(.object($0)) }
    }

    /// Writers use storedRows so projected names and unavailable marks never persist.
    public func storedRows(kind: AbilityStore.Kind? = .part) throws -> [[String: JSONValue]] {
        let abilities = AbilityStore(dataRoot: root)
        guard case .array(let rows) = try abilities.registry(kind: kind) else {
            throw ToolFailureError("The ability registry did not return rows.", effects: .none, owner: abilities.root.path,
                nextCall: ToolFailureError.call("app", ["action": .string("files.list"), "args": .object(["path": .string(abilities.root.path)])]),
                code: "ability_registry_shape", instruction: """
                    Inspect the ability sources and repair the reported malformed header from retained evidence; preserve versions and authority.
                    """, recovery: .inspect)
        }
        return try rows.map { try JSONRow($0).fields }
    }

    /// Absent names display the id; present non-string names are row-local damage so sibling records remain readable.
    private static func readRow(_ value: JSONValue) throws -> [String: JSONValue] {
        let checked = try JSONRow(value)
        let id = try checked.string("id")
        var row = checked.fields
        switch row["name"] {
        case nil: row["name"] = .string(id)
        case .string?: break
        default:
            let detail = "Part \(id) has an invalid name field; expected a string. Repair name in its retained header."
            row["name"] = .string("\(id) (name unavailable)")
            row["status"] = .string("unavailable")
            row["unavailableReason"] = .string(detail)
        }
        return row
    }
}
