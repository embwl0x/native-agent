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
        //
        // 2026-09-06: the primary list itself moved with the new shell
        // (3ccfb925/0b0c083f/df974e5f) — Personality is primary now, and
        // Skills and Mac Integration became tabs on other rail pages, so
        // `primaryItems` is shell-dependent. Pin the invariant that killed the
        // drift instead of one shell's membership: the menu holds nothing but
        // primary items, and no Advanced tab can ever claim a digit.
        #expect(entries.allSatisfy { SidebarItem.primaryItems.contains($0.item) })
        #expect(!entries.contains { $0.shortcut != nil && $0.item.isAdvanced })
        #expect(Set(SidebarItem.primaryItems).isDisjoint(with: Set(SidebarItem.advancedItems)))

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
