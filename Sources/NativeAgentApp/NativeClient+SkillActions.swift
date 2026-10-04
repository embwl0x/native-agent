import Foundation
import PersistenceCore
import Skills
import PersonaEngine
import MemoryV2


extension NativeClient {
    /// Skills owns the legacy/data-root manifest merge and checked read.
    func readSkillRegistry() async throws -> [SkillRegistryEntry] {
        let rows = try await makeSkillsClient(root: dataRootOverride ?? PersistenceCore.defaultDataRoot()).listManifestSkills()
        return try JSONDecoder.nativeAgent.decode([SkillRegistryEntry].self,
            from: JSONValue.array(rows).serializedData(pretty: false))
    }

    /// Read a skill's manifest.json from its directory (v1 fallback).
    func readSkillManifest(entry: SkillRegistryEntry) throws -> SkillManifest {
        let skillDir = try skillDirectory(for: entry)
        let manifestURL = skillDir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder.nativeAgent.decode(SkillManifest.self, from: data)
    }

    /// Read a skill's README.md from its directory if present (v1 fallback).
    func readSkillReadme(entry: SkillRegistryEntry) throws -> String? {
        let skillDir = try skillDirectory(for: entry)
        let readmeURL = skillDir.appendingPathComponent("README.md")
        guard FileManager.default.fileExists(atPath: readmeURL.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: readmeURL.path)
        let byteCount = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let previewLimit = 64 * 1024
        if byteCount <= previewLimit {
            return try String(contentsOf: readmeURL, encoding: .utf8)
        }
        let handle = try FileHandle(forReadingFrom: readmeURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: previewLimit) ?? Data()
        let preview = String(decoding: data, as: UTF8.self)
        return preview + "\n\n[README preview truncated in the app: \(byteCount) bytes total.]"
    }

    func skillDirectory(for entry: SkillRegistryEntry) throws -> URL {
        SwiftNativeSkillsClient(root: dataRootOverride ?? PersistenceCore.defaultDataRoot()).manifestDirectory(for: [
            "name": .string(entry.name), "path": .string(entry.path),
        ])
    }

    /// User's Install admits a script skill's exact digest as his: the one
    /// he reviewed (`reviewedDigest`), refused if the script changed since.
    /// An approved card's (`admitScript: false`) turns on only what needs no admission.
    func enableSkill(name: String, reviewedDigest: String? = nil, admitScript: Bool = true) async throws {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        try await Self.enableSkill(
            name: name, dataRoot: root, memory: nil,
            personaRoot: dataRootOverride == nil ? PersonaRootResolver.resolve() : root.appendingPathComponent("persona"),
            reviewedDigest: reviewedDigest, admitScript: admitScript
        )
    }

    static func enableSkill(
        name: String, dataRoot: URL, memory: SwiftNativeMemoryV2?, personaRoot: URL,
        reviewedDigest: String? = nil, admitScript: Bool = true
    ) async throws {
        let result = try await SwiftNativeSkillsClient(root: dataRoot).enableSkill(
            name: name, admittedBy: admitScript ? "user" : nil, reviewedDigest: reviewedDigest)
        // The runtime branch returns an active canonical skill record. The
        // manifest-only branch merely changes registration state; it does not
        // install a body or establish recall readiness, and needs no memory
        // owner. Do not mutate either branch a second time to reconcile it.
        if case .object(let record) = result, record["status"] == .string("active") {
            try await reconcileSkillEvolutionRecall(
                memory: memory ?? SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot),
                dataRoot: dataRoot, personaRoot: personaRoot
            )
        }
    }

    func disableSkill(name: String) async throws {
        let impl = makeSkillsClient(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
        _ = try await impl.disableSkill(name: name)
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        try await Self.reconcileSkillEvolutionRecall(
            memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root,
            personaRoot: dataRootOverride == nil ? PersonaRootResolver.resolve() : root.appendingPathComponent("persona"))
    }

}
