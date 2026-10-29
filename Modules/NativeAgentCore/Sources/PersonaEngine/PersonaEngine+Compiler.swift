import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `PersonaEngine+Compiler.swift` | `PersonaCompiler`: `compile`, `fingerprint`, `renderPrompt`; batched context surfaces share canonical persona documents and identity, with separate surface overrides; USER core projection |

// MARK: - PersonalityPacket

public struct PersonalityPacket: Sendable, Codable, Equatable {
    public let surface: String
    public let personaKind: String       // "Custom" | "Default"
    public let personaId: String
    public let fingerprint: String       // SHA-256 hex prefix (16 chars)
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
    public let essence: String
    public let voice: String
    public let customDirective: String
    public let traits: CompiledPersonalityTraits
    public let examples: [String]
    public let forbiddenPatterns: [String]
    public let instincts: [String]
    public let boundaries: [String]
    public let surfaceOverrides: [String: String]
    public let updatedAt: String

    /// Unknown profile.json keys round-trip losslessly, disjoint from normalized fields and the consumed gender alias.
    public let extras: [String: JSONValue]

    public init(
        schemaVersion: Int,
        personaEngineVersion: String,
        name: String,
        personaKind: String,
        essence: String,
        voice: String,
        customDirective: String,
        traits: CompiledPersonalityTraits,
        examples: [String],
        forbiddenPatterns: [String],
        instincts: [String],
        boundaries: [String],
        surfaceOverrides: [String: String],
        updatedAt: String,
        extras: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.personaEngineVersion = personaEngineVersion
        self.name = name
        self.personaKind = personaKind
        self.essence = essence
        self.voice = voice
        self.customDirective = customDirective
        self.traits = traits
        self.examples = examples
        self.forbiddenPatterns = forbiddenPatterns
        self.instincts = instincts
        self.boundaries = boundaries
        self.surfaceOverrides = surfaceOverrides
        self.updatedAt = updatedAt
        self.extras = extras
    }

    /// Normalization seed for missing profile storage and absent or malformed fields.
    public static let defaults: CompiledPersonalityProfile = CompiledPersonalityProfile(
        schemaVersion: 2,
        personaEngineVersion: "2.0",
        name: "NativeAgent",
        personaKind: "AI",
        essence: "A calm, sharp, practical native macOS agent that improves itself inside its own sandbox and helps the user get real work done.",
        voice: "Direct, grounded, specific, with no corporate fluff.",
        customDirective: "",
        traits: CompiledPersonalityTraits(
            warmth: 0.45, directness: 0.82, humor: 0.12, proactivity: 0.78,
            rigor: 0.86, autonomy: 0.82, creativity: 0.58, brevity: 0.74
        ),
        examples: [
            "When tools are involved, be explicit about what was actually done.",
        ],
        forbiddenPatterns: [
            "Claiming tool or file actions that did not happen.",
        ],
        instincts: [
            "Keep self-improvement autonomous but contained to app-owned paths.",
        ],
        boundaries: [
            "Do not invent tool results.",
            "Do not claim files were changed unless they were.",
            "Do not autonomously modify unrelated computer files while improving yourself.",
        ],
        surfaceOverrides: [
            "chat": "",
            "dream": "Reflect like an internal agent maintenance pass: specific lessons, memory candidates, eval ideas, and improvement targets.",
            "autonomy": "Operate as a careful self-improvement engineer inside the app-owned worktree.",
        ],
        updatedAt: ""
    )
}

// MARK: - PersonaCompiler

/// Compiles each surface from the engine's persona and data roots.
/// Optional active.json, selected persona documents, MEMORY.md and surface
/// overrides remain accepted file inputs. Local/off-disk backup and data export
/// include the persona root; phone sync excludes it; PrivacyMap: persona.
public actor PersonaCompiler {
    private struct ResolvedCompilation {
        let packet: PersonalityPacket
        let personaRoot: URL
        let activePersonaDirectory: URL?
        let documents: [PersonaContextDocumentSource]
    }

    /// Source engine for this compiler's persona and data roots.
    internal let engine: SwiftNativePersonaEngine
    private let fileManager: FileManager

    /// Canonical prompt order: MEMORY.md is an optional input with no runtime writer; surface guidance follows AGENTS.
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

    /// Honours the shared persona selection. When the selected name identifies
    /// a subdir under the persona root that contains at least one marker doc,
    /// that subdir wins over the on-disk `active.json` / scan resolution.
    /// Override resolution failures fall through to the normal resolver — a
    /// typo can't blank the persona. A turn requires the saved name: an
    /// unreadable profile then throws the repair text instead of omitting it.
    public func compile(
        surface: String,
        personaOverride: String? = nil,
        userMemoryCore: [String]? = nil,
        identityRequired: Bool = false
    ) async throws -> PersonalityPacket {
        try await resolvedCompilation(
            surface: surface,
            personaOverride: personaOverride,
            userMemoryCore: userMemoryCore,
            identityRequired: identityRequired
        ).packet
    }

    public static func selectedPersonaID(root: URL, personaOverride: String?, fileManager: FileManager = .default) throws -> String {
        try resolveActivePersona(root: root, personaOverride: personaOverride, fileManager: fileManager).id
    }

    private func resolvedCompilation(
        surface: String,
        personaOverride: String?,
        userMemoryCore: [String]? = nil,
        identityRequired: Bool = false
    ) async throws -> ResolvedCompilation {
        let root = await engine.personaRoot

        let persona = try Self.resolveActivePersona(
            root: root, personaOverride: personaOverride, fileManager: fileManager
        )
        let documents = try canonicalDocuments(root: root, personaSubdir: persona.subdir)
        var identity: String?
        // Unless a turn requires it, an unreadable profile omits the line;
        // her documents still carry her name.
        do {
            identity = try Self.identityPrompt(dataRoot: await engine.dataRootURL)
        } catch where !identityRequired {}
        return try resolvedCompilation(
            surface: surface, root: root, persona: persona,
            documents: documents, identity: identity, userMemoryCore: userMemoryCore
        )
    }

    private func canonicalDocuments(root: URL, personaSubdir: URL?) throws -> [PersonaContextDocumentSource] {
        var documents: [PersonaContextDocumentSource] = []
        for (order, id) in Self.canonicalDocOrder.enumerated() {
            if let personaSubdir, let override = try readDoc(root: personaSubdir, id: id, order: order) {
                documents.append(override)
            } else if let canonical = try readDoc(root: root, id: id, order: order) {
                documents.append(canonical)
            }
        }
        return documents
    }

    private func resolvedCompilation(
        surface: String,
        root: URL,
        persona: (kind: String, id: String, subdir: URL?),
        documents: [PersonaContextDocumentSource],
        identity: String?,
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

        // Fingerprint — SHA-256 over (sorted ids + their contents + surface).
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

    /// Cold compilation and the resident kernel share prompt ordering and USER core projection.
    /// Source documents and their fingerprints remain whole.
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

    /// ContextFlow retains each document's supplying file from the live compiler's read.
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

    /// One read of common documents per selected persona, with surface guidance
    /// applied to that same immutable input for every kernel in the refresh.
    public func contextSourceSnapshots(
        surfaces: [String],
        personaOverrides: [String: String] = [:]
    ) async throws -> [PersonaContextSourceSnapshot] {
        let root = await engine.personaRoot
        let selected = PersonaSelection.current() ?? ""
        let identity = try? Self.identityPrompt(dataRoot: await engine.dataRootURL)
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
                let loaded = try canonicalDocuments(root: root, personaSubdir: persona.subdir)
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

    /// Only missing storage receives defaults when compiling authoritative identity.
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
            guard raw["name"] == nil || raw["name"] is String else {
                throw PersonaEngineError.underlying("The profile name must be text.")
            }
            return normalize(raw: raw, defaults: .defaults)
        } catch CocoaError.fileReadNoSuchFile {
            return normalize(raw: [:], defaults: .defaults)
        } catch {
            throw PersonaEngineError.underlying("The saved personality profile is unavailable. Repair or restore access to memory/profile.json before continuing. \(error.localizedDescription)")
        }
    }

    /// Display and trait readers use a default-seeded projection when storage is unavailable.
    /// Authoritative identity and profile editing use the checked compiler.
    public nonisolated static func loadProfile(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> CompiledPersonalityProfile {
        (try? compileProfile(dataRoot: dataRoot)) ?? .defaults
    }

    /// Shared display-name normalization, including generic names and the
    /// 80-Unicode-scalar limit.
    public nonisolated static func agentDisplayName(
        profile: CompiledPersonalityProfile
    ) -> String {
        NativeAgentIdentity.displayName(profile.name)
    }

    /// Read and normalize the saved display name, including generic-label replacement.
    public nonisolated static func agentDisplayName(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        return agentDisplayName(profile: loadProfile(dataRoot: dataRoot))
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
                (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && (try? selectedPersonaDirectory(name: dir.lastPathComponent, root: root)) != nil
                    && subdirHasMarker(dir, fileManager: fileManager)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Returns (kind, id, customSubdirURL?). Selection order:
    ///   1. `<root>/active.json` { "persona": "<Name>" } if present + dir
    ///      exists + dir has at least one marker doc → Custom.
    ///   2. Otherwise scan immediate subdirs; pick the first (sorted)
    ///      that contains a marker doc → Custom.
    ///   3. None found → Default / "canonical".
    private static func resolveActivePersona(
        root: URL,
        personaOverride: String?,
        fileManager: FileManager
    ) throws -> (kind: String, id: String, subdir: URL?) {
        // 0. Shared selection. Trim, then look
        //    for a subdir with at least one marker doc. Misses fall through
        //    to the normal resolver so a typo can't blank the persona.
        if let raw = personaOverride ?? PersonaSelection.current() {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let candidate = try selectedPersonaDirectory(name: name, root: root)
                if subdirHasMarker(candidate, fileManager: fileManager) {
                    return ("Custom", name, candidate)
                }
                // Override naming the canonical persona by display name (e.g.
                // the configured name when SOUL.md lives at the root) —
                // fall through to the scan + default. The chosen-persona name
                // is preserved on `metadata.persona` upstream regardless.
            }
        }
        // 1. active.json
        let activeFile = root.appendingPathComponent("active.json")
        if fileManager.fileExists(atPath: activeFile.path) {
            let name: String
            do {
                let data = try Data(contentsOf: activeFile)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawName = object["persona"] as? String,
                      !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PersonaEngineError.rootUnreadable(
                        reason: "active.json must contain a non-empty persona string"
                    )
                }
                name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch let error as PersonaEngineError {
                throw error
            } catch {
                throw PersonaEngineError.rootUnreadable(
                    reason: "cannot read active.json: \(error.localizedDescription)"
                )
            }
            let candidate = try selectedPersonaDirectory(name: name, root: root)
            if subdirHasMarker(candidate, fileManager: fileManager) {
                return ("Custom", name, candidate)
            }
        }
        // 2. Scan immediate subdirs.
        if let dir = try? customPersonaDirectories(root: root, fileManager: fileManager).first {
            return ("Custom", dir.lastPathComponent, try selectedPersonaDirectory(name: dir.lastPathComponent, root: root))
        }
        // 3. Default
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

    private static func subdirHasMarker(_ dir: URL, fileManager: FileManager) -> Bool {
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }
        for id in Self.personaMarkerDocs {
            let f = dir.appendingPathComponent("\(id).md")
            if fileManager.fileExists(atPath: f.path) { return true }
        }
        return false
    }

    private func readDoc(root: URL, id: String, order: Int, surfaceOverride: Bool = false) throws -> PersonaContextDocumentSource? {
        let url = root.appendingPathComponent("\(id).md")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return PersonaContextDocumentSource(id: surfaceOverride ? "surface:\(id)" : id,
            fileURL: url, content: try readPersonaDocument(at: url), canonicalOrder: order,
            optional: surfaceOverride || id == "MEMORY", surfaceOverride: surfaceOverride)
    }

    private func readPersonaDocument(at url: URL) throws -> String {
        do {
            return try SwiftNativePersonaEngine.readPersonaDocument(at: url)
        } catch {
            throw PersonaEngineError.rootUnreadable(
                reason: "cannot read \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
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
            hasher.update(data: Data([0x1F])) // unit separator
            hasher.update(data: Data((documents[id] ?? "").utf8))
            hasher.update(data: Data([0x1E])) // record separator
        }
        hasher.update(data: Data("surface=".utf8))
        hasher.update(data: Data(surface.utf8))
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
