import NativeAgentCore
import PersistenceCore
// Blueprint: | `MorningBriefPart.swift` | Originating-door invocation and typed inactive-default/publication proposal wire; no briefing policy or model prompt |

/// The engine binds this call to the originating app door. The part proposes;
/// the scheduler alone claims occurrences and commits notifications.
public typealias MorningBriefPart = @Sendable (JSONValue) async throws -> JSONValue

struct MorningBriefDefaults: Sendable, Decodable {
    var inbox: [JSONValue]
    var workshop: [JSONValue]
    let notify: [String: Bool]
}

struct MorningBriefProposal: Sendable, Decodable {
    let title: String
    let summary: String
    let detail: JSONValue
    let presentation: JSONValue
    let actions: JSONValue
}
