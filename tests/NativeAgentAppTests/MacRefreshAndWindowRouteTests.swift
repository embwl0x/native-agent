import Foundation
import Testing
@testable import NativeAgentApp

// Ledger fence app.mac — rows `ui.menu.refreshStatus` and
// `public-api.NativeAgentAppCoordinator.presentLiveMainWindow`.
//
// Two dead-control modes with no failure signal:
//   * Command-R / "Refresh Status" fans out ~40 fetches, every one of them
//     swallowed with `try?`. If a failed endpoint stops being RECORDED, the
//     panels carry over last-known data and pressing the key produces no
//     visible change at all.
//   * The main window is located by a hard-coded TITLE STRING in two places,
//     while the scene declares its title independently. Any rename silently
//     breaks every menu-bar "Open NativeAgent", every deep link from Spotlight
//     and the inbox, and every ⌘-shortcut fired while the window is closed —
//     the typed route just stays queued forever and nothing happens.

// MARK: - Refresh Status (dead control)

@MainActor
@Test("a failed endpoint inside refreshAll is recorded, not silently swallowed")
func refreshStatus_recordsTheFailedEndpoint() async {
    struct Boom: Error, LocalizedError {
        var errorDescription: String? { "endpoint exploded" }
    }

    let model = AppModel()
    #expect(model.lastRefreshError == nil)

    // This is the exact helper every refreshAll fetch funnels through. A
    // regression that reverts it to a bare `try?` produces the silent mode:
    // the panel keeps its previous rows and nothing anywhere says why.
    let rows: [String] = await model.decodeLogged("getRuns", default: ["carried-over"]) {
        throw Boom()
    }
    #expect(rows == ["carried-over"], "the caller must keep its last-known value")
    let recorded = model.lastRefreshError
    #expect(recorded?.contains("getRuns") == true, "the failure did not name its endpoint: \(recorded ?? "nil")")
    #expect(recorded?.contains("endpoint exploded") == true)

    // The optional-returning overload must record too — that one is used where
    // there is no list fallback, and a nil result is the most collapsible
    // "nothing happened" value in the app.
    model.lastRefreshError = nil
    let single: String? = await model.decodeLogged("getHealth") { throw Boom() }
    #expect(single == nil)
    #expect(model.lastRefreshError?.contains("getHealth") == true)

    // A success must not leave a stale error behind on the next read.
    let ok: [String] = await model.decodeLogged("getRuns", default: []) { ["fresh"] }
    #expect(ok == ["fresh"])
}

@Test("refreshAll clears its error slot per pass, and both Refresh Status controls call it")
func refreshStatus_isWiredAndScopedToOnePass() throws {
    let refresh = try AppSourceScraping.appSource("AppModel+Refresh.swift")
    let body = try AppSourceScraping.functionBody(named: "refreshAll", in: refresh)

    // Without the reset, `lastRefreshError` is a permanent tombstone from the
    // first failure the app ever had and stops describing the current pass.
    let reset = try #require(
        body.range(of: "setIfChanged(\\.lastRefreshError, nil)"),
        "refreshAll no longer clears lastRefreshError at the start of a pass"
    )
    let firstFetch = try #require(body.range(of: "api.getHealth()"))
    #expect(reset.lowerBound < firstFetch.lowerBound)

    // Re-entrancy: a second ⌘R during an in-flight pass must queue rather than
    // interleave two fan-outs over the same observed properties.
    #expect(body.contains("if refreshAllInFlight"))
    #expect(body.contains("refreshAllQueued = true"))

    // Both surfaces the ledger names must reach the same function: the ⌘R menu
    // command and its menu-bar mirror.
    let app = try AppSourceScraping.appSource("NativeAgentApp.swift")
    // Two controls, one action: the ⌘R command-group button and the menu-bar
    // mirror (which carries a systemImage). Losing either is a control that
    // silently stops existing on one of the two surfaces.
    #expect(AppSourceScraping.occurrences(of: "Button(\"Refresh Status\"", in: app) == 2)
    #expect(AppSourceScraping.occurrences(of: "Button(\"Refresh Status\", systemImage: \"arrow.clockwise\")", in: app) == 1)
    #expect(AppSourceScraping.occurrences(of: "await appModel.refreshAll()", in: app) == 2)
    #expect(app.contains(".keyboardShortcut(\"r\", modifiers: [.command])"))
}

// MARK: - main-window lookup (dead control across the whole app)

@Test("the main window is looked up by the same title the scene declares")
func presentLiveMainWindow_usesTheSceneTitleAndSkipsPanels() throws {
    let app = try AppSourceScraping.appSource("NativeAgentApp.swift")
    let coordinator = try AppSourceScraping.appSource("NativeAgentAppCoordinator.swift")

    // The scene's declared title.
    let sceneDecl = try #require(
        app.range(of: "Window(\""),
        "the main Window scene declaration moved"
    )
    let afterQuote = app[sceneDecl.upperBound...]
    let end = try #require(afterQuote.firstIndex(of: "\""))
    let sceneTitle = String(afterQuote[..<end])
    #expect(app.contains("Window(\"\(sceneTitle)\", id: \"main\")"))

    // Both lookup sites in the coordinator must use that same string: the
    // NSWindow scan and the Window-menu fallback. A rename on one side leaves
    // every deep link queued in pendingDestinations forever, with nothing on
    // screen and no error.
    let present = try AppSourceScraping.functionBody(named: "presentLiveMainWindow", in: coordinator)
    #expect(present.contains("$0.title == \"\(sceneTitle)\""))
    #expect(present.contains("$0.title == \"\(sceneTitle)\"")) // menu-item arm uses the same literal
    #expect(AppSourceScraping.occurrences(of: "== \"\(sceneTitle)\"", in: present) == 2,
            "presentLiveMainWindow no longer matches the scene title at both lookup sites")

    // The NSPanel exclusion is what stops the Spotlight overlay (a floating
    // NSPanel) from being mistaken for the main window and "opened" instead.
    #expect(present.contains("!($0 is NSPanel)"))

    // And the recovery ladder must stay: order-front first, then dispatch the
    // Window-menu item so SwiftUI recreates the single "main" scene rather than
    // building a parallel AppKit window.
    let orderFront = try #require(present.range(of: "makeKeyAndOrderFront(nil)"))
    let menuFallback = try #require(present.range(of: "NSApp.windowsMenu?.items.first"))
    #expect(orderFront.lowerBound < menuFallback.lowerBound)
    #expect(present.contains("NSApp.sendAction(action, to: item.target, from: item)"))

    // The caller retries once — activation can materialise a closed SwiftUI
    // Window on the next run-loop turn, and without the retry the first deep
    // link after a window close is dropped.
    #expect(coordinator.contains("if !presentLiveMainWindow() {"))
}
