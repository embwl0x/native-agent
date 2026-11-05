import Foundation
// Blueprint: | `Skills.swift` | `SkillRecord`: built-in guidance carried directly through discovery, reads, Mac and phone |

// Built-in skill guidance is read-only persona material; authored executable work belongs to parts.

/// Share the guidance row between Skills and the phone snapshot.
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
