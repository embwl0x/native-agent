import CryptoKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `PersonaEngine+Writes.swift` | `SwiftNativePersonaEngine`: shared name validation and sole profile commit owner; fixed document specs; checked existing mutations with private backups; compilation's named missing-only required-document genesis uses shared onboarding templates under completion/document locks |

// MARK: - Persona writes
//
// Caller authorization still applies to profile and document mutations.
// Mutations hold the target's shared cross-process file lock. USER.md remains
// a MemoryV2 UserMDGenerator projection; only checked missing-document genesis
// can scaffold it here, never ordinary edits.
// Storage: persona Markdown/recovery copies and memory/profile.json are in local
// and off-disk backups and the data export. Phone sync projects only the profile;
// PrivacyMap lists persona documents under persona, profile.json under memory.

public enum PersonaWriteError: Error, LocalizedError, Equatable {
    case unknownDocument(String)
    /// IO failure during the atomic write / read-back.
    case ioFailure(String)
    /// Invalid persona kind, missing title or unresolvable persona path.
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

    // Fixed document ids and order are part of the listing contract.
    static let personalityDocSpecsFixed: [(id: String, title: String, filename: String)] = [
        ("SOUL",   "Soul",             "SOUL.md"),
        ("VOICE",  "Voice",            "VOICE.md"),
        ("GROWTH", "Growth",           "GROWTH.md"),
        ("USER",   "User",             "USER.md"),
        ("AGENTS", "Operating Manual", "AGENTS.md"),
    ]

    /// The single operating-manual seed, shared by onboarding and missing-only genesis.
    package static func operatingManualGenesis(name: String) -> String {
        "# \(name) Operating Manual\n"
    }

    /// Inspect the entry itself, including dangling links. A read failure is
    /// never absence and must not authorize replacement or inherited content.
    static func personaDocumentIsMissing(at path: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
            return false
        } catch let error as CocoaError where error.isFileAbsent {
            return true
        } catch {
            throw PersonaEngineError.rootUnreadable(reason: "cannot inspect \(path.path): \(error.localizedDescription). Restore access to this document; it has not been replaced.")
        }
    }

    /// The compile owner requests genesis by document id before reading it.
    /// Recheck absence, completion and identity while holding both locks.
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
                        throw PersonaWriteError.invalidInput("USER.md genesis cannot read memory/profile.json.userName as text. Repair that field before creating the document.")
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
                    throw PersonaWriteError.ioFailure("\(spec.filename) was created at \(path.path), but verification failed: \(error.localizedDescription). Preserve and inspect the saved bytes before another repair.")
                }
                return true
            }
        }
    }

    // MARK: - Profile writes

    /// Validate a submitted name through the shared identity rule, then validate the saved base,
    /// merge partial fields (traits replace wholesale), stamp and persist under the profile lock.
    /// Unspecified fields and unknown keys survive; JSON uses two-space indentation and keys sorted by UTF-8 byte order.
    public func savePersonality(body: [String: JSONValue]) async throws -> CompiledPersonalityProfile {
        let editable: Set<String> = ["name", "personaKind", "traits"]
        guard Set(body.keys).isSubset(of: editable) else {
            throw PersonaWriteError.invalidInput("Profile updates accept name, personaKind and traits only. Edit instructions through the canonical personality documents.")
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
            // Read raw under the lock so we merge over the latest on-disk state.
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

        // Apply onboarding values to the checked profile, then validate before publication.
        var merged = SwiftNativePersonaEngine.profileToRawDict(current)
        merged["name"] = agentName
        merged["personaKind"] = newKind
        merged["updatedAt"] = NativeTimestampFormat.fractionalZulu(Date())
        let renormalized = try PersonaCompiler.decodeProfile(raw: merged)
        var finalDict = SwiftNativePersonaEngine.profileToRawDict(renormalized)
        // Add the trimmed user's name after validation; an empty name is omitted.
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

    /// Edits require a checked existing document; onboarding/compile genesis initializes it. USER.md is MemoryV2-owned.
    /// Replacement caps at 30,000 Unicode scalars; append reads under the document lock and refuses overflow.
    /// Back up to `<file>.bak` and write durably under that lock; return saved content with the file's mtime.
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

        // Lock order: document, then activity feed. Bookkeeping cannot undo a committed edit.
        let result: PersonaDocSpec = try await SwiftNativePersistenceCore.withFileLock(path) { [self] in
            // Setup contributes only its section, never a carried-forward SOUL.
            // Both replacement and append require the real prior document.
            let existing = try Self.readPersonaDocumentForMutation(at: path)
            let nextContent = appending ? existing.text + content : content
            guard !appending || nextContent.unicodeScalars.count <= 30_000 else {
                throw PersonaWriteError.invalidInput("The combined document exceeds 30,000 code points. Nothing was appended; shorten the draft or edit the document explicitly.")
            }
            // Preserve the editor's 30000-code-point cap on the combined document.
            let cappedContent = Self.capByCodePoints(nextContent, cap: 30000)
            // One pre-edit copy per doc (`SOUL.md.bak`), replaced each save, so
            // the last version before any edit is always one file away.
            try SwiftNativePersistenceCore.writeDataAtomicDurable(
                existing.data,
                to: path.appendingPathExtension("bak")
            )
            try Self.atomicWriteText(cappedContent, to: path)

            // Invalidate the committed bytes even if subsequent metadata reads fail.
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
                throw PersonaWriteError.ioFailure("\(docId).md was saved, but its readback is unavailable. Read the saved document before repeating an edit; repair access to \(path.path). \(error.localizedDescription)")
            }
            let spec = PersonaDocSpec(
                id: spec.id,
                title: spec.title,
                filename: spec.filename,
                path: path.path,
                content: reread,
                updatedAt: NativeTimestampFormat.fractionalZulu(mtime)
            )
            // Activity is a separate owed effect; never invite a second append for its failure.
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

    /// Use the same typed fields for projection and persistence, preserving
    /// Foundation's NSNumber leaves and unknown profile keys.
    package static func profileToRawDict(_ p: CompiledPersonalityProfile) -> [String: Any] {
        profileFields(p).mapValues { $0.foundationObject }
    }

    /// Persist identity and live traits; opaque saved keys survive without becoming instruction fields.
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
    /// Field-for-field the profile the Personality tab and the phone read,
    /// on load and on save alike.
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
