import Foundation
import PersistenceCore
import Skills
import PersonaEngine
import MemoryV2


extension NativeClient {
    struct ManifestSkillValue: Decodable {
        let state: String
        let version: String
        let type: String
        let installedAt: String?
        let path: String
    }
    struct ManifestRegistryFile: Decodable {
        let skills: [String: ManifestSkillValue]
    }

    /// Read the manifest skill registry from the local filesystem.
    func readSkillRegistry() async throws -> [SkillRegistryEntry] {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let registryURL = dataRoot.appendingPathComponent("skills/manifest_registry.json")
        // The native merge treats malformed JSON as its default empty value.
        // Validate existing authority bytes first so the Skills banner can
        // distinguish unreadable storage from a genuine empty catalog.
        if FileManager.default.fileExists(atPath: registryURL.path) {
            let data = try Data(contentsOf: registryURL)
            _ = try JSONDecoder.nativeAgent.decode(ManifestRegistryFile.self, from: data)
        }
        let impl = makeSkillsClient(root: dataRoot)
        if let rows = try? await impl.listManifestSkills(),
           let data = try? JSONValue.array(rows).serializedData(pretty: false),
           let entries = try? JSONDecoder.nativeAgent.decode([SkillRegistryEntry].self, from: data) {
            return entries
        }
        // Read the saved registry directly if the native list projection is unavailable.
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return []
        }
        let data = try Data(contentsOf: registryURL)
        let wrapper = try JSONDecoder.nativeAgent.decode(ManifestRegistryFile.self, from: data)
        return wrapper.skills.map { name, val in
            SkillRegistryEntry(name: name, state: val.state, version: val.version,
                               type: val.type, installedAt: val.installedAt, path: val.path)
        }
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
        let fm = FileManager.default
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let fallback = dataRoot.appendingPathComponent("skills/\(entry.name)")
        let rawPath = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return fallback }

        let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        let allowedRoots = [
            dataRoot.appendingPathComponent("skills").standardizedFileURL,
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NativeAgent/skills")
                .standardizedFileURL,
        ]
        let candidatePath = candidate.path
        let allowed = allowedRoots.contains { root in
            candidatePath == root.path || candidatePath.hasPrefix(root.path + "/")
        }
        if allowed, fm.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
            return candidate
        }
        return fallback
    }

    func enableSkill(name: String) async throws {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        try await Self.enableSkill(
            name: name, dataRoot: root, memory: nil,
            personaRoot: dataRootOverride == nil ? PersonaRootResolver.resolve() : root.appendingPathComponent("persona")
        )
    }

    static func enableSkill(
        name: String, dataRoot: URL, memory: SwiftNativeMemoryV2?, personaRoot: URL
    ) async throws {
        let impl = makeSkillsClient(root: dataRoot)
        let result = try await impl.enableSkill(name: name)
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
        return
    }

}
