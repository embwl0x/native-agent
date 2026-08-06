import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Persona WRITE path (wave 32 W19)
//
// Native port of the two daemon persona-WRITE routes:
//
//   POST /v1/personality       -> Runtime.save_personality(body)
//
//   POST /v1/personality/docs  -> Runtime.save_personality_doc(body)
//
//
// The READ side of this subsystem (listPersonaDocs / listPersonaDocSpecs /
// PersonaCompiler.loadProfile) shipped in earlier waves and is FLAG_FLIPPED
// behind `.personaEngine`. The write side was held HTTP-only with a named
// retirement path (CUTOVER_PLAN.md §6.55 W17 `POST /v1/personality` and
// `POST /v1/personality/docs` rows, and §6.34 line "no `save*` write methods
// exist (grep: zero)"). This file closes that gap.
//
// PARITY CONTRACT (must match the daemon byte-for-byte on the wire):
//
//   save_personality(body):
//     existing = self.personality()          # normalize(read(profile.json))
//     merged   = dict(existing); merged.update(body)
//     merged["updatedAt"] = now_iso()
//     profile  = self.normalize_personality(merged)
//     write_json(self.personality_path(), profile)   # indent=2, sort_keys
//     self.persona_compile_cache.clear()      # daemon-process-only; N/A here
//     return profile
//
//   save_personality_doc(body):
//     doc_id  = (body.id or body.docId or "").strip().upper()
//     content = str(body.content or "")[:30000]      # 30K cap, CODE POINTS
//     soul_initialized = (_resolve_persona_root()/"SOUL.md").exists()
//     if not soul_initialized and doc_id != "SOUL": return {"error":"onboarding_required", ...}
//     if not soul_initialized and doc_id == "SOUL": return {"error":"onboarding_required", ...}
//     path = self.personality_doc_path(doc_id)        # raises on unknown id
//     _atomic_write_text(path, content)               # temp+O_EXCL 0600+rename
//     self.persona_compile_cache.clear()              # daemon-only; N/A here
//     spec = matching personality_doc_specs() entry
//     return {**spec, "path": str(path), "content": <reread>, "updatedAt": iso(mtime)}
//
// CROSS-PROCESS SAFETY (single-writer rule, the standing prereq class that
// reverted W03/W09):
//   profile.json AND the persona doc files are written by BOTH the Python
//   onboarding, dream/REM, memory consolidation, and this Swift path. To avoid
//   a split-write, every Swift write here is wrapped in
//   `withFileLock(<target>)` (PersistenceCore+FileLock.swift), which takes a
//   POSIX flock(2) on `<target>.lock`.
//   - The 3 RESIDUAL unlocked writers (wave-33 W06 §6.96 prereq A-residual)
//     were flocked in wave-34 W02 (CUTOVER §6.97), CLOSING prereq A-residual:
//       * `Runtime.personality()` (normalize-on-read profile.json write) now
//         holds the REENTRANT `_profile_file_lock()` guard — reentrant because
//         `save_personality` calls it from inside its own profile lock and a
//         second flock to the same lock file from the same process deadlocks
//         (POSIX flock non-reentrant; mirrors WAVE-31-W16 `_jobs_file_lock`).
//       * the persona-doc auto-scaffold (`personality_doc_contents` create
//         branch + the improvement_summary GROWTH scaffold) wraps each create
//         in `file_lock(<doc>)` with an inside-lock existence re-check.
//       * the Swift onboarding write path (`completeOnboarding` writes +
//         `resetOnboarding` renames) wraps each in `withFileLock(<target>)`.
//     ALL persona-file writers now share the cross-process `<path>.lock`.
//
// DORMANCY: the NativeClient persona WRITE gates are gated on the DEDICATED
// `.personaEngineWrites` flag (wave-33 W06), NOT the live read flag
// `.personaEngine`. `.personaEngineWrites` is DEFAULT-OFF and independent of
// the read flag, so this native write path is reached ONLY when the user explicitly
// adds `personaEngineWrites` to NATIVE_AGENT_SWIFT_SUBSYSTEMS. Until the
// §6.96 pre-flip prereqs close (A-residual unlocked writers — CLOSED wave-34
// W02 §6.97; B record_activity parity — CLOSED wave-36 W16 §6.138, the doc-save
// seam now emits the daemon's `record_activity("memory", ...)` row via the
// scoped `recordPersonaDocActivity` writer; C NFKC co-requisite still open)
// callers should keep writes disabled or fail closed.
// This module exposes the native impl + tests for the direct Swift writer.

public enum PersonaWriteError: Error, LocalizedError, Equatable {
    /// Mirrors the daemon `{"error":"onboarding_required", "detail": ...}`
    /// refusal. Carries the same `detail` string the HTTP route returns so a
    /// NativeClient adapter can surface the identical message.
    case onboardingRequired(detail: String)
    /// Mirrors `personality_doc_path`'s `ValueError(f"Unknown personality document: {doc_id}")`.
    case unknownDocument(String)
    /// IO failure during the atomic write / read-back.
    case ioFailure(String)
    /// Mirrors the agent-tool `{"ok": False, "error": ..., "error_code": "bad_input"}`
    /// rejection (`_exec_persona_write` / `_exec_persona_append_section`): a bad
    /// `kind`, a missing/invalid `skill_name`, a missing `title`, or an
    /// unresolvable persona path. Carries the same message the tool dict returns
    /// so a future native-dispatcher adapter can surface the identical error.
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
    /// flock on the profile file so it cannot interleave with a Python writer.
    ///
    /// `persona_compile_cache.clear()` is intentionally omitted — that cache
    /// is daemon-process-only state. The daemon re-reads profile.json on the
    /// next persona compile, so the on-disk wire output is what matters and it
    /// is byte-identical. (Same rationale as the wave-20 onboarding port,
    /// CUTOVER_PLAN §6.21 "Side effects deliberately skipped".)
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
            if let data = try? Data(contentsOf: profileURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existingRaw = obj
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
            let jv = Self.profileToJSONValue(normalized)
            let text = try jv.serialize(pretty: true)
            try Self.atomicWriteText(text, to: profileURL)

            return normalized
        }
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
    /// SIDE-EFFECT PARITY (CUTOVER_PLAN §6.76 item B.1 — CLOSED wave 36 W06 §6.138):
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
    public func savePersonalityDoc(id: String, content: String) async throws -> PersonaDocSpec {
        let docId = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // content[:30000] by CODE POINTS (Unicode scalars), matching Python's
        // string slice. Swift String.prefix(N) counts grapheme clusters and
        // would diverge for combining sequences — use unicodeScalars.
        let cappedContent = Self.capByCodePoints(content, cap: 30000)

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
        // LOCK ORDER: the append uses the daemon-faithful UNLOCKED
        // `appendJSONL` (the daemon's `append_jsonl` takes NO lock — it relies
        // on POSIX O_APPEND atomicity for sub-PIPE_BUF lines), so we do NOT
        // take a second flock on events.jsonl while holding the doc lock. The
        // doc lock alone serializes concurrent same-doc write+emit pairs, so
        // both the activity-row order AND its `createdAt` track the write order
        // exactly as the daemon's in-doc-lock emit does. A feed append failure
        // propagates (no `try?`), matching the daemon's no-try/except
        // `append_jsonl`.
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

        await flushDerivedPersonaChange(path, reason: "persona_document_saved")
        return result
    }

    // MARK: - personality_doc_contents(create_missing=True) PERSISTENCE mirror

    /// Native mirror of the daemon's `personality_doc_contents(create_missing=True)`
    /// WRITE side. Once SOUL.md exists, any
    /// MISSING fixed persona doc is atomically WRITTEN to disk with its
    /// `default_personality_doc_content` body (parameterized by the user's
    /// profile.json), exactly as the daemon does on every persona-docs read.
    ///
    /// This closes the wave-33 W19 "missing-doc default value persistence" gap:
    /// the Swift READ path (`listPersonaDocSpecs`) renders the SAME default body
    /// but leaves it in-memory (updatedAt nil) and never persists it. With the
    /// write subsystem flipped, the daemon's persistence side must have a Swift
    /// equivalent — otherwise a missing doc is regenerated in-memory on every
    /// read but never durably created, so the next DAEMON read would scaffold it
    /// unlocked, reopening the split-writer race the flock was meant to close.
    ///
    /// Semantics pinned to the daemon:
    ///  - Pre-onboarding (SOUL.md absent) → NO-OP (`create_missing=False`), so the
    ///    first-run wizard still renders against empty docs.
    ///  - SOUL is never auto-scaffolded (the daemon's loop skips writing when the
    ///    file exists; SOUL existing is the gate itself, and a SOUL write is owned
    ///    by onboarding).
    ///  - USER is never auto-scaffolded. MemoryV2 owns USER.md and regenerates it
    ///    from SQLite into the active persona root.
    ///  - Only VOICE/GROWTH/AGENTS get created-if-missing.
    ///  - The default body is rendered from `PersonaCompiler.loadProfile` (the
    ///    daemon calls `self.personality()` — the user's profile, NOT the
    ///    hardcoded `default_personality()`), matching the read path.
    ///  - Each write is atomic (temp + O_EXCL 0600 + rename) and held under the
    ///    per-doc `<path>.lock` cross-process flock the route write uses, so it is
    ///    symmetric with the daemon's `with file_lock(path)` writers.
    ///  - `persona_compile_cache.clear()` / `record_activity` are daemon-only side
    ///    effects (same boundary the route write omits, §6.76 item B.1).
    ///
    /// - Returns: the ids actually written this call (empty if none / pre-onboarding).
    @discardableResult
    public func scaffoldMissingDocs() async throws -> [String] {
        // ONBOARDING gate — SOUL.md is the sentinel (daemon L34677-34683).
        let soulURL = personaRoot.appendingPathComponent("SOUL.md")
        guard fileManagerForWrites.fileExists(atPath: soulURL.path) else {
            return []  // create_missing=False pre-onboarding → no scaffold.
        }

        let profile = PersonaCompiler.loadProfile(dataRoot: dataRootURL)
        let persistence = SwiftNativePersistenceCore()
        var written: [String] = []

        for spec in Self.personalityDocSpecsFixed {
            // SOUL exists (it's the gate); the daemon only writes when the file
            // is missing. Skip SOUL explicitly — it is never auto-scaffolded.
            if spec.id == "SOUL" || spec.id == "USER" { continue }
            let path = personaRoot.appendingPathComponent(spec.filename)
            if fileManagerForWrites.fileExists(atPath: path.path) { continue }

            let body = SwiftNativePersonaEngine.defaultPersonalityDocContent(
                id: spec.id,
                profile: profile
            )
            // Per-doc flock symmetric with `savePersonalityDoc` / the daemon's
            // `with file_lock(path)`. Re-check existence INSIDE the lock so two
            // racing writers (or a daemon write between the outer check and the
            // lock) don't double-write — first writer wins, matching the daemon's
            // `if create_missing and not path.exists()` guard semantics.
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
            await DerivedStateInvalidationCenter.shared.flush()
        }
        return written
    }

    // MARK: - record_activity parity (wave 36 W06, §6.138 — closes §6.76 item B.1)

    /// `<root>/activity/events.jsonl` — the daemon's `Runtime.activity_path`
    /// (`self.root / "activity" / "events.jsonl"`, the retired daemon). The
    /// engine's `dataRoot` IS `Runtime.root` (both `dataRoot/memory/profile.json`
    /// == `personality_path()` and `dataRoot/activity/events.jsonl` ==
    /// `activity_path` resolve off the same base), so this is the byte-identical
    /// path the daemon appends activity rows to.
    var activityEventsPath: URL {
        dataRootURL
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// Native mirror of `Runtime.record_activity(kind, title, detail, status,
    /// mission_id, payload)`, scoped to the SINGLE
    /// echo `save_personality_doc` emits — NOT a general port of the daemon's
    /// activity feed (68 call sites with the full `redact_secret_text` /
    /// `redact_secret_value` machinery; a future wave porting the activity feed
    /// wholesale subsumes this, see retirement_path below).
    ///
    /// Builds the SAME event dict the daemon does:
    ///   { id: uuid4, kind, title, detail, status, missionId, payload, createdAt }
    /// and appends it to `activity/events.jsonl` via `appendJSONL`
    /// (`serialize(pretty: false)` == Python `json.dumps(sort_keys=True)`; both
    /// chmod the file 0600 — byte-and-permission identical to the daemon's
    /// `append_jsonl`).
    ///
    /// REDACTION (verified pass-through for the persona-doc echo ONLY). The
    /// daemon runs `redact_secret_text` on title/detail and `redact_secret_value`
    /// on payload. For THIS call site:
    ///   title   = "<DOC>.md updated" where <DOC> ∈ {SOUL,VOICE,GROWTH,AGENTS}
    ///             (a fixed ASCII enum — no credential-shaped substring),
    ///   detail  = "Personality document saved" (a constant),
    ///   payload = {} (empty — `save_personality_doc` passes no payload).
    /// None can match a secret pattern, so the redactor is a verified
    /// pass-through and we emit the event verbatim — exactly the justification
    /// `ProactiveOutcomeLedger.recordOutcome` uses for its single echo. This is
    /// NOT a general replacement for the daemon redactor; do not route a payload
    /// that can carry credential-shaped strings through here without porting the
    /// redactor first.
    ///
    /// CROSS-PROCESS SAFETY. `events.jsonl` is an append-only JSONL file the
    /// daemon writes with a BARE `open("a")` + chmod (NO flock — verified,
    /// the retired daemon `append_jsonl` L1195-1202). `appendJSONL` uses
    /// `O_WRONLY|O_APPEND`, which interleaves at line boundaries; a separate
    /// flock here would only serialize against itself, not the daemon. We mirror
    /// the daemon's single-writer-per-line atomicity exactly (same posture
    /// `ProactiveOutcomeLedger` documents). The activity append targets a
    /// DIFFERENT file than the persona doc, so emitting it while the caller still
    /// holds `withFileLock(<doc>.md)` takes a lock on `<doc>.md.lock` only — no
    /// second flock on `events.jsonl`, hence no reentrancy concern and no need
    /// for the W34-W02 depth-tracked reentrant guard here (that guard exists for
    /// `personality()` re-entering its OWN profile.json flock; this path never
    /// re-enters any flock).
    ///
    /// retirement_path: subsumed by a future wave that ports the daemon activity
    /// feed (`record_activity` + `redact_secret_text`/`redact_secret_value`)
    /// wholesale into a Swift ActivityFeed module — at which point this and
    /// `ProactiveOutcomeLedger`'s inline echo both call the shared port.
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
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("memory"),
            "title": .string("\(docId).md updated"),
            "detail": .string("Personality document saved"),
            "status": .string("ok"),
            "executionId": .null,
            "payload": .object([:]),
            "createdAt": .string(Self.nowISOPython()),
        ])
        // U5 fix-round (2026-06-11, gpt-5.5 review): this path was the one
        // live activity writer still appending UNCAPPED. Routed through the
        // shared `appendJSONLCapped` (PersistenceCore). `takeLock: true` takes
        // the events.jsonl flock — the caller holds the DOC's flock, a
        // different lock file, so no re-entry; lock order is safe because no
        // path acquires the events lock before a doc lock.
        let persistence = SwiftNativePersistenceCore()
        try await appendJSONLCapped(
            event, to: activityEventsPath, using: persistence,
            logLabel: "PersonaEngine"
        )
    }

    // MARK: - helpers (write-side)

    /// `FileManager` for write-side existence checks. The actor's stored
    /// `fileManager` is private; expose the default here (the write path only
    /// needs `fileExists`, which `.default` answers identically).
    private var fileManagerForWrites: FileManager { .default }

    /// CompiledPersonalityProfile -> raw `[String: Any]` dict in the exact
    /// shape `normalize_personality` consumes AND `write_json` serializes.
    /// Field set + nesting matches daemon `normalize_personality`'s return
    /// so a round-trip is a fixed point.
    static func profileToRawDict(_ p: CompiledPersonalityProfile) -> [String: Any] {
        let traits: [String: Any] = [
            "warmth": p.traits.warmth,
            "directness": p.traits.directness,
            "humor": p.traits.humor,
            "proactivity": p.traits.proactivity,
            "rigor": p.traits.rigor,
            "autonomy": p.traits.autonomy,
            "creativity": p.traits.creativity,
            "brevity": p.traits.brevity,
        ]
        var out: [String: Any] = [
            "schemaVersion": p.schemaVersion,
            "personaEngineVersion": p.personaEngineVersion,
            "name": p.name,
            "personaKind": p.personaKind,
            "essence": p.essence,
            "voice": p.voice,
            "customDirective": p.customDirective,
            "traits": traits,
            "examples": p.examples,
            "forbiddenPatterns": p.forbiddenPatterns,
            "instincts": p.instincts,
            "boundaries": p.boundaries,
            "surfaceOverrides": p.surfaceOverrides,
            "updatedAt": p.updatedAt,
        ]
        // Splat the lossless extras (unknown profile.json keys) back into the
        // raw dict so `existing = self.personality()` carries them into the
        // merge — mirroring Python where `dict(existing)` already holds the
        // `{**raw}` extras. Keys here are disjoint from the known set above
        // (guaranteed by `PersonaCompiler.normalize`), so this never clobbers a
        // known field. On the merge path a body key with the same name as an
        // extra still overrides it (Python `merged.update(body)`), and the
        // re-normalize re-derives extras from the merged dict — so a body that
        // promotes/removes an extra is honored.
        for (key, value) in p.extras where out[key] == nil {
            out[key] = value.foundationValue
        }
        return out
    }

    /// CompiledPersonalityProfile -> JSONValue in the exact field set + leaf
    /// types `write_json` serializes. schemaVersion = int; traits = doubles;
    /// list fields = string arrays; surfaceOverrides = string->string object.
    /// Matches the daemon `normalize_personality` return (the retired daemon
    /// L35143-35156) so a Swift write is byte-identical to a daemon write of
    /// the same normalized profile.
    static func profileToJSONValue(_ p: CompiledPersonalityProfile) -> JSONValue {
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
        return .object(obj)
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

    /// Crash-safe atomic write mirroring Python `_atomic_write_text`
    ///: temp file created 0600 via O_CREAT|O_EXCL,
    /// full write with EINTR retry, close-failure escalated, rename(2),
    /// chmod 0600. Identical to `Onboarding.atomicWriteText` (CUTOVER §6.21);
    /// duplicated here so PersonaEngine does not take an Onboarding dep (which
    /// would invert the module graph — Onboarding depends on PersonaEngine).
    static func atomicWriteText(_ content: String, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = path.lastPathComponent
        let pid = getpid()
        let rand = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let tmpPath = dir.appendingPathComponent(".\(name).\(pid).\(rand).tmp")

        let fd = open(tmpPath.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            throw PersonaWriteError.ioFailure("open(tmp) failed: \(String(cString: strerror(errno)))")
        }
        var fdClosed = false
        var didRename = false
        defer {
            if !fdClosed { _ = close(fd) }
            if !didRename { _ = unlink(tmpPath.path) }
        }
        let bytes = Array(content.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { bp -> Int in
                Darwin.write(fd, bp.baseAddress!.advanced(by: written), bp.count - written)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw PersonaWriteError.ioFailure("write(tmp) failed: \(String(cString: strerror(errno)))")
            }
            written += n
        }
        if close(fd) != 0 {
            fdClosed = true
            throw PersonaWriteError.ioFailure("close(tmp) failed: \(String(cString: strerror(errno)))")
        }
        fdClosed = true
        if rename(tmpPath.path, path.path) != 0 {
            throw PersonaWriteError.ioFailure("rename failed: \(String(cString: strerror(errno)))")
        }
        didRename = true
        _ = chmod(path.path, 0o600)
    }
}

// MARK: - JSONValue <-> Foundation Any bridge (write-side)

extension JSONValue {
    /// Convert to a Foundation `Any` leaf/container so the existing
    /// `PersonaCompiler.normalize(raw: [String: Any], ...)` path (which
    /// inspects Foundation types) consumes a body decoded from JSON. Mirrors
    /// what `JSONSerialization.jsonObject` would produce, so a body built from
    /// `JSONValue` normalizes identically to one read off the wire.
    var foundationValue: Any {
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
