import ChatOrchestration
import Foundation
import PersistenceCore

/// The durable half of the update note: on the first launch after the bundle's
/// CFBundleShortVersionString changes, write ONE note to disk and remember the
/// new version. The note is picked up from there by
/// `NativeUpdateNoteContextProjection`, which is the quiet channel — it lands in
/// the turn's derived-context packet with no push, no sound, and no chat row.
enum AppUpdateNoteStore {
    /// The record shape, its path, the retention window and the delivered stamp
    /// all belong to `ChatUpdateNote` in ChatOrchestration — the turn engine is
    /// the reader, so the reader owns the format.
    static func recordURL(dataRoot: URL) -> URL {
        ChatUpdateNote.recordURL(dataRoot: dataRoot)
    }

    static func currentBundleVersion(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Versions whose notes ship inside this bundle.
    static func bundledVersions(bundle: Bundle = .main) -> [String] {
        guard let dir = bundledNotesDirectory(bundle: bundle),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .filter { !$0.isEmpty }
    }

    static func bundledNote(version: String, bundle: Bundle = .main) -> String? {
        guard !version.contains("/"), version != ".", version != ".." else { return nil }
        guard let dir = bundledNotesDirectory(bundle: bundle) else { return nil }
        let url = dir.appendingPathComponent("\(version).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func bundledNotesDirectory(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
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

    /// Call once per launch. Returns what it decided so the caller (and tests)
    /// can see it; writes a note ONLY for `.updated`.
    @discardableResult
    static func recordLaunch(
        dataRoot: URL,
        currentVersion: String,
        defaults: UserDefaults,
        now: Date = Date(),
        availableVersions: () -> [String],
        noteBody: (String) -> String?
    ) -> AppUpdateNoteDecision {
        guard !currentVersion.isEmpty else {
            // No version to compare: say nothing and store nothing rather than
            // inventing an update out of a blank string.
            return .unchanged(version: currentVersion)
        }
        let stored = defaults.string(forKey: AppUpdateNote.lastLaunchedVersionDefaultsKey)
        let decision = AppUpdateNote.decide(storedVersion: stored, currentVersion: currentVersion)
        defaults.set(currentVersion, forKey: AppUpdateNote.lastLaunchedVersionDefaultsKey)

        guard case .updated(let from, let to) = decision else { return decision }

        let versions = AppUpdateNote.versionsToReport(
            from: from,
            to: to,
            available: availableVersions()
        )
        let notes: [(version: String, body: String)] = versions.compactMap { version in
            guard let body = noteBody(version) else { return nil }
            return (version: version, body: body)
        }
        let text = AppUpdateNote.compose(from: from, to: to, notes: notes)
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

extension AppUpdateNoteStore {
    /// The launch wiring, in one place so `applicationDidFinishLaunching` reads
    /// as one line. Deliberately NOT gated on `isPublicReleaseBundle`: unlike the
    /// first-run greeting this writes no chat turn, and a developer install that
    /// bumps its version is a real update whose note is worth seeing.
    @discardableResult
    static func recordLaunchAtStartup(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> AppUpdateNoteDecision {
        recordLaunch(
            dataRoot: dataRoot,
            currentVersion: currentBundleVersion(),
            defaults: defaults,
            now: now,
            availableVersions: { bundledVersions() },
            noteBody: { bundledNote(version: $0) }
        )
    }
}
