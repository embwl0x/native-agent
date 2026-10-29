import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoryRecordDisclosure.swift` | `MemoryRecordDisclosurePolicy`: pure shared record privacy/persona/surface disclosure, independent of Trust tool admission |

public enum MemoryDisclosurePrivacy: String, Sendable, Codable, CaseIterable {
    case localPrivate = "local_private"
    case trustedRemote = "trusted_remote"
    case publicSafe = "public_safe"
}

public struct MemoryDisclosureClassification: Sendable, Codable, Equatable {
    public let personaID: String?
    public let privacy: MemoryDisclosurePrivacy
    public let permittedSurfaces: Set<String>

    public init(
        personaID: String?,
        privacy: MemoryDisclosurePrivacy,
        permittedSurfaces: Set<String>
    ) {
        self.personaID = personaID
        self.privacy = privacy
        self.permittedSurfaces = permittedSurfaces
    }

    public func permits(surface: String?, personaID requestedPersonaID: String?) -> Bool {
        if let requestedPersonaID,
           let personaID,
           normalize(requestedPersonaID) != normalize(personaID) {
            return false
        }
        guard let surface else { return true }
        return permittedSurfaces.contains(MemoryRecordDisclosurePolicy.canonicalSurface(surface))
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalize(_ value: String) -> String { Self.normalize(value) }
}

/// One pure disclosure policy consumed by automatic Context projection and
/// explicit MemoryV2 recall. TrustCenter still independently authorizes the
/// tool; this policy only decides whether a record may leave MemoryV2 for the
/// requested persona/surface.
public enum MemoryRecordDisclosurePolicy {
    /// Keep both `workshop` and `missions` for persisted rows and older readers.
    /// A standing bot runs under the agent's own Trust and can read local-private memories.
    public static let allSurfaces: Set<String> = ([
        "chat", "telegram", "ios", "slack", "bridge", "bot",
    ] as Set<String>).union(WorkshopSurfaceVocabulary.bothSpellings)
    /// Authenticated personal surfaces and local bot runs share the local-private tier.
    public static let localPrivateSurfaces: Set<String> = ([
        "chat", "telegram", "ios", "bridge", "bot",
    ] as Set<String>).union(WorkshopSurfaceVocabulary.bothSpellings)

    /// Canonicalize persisted `missions` to `workshop` and agent bridge surfaces to `bridge`.
    public static func canonicalSurface(_ value: String) -> String {
        let normalized = normalize(value)
        switch normalized {
        case "claude-bridge", "claude_bridge",
             "codex-bridge", "codex_bridge",
             // PeerTurnEffectPolicy fences effects; peer sessions retain ordinary bridge recall.
             "agent-bridge", "agent_bridge": return "bridge"
        default: return WorkshopSurfaceVocabulary.canonicalSurface(normalized)
        }
    }

    public static func classify(
        personaID: String?,
        status: String?,
        lifecycle: String?,
        tags: [String]?,
        metadata: JSONValue?
    ) -> MemoryDisclosureClassification? {
        let normalizedStatus = normalize(status ?? "active")
        guard normalizedStatus == "active" else { return nil }
        if let lifecycle,
           !MemoryLifecycle.isRecallEligible(lifecycle) {
            return nil
        }

        let normalizedTags = (tags ?? []).map(normalize)
        let rawPrivacy = metadata?.objectValue?["privacy"]?.stringValue
            ?? normalizedTags.first(where: { $0.hasPrefix("privacy:") })
                .map { String($0.dropFirst("privacy:".count)) }
        let privacy: MemoryDisclosurePrivacy
        switch normalize(rawPrivacy ?? "").replacingOccurrences(of: "-", with: "_") {
        case "public", "public_safe": privacy = .publicSafe
        case "trusted", "trusted_remote": privacy = .trustedRemote
        default: privacy = .localPrivate
        }

        var surfaceNames = strings(metadata, key: "permittedSurfaces")
        if surfaceNames.isEmpty { surfaceNames = strings(metadata, key: "surfaces") }
        surfaceNames.append(contentsOf: normalizedTags.compactMap { tag in
            guard tag.hasPrefix("surface:") else { return nil }
            return String(tag.dropFirst("surface:".count))
        })
        let surfaces: Set<String>
        if surfaceNames.isEmpty {
            surfaces = privacy == .localPrivate ? localPrivateSurfaces : allSurfaces
        } else {
            surfaces = Set(surfaceNames.map(canonicalSurface)).intersection(allSurfaces)
        }
        guard !surfaces.isEmpty else { return nil }
        return MemoryDisclosureClassification(
            personaID: personaID?.trimmingCharacters(in: .whitespacesAndNewlines),
            privacy: privacy,
            permittedSurfaces: surfaces
        )
    }

    /// A record whose `valid_to` has passed was true once and is not now: it
    /// stays in the store and leaves what is disclosed, like a superseded one.
    public static func isTemporallyEligible(validTo: String?, at now: Date) -> Bool {
        validTo.flatMap(MemoryRecallScoring.parseTimestamp).map { $0 > now } ?? true
    }

    public static func classify(_ record: MemoryRecord, at now: Date = Date()) -> MemoryDisclosureClassification? {
        guard isTemporallyEligible(validTo: record.validTo, at: now) else { return nil }
        return classify(
            personaID: record.personaId,
            status: record.status,
            lifecycle: record.lifecycle,
            tags: record.tags,
            metadata: record.extras
        )
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func strings(_ value: JSONValue?, key: String) -> [String] {
        guard case .object(let object)? = value,
              case .array(let values)? = object[key] else { return [] }
        return values.compactMap {
            guard case .string(let result) = $0 else { return nil }
            return result
        }
    }
}
