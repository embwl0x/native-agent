import CryptoKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `PersonaEngine+Writes.swift` | `SwiftNativePersonaEngine`. |

// MARK: - Persona writes
// Keep caller authorization and the shared target lock around mutations; MemoryV2 alone owns ordinary USER edits.
// Checked missing-document genesis may scaffold USER without replacing existing projection.
// Backups and export include persona/recovery files and profile; phone sync projects profile only.
// PrivacyMap owns persona documents under persona and profile under memory.

public enum PersonaWriteError: Error, LocalizedError, Equatable {
    case unknownDocument(String)
    case ioFailure(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .unknownDocument(let id):   return "Unknown personality document: \(id)"
        case .ioFailure(let m):          return m
        case .invalidInput(let m):       return m
        }
    }
}

extension SwiftNativePersonaEngine {

    // Keep document IDs and ordering stable for listing readers.
    package static let personalityDocSpecsFixed: [(id: String, title: String, filename: String)] = [
        ("SOUL",   "Soul",             "SOUL.md"),
        ("VOICE",  "Voice",            "VOICE.md"),
        ("GROWTH", "Growth",           "GROWTH.md"),
        ("USER",   "User",             "USER.md"),
        ("AGENTS", "Operating Manual", "AGENTS.md"),
    ]

    /// Share the operating-manual seed between onboarding and checked missing-only genesis.
    package static func operatingManualGenesis(name: String) -> String {
        "# \(name) Operating Manual\n"
    }

    /// Inspect dangling links as entries; read failure cannot authorize replacement or inherited content.
    static func personaDocumentIsMissing(at path: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
            return false
        } catch let error as CocoaError where error.isFileAbsent {
            return true
        } catch {
            throw PersonaEngineError.rootUnreadable(
                reason: "cannot inspect \(path.path): \(error.localizedDescription). Restore access to this document; it has not been replaced.")
        }
    }

    /// Recheck absence, completion and identity under both locks before genesis.
    @discardableResult
    public func createMissingRequiredDocument(id: String) async throws -> Bool {
        guard let spec = Self.personalityDocSpecsFixed.first(where: { $0.id == id }) else {
            throw PersonaWriteError.unknownDocument(id)
        }
        let repairDataRoot = dataRootURL
        let completionLock = repairDataRoot.appendingPathComponent("onboarding/pending-completion.json")
        let path = personaRoot.appendingPathComponent(spec.filename)
        guard try Self.personaDocumentIsMissing(at: path) else { return false }
        return try await SwiftNativePersistenceCore.withFileLock(completionLock) { [self] in
            try await SwiftNativePersistenceCore.withFileLock(path) { [self] in
                guard try Self.personaDocumentIsMissing(at: path) else { return false }
                guard NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: repairDataRoot) else { return false }
                let profile = try PersonaCompiler.compileProfile(dataRoot: repairDataRoot)
                let userName: String?
                if id == "USER", let saved = profile.extras["userName"], saved != .null {
                    guard let text = saved.stringValue else {
                        throw PersonaWriteError.invalidInput(
                            "USER.md genesis cannot read memory/profile.json.userName as text. Repair that field before creating the document.")
                    }
                    userName = text
                } else { userName = nil }
                let docs = try PersonaTemplates.generate(name: profile.name,
                    personaType: profile.personaKind, userName: userName)
                let content: String
                switch id {
                case "SOUL": content = docs.soul
                case "VOICE": content = docs.voice
                case "USER": content = docs.user
                case "GROWTH": content = docs.growth
                case "AGENTS": content = docs.agents
                default: throw PersonaWriteError.unknownDocument(id)
                }
                try Self.atomicWriteText(content, to: path)
                await self.publishDerivedPersonaChange(path, reason: "persona_required_document_created")
                do {
                    guard try Self.readPersonaDocument(at: path) == content else {
                        throw PersonaWriteError.ioFailure("created document does not match its committed seed")
                    }
                } catch {
                    throw PersonaWriteError.ioFailure(
                        """
                            \(spec.filename) was created at \(path.path), but verification failed: \(error.localizedDescription). Preserve and inspect the \
                            saved bytes before another repair.
                            """)
                }
                return true
            }
        }
    }

    // MARK: - Profile writes

    /// Validate submitted identity and saved base before locked merge; preserve unspecified and unknown fields.
    /// Replace traits as a whole and serialize with stable UTF-8 key ordering.
    public func savePersonality(body: [String: JSONValue]) async throws -> CompiledPersonalityProfile {
        let editable: Set<String> = ["name", "personaKind", "traits"]
        guard Set(body.keys).isSubset(of: editable) else {
            throw PersonaWriteError.invalidInput(
                "Profile updates accept name, personaKind and traits only. Edit instructions through the canonical personality documents.")
        }
        if let supplied = body["name"] {
            guard case .string(let name) = supplied else {
                throw PersonaWriteError.invalidInput("The agent's name must be text.")
            }
            if let message = NativeAgentIdentity.nameValidationMessage(name) {
                throw PersonaWriteError.invalidInput(message)
            }
        }
        let profileURL = dataRootURL
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")

        return try await SwiftNativePersistenceCore.withFileLock(profileURL) {
            // Read the latest saved state under the lock before merging.
            let existingRaw: [String: Any]
            do {
                let data = try Data(contentsOf: profileURL)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw PersonaWriteError.ioFailure(
                        "Cannot update profile.json because its top-level value is not an object."
                    )
                }
                existingRaw = object
            } catch {
                throw PersonaWriteError.ioFailure(
                    "Cannot update unreadable profile.json: \(error.localizedDescription)"
                )
            }
            let existing = try PersonaCompiler.decodeProfile(raw: existingRaw)
            var merged = Self.profileToRawDict(existing)

            for (key, value) in body {
                merged[key] = value.foundationObject
            }
            merged["updatedAt"] = NativeTimestampFormat.fractionalZulu(Date())

            let normalized = try PersonaCompiler.decodeProfile(raw: merged)

            let jv = JSONValue.object(Self.profileFields(normalized))
            let text = try jv.serialize(pretty: true)
            try Self.atomicWriteText(text, to: profileURL)
            await self.publishDerivedPersonaChange(profileURL, reason: "persona_profile_saved")

            return normalized
        }
    }

    // Keep schema and persistence here while onboarding owns creation intent.
    // Back up/export profile and expose it under PrivacyMap/memory; phone receives only its compiled projection.
    package static func onboardingProfileUpdate(
        profilePath: URL,
        agentName: String,
        personaType: String,
        userName: String
    ) throws -> (content: String, baseSHA256: String?) {
        var raw: [String: Any] = [:]
        var baseSHA256: String?
        let existingData: Data?
        do { existingData = try Data(contentsOf: profilePath) }
        catch CocoaError.fileReadNoSuchFile { existingData = nil }
        catch { throw PersonaWriteError.ioFailure("read existing profile.json failed: \(error.localizedDescription)") }
        if let data = existingData {
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
        let newKind: String
        switch personaType {
        case "female": newKind = "Female"
        case "male": newKind = "Male"
        case "ai": newKind = "AI"
        default: throw PersonaWriteError.invalidInput("Unknown persona type: \(personaType)")
        }
        let current: CompiledPersonalityProfile
        if baseSHA256 == nil { current = .genesis(name: agentName, personaKind: newKind) }
        else { current = try PersonaCompiler.decodeProfile(raw: raw) }

        // Validate checked onboarding state before publication.
        var merged = SwiftNativePersonaEngine.profileToRawDict(current)
        merged["name"] = agentName
        merged["personaKind"] = newKind
        merged["updatedAt"] = NativeTimestampFormat.fractionalZulu(Date())
        let renormalized = try PersonaCompiler.decodeProfile(raw: merged)
        var finalDict = SwiftNativePersonaEngine.profileToRawDict(renormalized)
        // Add only a validated nonempty trimmed user name.
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

    /// Require checked existing documents for edits and keep USER under MemoryV2.
    /// Hold the document lock across prior read, bounded mutation, backup and durable write.
    /// Return saved content and its modification time.
    public func savePersonalityDoc(id: String, content: String, appending: Bool = false) async throws -> PersonaDocSpec {
        let docId = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if docId == "USER" {
            throw PersonaWriteError.invalidInput(Self.memoryOwnedUserDocMessage)
        }

        guard let spec = Self.personalityDocSpecsFixed.first(where: { $0.id == docId }) else {
            throw PersonaWriteError.unknownDocument(docId)
        }
        let path = personaRoot.appendingPathComponent(spec.filename)
        let activityPath = activityEventsPath
        let activityDataRoot = dataRootURL

        // Acquire document before activity lock; later bookkeeping cannot undo a committed edit.
        let result: PersonaDocSpec = try await SwiftNativePersistenceCore.withFileLock(path) { [self] in
            // Setup supplies only its section; both replacement and append require actual prior content.
            let existing = try Self.readPersonaDocumentForMutation(at: path)
            let nextContent = appending ? existing.text + content : content
            guard !appending || nextContent.unicodeScalars.count <= 30_000 else {
                throw PersonaWriteError.invalidInput(
                    "The combined document exceeds 30,000 code points. Nothing was appended; shorten the draft or edit the document explicitly.")
            }
            // Enforce the editor's 30,000-scalar bound on the combined document.
            let cappedContent = Self.capByCodePoints(nextContent, cap: 30000)
            // Replace one pre-edit recovery copy per document so the immediately prior version remains reachable.
            try SwiftNativePersistenceCore.writeDataAtomicDurable(
                existing.data,
                to: path.appendingPathExtension("bak")
            )
            try Self.atomicWriteText(cappedContent, to: path)

            // Invalidate committed bytes even if later metadata reads fail.
            await self.publishDerivedPersonaChange(path, reason: "persona_document_saved")

            let reread: String
            let mtime: Date
            do {
                reread = try Self.readPersonaDocument(at: path)
                guard let date = try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    throw PersonaWriteError.ioFailure("The saved document has no readable modification time.")
                }
                mtime = date
            } catch {
                throw PersonaWriteError.ioFailure(
                    """
                        \(docId).md was saved, but its readback is unavailable. Read the saved document before repeating an edit; repair access to \
                        \(path.path). \(error.localizedDescription)
                        """)
            }
            let spec = PersonaDocSpec(
                id: spec.id,
                title: spec.title,
                filename: spec.filename,
                path: path.path,
                content: reread,
                updatedAt: NativeTimestampFormat.fractionalZulu(mtime)
            )
            // Activity remains separately owed; its failure cannot invite duplicate document append.
            do {
                try await self.recordPersonaDocActivity(docId: docId)
                RepairOwed.settle(activityDataRoot, operation: "persona.document_activity",
                    evidence: .init(source: "persona", id: docId))
            } catch {
                RepairOwed.owe(activityDataRoot, id: "persona-activity:" + docId, kind: .act,
                    evidence: [.init(source: "persona", id: docId)],
                    operation: "persona.document_activity", owner: activityPath.path,
                    words: "\(docId).md was saved; its activity recording failed: \(error.localizedDescription)")
            }
            return spec
        }

        return result
    }

    // MARK: - Document-save activity

    var activityEventsPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: dataRootURL)
    }

    /// Keep save activity payload-free; credential-bearing content requires redaction before inclusion.
    // Exclude activity from local backup, export and phone sync; include off-disk backup and support bundles under PrivacyMap/activity.
    func recordPersonaDocActivity(docId: String) async throws {
        // Stamp after the document write while holding its lock.
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

    /// Share typed projection and persistence fields while preserving Foundation leaves and unknown keys.
    package static func profileToRawDict(_ p: CompiledPersonalityProfile) -> [String: Any] {
        profileFields(p).mapValues { $0.foundationObject }
    }

    /// Keep opaque saved keys without promoting them to instruction fields.
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
            "traits": traits,
            "updatedAt": .string(p.updatedAt),
        ]
        // Round-trip unknown keys without replacing typed fields; include them in stable serialization ordering.
        for (key, value) in p.extras where obj[key] == nil {
            obj[key] = value
        }
        return obj
    }

    /// Bound Unicode scalars rather than grapheme clusters.
    static func capByCodePoints(_ s: String, cap: Int) -> String {
        let scalars = s.unicodeScalars
        if scalars.count <= cap { return s }
        return String(String.UnicodeScalarView(scalars.prefix(cap)))
    }

    /// Flush a private temporary file before rename, then fsync its parent so durable acknowledgement includes directory publication.
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
    /// Use JSON decoding's Foundation leaf types for full-profile save.
    public func savePersonality(_ profile: PersonalityProfile) async throws -> CompiledPersonalityProfile {
        let body: [String: Any] = [
            "name": profile.name,
            "personaKind": profile.personaKind,
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
        return try await savePersonality(body: NativeActionWire.jsonValueBody(body))
    }
}

extension CompiledPersonalityProfile {
    /// Share one profile shape across Mac/phone loading and saving.
    public var sharedProfile: PersonalityProfile {
        PersonalityProfile(
            schemaVersion: schemaVersion,
            personaEngineVersion: personaEngineVersion,
            name: name,
            personaKind: personaKind,
            traits: traits,
            updatedAt: updatedAt.isEmpty ? nil : updatedAt,
            userName: extras["userName"]?.stringValue
        )
    }
}

extension PersonaDocSpec: Identifiable {}

extension SwiftNativePersonaEngine {
    public func saveName(_ rawName: String) async throws -> PersonalityProfile {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await savePersonality(body: ["name": .string(name)]).sharedProfile
    }
}
