import CryptoKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaEngine+Writes.swift` | `SwiftNativePersonaEngine`: profile schema preparation, including onboarding, and sole profile commit owner; fixed document specs and guarded writes; append reads current content under the write lock with the editor's cap and backup policy |

// MARK: - Persona writes
//
// NativeAgent.app uses this Swift owner unconditionally for profile updates,
// persona document saves and missing-document scaffolding. Onboarding and
// caller authorization still apply; no subsystem environment flag is required.
// Mutations hold the target's shared cross-process file lock. USER.md remains
// a MemoryV2 UserMDGenerator projection and cannot be saved or scaffolded here.
// Storage: persona Markdown/recovery copies and memory/profile.json are in local
// and off-disk backups and the data export. Phone sync projects only the profile;
// PrivacyMap lists persona documents under persona, profile.json under memory.

public enum PersonaWriteError: Error, LocalizedError, Equatable {
    /// Mirrors the daemon `{"error":"onboarding_required", "detail": ...}`
    /// refusal. Carries the same `detail` string the HTTP route returns so a
    /// NativeClient adapter can surface the identical message.
    case onboardingRequired(detail: String)
    /// Mirrors `personality_doc_path`'s `ValueError(f"Unknown personality document: {doc_id}")`.
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

    // MARK: - personality_doc_specs() mirror
    //
    // Fixed spec list, identical order to daemon `personality_doc_specs()`
    //. AGENTS last so it lands freshest in
    // the persona prompt.
    static let personalityDocSpecsFixed: [(id: String, title: String, filename: String)] = [
        ("SOUL",   "Soul",             "SOUL.md"),
        ("VOICE",  "Voice",            "VOICE.md"),
        ("GROWTH", "Growth",           "GROWTH.md"),
        ("USER",   "User",             "USER.md"),
        ("AGENTS", "Operating Manual", "AGENTS.md"),
    ]

    /// The on-disk persona-root path for a doc id. Mirrors
    /// `personality_doc_path(doc_id)`:
    /// upper-cased + stripped id, must be a known spec id else throw.
    /// Resolves under the persona root (NOT dataRoot/memory) — same as the
    /// daemon's `_resolve_persona_root() / specs[normalized]["filename"]`.
    func personalityDocPath(_ docId: String) throws -> URL {
        let normalized = docId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let spec = Self.personalityDocSpecsFixed.first(where: { $0.id == normalized }) else {
            throw PersonaWriteError.unknownDocument(docId)
        }
        return personaRoot.appendingPathComponent(spec.filename)
    }

    // MARK: - POST /v1/personality  (save_personality)

    /// Native mirror of `save_personality(body)`.
    ///
    /// Reads the current normalized profile, merges `body` over it (Python
    /// `dict(existing); merged.update(body)`), stamps a fresh `updatedAt`,
    /// re-normalizes through `PersonaCompiler.normalize` (the same canonical
    /// seed + caps the daemon's `normalize_personality` applies), and writes
    /// `<dataRoot>/memory/profile.json` with `indent=2, sort_keys=True`
    /// byte-shape (PersistenceCore JSONValue `pretty: true` == Python
    /// `write_json`). The whole read-merge-write is held under a cross-process
    /// flock on the profile file so concurrent mutations cannot interleave.
    ///
    /// - Parameter body: the partial profile fields to merge (the same dict
    ///   the HTTP route receives — keys NOT present are preserved from the
    ///   existing profile; `traits` REPLACES wholesale, matching Python
    ///   `dict.update`).
    /// - Returns: the fully-normalized profile that was persisted.
    public func savePersonality(body: [String: JSONValue]) async throws -> CompiledPersonalityProfile {
        let profileURL = dataRootURL
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")

        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(profileURL) {
            // existing = self.personality() — normalize(read(profile.json)).
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
            // Normalize the existing raw to the canonical dict (= self.personality()).
            let existing = PersonaCompiler.normalize(raw: existingRaw, defaults: .defaults)
            var merged = Self.profileToRawDict(existing)

            // merged.update(body) — JSONValue leaves converted to Foundation
            // Any so normalize() (which inspects [String: Any]) sees them.
            for (key, value) in body {
                merged[key] = value.foundationValue
            }
            // merged["updatedAt"] = now_iso()
            merged["updatedAt"] = Self.nowISOWrite()

            // profile = self.normalize_personality(merged)
            let normalized = PersonaCompiler.normalize(raw: merged, defaults: .defaults)

            // write_json(personality_path(), profile)  — indent=2, sort_keys.
            // Build the JSONValue directly from the typed profile so the
            // int/double/string leaf types are explicit (no NSNumber
            // round-trip ambiguity): schemaVersion is an int, every trait is a
            // double, lists are string arrays. PersistenceCore's
            // `serialize(pretty: true)` == Python `json.dumps(indent=2,
            // sort_keys=True)` (keys sorted by UTF-8 byte order).
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

        // Override fields per Python L20343-L20347.
        let kindMap: [String: String] = ["female": "Female", "male": "Male", "ai": "AI"]
        let newKind = kindMap[personaType] ?? "AI"
        let voiceMap: [String: String] = [
            "female": "Warm, observational, judgment-forward.",
            "male": "Direct, dry, holds ground.",
            "ai": "Precise, characterful, honest.",
        ]
        let newVoice = voiceMap[personaType] ?? voiceMap["ai"]!

        // Build the on-disk dict. Re-runs normalize semantics: save_personality
        // in Python does {existing ∪ body} → normalize → write. We constructed
        // `current` from normalize(raw) so it already matches the
        // first-normalize step; now apply body overrides and normalize once more.
        var merged = SwiftNativePersonaEngine.profileToRawDict(current)
        merged["name"] = agentName
        merged["personaKind"] = newKind
        merged["voice"] = newVoice
        merged["updatedAt"] = NativeTimestampFormat.fractionalZulu(Date())
        let renormalized = PersonaCompiler.normalize(raw: merged, defaults: .defaults)
        var finalDict = SwiftNativePersonaEngine.profileToRawDict(renormalized)
        // The USER's name (not the agent's `name`). Injected AFTER normalize so
        // it survives regardless of the compiler's known-key set — the substrate
        // reads this to address the user in her inner voice (never hardcode a
        // name in the capsule/reflection cues). Trimmed; empty → omit.
        let trimmedUserName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUserName.isEmpty {
            finalDict["userName"] = trimmedUserName
        }

        let json = JSONValue(fromFoundation: finalDict)
        let bytes = try json.serializedData(pretty: false)
        let text = String(decoding: bytes, as: UTF8.self)
        return (content: text, baseSHA256: baseSHA256)
    }

    // MARK: - POST /v1/personality/docs  (save_personality_doc)

    /// Native mirror of `save_personality_doc(body)`, except USER.md is now a
    /// MemoryV2-owned projection and is rejected here.
    ///
    /// Enforces the ONBOARDING-2026-05-26 sentinel gate: SOUL.md is the
    /// "persona initialized" marker. Pre-onboarding (SOUL.md missing) any doc
    /// write — including a SOUL write — is REFUSED with the daemon's exact
    /// `onboarding_required` detail string, because `/v1/onboarding/complete`
    /// is the canonical SOUL writer and writing SOUL through this route would
    /// flip the onboarding gate and lock out the wizard. Content is capped at
    /// 30000 CODE POINTS (Python `str(...)[:30000]` slices by code point, not
    /// grapheme cluster). The write is atomic (temp + O_EXCL 0600 + rename,
    /// mirroring `_atomic_write_text`) and held under a cross-process flock on
    /// the target doc file.
    ///
    /// SIDE-EFFECT PARITY (closed wave 36 W06):
    /// the daemon's `save_personality_doc` calls, inside its `with file_lock(path)`
    /// block, BOTH `persona_compile_cache.clear()` AND
    /// `record_activity("memory", "{doc}.md updated", "Personality document saved",
    /// "ok")`.
    ///   * `persona_compile_cache.clear()` is daemon-process-only state — this
    ///     Swift impl runs in the Mac app process, so (like the wave-20 onboarding
    ///     port, §6.21) it omits it: the daemon re-reads the doc on next compile,
    ///     the cache self-invalidates, and the on-disk wire output is what matters.
    ///   * `record_activity` is NOT daemon-process-only — it is a durable append to
    ///     `<root>/activity/events.jsonl`, read by the activity UI / feed on EITHER
    ///     process. Omitting it (the prior disposition) silently dropped a feed row
    ///     whenever the write ran natively under `.personaEngineWrites` — the SAME
    ///     side-effect-parity class that reverted W03/W15. This wave CLOSES the gap:
    ///     `recordPersonaDocActivity` emits the byte-identical event row inside the
    ///     same flock the daemon holds (see its doc comment for the redaction
    ///     pass-through proof and the no-reentrancy-needed rationale).
    /// With the activity row now emitted, the §6.76 item B.1 flip prereq is
    /// satisfied; the cache-clear remains correctly omitted (daemon-internal).
    /// - Returns: the saved doc spec with the re-read content + the file's
    ///   mtime as `updatedAt` — the same `{**spec, path, content, updatedAt}`
    ///   shape the HTTP route returns.
    /// - Throws: `PersonaWriteError.onboardingRequired` when the gate refuses
    ///   (so a NativeClient adapter surfaces the same failure the HTTP path
    ///   produces — the daemon returns an error dict that fails the
    ///   `PersonalityDoc` decode, throwing on the Mac side; the Swift gate
    ///   throws directly for identical UX). `.unknownDocument` for an id
    ///   outside the fixed spec set.
    /// With `appending`, content is a suffix: read the current document under
    /// the same write lock, retaining the document editor's cap and backup policy.
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

        let path = try personalityDocPath(docId)
        guard let spec = Self.personalityDocSpecsFixed.first(where: { $0.id == docId }) else {
            // personalityDocPath already validated, but keep the contract tight.
            throw PersonaWriteError.unknownDocument(id)
        }

        // §6.76 item-B parity (CLOSED wave-36 W16): the daemon's
        // `save_personality_doc` emits
        // `record_activity("memory", "{doc_id}.md updated", "Personality
        // document saved", "ok")` INSIDE its `with file_lock(path)`, AFTER the
        // write — and `record_activity` itself BUILDS the event (uuid +
        // `createdAt = now_iso()`) at that point, inside the lock. We mirror
        // all three facets: the row, its in-lock placement, AND the build-inside
        // -lock timestamp — so under contention `createdAt` reflects the moment
        // the write actually landed (after the lock wait), not envelope-prep
        // time. `docId` is the UPPER-cased id (e.g. "VOICE"), so the title is
        // "VOICE.md updated" — byte-identical to the daemon f-string.
        //
        // Lock order: document, then the distinct activity-feed lock in
        // appendJSONLCapped. The timestamp is made after the document write;
        // append failures propagate.
        //
        // SINGLE EMIT (wave-40 W17, §6.220): the daemon's `save_personality_doc`
        // emits EXACTLY ONE `record_activity` row per save (the retired daemon
        // L34950). The activity row is emitted ONCE below via
        // `recordPersonaDocActivity` (the wave-36 W06 helper, which uses the
        // byte-exact microsecond `nowISOPython` timestamp).
        // `recordPersonaDocActivity` is the sole in-lock emit, matching the
        // daemon's single `record_activity`.
        let persistence = SwiftNativePersistenceCore()
        let result: PersonaDocSpec = try await persistence.withFileLock(path) { [self] in
            // Setup contributes only its section, never a carried-forward SOUL.
            // An unreadable append base throws before either backup or mutation.
            let nextContent = appending ? try String(contentsOf: path, encoding: .utf8) + content : content
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

            // §6.76 item B.1 / §6.138: emit the daemon's activity-feed row. The
            // daemon order is write -> persona_compile_cache.clear() (omitted,
            // daemon-internal) -> record_activity -> build spec -> read-back. We
            // emit the row here (after the write, before the read-back) inside the
            // SAME flock the daemon holds. The append targets events.jsonl (a
            // different file), so no second flock is taken on the doc lock. The
            // row's createdAt is computed INSIDE recordPersonaDocActivity (after
            // the write, in-lock) so it cannot predate the save. Like the daemon,
            // a failure here PROPAGATES (save_personality_doc does not wrap
            // record_activity in try/except), so the caller sees an identical
            // failure surface.
            try await self.recordPersonaDocActivity(docId: docId)

            // Re-read to match the daemon's `path.read_text(errors="replace")`
            // and stamp updatedAt from the file mtime (iso of st_mtime, UTC).
            let reread = (try? String(contentsOf: path, encoding: .utf8)) ?? cappedContent
            let mtime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let spec = PersonaDocSpec(
                id: spec.id,
                title: spec.title,
                filename: spec.filename,
                path: path.path,
                content: reread,
                updatedAt: Self.isoFromDate(mtime)
            )
            // (record_activity already emitted ONCE above via
            // recordPersonaDocActivity — no second emit here; see §6.220.)
            return spec
        }

        await publishDerivedPersonaChange(path, reason: "persona_document_saved")
        return result
    }

    // MARK: - personality_doc_contents(create_missing=True) PERSISTENCE mirror

    /// After SOUL exists, create missing VOICE/GROWTH/AGENTS documents from
    /// the profile defaults, atomically under each document's lock. SOUL is
    /// onboarding-owned; USER is MemoryV2-owned. Publish invalidations for
    /// created documents; unlike `savePersonalityDoc`, this emits no activity.
    ///
    /// - Returns: the ids actually written this call (empty if none / pre-onboarding).
    @discardableResult
    public func scaffoldMissingDocs() async throws -> [String] {
        // ONBOARDING gate — SOUL.md is the sentinel (daemon L34677-34683).
        let soulURL = personaRoot.appendingPathComponent("SOUL.md")
        guard fileManagerForWrites.fileExists(atPath: soulURL.path) else {
            return []  // create_missing=False pre-onboarding → no scaffold.
        }

        let missing = Self.personalityDocSpecsFixed.filter {
            $0.id != "SOUL" && $0.id != "USER"
                && !fileManagerForWrites.fileExists(atPath: personaRoot.appendingPathComponent($0.filename).path)
        }
        guard !missing.isEmpty else { return [] }
        let profile = PersonaCompiler.loadProfile(dataRoot: dataRootURL)
        let persistence = SwiftNativePersistenceCore()
        var written: [String] = []

        for spec in missing {
            let path = personaRoot.appendingPathComponent(spec.filename)

            let body = SwiftNativePersonaEngine.defaultPersonalityDocContent(
                id: spec.id,
                profile: profile
            )
            // Share savePersonalityDoc's lock; recheck existence inside it
            // so concurrent writers cannot replace a document that just arrived.
            let didWrite: Bool = try await persistence.withFileLock(path) {
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

    // MARK: - record_activity parity (wave 36 W06, §6.138 — closes §6.76 item B.1)

    /// The document-save activity feed under this engine's data root.
    var activityEventsPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: dataRootURL)
    }

    /// Emit the document-save event through shared `appendJSONLCapped`.
    ///
    /// REDACTION (verified pass-through for the persona-doc echo ONLY). The
    /// daemon runs `redact_secret_text` on title/detail and `redact_secret_value`
    /// on payload. For THIS call site:
    ///   title   = "<DOC>.md updated" where <DOC> ∈ {SOUL,VOICE,GROWTH,AGENTS}
    ///             (a fixed ASCII enum — no credential-shaped substring),
    ///   detail  = "Personality document saved" (a constant),
    ///   payload = {} (empty — `save_personality_doc` passes no payload).
    /// None can match a secret pattern, so the redactor is a verified
    /// pass-through and we emit the event verbatim. This is
    /// NOT a general replacement for the daemon redactor; do not route a payload
    /// that can carry credential-shaped strings through here without porting the
    /// redactor first.
    ///
    /// The caller holds the document lock; `appendJSONLCapped` takes the
    /// distinct activity-feed lock. No same-lock reentry occurs.
    ///
    // activity/events.jsonl: local backup/data export/phone sync exclude it;
    // off-disk backup and support bundles include it. PrivacyMap: activity.
    func recordPersonaDocActivity(docId: String) async throws {
        // event = record_activity("memory", f"{doc_id}.md updated",
        //                          "Personality document saved", "ok")
        // The daemon's record_activity stamps createdAt = now_iso() INTERNALLY,
        // AFTER the write and still INSIDE the doc flock (the retired daemon
        // L34843-34846). We mirror that exactly: this method is called from
        // inside the withFileLock closure after the atomic write, and it computes
        // its OWN now_iso() here (the Python-byte-exact `nowISOPython` =
        // microseconds + `+00:00`, matching `datetime.now(timezone.utc)
        // .isoformat()`) — so the row's createdAt cannot predate the save under
        // lock contention, and a Swift-written row sorts identically to a
        // daemon-written row in the interleaved activity feed.
        let event = SwiftNativePersistenceCore.activityEvent(
            id: UUID().uuidString.lowercased(),
            kind: "memory",
            title: "\(docId).md updated",
            detail: "Personality document saved",
            status: "ok",
            executionId: nil,
            payload: .object([:]),
            createdAt: Self.nowISOPython()
        )
        let persistence = SwiftNativePersistenceCore()
        try await SwiftNativePersistenceCore.appendActivityEvent(
            event, to: activityEventsPath, using: persistence,
            logLabel: "PersonaEngine"
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
        profileFields(p).mapValues { $0.foundationValue }
    }

    /// CompiledPersonalityProfile -> JSON fields in the exact field set + leaf
    /// types `write_json` serializes. schemaVersion = int; traits = doubles;
    /// list fields = string arrays; surfaceOverrides = string->string object.
    /// Matches the daemon `normalize_personality` return (the retired daemon
    /// L35143-35156) so a Swift write is byte-identical to a daemon write of
    /// the same normalized profile.
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
        // Splat extras onto the on-disk object so unknown profile.json keys
        // are PERSISTED verbatim (the §6.76 W19 item-B.2 gap: a flipped write
        // used to DROP them). `serialize(pretty: true)` sorts all keys by
        // UTF-8 byte order, so an extra interleaves into the same position
        // Python's `json.dumps(indent=2, sort_keys=True)` would place it.
        // Extras keys are disjoint from the known set (PersonaCompiler.normalize),
        // so this never overwrites a typed field.
        for (key, value) in p.extras where obj[key] == nil {
            obj[key] = value
        }
        return obj
    }

    /// `str(value)[:cap]` by Unicode SCALAR (code point), matching Python.
    static func capByCodePoints(_ s: String, cap: Int) -> String {
        let scalars = s.unicodeScalars
        if scalars.count <= cap { return s }
        return String(String.UnicodeScalarView(scalars.prefix(cap)))
    }

    /// `now_iso()` form used for the profile `updatedAt` stamp. Matches the
    /// existing Swift convention (PersonaCompiler.normalize / Onboarding
    /// `nowISO`): ISO8601 internet date-time with fractional seconds, UTC.
    /// (Python uses `datetime.now(timezone.utc).isoformat()` = microsecond
    /// precision; `updatedAt` is a free-form string field that normalize only
    /// `str()`s, so the ms-vs-us difference is non-functional. Kept consistent
    /// with the rest of the Swift codebase rather than the Python microsecond
    /// form.)
    static func nowISOWrite() -> String { isoFromDate(Date()) }

    static func isoFromDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Byte-exact mirror of the daemon `now_iso()` =
    /// `datetime.now(timezone.utc).isoformat()`:
    /// `YYYY-MM-DDTHH:MM:SS.ffffff+00:00` — MICROSECOND precision and the
    /// `+00:00` UTC offset (NOT the `.123Z` millisecond form `isoFromDate`
    /// produces). Used for fields that land in a file INTERLEAVED with
    /// daemon-written rows (e.g. the activity feed's `createdAt`), where the
    /// `Z`-vs-`+00:00` offset character and ms-vs-us width would otherwise make
    /// a Swift row sort/compare differently from a daemon row at the same
    /// instant. Python `isoformat()` DROPS the fractional part entirely when
    /// microseconds == 0 (e.g. `...T09:24:21+00:00`); we reproduce that so the
    /// shape matches in every case.
    static func nowISOPython(_ d: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d)
        let micros = (c.nanosecond ?? 0) / 1000
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        let frac = micros == 0 ? "" : String(format: ".%06d", micros)
        return base + frac + "+00:00"
    }

    /// Crash-safe atomic write: the shared durable writer (0600 temp, fsync,
    /// rename, parent-directory fsync). The old hand-rolled copy renamed
    /// without an fsync, so a power loss could leave an identity doc empty.
    package static func atomicWriteText(_ content: String, to path: URL) throws {
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(content.utf8), to: path)
        } catch PersistenceCoreError.ioFailure(let detail) {
            throw PersonaWriteError.ioFailure(detail)
        }
    }
}

// MARK: - JSONValue <-> Foundation Any bridge (write-side)

extension JSONValue {
    /// Convert to a Foundation `Any` leaf/container so the existing
    /// `PersonaCompiler.normalize(raw: [String: Any], ...)` path (which
    /// inspects Foundation types) consumes a body decoded from JSON. Mirrors
    /// what `JSONSerialization.jsonObject` would produce, so a body built from
    /// `JSONValue` normalizes identically to one read off the wire.
    package var foundationValue: Any {
        switch self {
        case .null:            return NSNull()
        case .bool(let b):     return b
        // Bridge to NSNumber so `normalize`'s `as? Int` / `as? Double` /
        // `as? NSNumber` probes all resolve the way they would for a value
        // decoded by JSONSerialization off the wire (which boxes JSON numbers
        // as NSNumber). A bare Swift `Int64` would miss `as? Int`.
        case .int(let i):      return NSNumber(value: i)
        case .double(let d):   return NSNumber(value: d)
        case .string(let s):   return s
        case .array(let arr):  return arr.map { $0.foundationValue }
        case .object(let obj): return obj.mapValues { $0.foundationValue }
        }
    }
}

// MARK: - The shared (Mac and phone) profile shape

extension SwiftNativePersonaEngine {
    /// The Personality tab's full-profile save. The body goes through the
    /// same JSONSerialization normalization a wire body had, so the merge sees
    /// the leaf types it always did.
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
        return try await savePersonality(body: NativeActionRouteSupport.jsonValueBody(body))
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
