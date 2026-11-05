import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoryRecordDisclosure.swift` | `MemoryRecordDisclosurePolicy`: record privacy independent of tool admission |

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

/// Share record disclosure between automatic Context and explicit recall; TrustCenter independently authorizes the tool.
public enum MemoryRecordDisclosurePolicy {
    /// Persisted surface IDs share disclosure scope; standing bots use the agent's Trust for local-private memories.
    public static let allSurfaces: Set<String> = [
        "chat", "telegram", "ios", "slack", "bridge", "bot", WorkshopSurfaceVocabulary.canonical,
    ]
    /// Authenticated personal surfaces and local bot runs share the local-private tier.
    public static let localPrivateSurfaces: Set<String> = [
        "chat", "telegram", "ios", "bridge", "bot", WorkshopSurfaceVocabulary.canonical,
    ]

    /// The disclosure scope of a turn surface: the agent-bridge surface shares the `bridge` scope; every other surface is its own scope.
    public static func canonicalSurface(_ value: String) -> String {
        let normalized = normalize(value)
        // PeerTurnEffectPolicy fences effects; peer sessions retain ordinary bridge recall.
        return normalized == "agent-bridge" ? "bridge" : normalized
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

    /// Expired validity withholds current disclosure without deleting historical truth.
    public static func isTemporallyEligible(validTo: String?, at now: Date) -> Bool {
        guard let validTo else { return true }
        guard let expiry = MemoryRecallScoring.parseTimestamp(validTo) else { return false }
        return expiry > now
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
