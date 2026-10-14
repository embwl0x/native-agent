import Foundation

/// U1 (User, 2026-09-10): after the app updates, the agent had no way to know
/// what changed — someone asked theirs and it could not find out.
///
/// The app writes ONE record here when the bundle version changes; the turn
/// engine reads it into the DYNAMIC system segment on the next turn and stamps
/// it delivered, so it is a note left quietly rather than a push, a sound, or a
/// chat row that looks like the person typed. The dynamic segment is turn-scoped
/// volatile (lifted out of the cached prefix), so this costs no prompt-cache
/// prefix and vanishes after the one delivery.
public struct ChatUpdateNoteRecord: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var createdAt: String
    public var note: String
    /// Stamped when the note has been put in front of the agent once.
    public var deliveredAt: String?

    public init(from: String, to: String, createdAt: String, note: String, deliveredAt: String? = nil) {
        self.from = from
        self.to = to
        self.createdAt = createdAt
        self.note = note
        self.deliveredAt = deliveredAt
    }
}

public enum ChatUpdateNote {
    /// A note nobody ever collected stops being news. Without this, an app that
    /// is updated while it is closed for a month would open with a stale note.
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60

    public static func recordURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("update_note.json")
    }

    public static func load(dataRoot: URL) -> ChatUpdateNoteRecord? {
        guard let data = try? Data(contentsOf: recordURL(dataRoot: dataRoot)) else { return nil }
        return try? JSONDecoder().decode(ChatUpdateNoteRecord.self, from: data)
    }

    /// The note to put in this turn's context, or nil when there is nothing to
    /// say: no record, already delivered, empty, or past retention.
    public static func pendingNote(dataRoot: URL, now: Date = Date()) -> String? {
        guard let record = load(dataRoot: dataRoot) else { return nil }
        guard record.deliveredAt == nil else { return nil }
        let note = record.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        guard let created = ISO8601DateFormatter().date(from: record.createdAt),
              now.timeIntervalSince(created) <= retentionSeconds else { return nil }
        return note
    }

    /// Stamp the record delivered. Best-effort on purpose: failing to stamp must
    /// not fail the turn, and the worst case is the note appearing once more.
    public static func markDelivered(dataRoot: URL, now: Date = Date(), expectedNote: String? = nil) {
        guard var record = load(dataRoot: dataRoot), record.deliveredAt == nil else { return }
        if let expectedNote, record.note.trimmingCharacters(in: .whitespacesAndNewlines) != expectedNote { return }
        record.deliveredAt = ISO8601DateFormatter().string(from: now)
        write(record, dataRoot: dataRoot)
    }

    public static func write(_ record: ChatUpdateNoteRecord, dataRoot: URL) {
        let url = recordURL(dataRoot: dataRoot)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: url, options: [.atomic])
        } catch {
            nativeLog("[update-note] could not write the update note: %@", error.localizedDescription)
        }
    }
}

public enum ChatUpdateNoteDecision: Equatable, Sendable {
    /// No version was ever stored. A fresh install is NOT an update and gets no
    /// note — the first-run greeting already owns that moment.
    case freshInstall(version: String)
    case unchanged(version: String)
    case updated(from: String, to: String)
}

extension ChatUpdateNote {
    /// Persisted "last launched version". One key, written after the decision.
    public static let lastLaunchedVersionDefaultsKey = "NativeAgentLastLaunchedVersion"

    /// The whole note is capped so one update cannot swallow a turn's context.
    /// Anything trimmed is still on disk, and the note says where. The ceiling
    /// is well under the context projection's 4 KiB per-atom body gate, which
    /// silently DROPS an oversized atom — a too-generous cap here would mean no
    /// note at all after a big release.
    public static let maximumNoteCharacters = 3200

    public static let bundledNotesRelativeDirectory = "docs/release-notes"

    public static func decide(storedVersion: String?, currentVersion: String) -> ChatUpdateNoteDecision {
        let current = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = storedVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return .freshInstall(version: current) }
        guard stored != current else { return .unchanged(version: current) }
        return .updated(from: stored, to: current)
    }

    /// Numeric dot-component compare, so 0.4.10 sorts after 0.4.9 (a string
    /// compare gets that backwards, which would drop the newest note).
    public static func versionIsLessThan(_ lhs: String, _ rhs: String) -> Bool {
        let a = components(lhs)
        let b = components(rhs)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: true)
            .map { part in
                Int(part.prefix(while: { $0.isNumber })) ?? 0
            }
    }

    /// Versions to include, oldest first: everything newer than the stored
    /// version up to and including the current one. A downgrade or an unknown
    /// current version still reports the current version if a note exists.
    public static func versionsToReport(
        from stored: String,
        to current: String,
        available: [String]
    ) -> [String] {
        let sorted = available
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted(by: versionIsLessThan)
        let window = sorted.filter { candidate in
            versionIsLessThan(stored, candidate)
                && !versionIsLessThan(current, candidate)
        }
        if window.isEmpty, sorted.contains(current) { return [current] }
        return window
    }

    /// The note, in plain words. The closing line is the whole point of the
    /// quiet channel: the agent may use this when asked or when it fits, and is
    /// told NOT to announce it on its own.
    public static func compose(
        from: String,
        to: String,
        notes: [(version: String, body: String)],
        maximumCharacters: Int = ChatUpdateNote.maximumNoteCharacters
    ) -> String {
        guard notes.contains(where: { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "NativeAgent version changed: \(from) → \(to). No change summary is available."
        }
        var text = "NativeAgent updated from \(from) to \(to). What changed:\n"
        for note in notes {
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            text += "\n— \(note.version) —\n"
            text += body.isEmpty ? "(no notes for this version)\n" : body + "\n"
        }
        if text.count > maximumCharacters {
            let kept = String(text.prefix(maximumCharacters))
            text = kept + "\n\n[Trimmed here. The full notes for every version ship with the app; "
                + "read it with app {action:\"files.read\", args:{path:\"\(bundledNotesRelativeDirectory)/<version>.md\"}}.]\n"
        }
        text += """

        You may summarise this for the person when they ask what changed, or when \
        it fits the conversation. Do not announce it unprompted. The full notes \
        for any version are readable at \(bundledNotesRelativeDirectory)/<version>.md.
        """
        return text
    }

    /// Call once per launch. Returns what it decided so the caller (and tests)
    /// can see it; writes a note ONLY for `.updated`.
    @discardableResult
    public static func recordLaunch(
        dataRoot: URL,
        currentVersion: String,
        defaults: UserDefaults,
        now: Date = Date(),
        availableVersions: () -> [String],
        noteBody: (String) -> String?
    ) -> ChatUpdateNoteDecision {
        guard !currentVersion.isEmpty else {
            // No version to compare: say nothing and store nothing rather than
            // inventing an update out of a blank string.
            return .unchanged(version: currentVersion)
        }
        let stored = defaults.string(forKey: ChatUpdateNote.lastLaunchedVersionDefaultsKey)
        let decision = ChatUpdateNote.decide(storedVersion: stored, currentVersion: currentVersion)
        defaults.set(currentVersion, forKey: ChatUpdateNote.lastLaunchedVersionDefaultsKey)

        guard case .updated(let from, let to) = decision else { return decision }

        let versions = ChatUpdateNote.versionsToReport(
            from: from,
            to: to,
            available: availableVersions()
        )
        let notes: [(version: String, body: String)] = versions.compactMap { version in
            guard let body = noteBody(version) else { return nil }
            return (version: version, body: body)
        }
        let text = ChatUpdateNote.compose(from: from, to: to, notes: notes)
        let record = ChatUpdateNoteRecord(
            from: from,
            to: to,
            createdAt: ISO8601DateFormatter().string(from: now),
            note: text
        )
        ChatUpdateNote.write(record, dataRoot: dataRoot)
        return decision
    }
}

extension ChatUpdateNote {
    /// Versions whose notes ship inside this bundle.
    public static func bundledVersions(resources: URL?) -> [String] {
        guard let dir = bundledNotesDirectory(resources: resources),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .filter { !$0.isEmpty }
    }

    public static func bundledNote(version: String, resources: URL?) -> String? {
        guard !version.contains("/"), version != ".", version != ".." else { return nil }
        guard let dir = bundledNotesDirectory(resources: resources) else { return nil }
        let url = dir.appendingPathComponent("\(version).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func bundledNotesDirectory(resources: URL?) -> URL? {
        guard let resources else { return nil }
        // The release layout is Resources/docs/release-notes/; the SwiftPM
        // development layout puts copied resources at the resource root, so
        // accept release-notes/ there too (same two-step as the data-limits doc).
        for relative in ["docs/release-notes", "release-notes"] {
            let candidate = resources.appendingPathComponent(relative, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    public static func recordLaunchAtStartup(
        dataRoot: URL,
        currentVersion: String,
        resources: URL?,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> ChatUpdateNoteDecision {
        recordLaunch(
            dataRoot: dataRoot,
            currentVersion: currentVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            defaults: defaults,
            now: now,
            availableVersions: { bundledVersions(resources: resources) },
            noteBody: { bundledNote(version: $0, resources: resources) }
        )
    }
}
