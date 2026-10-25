import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Skills.swift` | `SkillRecord`, `SkillRegistryEntry`: built-in guidance rows as the Skills page and phone snapshot carry them |

// A skill is built-in guidance from the persona, read and never run; what
// she writes is a part (ToolExecution's `Parts`).

/// One guidance row, as the Skills page and the phone snapshot carry it.
public struct SkillRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var triggers: [String]
    public var kind: String?
    public var status: String?
    public var autoCreated: Bool?
    public var sourceRunId: String?
    public var bodyPath: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var useCount: Int?
    public var lastUsedAt: String?
    public var source: String?
    public var body: String?
    public var bodyRevision: String?
}

extension SkillRecord {
    /// One registry row; a present field of the wrong type makes it malformed.
    public init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), name: try row.string("name"), description: try row.string("description"),
            triggers: try row.strings("triggers"), kind: try row.optionalString("kind"),
            status: try row.optionalString("status"), autoCreated: try row.optionalBool("autoCreated"),
            sourceRunId: try row.optionalString("sourceRunId"), bodyPath: try row.optionalString("bodyPath"),
            createdAt: try row.optionalString("createdAt"), updatedAt: try row.optionalString("updatedAt"),
            useCount: try row.optionalInt("useCount"), lastUsedAt: try row.optionalString("lastUsedAt"),
            source: try row.optionalString("source"))
    }
}

/// One built-in guidance entry, as the Skills page lists it.
public struct SkillRegistryEntry: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let state: String     // "built in"
    public let version: String
    public let type: String
    public let installedAt: String?
    public let path: String

    public init(name: String, state: String, version: String, type: String, installedAt: String?, path: String) {
        self.name = name; self.state = state; self.version = version
        self.type = type; self.installedAt = installedAt; self.path = path
    }

    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(name: try row.string("name"), state: try row.string("state"), version: try row.string("version"),
                  type: try row.string("type"), installedAt: try row.optionalString("installedAt"),
                  path: try row.string("path"))
    }
}
