import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `InstalledSkillInventory.swift` | Built-in guidance inventory, matching and body reads shared by Parts, Mac and phone; each checked entry carries its readme into source/revision and UI detail without a second body read |

public struct SkillManifest: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let schemaVersion: Int
    public let name: String
    public let version: String
    public let type: String
    public let description: String
    public let author: SkillAuthor?
    public let permissions: [String]?
    public let tools: [SkillTool]?
    public let oauth: SkillOAuth?
    public let tags: [String]?
    public let homepage: String?
}

public struct SkillAuthor: Codable, Sendable {
    public let name: String
    public let email: String?
    public let url: String?
}

public struct SkillOAuth: Codable, Sendable {
    public let provider: String
    public let scopes: [String]
    public let deviceFlow: Bool?
}

public struct SkillTool: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
}

public struct SkillInfo: Identifiable, Sendable {
    public let id: String
    public let manifest: SkillManifest
    public let registry: SkillRegistryEntry
    public let readme: String?

    /// A built-in skill's guidance as the Skills page shows it: read, never run.
    public static func guidance(_ skill: SkillRecord) -> SkillInfo {
        let id = skill.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? skill.name : skill.id
        let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : skill.name
        return SkillInfo(id: id,
            manifest: SkillManifest(schemaVersion: 1, name: name, version: "built_in", type: "guidance", description: skill.description,
                                    author: nil, permissions: nil, tools: nil, oauth: nil, tags: nil, homepage: nil),
            registry: SkillRegistryEntry(name: id, state: "built in", version: "built_in", type: "guidance",
                                         installedAt: skill.createdAt, path: skill.bodyPath ?? ""),
            readme: skill.body)
    }
}

/// The identity and availability projection shared by discovery, UI and recall.
public enum InstalledSkillInventory {
    public struct Entry: Sendable {
        public let row: [String: JSONValue]
        public var id: String { InstalledSkillInventory.string(row["id"]) ?? "" }
        public var name: String { InstalledSkillInventory.string(row["name"]) ?? "" }
        public var isAvailable: Bool { InstalledSkillInventory.isAvailable(row) }
        public let readme: String
    }

    public static func isAvailable(_ row: [String: JSONValue]) -> Bool {
        ["active", "installed"].contains((string(row["status"] ?? row["state"]) ?? "active").lowercased())
    }

    /// The persona's built-in guidance, excluding ids now owned by abilities.
    public static func entries(dataRoot: URL) throws -> [Entry] {
        let bodies = defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("skills/bodies")
        guard FileManager.default.fileExists(atPath: bodies.path) else { return [] }
        let abilityIDs = Set(try AbilityStore(dataRoot: dataRoot).files(kind: .part)
            .compactMap { $0.record == nil ? nil : $0.id.lowercased() })
        return try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "md" && !abilityIDs.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
            .compactMap { try entry(["id": .string($0.deletingPathExtension().lastPathComponent), "overrides": .string("built_in")], dataRoot: dataRoot) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bundled originals stay outside the writable ability store.
    private static func entry(_ row: [String: JSONValue], dataRoot: URL) throws -> Entry? {
        guard row["overrides"] == .string("built_in"), let id = string(row["id"]) else { return nil }
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/") else { return nil }
        let file = defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("skills/bodies/\(id).md")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let body = try body(at: file)
        return Entry(row: ["id": .string(id), "name": row["name"] ?? .string(id),
                "description": .string(body.split(separator: "\n").first.map(String.init) ?? id),
                "triggers": .array([]), "status": .string("active"), "source": .string("persona_body"),
                "bodyPath": .string(file.path), "overrides": .string("built_in")], readme: body)
    }

    public static func match(_ name: String, in entries: [Entry]) -> Entry? {
        entries.first { $0.id.caseInsensitiveCompare(name) == .orderedSame }
            ?? entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func body(at file: URL) throws -> String {
        try VerifiedPath.confirmNoSymlink(file)
        return try String(contentsOf: file, encoding: .utf8)
    }

    fileprivate static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }
}
