import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaEngine+GrowthVoiceWrites.swift` | `SwiftNativePersonaEngine`: shared document-kind normalization and selection, locked persona mutations and private backups; ordinary persona mutations; skill-specific aliases are retired |

// Persona tool writes hold one cross-process file lock around each target's
// read, backup and mutation. USER.md remains owned by MemoryV2.

extension SwiftNativePersonaEngine {

    // USER.md is intentionally absent from the mutation sets. MemoryV2 owns
    // USER.md and regenerates it from SQLite; persona tools may read it, but
    // direct writes would split the projection from the source of truth.
    static let personaWriteKinds: Set<String> = ["soul", "voice", "growth", "agents"]
    static let memoryOwnedUserDocMessage =
        "USER.md is generated from MemoryV2; use app memory.commit or memory proposal tools for durable user facts."

    /// Protected reads and writes share NFKC, trimming and lowercase before selecting a document.
    package static func canonicalizeKind(_ kind: String) -> String {
        (kind)
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    package static let personaReadKinds: Set<String> = ["soul", "user", "voice", "growth", "agents"]

    /// Document selection shared by protected tool reads and guarded writes.
    /// USER is readable here; mutation callers exclude it because MemoryV2
    /// owns that projection. Routine authoring uses the app door.
    package static func personaDocumentPath(kind: String, root: URL) -> URL? {
        let kind = canonicalizeKind(kind)
        guard personaReadKinds.contains(kind) else { return nil }
        return root.appendingPathComponent(kind.uppercased() + ".md")
    }

    // MARK: - persona_write (full-doc REPLACE + backup)

    /// Under the target lock, `keeping` may refuse replacement before backup or write.
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
        guard let target = Self.personaDocumentPath(kind: canon, root: personaRoot) else {
            throw PersonaWriteError.invalidInput("Could not resolve persona path")
        }

        let contentBytes = Array(content.utf8)
        let backupPath: String? = try await SwiftNativePersistenceCore.withFileLock(target) {
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

    /// Append the full `\n\n## <trimmed title>\n<content>` section after trimming the base's trailing whitespace.
    /// Read, backup and rewrite hold the target lock.
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

        guard let target = Self.personaDocumentPath(kind: canon, root: personaRoot) else {
            throw PersonaWriteError.invalidInput("Could not resolve persona path")
        }

        let newSection = "\n\n## \(trimmedTitle)\n\(content)"
        let newSectionBytes = Array(newSection.utf8).count

        let backupPath: String? = try await SwiftNativePersistenceCore.withFileLock(target) {
            let existing = FileManager.default.fileExists(atPath: target.path)
                ? try Self.readPersonaTextForAppend(at: target) : nil
            let backup = try Self.backup(target, data: existing?.data)
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

    /// Remove trailing Unicode whitespace scalars only.
    static func rstrip(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Copy prior bytes to `<file>.pre-<UTC timestamp>-<8 lowercase hex digits>.bak`; nil means no prior file.
    static func backup(_ target: URL, data: Data?) throws -> String? {
        guard let data else { return nil }
        let ts = backupTimestamp()
        let uid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let backupURL = target.deletingPathExtension()
            .appendingPathExtension("\(target.pathExtension).pre-\(ts)-\(uid).bak")
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: backupURL)
        } catch {
            throw PersonaWriteError.ioFailure("Could not create backup: \(error.localizedDescription)")
        }
        // Keep the newest backupRetention siblings per target; pruning failure cannot fail the write.
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

    /// Backup timestamp shape: YYYYMMDDTHHMMSS<6-digit-microseconds>Z in UTC.
    static func backupTimestamp() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
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
