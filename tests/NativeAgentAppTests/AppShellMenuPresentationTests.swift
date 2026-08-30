import Foundation
import Testing
import NativeAgentShared
@testable import NativeAgentApp

// D7/D9 — app-shell menu honesty. The Navigate menu and the menu-bar extra are
// projections of state that lives elsewhere; these pin that they cannot drift
// from, or contradict, what they project.

@Suite("App shell menus")
struct AppShellMenuPresentationTests {
    @Test("Navigate's ⌘N order IS the sidebar's primary order")
    func navigateMenuDerivesFromPrimaryItems() {
        let entries = NavigateMenuPresentation.entries
        #expect(entries.map(\.item) == SidebarItem.primaryItems)
        #expect(entries.prefix(9).map(\.shortcut) == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(entries.dropFirst(9).allSatisfy { $0.shortcut == nil })

        // The drift the hand-kept list had: an Advanced tab holding a digit
        // while two primary tabs had none.
        #expect(!entries.contains { $0.item == .personality })
        #expect(entries.contains { $0.item == .skills && $0.shortcut != nil })
        #expect(entries.contains { $0.item == .macIntegration && $0.shortcut != nil })

        // No digit may be claimed twice.
        let digits = entries.compactMap(\.shortcut)
        #expect(Set(digits).count == digits.count)
    }

    @Test("the menu bar states reachability once, never a contradicting pair")
    func menuBarStatusIsOneTruthLine() throws {
        // RuntimeHealth's memberwise init is internal to NativeAgentShared;
        // it arrives over the wire, so build it the way the app does.
        func health(ok: Bool) throws -> RuntimeHealth {
            let json = """
            {"ok":\(ok),"app":"nativeagent","version":"1","dataDir":"/tmp","uptimeSeconds":5}
            """
            return try JSONDecoder().decode(RuntimeHealth.self, from: Data(json.utf8))
        }
        let down = try #require(try? health(ok: false))
        let up = try #require(try? health(ok: true))

        // The failure this replaced: "Ready" stacked above "unavailable".
        let contradiction = MenuBarStatusPresentation.line(statusText: "Ready", health: down)
        #expect(contradiction == "Native runtime unavailable — Ready")
        #expect(!contradiction.contains("\n"))

        #expect(MenuBarStatusPresentation.line(statusText: "  ", health: up) == "Native runtime online")
        #expect(MenuBarStatusPresentation.line(
            statusText: "native runtime online",
            health: up
        ) == "Native runtime online")
        #expect(MenuBarStatusPresentation.line(statusText: "Not checked", health: nil) == "Not checked")
        #expect(MenuBarStatusPresentation.line(statusText: "", health: nil) == "Runtime status unknown")
    }

    @Test("New Task is offered only where a Desk task lands")
    func newTaskActionMountsOnlyOnDesk() {
        #expect(DeskRootRoutePresentation.showsNewTaskAction(in: .desk))
        #expect(!DeskRootRoutePresentation.showsNewTaskAction(in: .schedule))
        #expect(!DeskRootRoutePresentation.showsNewTaskAction(in: .research))
    }
}
