import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Growth + Voice persona MUTATION writers (wave 35 W13)
//
// Native twins of the three persona-MUTATION writers wave-34 W02 (§6.97)
// flocked on the Python side:
//
//   Runtime.append_personality_growth(kind, text, source_run_id)
//
//     -> appendPersonalityGrowth(kind:text:sourceRunId:)
//
//   _exec_persona_write(inp, context)
//     -> personaWrite(kind:content:skillName:)
//
//   _exec_persona_append_section(inp, context)
//
//     -> personaAppendSection(kind:title:content:)
//
// Why this cluster, and why now. The wave-32 W19 write port covered the two
// HTTP routes (POST /v1/personality + /v1/personality/docs -> savePersonality /
// savePersonalityDoc). It did NOT cover the structured GROWTH journal append
// (the dream/REM/dream-candidate path, a DIFFERENT write shape from a full-doc
// replace) nor the agent-tool persona_write / persona_append_section mutations
// (the surface that writes VOICE.md / GROWTH.md / etc. from an LLM tool call,
// with a timestamped backup-before-write). Those three Python writers were the
// LAST unlocked persona-file writers; once wave-34 W02 flocked them (CLOSING
// the .personaEngineWrites prereq A-residual), the native side could close the
// coverage gap so every persona-file writer has a Swift equivalent that shares
// the same <path>.lock.
//
// CROSS-PROCESS SAFETY (single-writer rule). Every write here is wrapped in
// SwiftNativePersistenceCore.withFileLock(<target>) -- the POSIX flock(2) on
// <target>.lock. Actor isolation serializes the read-modify-rewrite within this
// Swift process; the flock serializes it against the agent tools, onboarding,
// and dream/REM. Lock order is
// deterministic (actor first, then one flock per call) and no wrapped path
// re-enters the same flock -- withFileLock is non-reentrant per-fd, and each
// writer below holds exactly ONE flock
// at a time on a single target file, so there is no self-deadlock and no
// cross-lock cycle.
//
// SIDE-EFFECT PARITY (DORMANT-safe, named not silently skipped). The daemon's
// append_personality_growth calls self.persona_compile_cache.clear() after the
// append; _exec_persona_write/_exec_persona_append_section run their verify
// callbacks at the dispatcher layer. The cache clear is daemon-process state
// (the daemon re-reads the doc on next compile, same boundary the route write
// omits -- §6.76 B.1), and the verify callbacks are the DISPATCHER's concern,
// not the writer's. Both are out of scope for these native impls, which are
// DORMANT (no NativeClient seam routes through them; the daemon tool dispatch
// still runs the Python executors). Resolve the cache/verify wiring alongside
// the native dispatcher port BEFORE any seam flips these on.
//
// DORMANCY. These conform to PersonaEngineWriting, which the NativeClient
// reaches ONLY inside currentSwiftSnapshot(.personaEngineWrites) via
// makePersonaEngineWriter. .personaEngineWrites is DEFAULT-OFF; no script sets
// it. There is no NativeClient gate calling these three yet (no HTTP route maps
// to them -- they are agent-tool / internal surfaces), so they are pure dormant
// native impls + tests until a future wave wires the native dispatcher.

extension SwiftNativePersonaEngine {

    // USER.md is intentionally absent from the mutation sets. MemoryV2 owns
    // USER.md and regenerates it from SQLite; persona tools may read it, but
    // direct writes would split the projection from the source of truth.
    static let personaWriteKinds: Set<String> = ["soul", "skill", "voice", "growth", "agents"]
    static let personaAppendKinds: Set<String> = ["soul", "voice", "growth", "agents"]
    static let memoryOwnedUserDocMessage =
        "USER.md is generated from MemoryV2; use commit_memory or memory proposal tools for durable user facts."

    /// NFKC + strip + lower, matching the daemon's
    /// `unicodedata.normalize("NFKC", str(kind or "")).strip().lower()` AND the
    /// Swift `PersonaWriteGuard` canonicalization (same byte form, so a kind that
    /// the guard upgrades resolves here to the same protected doc).
    static func canonicalizeKind(_ kind: String) -> String {
        (kind)
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// `[A-Za-z0-9_-]+`, matching the daemon `_validate_skill_name` / `_SKILL_NAME_RE`.
    static func validateSkillName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")
        }
    }

    /// Resolve the on-disk persona path for a tool `kind` (post-canonicalization).
    /// SOUL/VOICE/GROWTH/AGENTS live under the persona root; USER is deliberately
    /// absent because MemoryV2 owns that projection. A skill body lives under
    /// `<persona>/skills/bodies/<name>.md` (new) or `<dataRoot>/skills/bodies/
    /// <name>.md` (legacy) -- the persona path wins iff it already EXISTS, else
    /// the data-root path is the write target. Returns `nil` for an unknown kind
    /// or a missing/invalid skill name (caller surfaces `.invalidInput`).
    func personaToolPath(kind: String, skillName: String?) -> URL? {
        switch kind {
        case "soul":   return personaRoot.appendingPathComponent("SOUL.md")
        case "voice":  return personaRoot.appendingPathComponent("VOICE.md")
        case "growth": return personaRoot.appendingPathComponent("GROWTH.md")
        case "agents": return personaRoot.appendingPathComponent("AGENTS.md")
        case "skill":
            guard let name = skillName, Self.validateSkillName(name) else { return nil }
            let personaSkill = personaRoot
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent("bodies", isDirectory: true)
                .appendingPathComponent("\(name).md")
            if FileManager.default.fileExists(atPath: personaSkill.path) {
                return personaSkill
            }
            return dataRootURL
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent("bodies", isDirectory: true)
                .appendingPathComponent("\(name).md")
        default:
            return nil
        }
    }

    // MARK: - append_personality_growth

    /// Native mirror of `Runtime.append_personality_growth` (the retired daemon
    /// L34846-34881). Appends one structured journal line to GROWTH.md.
    ///
    ///   cleaned = " ".join(text.split())[:1000]      # word-collapse, 1000 CP cap
    ///   if not cleaned: return                         # NO-OP on empty
    ///   if not (persona_root/"SOUL.md").exists(): return   # onboarding gate
    ///   path  = GROWTH.md
    ///   entry = f"- {now_iso()} . {kind} . {cleaned}"
    ///   if source_run_id: entry += f" . run {source_run_id}"
    ///   with growth_lock, file_lock(path):
    ///       existing = path.exists() ? read : default_personality_doc_content("GROWTH")
    ///       _atomic_write_text(path, existing.rstrip() + "\n" + entry + "\n")
    ///
    /// The whole read-(scaffold-)append runs under ONE flock on GROWTH.md. The
    /// scaffold body is rendered from the user's profile (the daemon calls
    /// `self.personality()`; we read profile.json read-only via
    /// `PersonaCompiler.loadProfile` so we do NOT take a second profile.json
    /// flock inside the GROWTH flock -- no nested-lock hazard).
    @discardableResult
    public func appendPersonalityGrowth(kind: String, text: String, sourceRunId: String?) async throws -> Bool {
        // cleaned = " ".join(text.split())[:1000] -- Python str.split() collapses
        // ANY run of Unicode whitespace and drops leading/trailing; then cap by
        // CODE POINT (Unicode scalar), NOT grapheme.
        let collapsed = text.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
        let cleaned = Self.capByCodePoints(collapsed, cap: 1000)
        if cleaned.isEmpty { return false }

        // ONBOARDING gate -- SOUL.md is the sentinel (daemon L34855).
        let soulURL = personaRoot.appendingPathComponent("SOUL.md")
        guard FileManager.default.fileExists(atPath: soulURL.path) else { return false }

        let growthURL = personaRoot.appendingPathComponent("GROWTH.md")

        // entry = f"- {now_iso()} . {kind} . {cleaned}"[ + " . run {source}"].
        // The separator is U+00B7 MIDDLE DOT (the daemon uses a literal middle
        // dot). now_iso() is datetime.now(timezone.utc).isoformat(); the existing
        // Swift convention (isoFromDate) is internet-date-time + fractional
        // seconds, UTC -- a free-form journal stamp, ms-vs-us is non-functional
        // (kept consistent with the rest of the Swift codebase per §6.21).
        let sep = "\u{00B7}"
        let runSuffix: String = {
            if let source = sourceRunId, !source.isEmpty { return " \(sep) run \(source)" }
            return ""
        }()
        let entry = "- \(Self.nowISOWrite()) \(sep) \(kind) \(sep) \(cleaned)" + runSuffix

        // Render the missing-doc scaffold body BEFORE taking the flock (cheap,
        // read-only; mirrors the daemon computing self.personality() before the
        // growth lock -- consistent lock ordering).
        let profile = PersonaCompiler.loadProfile(dataRoot: dataRootURL)
        let scaffoldBody = SwiftNativePersonaEngine.defaultPersonalityDocContent(
            id: "GROWTH",
            profile: profile
        )

        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(growthURL) {
            let existing: String
            if FileManager.default.fileExists(atPath: growthURL.path) {
                existing = (try? String(contentsOf: growthURL, encoding: .utf8)) ?? ""
            } else {
                // daemon: existing = default_personality_doc_content("GROWTH", ...)
                existing = scaffoldBody
            }
            // _atomic_write_text(path, existing.rstrip() + "\n" + entry + "\n")
            let newContent = Self.rstrip(existing) + "\n" + entry + "\n"
            try Self.atomicWriteText(newContent, to: growthURL)
        }
        await flushDerivedPersonaChange(growthURL, reason: "persona_growth_appended")
        return true
    }

    // MARK: - persona_write (full-doc REPLACE + backup)

    /// Native mirror of `_exec_persona_write`.
    /// Full-doc REPLACE: back up the prior content (if any) to a timestamped
    /// `<file>.pre-<ts>-<uid>.bak`, then atomically write `content`. The backup
    /// + write run under ONE flock on the target (the daemon's
    /// `with _persona_write_lock, file_lock(target)`).
    @discardableResult
    public func personaWrite(kind: String, content: String, skillName: String?) async throws -> PersonaToolWriteResult {
        let canon = Self.canonicalizeKind(kind)
        if canon == "user" {
            throw PersonaWriteError.invalidInput(Self.memoryOwnedUserDocMessage)
        }
        guard Self.personaWriteKinds.contains(canon) else {
            throw PersonaWriteError.invalidInput(
                "kind must be one of: \(Self.personaWriteKinds.sorted().joined(separator: ", "))"
            )
        }
        // skill kind requires + validates skill_name (daemon L3630-3634).
        if canon == "skill" {
            guard let name = skillName, !name.isEmpty else {
                throw PersonaWriteError.invalidInput("skill_name is required when kind=skill")
            }
            guard Self.validateSkillName(name) else {
                throw PersonaWriteError.invalidInput(
                    "skill_name '\(name)' contains invalid characters (only A-Za-z0-9_- allowed)"
                )
            }
            let hygieneViolations = SkillBodyHygiene.violations(in: content)
            if !hygieneViolations.isEmpty {
                throw PersonaWriteError.invalidInput(
                    "skill body hygiene failed: \(SkillBodyHygiene.failureMessage(for: hygieneViolations))"
                )
            }
        } else if let name = skillName, !name.isEmpty, !Self.validateSkillName(name) {
            // Daemon validates a present skill_name for ANY kind (L3633).
            throw PersonaWriteError.invalidInput(
                "skill_name '\(name)' contains invalid characters (only A-Za-z0-9_- allowed)"
            )
        }

        guard let target = personaToolPath(kind: canon, skillName: skillName) else {
            throw PersonaWriteError.invalidInput("Could not resolve persona path")
        }

        let contentBytes = Array(content.utf8)
        let persistence = SwiftNativePersistenceCore()
        let backupPath: String? = try await persistence.withFileLock(target) {
            let backup = try Self.backupIfExists(target)
            try Self.atomicWriteText(content, to: target)
            return backup
        }

        await flushDerivedPersonaChange(target, reason: "persona_tool_write")

        return PersonaToolWriteResult(
            kind: canon,
            path: target.path,
            backupPath: backupPath,
            bytesWritten: contentBytes.count,
            bytesAppended: nil
        )
    }

    // MARK: - persona_append_section (titled section append + backup)

    /// Native mirror of `_exec_persona_append_section` (builtin_tools.py
    /// L3948-4038). Appends `\n\n## <title>\n<content>` to the persona file
    /// after `existing.rstrip()`, with a timestamped backup of the prior
    /// content. Read-modify-rewrite + backup run under ONE flock on the target.
    @discardableResult
    public func personaAppendSection(kind: String, title: String, content: String) async throws -> PersonaToolWriteResult {
        let canon = Self.canonicalizeKind(kind)
        if canon == "user" {
            throw PersonaWriteError.invalidInput(Self.memoryOwnedUserDocMessage)
        }
        guard Self.personaAppendKinds.contains(canon) else {
            throw PersonaWriteError.invalidInput(
                "kind must be one of: \(Self.personaAppendKinds.sorted().joined(separator: ", "))"
            )
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw PersonaWriteError.invalidInput("title is required")
        }

        guard let target = personaToolPath(kind: canon, skillName: nil) else {
            throw PersonaWriteError.invalidInput("Could not resolve persona path")
        }

        // new_section = f"\n\n## {title}\n{content}" -- the daemon uses the
        // STRIPPED title value (title = str(...).strip(), L3966) in the heading.
        let newSection = "\n\n## \(trimmedTitle)\n\(content)"
        let newSectionBytes = Array(newSection.utf8).count

        let persistence = SwiftNativePersistenceCore()
        let backupPath: String? = try await persistence.withFileLock(target) {
            let existing: String
            if FileManager.default.fileExists(atPath: target.path) {
                existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            } else {
                existing = ""
            }
            let backup = try Self.backupIfExists(target)
            // new_content = existing.rstrip() + new_section
            let newContent = Self.rstrip(existing) + newSection
            try Self.atomicWriteText(newContent, to: target)
            return backup
        }

        await flushDerivedPersonaChange(target, reason: "persona_section_appended")

        return PersonaToolWriteResult(
            kind: canon,
            path: target.path,
            backupPath: backupPath,
            bytesWritten: nil,
            bytesAppended: newSectionBytes
        )
    }

    // MARK: - shared write helpers

    func flushDerivedPersonaChange(_ target: URL, reason: String) async {
        let namespace = target.path.contains("/skills/bodies/") ? "skill" : "persona"
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: namespace,
            stableID: target.lastPathComponent,
            operation: .changed,
            canonicalLocator: target.path,
            reason: reason
        ))
        await DerivedStateInvalidationCenter.shared.flush()
    }

    /// `existing.rstrip()` -- Python strips trailing Unicode whitespace only.
    /// Swift String has no rstrip; drop trailing whitespace scalars.
    static func rstrip(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Back up the target file's current content to a timestamped sibling
    /// `<file>.pre-<ts>-<uid>.bak`, mirroring the daemon's backup naming:
    /// `target.with_suffix(target.suffix + f".pre-{ts}-{uid}.bak")` where
    /// `ts = strftime("%Y%m%dT%H%M%S%fZ")` (UTC, microseconds) and
    /// `uid = uuid4().hex[:8]`. Returns the backup path (or `nil` if the target
    /// did not exist -- no backup needed). Byte-for-byte copy.
    static func backupIfExists(_ target: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let ts = backupTimestamp()
        let uid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        // Python with_suffix(suffix + ".pre-...") REPLACES the final suffix with
        // <oldsuffix>.pre-<ts>-<uid>.bak -- e.g. VOICE.md -> VOICE.md.pre-...bak
        // (the old ".md" is kept because the new suffix string starts with it).
        let backupURL = target.deletingPathExtension()
            .appendingPathExtension("\(target.pathExtension).pre-\(ts)-\(uid).bak")
        let data = try Data(contentsOf: target)
        do {
            try data.write(to: backupURL)
        } catch {
            throw PersonaWriteError.ioFailure("Could not create backup: \(error.localizedDescription)")
        }
        // A5.5(c): bound the `.pre-*.bak` accumulation at the source. Every
        // SOUL/VOICE/GROWTH/USER write (dream, REM, growth feedback) drops a
        // full-file copy here — with no retention they pile up forever (the
        // orphan-.bak bloat the audit measured). Keep the newest
        // `backupRetention` per target; the compact UTC timestamp in the name
        // sorts chronologically, so newest = lexicographically largest. The
        // sweep is scoped to THIS target's siblings and best-effort — a prune
        // failure must never fail the write we just backed up.
        pruneOldBackups(for: target, keeping: backupRetention)
        return backupURL.path
    }

    /// Newest `.pre-*.bak` copies to keep per persona file.
    static let backupRetention = 10

    /// Delete all but the newest `keeping` `<basename>.pre-*.bak` siblings of
    /// `target`. Best-effort: any filesystem error is swallowed. Scoped by an
    /// exact `<basename>.pre-` prefix so it can only ever touch this file's own
    /// timestamped backups, never another file or a non-backup sibling.
    static func pruneOldBackups(for target: URL, keeping: Int) {
        guard keeping >= 0 else { return }
        let dir = target.deletingLastPathComponent()
        let prefix = target.lastPathComponent + ".pre-"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(".bak") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
        guard backups.count > keeping else { return }
        for stale in backups.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// `datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")` -- compact UTC
    /// timestamp with microseconds, used only for backup-file uniqueness.
    /// Shape: YYYYMMDDTHHMMSS<6-digit-micros>Z (e.g. 20260602T031540123456Z).
    static func backupTimestamp() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
        let micros = (c.nanosecond ?? 0) / 1000
        return String(
            format: "%04d%02d%02dT%02d%02d%02d%06dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, micros
        )
    }
}
