import PersistenceCore
import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import os
// Blueprint: | `TranscriptRowStamp.swift` | One saved-row speaker/steering/contact projection for metadata and persisted preview stamps; imported or generic-agent rows attest no speaker |

/// Projects the saved row's verified envelope speaker or specific origin, steering peers
/// and contact status. Generic agents and imports (`unattested`, `<id>-reply`, `agent-live:`)
/// attest no speaker.
public struct TranscriptRowStamp: Sendable, Equatable {
    public let source: String?
    public let steeredBy: [String]
    public let contact: Bool

    public init(source: String?, steeredBy: [String], contact: Bool) {
        self.source = source
        var seen: Set<String> = []
        // Preserve the speaker among steering sources; combined principals deduplicate it.
        self.steeredBy = steeredBy.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.contact = contact
    }

    static func of(id: String, role: String, userId: String?, originAgent: String?, replyTo: String?, authored: String?,
                   envelopeAgent: String?, surfaces: [String], byPerson: Bool, unattested: Bool, untrusted: [String]) -> Self {
        let imported = unattested || id.hasSuffix("-reply") || replyTo?.hasPrefix("agent-live:") == true
        let source: String? = if imported { nil }
            else if let door = userId, !door.isEmpty { door.hasPrefix("peer:") ? door : "peer:" + door }
            else if let agent = originAgent, !["agent", "peer", "another agent", ""].contains(agent) { agent }
            else { nil }
        let contact = role == "user" && !byPerson && authored != "human"
            && (originAgent != nil || envelopeAgent != nil || surfaces.contains { $0.hasSuffix("-bridge") })
        return .init(source: source, steeredBy: untrusted, contact: contact)
    }

    public static func of(id: String, role: String, metadata: [String: Any]?, rowSource: String? = nil) -> Self {
        let origin = metadata?["origin"] as? [String: Any], envelope = metadata?["envelope"] as? [String: Any]
        return of(id: id, role: role, userId: envelope?["userId"] as? String, originAgent: origin?["agent"] as? String,
                  replyTo: origin?["replyTo"] as? String, authored: origin?["authored"] as? String, envelopeAgent: envelope?["agent"] as? String,
                  surfaces: [origin?["surface"], envelope?["surface"], rowSource].compactMap { $0 as? String },
                  byPerson: metadata?["byPerson"] as? Bool == true, unattested: metadata?["unattested"] as? Bool == true,
                  untrusted: metadata?["untrusted_sources"] as? [String] ?? [])
    }

    public static func of(id: String, role: String, metadata: [String: JSONValue], rowSource: String? = nil) -> Self {
        func text(_ value: JSONValue?) -> String? { if case .string(let text)? = value { text } else { nil } }
        let origin: [String: JSONValue] = if case .object(let value)? = metadata["origin"] { value } else { [:] }
        let envelope: [String: JSONValue] = if case .object(let value)? = metadata["envelope"] { value } else { [:] }
        let untrusted: [String] = if case .array(let values)? = metadata["untrusted_sources"] { values.compactMap(text) } else { [] }
        return of(id: id, role: role, userId: text(envelope["userId"]), originAgent: text(origin["agent"]), replyTo: text(origin["replyTo"]),
                  authored: text(origin["authored"]), envelopeAgent: text(envelope["agent"]),
                  surfaces: [text(origin["surface"]), text(envelope["surface"]), rowSource].compactMap { $0 },
                  byPerson: metadata["byPerson"] == .bool(true), unattested: metadata["unattested"] == .bool(true), untrusted: untrusted)
    }

    /// As an index row keeps it beside the preview it stamps.
    public var json: JSONValue {
        .object(["source": source.map(JSONValue.string) ?? .null, "steered_by": .array(steeredBy.map(JSONValue.string)), "contact": .bool(contact)])
    }

    public init?(json: JSONValue?) {
        guard case .object(let fields)? = json, case .bool(let contact)? = fields["contact"] else { return nil }
        let source: String? = if case .string(let text)? = fields["source"] { text } else { nil }
        let steering: [String] = if case .array(let values)? = fields["steered_by"] {
            values.compactMap { if case .string(let peer) = $0 { peer } else { nil } }
        } else { [] }
        self.init(source: source, steeredBy: steering, contact: contact)
    }

    /// The index row key that carries the stamp of its `lastMessagePreview`.
    public static let previewKey = "lastMessagePreviewStamp"
}
