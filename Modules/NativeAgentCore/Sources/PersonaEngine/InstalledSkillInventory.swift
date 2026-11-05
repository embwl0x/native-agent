import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `InstalledSkillInventory.swift` | InstalledSkillInventory owner. |

/// Share skill identity and availability across discovery, UI and recall.
public enum InstalledSkillInventory {
    /// Exclude IDs now owned by abilities so built-in guidance cannot compete with executable parts.
    public static func entries(dataRoot: URL, includingSource: Bool = true) throws -> [SkillRecord] {
        let bodies = defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("skills/bodies")
        let directory: [URL]
        do {
            directory = try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let abilityIDs = Set(try AbilityStore(dataRoot: dataRoot).files(kind: .part)
            .map { $0.id.lowercased() })
        let files = directory.filter { $0.pathExtension == "md" && !abilityIDs.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
        return files.map { file in
            let id = file.deletingPathExtension().lastPathComponent
            do { return try entry(id, file: file, includingSource: includingSource) }
            catch {
                return SkillRecord(id: id, name: id,
                    description: "Guidance unavailable at \(file.path): \(error.localizedDescription)",
                    triggers: [], status: "unavailable", bodyPath: file.path, source: "persona_body")
            }
        }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Keep bundled originals outside the writable ability store.
    private static func entry(_ id: String, file: URL, includingSource: Bool) throws -> SkillRecord {
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
