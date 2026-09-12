import ChatOrchestration
import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Update note: version changed leaves one note, nothing else does")
struct AppUpdateNoteBehaviorEvalTests {
    @Test("A changed version is an update")
    func changedVersionIsAnUpdate() {
        #expect(
            AppUpdateNote.decide(storedVersion: "0.4.9", currentVersion: "0.4.10")
                == .updated(from: "0.4.9", to: "0.4.10")
        )
    }

    @Test("The same version leaves no note")
    func sameVersionLeavesNoNote() {
        #expect(
            AppUpdateNote.decide(storedVersion: "0.4.10", currentVersion: "0.4.10")
                == .unchanged(version: "0.4.10")
        )
    }

    @Test("A fresh install has no stored version and is not an update")
    func freshInstallIsNotAnUpdate() {
        #expect(
            AppUpdateNote.decide(storedVersion: nil, currentVersion: "0.4.10")
                == .freshInstall(version: "0.4.10")
        )
        // An empty or whitespace-only stored value is the same blank slate; it
        // must not read as an update from "" to the current version.
        #expect(
            AppUpdateNote.decide(storedVersion: "   ", currentVersion: "0.4.10")
                == .freshInstall(version: "0.4.10")
        )
    }

    @Test("0.4.10 is newer than 0.4.9 — a string compare gets this backwards")
    func versionOrderIsNumeric() {
        #expect(AppUpdateNote.versionIsLessThan("0.4.9", "0.4.10"))
        #expect(!AppUpdateNote.versionIsLessThan("0.4.10", "0.4.9"))
    }

    @Test("Skipped versions are reported oldest first, current included")
    func skippedVersionsAreReportedOldestFirst() {
        let available = ["0.4.7", "0.4.8", "0.4.9", "0.4.10"]
        #expect(
            AppUpdateNote.versionsToReport(from: "0.4.7", to: "0.4.10", available: available)
                == ["0.4.8", "0.4.9", "0.4.10"]
        )
        #expect(
            AppUpdateNote.versionsToReport(from: "0.4.9", to: "0.4.10", available: available)
                == ["0.4.10"]
        )
    }

    @Test("The note names both versions and tells the agent not to announce it")
    func noteTextIsPlainAndUnprompted() {
        let text = AppUpdateNote.compose(
            from: "0.4.9",
            to: "0.4.10",
            notes: [(version: "0.4.10", body: "- Bots tab is on by default.")]
        )
        #expect(text.hasPrefix("NativeAgent updated from 0.4.9 to 0.4.10. What changed:"))
        #expect(text.contains("- Bots tab is on by default."))
        #expect(text.contains("Do not announce it unprompted."))
    }

    @Test("A very long note is trimmed and says where the full text lives")
    func longNoteIsTrimmed() {
        let huge = String(repeating: "x", count: 20_000)
        let text = AppUpdateNote.compose(
            from: "0.4.8",
            to: "0.4.10",
            notes: [(version: "0.4.10", body: huge)]
        )
        #expect(text.count < 20_000)
        #expect(text.contains("docs/release-notes/<version>.md"))
    }
}

@Suite("Update note on disk: written once for an update, never otherwise", .serialized)
struct AppUpdateNoteStoreBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-note-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A private suite, so the test never reads or writes the real app's
    /// last-launched version.
    private func defaults(_ label: String) -> UserDefaults {
        let suite = "nativeagent.update-note.test.\(label).\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    private func recordExists(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: ChatUpdateNote.recordURL(dataRoot: root).path)
    }

    @Test("A changed version writes exactly one note, and the next launch writes none")
    func versionChangeWritesOneNote() throws {
        let root = try temporaryRoot("changed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = defaults("changed")
        store.set("0.4.9", forKey: AppUpdateNote.lastLaunchedVersionDefaultsKey)

        let first = AppUpdateNoteStore.recordLaunch(
            dataRoot: root,
            currentVersion: "0.4.10",
            defaults: store,
            availableVersions: { ["0.4.9", "0.4.10"] },
            noteBody: { $0 == "0.4.10" ? "- Bots tab is on by default." : nil }
        )
        #expect(first == .updated(from: "0.4.9", to: "0.4.10"))
        #expect(recordExists(root))
        let note = try #require(ChatUpdateNote.pendingNote(dataRoot: root))
        #expect(note.contains("NativeAgent updated from 0.4.9 to 0.4.10"))
        #expect(note.contains("- Bots tab is on by default."))
        #expect(store.string(forKey: AppUpdateNote.lastLaunchedVersionDefaultsKey) == "0.4.10")

        // The turn engine puts it in front of the agent once and stamps it.
        ChatUpdateNote.markDelivered(dataRoot: root)
        #expect(ChatUpdateNote.pendingNote(dataRoot: root) == nil)

        // Relaunch on the same version: no new note, and the delivered one stays
        // delivered rather than reappearing.
        let second = AppUpdateNoteStore.recordLaunch(
            dataRoot: root,
            currentVersion: "0.4.10",
            defaults: store,
            availableVersions: { ["0.4.9", "0.4.10"] },
            noteBody: { _ in "- Bots tab is on by default." }
        )
        #expect(second == .unchanged(version: "0.4.10"))
        #expect(ChatUpdateNote.pendingNote(dataRoot: root) == nil)
    }

    @Test("The same version writes no note at all")
    func sameVersionWritesNothing() throws {
        let root = try temporaryRoot("same")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = defaults("same")
        store.set("0.4.10", forKey: AppUpdateNote.lastLaunchedVersionDefaultsKey)

        let decision = AppUpdateNoteStore.recordLaunch(
            dataRoot: root,
            currentVersion: "0.4.10",
            defaults: store,
            availableVersions: { ["0.4.10"] },
            noteBody: { _ in "- something" }
        )
        #expect(decision == .unchanged(version: "0.4.10"))
        #expect(!recordExists(root))
        #expect(ChatUpdateNote.pendingNote(dataRoot: root) == nil)
    }

    @Test("A fresh install writes no note and just remembers the version")
    func freshInstallWritesNothing() throws {
        let root = try temporaryRoot("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = defaults("fresh")

        let decision = AppUpdateNoteStore.recordLaunch(
            dataRoot: root,
            currentVersion: "0.4.10",
            defaults: store,
            availableVersions: { ["0.4.10"] },
            noteBody: { _ in "- something" }
        )
        #expect(decision == .freshInstall(version: "0.4.10"))
        #expect(!recordExists(root))
        #expect(ChatUpdateNote.pendingNote(dataRoot: root) == nil)
        // Stored now, so the NEXT version change is a real update.
        #expect(store.string(forKey: AppUpdateNote.lastLaunchedVersionDefaultsKey) == "0.4.10")
    }

    @Test("A note older than the retention window is not delivered")
    func staleNoteIsNotDelivered() throws {
        let root = try temporaryRoot("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-(ChatUpdateNote.retentionSeconds + 60))
        ChatUpdateNote.write(
            ChatUpdateNoteRecord(
                from: "0.4.8",
                to: "0.4.9",
                createdAt: ISO8601DateFormatter().string(from: old),
                note: "NativeAgent updated from 0.4.8 to 0.4.9. What changed:"
            ),
            dataRoot: root
        )
        #expect(ChatUpdateNote.pendingNote(dataRoot: root) == nil)
    }
}
