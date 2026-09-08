import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Bots shelf preview")
struct BotsShelfTests {
    @Test("Flag off preserves the shipped rail destination snapshot")
    func flagOffDestinationSnapshot() {
        let expected = ["Chat", "Activity", "Memories", "Personality", "Providers", "Trust",
                        "Connectors", "Diagnostics", "Capabilities", "Inbox Policy", "Desk", "Settings"]
        #expect(BotsShelfRailProposal.destinations(SidebarItem.shellPrimaryItems, enabled: false) == expected)
        let subset: [SidebarItem] = [.chat, .desk, .settings]
        #expect(BotsShelfRailProposal.destinations(subset, enabled: false) == subset.map(\.rawValue))
        let defaults = UserDefaults(suiteName: "BotsShelfTests.\(UUID().uuidString)")!
        #expect(!BotsShelfPreference.isEnabled(defaults))
    }

    @MainActor @Test("Render the review shelf offscreen when explicitly requested")
    func headlessSnapshots() throws {
        #if DEBUG
        guard let output = ProcessInfo.processInfo.environment["BOTS_SHELF_SNAPSHOT_DIR"] else { return }
        try BotsShelfSnapshots.render(to: URL(fileURLWithPath: output, isDirectory: true))
        #endif
    }
}
