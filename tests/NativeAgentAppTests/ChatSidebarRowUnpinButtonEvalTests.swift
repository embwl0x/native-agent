import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.sidebar.rowUnpinButton
//
// Runs the exact SessionRow button action shape through the mounted sidebar's
// unpin transaction and its canonical UserDefaults + retention-mirror writer.
// A pinned row has a required handler; an unpinned row has no action to invoke.

@MainActor
@Test("pinned sidebar row unpin action updates the canonical pin state and survives a fresh read")
func chatSidebarRowUnpinButtonUsesCanonicalTransaction() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidebar-row-unpin-\(UUID().uuidString)", isDirectory: true)
    let suiteName = "ChatSidebarRowUnpinButtonEvalTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    try MacPinnedChatSessionStore.save(
        ["keep", "remove"],
        defaults: defaults,
        dataRoot: root
    )

    var outcome: ChatSidebarRowUnpinTransaction.Outcome?
    let pinnedRowAction = SessionRow.PinState.pinned(onUnpin: {
        outcome = ChatSidebarRowUnpinTransaction.execute(
            sessionID: "remove",
            defaults: defaults,
            dataRoot: root
        )
    })

    #expect(pinnedRowAction.isPinned)
    pinnedRowAction.performUnpin()
    #expect(outcome == .unpinned(encoded: "[\"keep\"]"))
    #expect(MacPinnedChatSessionStore.load(defaults: defaults) == ["keep"])

    let mirror = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("pinned_session_ids.json")
    #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: mirror)) == ["keep"])
    #expect(
        ChatSidebarRowUnpinTransaction.execute(
            sessionID: "remove",
            defaults: defaults,
            dataRoot: root
        ) == .refusedAlreadyUnpinned
    )

    let unpinnedRowAction = SessionRow.PinState.unpinned
    unpinnedRowAction.performUnpin()
    #expect(!unpinnedRowAction.isPinned)
}
