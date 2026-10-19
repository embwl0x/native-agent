import Foundation
import NativeAgentCore
import PersistenceCore

// Persona tool writes hold one cross-process file lock around each target's
// read, backup and mutation. USER.md remains owned by MemoryV2.

extension SwiftNativePersonaEngine {

    // USER.md is intentionally absent from the mutation sets. MemoryV2 owns
    // USER.md and regenerates it from SQLite; persona tools may read it, but
    // direct writes would split the projection from the source of truth.
    static let personaWriteKinds: Set<String> = ["soul", "voice", "growth", "agents"]
    static let memoryOwnedUserDocMessage =
        "USER.md is generated from MemoryV2; use app memory.commit or memory proposal tools for durable user facts."

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
    /// Resolve the on-disk persona path for a tool `kind` (post-canonicalization).
    /// SOUL/VOICE/GROWTH/AGENTS live under the persona root; USER is deliberately
    /// absent because MemoryV2 owns that projection. Routine authoring uses the app door.
    /// Returns `nil` for an unknown kind.
    func personaToolPath(kind: String) -> URL? {
        switch kind {
        case "soul":   return personaRoot.appendingPathComponent("SOUL.md")
        case "voice":  return personaRoot.appendingPathComponent("VOICE.md")
        case "growth": return personaRoot.appendingPathComponent("GROWTH.md")
        case "agents": return personaRoot.appendingPathComponent("AGENTS.md")
        default:
            return nil
        }
    }

    // MARK: - persona_write (full-doc REPLACE + backup)

    /// Native mirror of `_exec_persona_write`.
    /// Full-doc REPLACE: back up the prior content (if any) to a timestamped
    /// `<file>.pre-<ts>-<uid>.bak`, then atomically write `content`. The backup
    /// + write run under ONE flock on the target (the daemon's
    /// `with _persona_write_lock, file_lock(target)`). `keeping` sees the
    /// document being replaced under that lock and throws to refuse the write.
    @discardableResult
    public func personaWrite(kind: String, content: String,
                             keeping: (@Sendable (_ current: String) throws -> Void)? = nil) async throws -> PersonaToolWriteResult {
        let canon = Self.canonicalizeKind(kind)
        if canon == "user" {
            throw PersonaWriteError.invalidInput(Self.memoryOwnedUserDocMessage)
        }
        guard Self.personaWriteKinds.contains(canon) else {
            throw PersonaWriteError.invalidInput(
                "kind must be one of: \(Self.personaWriteKinds.sorted().joined(separator: ", "))"
            )
        }
        guard let target = personaToolPath(kind: canon) else {
            throw PersonaWriteError.invalidInput("Could not resolve persona path")
        }

        let contentBytes = Array(content.utf8)
        let persistence = SwiftNativePersistenceCore()
        let backupPath: String? = try await persistence.withFileLock(target) {
            let original = FileManager.default.fileExists(atPath: target.path)
                ? try Data(contentsOf: target) : nil
            if let keeping, let original {
                guard let current = String(data: original, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
                        NSFilePathErrorKey: target.path, NSStringEncodingErrorKey: String.Encoding.utf8.rawValue
                    ])
                }
                try keeping(current)
            }
            let backup = try Self.backup(target, data: original)
            try Self.atomicWriteText(content, to: target)
            return backup
        }

        await publishDerivedPersonaChange(target, reason: "persona_tool_write")

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
        guard Self.personaWriteKinds.contains(canon) else {
            throw PersonaWriteError.invalidInput(
                "kind must be one of: \(Self.personaWriteKinds.sorted().joined(separator: ", "))"
            )
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw PersonaWriteError.invalidInput("title is required")
        }

        guard let target = personaToolPath(kind: canon) else {
            throw PersonaWriteError.invalidInput("Could not resolve persona path")
        }

        // new_section = f"\n\n## {title}\n{content}" -- the daemon uses the
        // STRIPPED title value (title = str(...).strip(), L3966) in the heading.
        let newSection = "\n\n## \(trimmedTitle)\n\(content)"
        let newSectionBytes = Array(newSection.utf8).count

        let persistence = SwiftNativePersistenceCore()
        let backupPath: String? = try await persistence.withFileLock(target) {
            let existing = FileManager.default.fileExists(atPath: target.path)
                ? try Self.readPersonaTextForAppend(at: target) : nil
            let backup = try Self.backup(target, data: existing?.data)
            // new_content = existing.rstrip() + new_section
            let newContent = Self.rstrip(existing?.text ?? "") + newSection
            try Self.atomicWriteText(newContent, to: target)
            return backup
        }

        await publishDerivedPersonaChange(target, reason: "persona_section_appended")

        return PersonaToolWriteResult(
            kind: canon,
            path: target.path,
            backupPath: backupPath,
            bytesWritten: nil,
            bytesAppended: newSectionBytes
        )
    }

    // MARK: - shared write helpers

    /// Append operations are read-modify-write transitions over canonical
    /// persona documents. An existing unreadable file is authority we cannot
    /// safely merge, never an empty document; fail before backup/write so the
    /// original bytes remain the only state until an explicit repair occurs.
    private static func readPersonaTextForAppend(at url: URL) throws -> (text: String, data: Data) {
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
                    NSFilePathErrorKey: url.path, NSStringEncodingErrorKey: String.Encoding.utf8.rawValue
                ])
            }
            return (text, data)
        } catch {
            throw PersonaWriteError.ioFailure(
                "Cannot append to unreadable \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    func publishDerivedPersonaChange(_ target: URL, reason: String) async {
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "persona",
            stableID: target.lastPathComponent,
            operation: .changed,
            canonicalLocator: target.path,
            reason: reason
        ))
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
    static func backup(_ target: URL, data: Data?) throws -> String? {
        guard let data else { return nil }
        let ts = backupTimestamp()
        let uid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        // Python with_suffix(suffix + ".pre-...") REPLACES the final suffix with
        // <oldsuffix>.pre-<ts>-<uid>.bak -- e.g. VOICE.md -> VOICE.md.pre-...bak
        // (the old ".md" is kept because the new suffix string starts with it).
        let backupURL = target.deletingPathExtension()
            .appendingPathExtension("\(target.pathExtension).pre-\(ts)-\(uid).bak")
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: backupURL)
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
