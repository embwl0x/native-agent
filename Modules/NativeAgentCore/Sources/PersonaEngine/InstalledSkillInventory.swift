import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `InstalledSkillInventory.swift` | Built-in guidance inventory, matching and body reads shared by Parts, Mac and phone as SkillRecord, carrying source text and revision without reconstruction |

/// The identity and availability projection shared by discovery, UI and recall.
public enum InstalledSkillInventory {
    /// The persona's built-in guidance, excluding ids now owned by abilities.
    public static func entries(dataRoot: URL, includingSource: Bool = true) throws -> [SkillRecord] {
        let bodies = defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("skills/bodies")
        guard FileManager.default.fileExists(atPath: bodies.path) else { return [] }
        let abilityIDs = Set(try AbilityStore(dataRoot: dataRoot).files(kind: .part)
            .map { $0.id.lowercased() })
        return try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "md" && !abilityIDs.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
            .compactMap { try entry($0.deletingPathExtension().lastPathComponent, dataRoot: dataRoot, includingSource: includingSource) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bundled originals stay outside the writable ability store.
    private static func entry(_ id: String, dataRoot: URL, includingSource: Bool) throws -> SkillRecord? {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/") else { return nil }
        let file = defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("skills/bodies/\(id).md")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let body = try body(at: file)
        return SkillRecord(id: id, name: id, description: body.split(separator: "\n").first.map(String.init) ?? id,
            triggers: [], status: "active", bodyPath: file.path, source: "persona_body",
            body: includingSource ? body : nil,
            bodyRevision: includingSource ? SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined() : nil)
    }

    public static func match(_ name: String, in entries: [SkillRecord]) -> SkillRecord? {
        entries.first { $0.id.caseInsensitiveCompare(name) == .orderedSame }
            ?? entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func body(at file: URL) throws -> String {
        try VerifiedPath.confirmNoSymlink(file)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
