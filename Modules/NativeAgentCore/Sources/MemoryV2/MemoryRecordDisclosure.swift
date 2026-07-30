import Foundation
import NativeAgentCore
import PersistenceCore

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
    public static let allSurfaces: Set<String> = [
        "chat", "telegram", "ios", "slack", "missions", "bridge",
    ]
    /// Telegram is User's authenticated personal surface — same trust tier as
    /// the Mac app and iOS (2026-07-20: its absence here silently filtered
    /// EVERY semantic recall on Telegram; only prompt-injectable no-human
    /// surfaces like slack stay outside local_private).
    public static let localPrivateSurfaces: Set<String> = [
        "chat", "telegram", "ios", "missions", "bridge",
    ]

    /// Context's stable wire identifier for the Workshop/Missions surface is
    /// `missions`. Accept the human-facing `workshop` spelling at memory
    /// boundaries, but persist and compare only the canonical identifier.
    /// The agent bridges dispatch tools with surface "claude-bridge" /
    /// "codex-bridge"; their policy identity is `bridge` (2026-07-20: the
    /// unmapped spellings fail-closed every bridge recall).
    public static func canonicalSurface(_ value: String) -> String {
        let normalized = normalize(value)
        switch normalized {
        case "workshop": return "missions"
        case "claude-bridge", "claude_bridge",
             "codex-bridge", "codex_bridge": return "bridge"
        default: return normalized
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
        let rawPrivacy = string(metadata, key: "privacy")
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

    public static func classify(_ record: MemoryRecord) -> MemoryDisclosureClassification? {
        classify(
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

    private static func string(_ value: JSONValue?, key: String) -> String? {
        guard case .object(let object)? = value,
              case .string(let result)? = object[key] else { return nil }
        return result
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
