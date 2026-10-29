import CryptoKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaEngine+Writes.swift` | `SwiftNativePersonaEngine`: profile schema preparation, including onboarding, and sole profile commit owner; fixed document specs and guarded writes; append reads current content under the write lock with the editor's cap and backup policy |

// MARK: - Persona writes
//
// Caller authorization still applies to profile and document mutations.
// Mutations hold the target's shared cross-process file lock. USER.md remains
// a MemoryV2 UserMDGenerator projection and cannot be saved or scaffolded here.
// Storage: persona Markdown/recovery copies and memory/profile.json are in local
// and off-disk backups and the data export. Phone sync projects only the profile;
// PrivacyMap lists persona documents under persona, profile.json under memory.

public enum PersonaWriteError: Error, LocalizedError, Equatable {
    /// Onboarding refusal with the caller-visible detail preserved.
    case onboardingRequired(detail: String)
    case unknownDocument(String)
    /// IO failure during the atomic write / read-back.
    case ioFailure(String)
    /// Invalid persona kind, missing title or unresolvable persona path.
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .onboardingRequired(let d): return d
        case .unknownDocument(let id):   return "Unknown personality document: \(id)"
        case .ioFailure(let m):          return m
        case .invalidInput(let m):       return m
        }
    }
}

extension SwiftNativePersonaEngine {

    // Fixed document ids and order are part of the listing contract.
    static let personalityDocSpecsFixed: [(id: String, title: String, filename: String)] = [
        ("SOUL",   "Soul",             "SOUL.md"),
        ("VOICE",  "Voice",            "VOICE.md"),
        ("GROWTH", "Growth",           "GROWTH.md"),
        ("USER",   "User",             "USER.md"),
        ("AGENTS", "Operating Manual", "AGENTS.md"),
    ]

    // MARK: - Profile writes

    /// Normalize, merge partial fields (traits replace wholesale), stamp and persist under the profile lock.
    /// Unspecified fields and unknown keys survive; JSON uses two-space indentation and keys sorted by UTF-8 byte order.
    public func savePersonality(body: [String: JSONValue]) async throws -> CompiledPersonalityProfile {
        let profileURL = dataRootURL
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")

        return try await SwiftNativePersistenceCore.withFileLock(profileURL) {
            // Read raw under the lock so we merge over the latest on-disk state.
            var existingRaw: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: profileURL.path) {
                do {
                    let data = try Data(contentsOf: profileURL)
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw PersonaWriteError.ioFailure(
                            "Cannot update profile.json because its top-level value is not an object."
                        )
                    }
                    existingRaw = object
                } catch let error as PersonaWriteError {
                    throw error
                } catch {
                    throw PersonaWriteError.ioFailure(
                        "Cannot update unreadable profile.json: \(error.localizedDescription)"
                    )
                }
            }
            let existing = PersonaCompiler.normalize(raw: existingRaw, defaults: .defaults)
            var merged = Self.profileToRawDict(existing)

            for (key, value) in body {
                merged[key] = value.foundationObject
            }
            merged["updatedAt"] = NativeTimestampFormat.fractionalZulu(Date())

            let normalized = PersonaCompiler.normalize(raw: merged, defaults: .defaults)

            let jv = JSONValue.object(Self.profileFields(normalized))
            let text = try jv.serialize(pretty: true)
            try Self.atomicWriteText(text, to: profileURL)

            return normalized
        }
    }

    // Profile schema preparation and commits stay here; onboarding owns intent.
    // profile.json is backed up/exported and listed under memory in PrivacyMap;
    // the phone receives a compiled profile projection.
    package static func onboardingProfileUpdate(
        profilePath: URL,
        agentName: String,
        personaType: String,
        userName: String
    ) throws -> (content: String, baseSHA256: String?) {
        var raw: [String: Any] = [:]
        var baseSHA256: String?
        if FileManager.default.fileExists(atPath: profilePath.path) {
            let data: Data
            do {
                data = try Data(contentsOf: profilePath)
            } catch {
                throw PersonaWriteError.ioFailure("read existing profile.json failed: \(error.localizedDescription)")
            }
            baseSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let decoded: Any
            do {
                decoded = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw PersonaWriteError.ioFailure("existing profile.json is malformed; preserving original bytes")
            }
            guard let object = decoded as? [String: Any] else {
                throw PersonaWriteError.ioFailure("existing profile.json is not an object; preserving original bytes")
            }
            raw = object
        }
        // First normalize to current canonical shape.
        let current = PersonaCompiler.normalize(raw: raw, defaults: .defaults)

        let kindMap: [String: String] = ["female": "Female", "male": "Male", "ai": "AI"]
        let newKind = kindMap[personaType] ?? "AI"
        let newVoice: String
        switch personaType {
        case "female": newVoice = "Warm, observational, judgment-forward."
        case "male": newVoice = "Direct, dry, holds ground."
        default: newVoice = "Precise, characterful, honest."
        }

        // Apply onboarding values to the normalized profile, then normalize again.
        var merged = SwiftNativePersonaEngine.profileToRawDict(current)
        merged["name"] = agentName
        merged["personaKind"] = newKind
        merged["voice"] = newVoice
        merged["updatedAt"] = NativeTimestampFormat.fractionalZulu(Date())
        let renormalized = PersonaCompiler.normalize(raw: merged, defaults: .defaults)
        var finalDict = SwiftNativePersonaEngine.profileToRawDict(renormalized)
        // Add the trimmed user's name after normalization; an empty name is omitted.
        let trimmedUserName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUserName.isEmpty {
            finalDict["userName"] = trimmedUserName
        }

        let json = JSONValue(fromFoundation: finalDict)
        let bytes = try json.serializedData(pretty: false)
        let text = String(decoding: bytes, as: UTF8.self)
        return (content: text, baseSHA256: baseSHA256)
    }

    // MARK: - Document writes

    /// SOUL.md gates editing; onboarding alone initializes it. USER.md is MemoryV2-owned.
    /// Replacement caps at 30,000 Unicode scalars; append reads under the document lock and refuses overflow.
    /// Back up to `<file>.bak` and write durably under that lock; return saved content with the file's mtime.
    public func savePersonalityDoc(id: String, content: String, appending: Bool = false) async throws -> PersonaDocSpec {
        let docId = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // ONBOARDING gate — SOUL.md existence is the sentinel.
        let soulURL = personaRoot.appendingPathComponent("SOUL.md")
        let soulInitialized = fileManagerForWrites.fileExists(atPath: soulURL.path)
        if !soulInitialized && docId != "SOUL" {
            throw PersonaWriteError.onboardingRequired(
                detail: "Persona is not initialized. Complete first-run onboarding before editing personality docs."
            )
        }
        if !soulInitialized && docId == "SOUL" {
            throw PersonaWriteError.onboardingRequired(
                detail: "Run /v1/onboarding/complete to initialize the persona; do not write SOUL.md directly."
            )
        }
        if docId == "USER" {
            throw PersonaWriteError.invalidInput(Self.memoryOwnedUserDocMessage)
        }

        guard let spec = Self.personalityDocSpecsFixed.first(where: { $0.id == docId }) else {
            throw PersonaWriteError.unknownDocument(docId)
        }
        let path = personaRoot.appendingPathComponent(spec.filename)

        // Lock order: document, then activity feed; activity append failures propagate.
        let result: PersonaDocSpec = try await SwiftNativePersistenceCore.withFileLock(path) { [self] in
            // Setup contributes only its section, never a carried-forward SOUL.
            // An unreadable append base throws before either backup or mutation.
            let nextContent = appending ? try String(contentsOf: path, encoding: .utf8) + content : content
            guard !appending || nextContent.unicodeScalars.count <= 30_000 else {
                throw PersonaWriteError.invalidInput("The combined document exceeds 30,000 code points. Nothing was appended; shorten the draft or edit the document explicitly.")
            }
            // Preserve the editor's 30000-code-point cap on the combined document.
            let cappedContent = Self.capByCodePoints(nextContent, cap: 30000)
            // One pre-edit copy per doc (`SOUL.md.bak`), replaced each save, so
            // the last version before any edit is always one file away.
            if FileManager.default.fileExists(atPath: path.path) {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(
                    Data(contentsOf: path),
                    to: path.appendingPathExtension("bak")
                )
            }
            try Self.atomicWriteText(cappedContent, to: path)

            // Emit once after the write and before readback, while holding the document lock.
            try await self.recordPersonaDocActivity(docId: docId)

            let reread = (try? String(contentsOf: path, encoding: .utf8)) ?? cappedContent
            let mtime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let spec = PersonaDocSpec(
                id: spec.id,
                title: spec.title,
                filename: spec.filename,
                path: path.path,
                content: reread,
                updatedAt: NativeTimestampFormat.fractionalZulu(mtime)
            )
            return spec
        }

        await publishDerivedPersonaChange(path, reason: "persona_document_saved")
        return result
    }

    // MARK: - Missing-document scaffolding

    /// After SOUL exists, create missing VOICE/GROWTH/AGENTS documents from
    /// the profile defaults, atomically under each document's lock. SOUL is
    /// onboarding-owned; USER is MemoryV2-owned. Publish invalidations for
    /// created documents; unlike `savePersonalityDoc`, this emits no activity.
    ///
    /// - Returns: the ids actually written this call (empty if none / pre-onboarding).
    @discardableResult
    public func scaffoldMissingDocs() async throws -> [String] {
        let soulURL = personaRoot.appendingPathComponent("SOUL.md")
        guard fileManagerForWrites.fileExists(atPath: soulURL.path) else {
            return []
        }

        let missing = Self.personalityDocSpecsFixed.filter {
            $0.id != "SOUL" && $0.id != "USER"
                && !fileManagerForWrites.fileExists(atPath: personaRoot.appendingPathComponent($0.filename).path)
        }
        guard !missing.isEmpty else { return [] }
        let profile = PersonaCompiler.loadProfile(dataRoot: dataRootURL)
        var written: [String] = []

        for spec in missing {
            let path = personaRoot.appendingPathComponent(spec.filename)

            let body = SwiftNativePersonaEngine.defaultPersonalityDocContent(
                id: spec.id,
                profile: profile
            )
            // Share savePersonalityDoc's lock; recheck existence inside it
            // so concurrent writers cannot replace a document that just arrived.
            let didWrite: Bool = try await SwiftNativePersistenceCore.withFileLock(path) {
                if FileManager.default.fileExists(atPath: path.path) { return false }
                try Self.atomicWriteText(body, to: path)
                return true
            }
            if didWrite { written.append(spec.id) }
        }
        if !written.isEmpty {
            let changes = written.map { id in
                DerivedSourceChange(
                    namespace: "persona",
                    stableID: id,
                    operation: .changed,
                    canonicalLocator: personaRoot.appendingPathComponent("\(id).md").path,
                    reason: "persona_documents_scaffolded"
                )
            }
            await DerivedStateInvalidationCenter.shared.publish(changes)
        }
        return written
    }

    // MARK: - Document-save activity

    /// The document-save activity feed under this engine's data root.
    var activityEventsPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: dataRootURL)
    }

    /// Save events contain only a fixed document id, constant text and an empty payload.
    /// Credential-bearing content requires redaction before it can be added here.
    // activity/events.jsonl: local backup/data export/phone sync exclude it;
    // off-disk backup and support bundles include it. PrivacyMap: activity.
    func recordPersonaDocActivity(docId: String) async throws {
        // Stamp after the document write, while its lock is still held.
        let event = SwiftNativePersistenceCore.activityEvent(
            id: UUID().uuidString.lowercased(),
            kind: "memory",
            title: "\(docId).md updated",
            detail: "Personality document saved",
            status: "ok",
            executionId: nil,
            payload: .object([:]),
            createdAt: NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(Date())
        )
        try await SwiftNativePersistenceCore.appendActivityEvent(
            event, to: activityEventsPath, logLabel: "PersonaEngine"
        )
    }

    // MARK: - helpers (write-side)

    /// `FileManager` for write-side existence checks. The actor's stored
    /// `fileManager` is private; expose the default here (the write path only
    /// needs `fileExists`, which `.default` answers identically).
    private var fileManagerForWrites: FileManager { .default }

    /// Use the same typed fields for normalization and persistence, preserving
    /// Foundation's NSNumber leaves and unknown profile keys.
    package static func profileToRawDict(_ p: CompiledPersonalityProfile) -> [String: Any] {
        profileFields(p).mapValues { $0.foundationObject }
    }

    /// Persist schemaVersion as an integer, traits as doubles, lists as string arrays
    /// and surfaceOverrides as a string-to-string object.
    static func profileFields(_ p: CompiledPersonalityProfile) -> [String: JSONValue] {
        let traits: JSONValue = .object([
            "warmth": .double(p.traits.warmth),
            "directness": .double(p.traits.directness),
            "humor": .double(p.traits.humor),
            "proactivity": .double(p.traits.proactivity),
            "rigor": .double(p.traits.rigor),
            "autonomy": .double(p.traits.autonomy),
            "creativity": .double(p.traits.creativity),
            "brevity": .double(p.traits.brevity),
        ])
        var obj: [String: JSONValue] = [
            "schemaVersion": .int(Int64(p.schemaVersion)),
            "personaEngineVersion": .string(p.personaEngineVersion),
            "name": .string(p.name),
            "personaKind": .string(p.personaKind),
            "essence": .string(p.essence),
            "voice": .string(p.voice),
            "customDirective": .string(p.customDirective),
            "traits": traits,
            "examples": .array(p.examples.map { .string($0) }),
            "forbiddenPatterns": .array(p.forbiddenPatterns.map { .string($0) }),
            "instincts": .array(p.instincts.map { .string($0) }),
            "boundaries": .array(p.boundaries.map { .string($0) }),
            "surfaceOverrides": .object(p.surfaceOverrides.mapValues { JSONValue.string($0) }),
            "updatedAt": .string(p.updatedAt),
        ]
        // Unknown keys round-trip without replacing typed fields; serialization sorts them with the rest.
        for (key, value) in p.extras where obj[key] == nil {
            obj[key] = value
        }
        return obj
    }

    /// Cap by Unicode scalars rather than grapheme clusters.
    static func capByCodePoints(_ s: String, cap: Int) -> String {
        let scalars = s.unicodeScalars
        if scalars.count <= cap { return s }
        return String(String.UnicodeScalarView(scalars.prefix(cap)))
    }

    /// Durable write: 0600 temp, fsync, rename and parent-directory fsync.
    package static func atomicWriteText(_ content: String, to path: URL) throws {
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(content.utf8), to: path)
        } catch PersistenceCoreError.ioFailure(let detail) {
            throw PersonaWriteError.ioFailure(detail)
        }
    }
}

// MARK: - The shared (Mac and phone) profile shape

extension SwiftNativePersonaEngine {
    /// The Personality tab's full-profile save uses the same Foundation leaf types as JSON decoding.
    public func savePersonality(_ profile: PersonalityProfile) async throws -> CompiledPersonalityProfile {
        var body: [String: Any] = [
            "name": profile.name,
            "personaKind": profile.personaKind,
            "essence": profile.essence,
            "voice": profile.voice,
            "customDirective": profile.customDirective ?? "",
            "traits": [
                "warmth": profile.traits.warmth,
                "directness": profile.traits.directness,
                "humor": profile.traits.humor,
                "proactivity": profile.traits.proactivity,
                "rigor": profile.traits.rigor,
                "autonomy": profile.traits.autonomy,
                "creativity": profile.traits.creativity,
                "brevity": profile.traits.brevity
            ]
        ]
        if let instincts = profile.instincts {
            body["instincts"] = instincts
        }
        if let boundaries = profile.boundaries {
            body["boundaries"] = boundaries
        }
        if let examples = profile.examples {
            body["examples"] = examples
        }
        if let forbiddenPatterns = profile.forbiddenPatterns {
            body["forbiddenPatterns"] = forbiddenPatterns
        }
        if let surfaceOverrides = profile.surfaceOverrides {
            body["surfaceOverrides"] = surfaceOverrides
        }
        return try await savePersonality(body: NativeActionWire.jsonValueBody(body))
    }
}

extension CompiledPersonalityProfile {
    /// Field-for-field the profile the Personality tab and the phone read,
    /// on load and on save alike.
    public var sharedProfile: PersonalityProfile {
        PersonalityProfile(
            schemaVersion: schemaVersion,
            personaEngineVersion: personaEngineVersion,
            name: name,
            personaKind: personaKind,
            essence: essence,
            voice: voice,
            customDirective: customDirective.isEmpty ? nil : customDirective,
            traits: traits,
            examples: examples,
            forbiddenPatterns: forbiddenPatterns,
            instincts: instincts,
            boundaries: boundaries,
            surfaceOverrides: surfaceOverrides,
            updatedAt: updatedAt.isEmpty ? nil : updatedAt
        )
    }
}

extension PersonaDocSpec: Identifiable {}

extension SwiftNativePersonaEngine {
    public func saveName(_ rawName: String) async throws -> PersonalityProfile {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PersonaWriteError.invalidInput("Enter a name before saving.") }
        guard !NativeAgentIdentity.displayName(name, fallback: "").isEmpty else {
            throw PersonaWriteError.invalidInput("Choose a specific name instead of a generic persona label.")
        }
        return try await savePersonality(body: ["name": .string(name)]).sharedProfile
    }
}
