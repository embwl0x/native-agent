import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `PersonaEngine+Compiler.swift` | `PersonaCompiler`, `configuredNames`. |

// MARK: - PersonalityPacket

public struct PersonalityPacket: Sendable, Codable, Equatable {
    public let surface: String
    public let personaKind: String
    public let personaId: String
    public let fingerprint: String
    public let compiledSystemPrompt: String
    public let activeDocs: [String: String]
    public let extras: JSONValue?

    public init(
        surface: String,
        personaKind: String,
        personaId: String,
        fingerprint: String,
        compiledSystemPrompt: String,
        activeDocs: [String: String],
        extras: JSONValue? = nil
    ) {
        self.surface = surface
        self.personaKind = personaKind
        self.personaId = personaId
        self.fingerprint = fingerprint
        self.compiledSystemPrompt = compiledSystemPrompt
        self.activeDocs = activeDocs
        self.extras = extras
    }
}

public struct PersonaContextDocumentSource: Sendable, Equatable {
    public let id: String
    public let fileURL: URL
    public let content: String
    public let canonicalOrder: Int
    public let optional: Bool
    public let surfaceOverride: Bool

    public init(
        id: String,
        fileURL: URL,
        content: String,
        canonicalOrder: Int,
        optional: Bool,
        surfaceOverride: Bool
    ) {
        self.id = id
        self.fileURL = fileURL
        self.content = content
        self.canonicalOrder = canonicalOrder
        self.optional = optional
        self.surfaceOverride = surfaceOverride
    }
}

public struct PersonaContextSourceSnapshot: Sendable, Equatable {
    public let packet: PersonalityPacket
    public let personaRoot: URL
    public let activePersonaDirectory: URL?
    public let documents: [PersonaContextDocumentSource]
    public let watchedDirectories: [URL]

    public init(
        packet: PersonalityPacket,
        personaRoot: URL,
        activePersonaDirectory: URL?,
        documents: [PersonaContextDocumentSource],
        watchedDirectories: [URL]
    ) {
        self.packet = packet
        self.personaRoot = personaRoot
        self.activePersonaDirectory = activePersonaDirectory
        self.documents = documents
        self.watchedDirectories = watchedDirectories
    }
}

// MARK: - CompiledPersonalityProfile

public typealias CompiledPersonalityTraits = PersonalityTraits

public struct CompiledPersonalityProfile: Sendable, Equatable {
    public let schemaVersion: Int
    public let personaEngineVersion: String
    public let name: String
    public let personaKind: String
    public let traits: CompiledPersonalityTraits
    public let updatedAt: String

    /// Round-trip unknown profile keys losslessly without letting them replace typed fields.
    public let extras: [String: JSONValue]

    public init(
        schemaVersion: Int,
        personaEngineVersion: String,
        name: String,
        personaKind: String,
        traits: CompiledPersonalityTraits,
        updatedAt: String,
        extras: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.personaEngineVersion = personaEngineVersion
        self.name = name
        self.personaKind = personaKind
        self.traits = traits
        self.updatedAt = updatedAt
        self.extras = extras
    }

    /// Only explicit onboarding or repair input may create identity.
    package static func genesis(name: String, personaKind: String) -> CompiledPersonalityProfile {
        CompiledPersonalityProfile(
            schemaVersion: 2, personaEngineVersion: "2.0", name: name,
            personaKind: personaKind,
            traits: CompiledPersonalityTraits(
                warmth: 0.45, directness: 0.82, humor: 0.12, proactivity: 0.78,
                rigor: 0.86, autonomy: 0.82, creativity: 0.58, brevity: 0.74),
            updatedAt: NativeTimestampFormat.fractionalZulu(Date()))
    }

}

// MARK: - PersonaCompiler

/// Compile from the engine's selected roots with optional memory and surface guidance.
/// Backups and export include the persona root; phone sync excludes it, under PrivacyMap/persona.
public actor PersonaCompiler {
    private struct ResolvedCompilation {
        let packet: PersonalityPacket
        let personaRoot: URL
        let activePersonaDirectory: URL?
        let documents: [PersonaContextDocumentSource]
    }

    internal let engine: SwiftNativePersonaEngine
    private let fileManager: FileManager

    /// Keep canonical ordering; optional MEMORY has no runtime writer and surface guidance follows AGENTS.
    private static let canonicalDocOrder: [String] = [
        "SOUL", "VOICE", "USER", "GROWTH", "MEMORY", "AGENTS",
    ]

    public init(
        engine: SwiftNativePersonaEngine = SwiftNativePersonaEngine(),
        fileManager: FileManager = .default
    ) {
        self.engine = engine
        self.fileManager = fileManager
    }

    // MARK: Public API

    /// Require canonical identity and exact saved persona selection; unavailable source fails compilation.
    public func compile(
        surface: String,
        personaOverride: String? = nil,
        userMemoryCore: [String]? = nil
    ) async throws -> PersonalityPacket {
        try await resolvedCompilation(
            surface: surface,
            personaOverride: personaOverride,
            userMemoryCore: userMemoryCore
        ).packet
    }

    public static func selectedPersonaID(root: URL, personaOverride: String?, fileManager: FileManager = .default) throws -> String {
        try resolveActivePersona(root: root, personaOverride: personaOverride, fileManager: fileManager).id
    }

    private func resolvedCompilation(
        surface: String,
        personaOverride: String?,
        userMemoryCore: [String]? = nil
    ) async throws -> ResolvedCompilation {
        let root = await engine.personaRoot

        let persona = try Self.resolveActivePersona(
            root: root, personaOverride: personaOverride, fileManager: fileManager
        )
        let documents = try await canonicalDocuments(root: root, personaSubdir: persona.subdir)
        let identity = try Self.identityPrompt(dataRoot: await engine.dataRootURL)
        return try resolvedCompilation(
            surface: surface, root: root, persona: persona,
            documents: documents, identity: identity, userMemoryCore: userMemoryCore
        )
    }

    private func canonicalDocuments(root: URL, personaSubdir: URL?) async throws -> [PersonaContextDocumentSource] {
        var documents: [PersonaContextDocumentSource] = []
        for (order, id) in Self.canonicalDocOrder.enumerated() {
            if let personaSubdir, let override = try readDoc(root: personaSubdir, id: id, order: order) {
                documents.append(override)
            } else {
                if id != "MEMORY" {
                    // Genesis requires checked absence; failed reads cannot select templates or another source.
                    _ = try await engine.createMissingRequiredDocument(id: id)
                }
                if let canonical = try readDoc(root: root, id: id, order: order, required: id != "MEMORY") {
                    documents.append(canonical)
                }
            }
        }
        return documents
    }

    private func resolvedCompilation(
        surface: String,
        root: URL,
        persona: (kind: String, id: String, subdir: URL?),
        documents: [PersonaContextDocumentSource],
        identity: String,
        userMemoryCore: [String]? = nil
    ) throws -> ResolvedCompilation {
        var documents = documents
        if let guidance = try readDoc(root: root.appendingPathComponent("surfaces", isDirectory: true),
            id: surface, order: Self.canonicalDocOrder.count, surfaceOverride: true) {
            documents.append(guidance)
        }
        var activeDocs = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.content) })
        activeDocs["IDENTITY"] = identity
        let compiledSystemPrompt = Self.renderPrompt(
            documents: activeDocs, surface: surface, userMemoryCore: userMemoryCore
        )

        // Fingerprint sorted document IDs, contents and surface so selection and source edits invalidate compiled identity.
        let fingerprint = Self.fingerprint(documents: activeDocs, surface: surface)

        let packet = PersonalityPacket(
            surface: surface,
            personaKind: persona.kind,
            personaId: persona.id,
            fingerprint: fingerprint,
            compiledSystemPrompt: compiledSystemPrompt,
            activeDocs: activeDocs,
            extras: nil
        )
        return ResolvedCompilation(
            packet: packet,
            personaRoot: root,
            activePersonaDirectory: persona.subdir,
            documents: documents
        )
    }

    /// Share prompt order and USER projection with the resident kernel while retaining whole source documents and fingerprints.
    public static func renderPrompt(
        documents: [String: String],
        surface: String? = nil,
        userMemoryCore: [String]? = nil
    ) -> String {
        let surfaceID = surface.map { "surface:\($0)" }
        let order = ["IDENTITY"] + canonicalDocOrder + (surfaceID.map { [$0] } ?? [])
        return order.compactMap { id -> String? in
            guard let document = documents[id] else { return nil }
            let body = id == "USER"
                ? UserMDAutogenMarkers.promptText(document, pinnedCore: userMemoryCore) : document
            if let surface, id == surfaceID {
                return "Surface guidance for \(surface):\n\(body)"
            }
            return body.isEmpty ? nil : "# \(id)\n\(body)"
        }.joined(separator: "\n\n")
    }

    public static func identityPrompt(dataRoot: URL) throws -> String {
        let name = agentDisplayName(profile: try compileProfile(dataRoot: dataRoot))
        return "Your name is \(name). This saved name is authoritative even when your personal documents use an earlier name."
    }

    /// Retain each document's supplying file from the actual compiler read for ContextFlow.
    public func contextSourceSnapshot(
        surface: String,
        personaOverride: String? = nil
    ) async throws -> PersonaContextSourceSnapshot {
        let resolved = try await resolvedCompilation(
            surface: surface,
            personaOverride: personaOverride
        )
        return contextSourceSnapshot(resolved)
    }

    /// Read common documents once so every refreshed surface uses the same immutable persona input.
    public func contextSourceSnapshots(
        surfaces: [String],
        personaOverrides: [String: String] = [:]
    ) async throws -> [PersonaContextSourceSnapshot] {
        let root = await engine.personaRoot
        let selected = PersonaSelection.current() ?? ""
        let identity = try Self.identityPrompt(dataRoot: await engine.dataRootURL)
        var resolvedByOverride: [String: (kind: String, id: String, subdir: URL?)] = [:]
        var documentsByPersona: [String: [PersonaContextDocumentSource]] = [:]
        var snapshots: [PersonaContextSourceSnapshot] = []
        for surface in surfaces {
            let override = personaOverrides[surface] ?? selected
            let persona: (kind: String, id: String, subdir: URL?)
            if let cached = resolvedByOverride[override] {
                persona = cached
            } else {
                persona = try Self.resolveActivePersona(
                    root: root, personaOverride: override, fileManager: fileManager
                )
                resolvedByOverride[override] = persona
            }
            let documents: [PersonaContextDocumentSource]
            if let cached = documentsByPersona[persona.id] {
                documents = cached
            } else {
                let loaded = try await canonicalDocuments(root: root, personaSubdir: persona.subdir)
                documentsByPersona[persona.id] = loaded
                documents = loaded
            }
            let resolved = try resolvedCompilation(
                surface: surface, root: root, persona: persona, documents: documents, identity: identity
            )
            snapshots.append(contextSourceSnapshot(resolved))
        }
        return snapshots
    }

    private func contextSourceSnapshot(_ resolved: ResolvedCompilation) -> PersonaContextSourceSnapshot {
        let packet = resolved.packet
        let root = resolved.personaRoot
        let activeDirectory = resolved.activePersonaDirectory
        var watched = Set<URL>([
            root,
            root.deletingLastPathComponent(),
            root.appendingPathComponent("surfaces", isDirectory: true),
        ])
        if let activeDirectory { watched.insert(activeDirectory) }
        return PersonaContextSourceSnapshot(
            packet: packet,
            personaRoot: root,
            activePersonaDirectory: activeDirectory,
            documents: resolved.documents,
            watchedDirectories: watched.sorted { $0.path < $1.path }
        )
    }

    /// Existing identity always requires checked reading; only onboarding creates it.
    public nonisolated static func compileProfile(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> CompiledPersonalityProfile {
        let profileURL = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
        do {
            let data = try Data(contentsOf: profileURL)
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PersonaEngineError.underlying("The profile must be a JSON object.")
            }
            return try decodeProfile(raw: raw)
        } catch {
            throw PersonaEngineError.profileUnavailable(path: profileURL.path, reason: error.localizedDescription)
        }
    }

    /// Require both saved identities for routing words; consumers cannot invent sender or recipient.
    public nonisolated static func configuredNames(dataRoot: URL) throws -> (agent: String, user: String) {
        let profile = try compileProfile(dataRoot: dataRoot)
        guard case .string(let supplied)? = profile.extras["userName"],
              !supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersonaEngineError.underlying("memory/profile.json.userName must be nonempty text. Repair that field before starting the helper.")
        }
        return (agentDisplayName(profile: profile), supplied.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Share generic-name normalization and the 80-scalar bound across readers.
    public nonisolated static func agentDisplayName(
        profile: CompiledPersonalityProfile
    ) -> String {
        NativeAgentIdentity.displayName(profile.name)
    }

    public nonisolated static func agentDisplayName(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        do { return agentDisplayName(profile: try compileProfile(dataRoot: dataRoot)) }
        catch {
            FileHandle.standardError.write(Data("Persona identity unavailable: \(error.localizedDescription)\n".utf8))
            return ""
        }
    }

    // MARK: - Internals

    /// A custom persona must override at least one canonical marker document.
    private static let personaMarkerDocs: Set<String> = ["SOUL", "VOICE", "GROWTH", "USER", "AGENTS"]

    public static func customPersonaNames(root: URL) throws -> [String] {
        try customPersonaDirectories(root: root, fileManager: .default).map(\.lastPathComponent)
    }

    private static func customPersonaDirectories(root: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            .filter { dir in
                guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return false }
                let selected = try selectedPersonaDirectory(name: dir.lastPathComponent, root: root)
                return try subdirHasMarker(selected, fileManager: fileManager)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Only absent selection uses the canonical root; a missing custom persona cannot select another.
    private static func resolveActivePersona(
        root: URL,
        personaOverride: String?,
        fileManager: FileManager
    ) throws -> (kind: String, id: String, subdir: URL?) {
        if let raw = personaOverride ?? PersonaSelection.current() {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                if name == "canonical" { return ("Default", "canonical", nil) }
                let candidate = try selectedPersonaDirectory(name: name, root: root)
                if try subdirHasMarker(candidate, fileManager: fileManager) {
                    return ("Custom", name, candidate)
                }
                throw PersonaEngineError.rootUnreadable(
                    reason: "Selected persona \(name) has no persona documents at \(candidate.path). Repair the selection or select canonical.")
            }
        }
        return ("Default", "canonical", nil)
    }

    private static func selectedPersonaDirectory(name: String, root: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PersonaEngineError.rootUnreadable(reason: "persona name must be a safe directory name")
        }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard let tail = NativeAgentWorkspaceRoot.relativePath(candidate.path, under: resolvedRoot.path), !tail.isEmpty else {
            throw PersonaEngineError.rootUnreadable(reason: "selected persona directory is outside the persona root")
        }
        return candidate
    }

    private static func subdirHasMarker(_ dir: URL, fileManager: FileManager) throws -> Bool {
        let isDirectory: Bool?
        do { isDirectory = try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory }
        catch CocoaError.fileReadNoSuchFile { return false }
        guard isDirectory == true else {
            return false
        }
        for id in Self.personaMarkerDocs {
            let f = dir.appendingPathComponent("\(id).md")
            do {
                if try f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { return true }
            } catch CocoaError.fileReadNoSuchFile { continue }
        }
        return false
    }

    private func readDoc(root: URL, id: String, order: Int, surfaceOverride: Bool = false, required: Bool = false) throws -> PersonaContextDocumentSource? {
        let url = root.appendingPathComponent("\(id).md")
        if try SwiftNativePersonaEngine.personaDocumentIsMissing(at: url) {
            if required { throw PersonaEngineError.missingRequiredDocument(path: url.path) }
            return nil
        }
        let content: String
        do { content = try SwiftNativePersonaEngine.readPersonaDocument(at: url) }
        catch {
            throw PersonaEngineError.rootUnreadable(
                reason: "cannot read \(url.path): \(error.localizedDescription). Repair or restore this document before continuing."
            )
        }
        return PersonaContextDocumentSource(id: surfaceOverride ? "surface:\(id)" : id,
            fileURL: url, content: content, canonicalOrder: order,
            optional: surfaceOverride || id == "MEMORY", surfaceOverride: surfaceOverride)
    }

    public static func fingerprint(documents: [String: String], surface: String) -> String {
        var documents = documents
        let surfaceID = "surface:\(surface)"
        if let guidance = documents.removeValue(forKey: surfaceID) {
            documents["surfaceGuidance"] = renderPrompt(documents: [surfaceID: guidance], surface: surface)
        }
        var hasher = SHA256()
        let ids = documents.keys.sorted()
        for id in ids {
            hasher.update(data: Data(id.utf8))
            hasher.update(data: Data([0x1F]))
            hasher.update(data: Data((documents[id] ?? "").utf8))
            hasher.update(data: Data([0x1E]))
        }
        hasher.update(data: Data("surface=".utf8))
        hasher.update(data: Data(surface.utf8))
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
