import Foundation

/// U1 (User, 2026-09-10): after the app updates, the agent had no way to know
/// what changed — someone asked theirs and it could not find out. Most people
/// will ask the agent rather than read a changelog on the web, so the app leaves
/// the agent exactly one note when the bundle version changes, and the release
/// notes now ship inside the bundle so the agent can read any of them later.
///
/// This type is pure: version comparison, which versions a person skipped, and
/// the note text. Delivery and the UserDefaults write live at the call site.
enum AppUpdateNoteDecision: Equatable, Sendable {
    /// No version was ever stored. A fresh install is NOT an update and gets no
    /// note — the first-run greeting already owns that moment.
    case freshInstall(version: String)
    case unchanged(version: String)
    case updated(from: String, to: String)
}

enum AppUpdateNote {
    /// Persisted "last launched version". One key, written after the decision.
    static let lastLaunchedVersionDefaultsKey = "NativeAgentLastLaunchedVersion"

    /// The whole note is capped so one update cannot swallow a turn's context.
    /// Anything trimmed is still on disk, and the note says where. The ceiling
    /// is well under the context projection's 4 KiB per-atom body gate, which
    /// silently DROPS an oversized atom — a too-generous cap here would mean no
    /// note at all after a big release.
    static let maximumNoteCharacters = 3200

    static let bundledNotesRelativeDirectory = "docs/release-notes"

    static func decide(storedVersion: String?, currentVersion: String) -> AppUpdateNoteDecision {
        let current = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = storedVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return .freshInstall(version: current) }
        guard stored != current else { return .unchanged(version: current) }
        return .updated(from: stored, to: current)
    }

    /// Numeric dot-component compare, so 0.4.10 sorts after 0.4.9 (a string
    /// compare gets that backwards, which would drop the newest note).
    static func versionIsLessThan(_ lhs: String, _ rhs: String) -> Bool {
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
    static func versionsToReport(
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
    static func compose(
        from: String,
        to: String,
        notes: [(version: String, body: String)],
        maximumCharacters: Int = AppUpdateNote.maximumNoteCharacters
    ) -> String {
        var text = "NativeAgent updated from \(from) to \(to). What changed:\n"
        if notes.isEmpty {
            text += "\nNo release notes shipped for this version.\n"
        } else {
            for note in notes {
                let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
                text += "\n— \(note.version) —\n"
                text += body.isEmpty ? "(no notes for this version)\n" : body + "\n"
            }
        }
        if text.count > maximumCharacters {
            let kept = String(text.prefix(maximumCharacters))
            text = kept + "\n\n[Trimmed here. The full notes for every version ship with the app; "
                + "read \(bundledNotesRelativeDirectory)/<version>.md with read_file.]\n"
        }
        text += """

        You may summarise this for the person when they ask what changed, or when \
        it fits the conversation. Do not announce it unprompted. The full notes \
        for any version are readable at \(bundledNotesRelativeDirectory)/<version>.md.
        """
        return text
    }
}
