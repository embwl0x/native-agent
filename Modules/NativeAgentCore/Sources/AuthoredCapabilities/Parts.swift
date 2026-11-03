import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Parts.swift` | Shared part reader and display-name schema; `storedRows` is the write-back read, `rows` the display projection; row-local name damage stays unavailable while sibling rows publish; executable Parts extensions live in ToolExecution |

/// One part reader for projections and the executable lifecycle. Keeping the
/// reader with its store lets lower-level catalog projections use it too.
public struct Parts: Sendable {
    public typealias Outcome = (ok: Bool, text: String, fields: [String: JSONValue])
    public let root: URL
    public init(root: URL = PersistenceCore.defaultDataRoot()) { self.root = root }

    /// Execution records by default; nil includes every stored kind for reads.
    /// A display projection: never written back (writers use `storedRows`).
    public func rows(kind: AbilityStore.Kind? = .part) throws -> [[String: JSONValue]] {
        try storedRows(kind: kind).map { try Self.readRow(.object($0)) }
    }

    /// The registry rows exactly as stored, for writers that save the registry
    /// back. Display names and unavailable marks never reach the disk.
    public func storedRows(kind: AbilityStore.Kind? = .part) throws -> [[String: JSONValue]] {
        let abilities = AbilityStore(dataRoot: root)
        guard case .array(let rows) = try abilities.registry(kind: kind) else {
            throw ToolFailureError("The ability registry did not return rows.", effects: .none, owner: abilities.root.path,
                nextCall: ToolFailureError.call("app", ["action": .string("files.list"), "args": .object(["path": .string(abilities.root.path)])]),
                code: "ability_registry_shape", instruction: "Inspect the ability sources and repair the reported malformed header from retained evidence; preserve versions and authority.", recovery: .inspect)
        }
        return try rows.map { try JSONRow($0).fields }
    }

    /// Part read schema: name is optional. Its display name is the declared
    /// string, or its id when absent. A present non-string is row-local damage,
    /// never an omitted name or a reason to lose the rest of the catalog.
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
