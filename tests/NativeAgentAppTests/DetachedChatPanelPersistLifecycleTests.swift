import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// Coverage ledger app.chat / api.DetachedChatWindowController (REPORTS-ONLY →
// COVERED, for the persist-set half).
//
// Silent-failure mode being pinned: the persisted open-set is replayed on every
// launch. An entry for a session that no longer exists must be PRUNED when the
// session list is loaded, and must NOT be pruned when the list is merely empty
// (not loaded yet) — the second mistake silently deletes a valid detached
// window, the first re-spawns a window bound to a dead session forever. Both
// paths only NSLog.
//
// Scope note: `open()` for a session that DOES exist constructs an NSPanel and
// an NSHostingController, which needs a running app — that half of the
// lifecycle (every add has a matching remove) belongs to the ui-walk tier. Both
// cases asserted here return BEFORE any window is created.

private let detachedPersistKey = "NativeAgent.detachedChatSessionIds"

private func detachedSession(_ id: String) throws -> ChatSession {
    try JSONDecoder().decode(ChatSession.self, from: Data("""
    {"id": "\(id)", "title": "Detached", "createdAt": "2026-08-23T00:00:00Z"}
    """.utf8))
}

@MainActor
@Suite("Detached chat panel persist lifecycle")
struct DetachedChatPanelPersistLifecycleTests {

    /// Run `body` with the persist key seeded, restoring whatever the process
    /// had before (the suite must not leak defaults into other tests).
    private func withPersistedSet(_ seeded: String, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: detachedPersistKey)
        defaults.set(seeded, forKey: detachedPersistKey)
        defer {
            if let previous { defaults.set(previous, forKey: detachedPersistKey) }
            else { defaults.removeObject(forKey: detachedPersistKey) }
        }
        body()
    }

    private func persistedIDs() -> [String] {
        (UserDefaults.standard.string(forKey: detachedPersistKey) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Sessions not loaded yet (empty list) is NOT evidence the session is
    /// gone. Pruning here silently loses the user's detached window.
    @Test func anUnloadedSessionListNeverPrunesTheRestoreSet() throws {
        let model = AppModel()
        model.chatSessions = []
        DetachedChatWindowController.shared.attach(appModel: model)

        withPersistedSet("live-session,ghost-session") {
            DetachedChatWindowController.shared.open(sessionId: "ghost-session", origin: nil)
            #expect(persistedIDs() == ["live-session", "ghost-session"],
                    "an empty (not-yet-loaded) session list pruned a persisted panel")
            #expect(!DetachedChatWindowController.shared.isDetached("ghost-session"),
                    "a panel was opened for a session that could not be resolved")
        }
    }

    /// With the list actually loaded, an entry whose session is gone must be
    /// pruned — otherwise every launch re-spawns a window for a deleted chat.
    @Test func aLoadedSessionListPrunesOnlyTheUnknownEntry() throws {
        let model = AppModel()
        model.chatSessions = [try detachedSession("live-session")]
        DetachedChatWindowController.shared.attach(appModel: model)

        withPersistedSet("live-session,ghost-session") {
            DetachedChatWindowController.shared.open(sessionId: "ghost-session", origin: nil)
            #expect(persistedIDs() == ["live-session"],
                    "the dead session id survived a load-time open()")
            #expect(!DetachedChatWindowController.shared.isDetached("ghost-session"))
        }
    }

    /// The persisted set is a comma string written by hand-rolled parsing; a
    /// prune must normalize it (dedupe + trim) rather than re-emitting a
    /// malformed list that grows on every launch.
    @Test func pruningNormalizesADuplicatedOrPaddedRestoreSet() throws {
        let model = AppModel()
        model.chatSessions = [try detachedSession("live-session")]
        DetachedChatWindowController.shared.attach(appModel: model)

        withPersistedSet("live-session, live-session ,,ghost-session, ghost-session") {
            DetachedChatWindowController.shared.open(sessionId: "ghost-session", origin: nil)
            let ids = persistedIDs()
            #expect(ids == ["live-session"],
                    "prune left a duplicated/padded restore set: \(ids)")
            #expect(Set(ids).count == ids.count, "the restore set kept duplicate ids")
        }
    }

    /// `hasSavedFrame` is the open-time branch between "restore the user's
    /// placement" and "center a new window". It must key on THIS session only —
    /// a shared key would drag every panel to one frame.
    @Test func savedFrameLookupIsScopedToOneSessionId() {
        let defaults = UserDefaults.standard
        let sessionId = "frame-\(UUID().uuidString)"
        let otherId = "frame-other-\(UUID().uuidString)"
        let key = "NSWindow Frame DetachedChatPanel.\(sessionId)"
        defer { defaults.removeObject(forKey: key) }

        #expect(!DetachedChatPanel.hasSavedFrame(sessionId: sessionId))
        defaults.set("0 0 520 600 0 0 1440 900", forKey: key)
        #expect(DetachedChatPanel.hasSavedFrame(sessionId: sessionId))
        #expect(!DetachedChatPanel.hasSavedFrame(sessionId: otherId),
                "one session's saved frame answered for another session")
    }
}
