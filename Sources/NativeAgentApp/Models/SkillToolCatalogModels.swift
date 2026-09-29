import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct SkillRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var description: String
    var triggers: [String]
    var kind: String?
    var status: String?
    var autoCreated: Bool?
    var sourceRunId: String?
    var bodyPath: String?
    var createdAt: String?
    var updatedAt: String?
    var useCount: Int?
    var lastUsedAt: String?
    /// "runtime_registry" (default for in-registry rows), "runtime_body" (a
    /// markdown body under data/skills/bodies/ with no registry entry yet),
    /// or "persona_body" (a markdown body under persona/skills/bodies/). UI
    /// uses this to gate destructive actions — Disable/Delete only make sense
    /// for registry rows; body-only rows have no entry to mutate.
    var source: String?
}
