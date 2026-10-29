import Foundation
// Blueprint: | `Skills.swift` | `SkillRecord`: built-in guidance carried directly through discovery, reads, Mac and phone |

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
