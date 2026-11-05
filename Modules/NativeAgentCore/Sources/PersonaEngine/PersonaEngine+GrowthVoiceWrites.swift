import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaEngine+GrowthVoiceWrites.swift` | `SwiftNativePersonaEngine`. |

// Lock each persona target across read, backup and mutation; MemoryV2 retains USER ownership.

extension SwiftNativePersonaEngine {

    // Exclude USER from mutations because direct writes would split its projection from MemoryV2 authority.
    static let personaWriteKinds: Set<String> = ["soul", "voice", "growth", "agents"]
    static let memoryOwnedUserDocMessage =
        "USER.md is generated from MemoryV2; use app memory.commit or memory proposal tools for durable user facts."

    /// Normalize protected reads and writes identically before selecting documents.
    package static func canonicalizeKind(_ kind: String) -> String {
        (kind)
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    package static let personaReadKinds: Set<String> = ["soul", "user", "voice", "growth", "agents"]

    /// Share selection across protected reads and writes, but keep MemoryV2's USER projection outside mutation authority.
    package static func personaDocumentPath(kind: String, root: URL) -> URL? {
        let kind = canonicalizeKind(kind)
        guard personaReadKinds.contains(kind) else { return nil }
        return root.appendingPathComponent(kind.uppercased() + ".md")
    }

    // MARK: - persona_write (full-doc REPLACE + backup)

    /// Run keeping under the target lock before backup or write so refused replacements leave no edit.
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
            let original = try Self.readPersonaDocumentForMutation(at: target)
            try keeping?(original.text)
            let backup = try Self.backup(target, data: original.data)
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

    /// Hold the target lock across checked read, backup and complete section append.
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
            let existing = try Self.readPersonaDocumentForMutation(at: target)
            let backup = try Self.backup(target, data: existing.data)
            let newContent = Self.rstrip(existing.text) + newSection
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

    /// Ordinary edits require the checked canonical document; only explicit setup creates one.
    /// Missing or unreadable content cannot become an empty replacement base.
    static func readPersonaDocumentForMutation(at url: URL) throws -> (text: String, data: Data) {
        do {
            return try readPersonaDocumentContents(at: url)
        } catch {
            throw PersonaEngineError.rootUnreadable(
                reason: "cannot read \(url.path): \(error.localizedDescription). Repair or restore this document before continuing."
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

    /// Trim Unicode whitespace scalars only.
    static func rstrip(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Copy checked prior bytes under a unique timestamped backup name.
    static func backup(_ target: URL, data: Data) throws -> String {
        let ts = backupTimestamp()
        let uid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let backupURL = target.deletingPathExtension()
            .appendingPathExtension("\(target.pathExtension).pre-\(ts)-\(uid).bak")
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: backupURL)
        } catch {
            throw PersonaWriteError.ioFailure("Could not create backup: \(error.localizedDescription)")
        }
        // Refuse the edit if backup retention fails, preserving both prior content and the new recovery copy.
        do { try pruneOldBackups(for: target, keeping: backupRetention) }
        catch {
            throw PersonaWriteError.ioFailure(
                """
                    Created the recovery copy at \(backupURL.path), but could not prune older copies. The edit has not been applied. Repair access to \
                    \(target.deletingLastPathComponent().path). \(error.localizedDescription)
                    """)
        }
        return backupURL.path
    }

    static let backupRetention = 10

    /// Scope retention to the exact target's timestamped backup prefix so cleanup cannot remove unrelated files.
    /// Inspection or deletion failure refuses the pending edit.
    static func pruneOldBackups(for target: URL, keeping: Int) throws {
        guard keeping >= 0 else { return }
        let dir = target.deletingLastPathComponent()
        let prefix = target.lastPathComponent + ".pre-"
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(".bak") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard backups.count > keeping else { return }
        for stale in backups.dropFirst(keeping) {
            try FileManager.default.removeItem(at: stale)
        }
    }

    /// Use UTC microsecond timestamps so backup names sort chronologically.
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
