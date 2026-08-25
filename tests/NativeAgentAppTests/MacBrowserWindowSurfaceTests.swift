import Foundation
import Testing
@testable import NativeAgentApp

// Ledger fence app.mac — rows `public-api.BrowserWindowController.quietLoad`,
// `ui.menu.browserWindow`, `route.browserStatusUnauthenticated`,
// `public-api.BrowserWindowController.navigate`,
// `public-api.BrowserNavDelegate.httpStatusTruthfulness`, and
// `loop.browserIPCConnectionReaper`.
//
// Every interesting member of BrowserWindowController is `private` (routeIPC,
// statusPayload, endpointIsLoopback, jsStringLiteral, dropIPCConnection) or
// requires a live WKWebView + NWListener, so these are source-conformance
// guards: they read the shipped source and fail when the invariant's WORDING
// in code changes. That is weaker than executing the path, but each one bites
// on the exact mutation the ledger names, and every assertion below was
// confirmed to fail when the corresponding line is removed.

private func browserSource() throws -> String {
    try AppSourceScraping.appSource("BrowserWindow.swift")
}

// MARK: - quiet load vs deliberate show (User's 3:30am regression)

@Test("showWindow fronts and activates; ensureWindowLoadedQuietly does neither")
func browserQuietLoad_neverStealsTheScreen() throws {
    let source = try browserSource()

    let show = try AppSourceScraping.functionBody(named: "showWindow", in: source)
    #expect(show.contains("NSApp.activate(ignoringOtherApps: true)"))
    #expect(show.contains("makeKeyAndOrderFront"))
    #expect(show.contains("deminiaturize"))

    let quiet = try AppSourceScraping.functionBody(named: "ensureWindowLoadedQuietly", in: source)
    // The whole point of the split: the quiet path may CREATE the window (the
    // WKWebView needs one to render for text/screenshot capture) and nothing else.
    #expect(quiet.contains("ensureWindow()"))
    for stealer in ["activate(", "makeKeyAndOrderFront", "orderFrontRegardless", "deminiaturize", "setActivationPolicy"] {
        #expect(!quiet.contains(stealer), "ensureWindowLoadedQuietly must not \(stealer)")
    }
}

@Test("navigate() only ensures the window exists — the agent lane cannot front the browser")
func browserNavigate_usesTheQuietPath() throws {
    let source = try browserSource()
    let navigate = try AppSourceScraping.functionBody(named: "navigate", in: source)

    // Confirmed at HEAD: navigate() calls the bare `ensureWindow()` (which is
    // exactly what ensureWindowLoadedQuietly wraps). The invariant that matters
    // is the negative one — no screen-stealing call may appear on this path.
    #expect(navigate.contains("ensureWindow()"))
    for stealer in ["showWindow()", "activate(", "makeKeyAndOrderFront", "orderFrontRegardless", "deminiaturize"] {
        #expect(!navigate.contains(stealer), "navigate() must not \(stealer) — this is the 3:30am regression")
    }
}

@Test("showWindow has exactly the three deliberate callers, plus the menu mirror")
func browserShow_callSitesAreTheDeliberateSurfacesOnly() throws {
    let root = try AppSourceScraping.appSourcesRoot()
    var callSites: [String] = []
    for (file, source) in try AppSourceScraping.swiftSourceContents(under: root) {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("showWindow()"),
                  !trimmed.hasPrefix("//"),
                  !trimmed.hasPrefix("///"),
                  !trimmed.hasPrefix("func ") else { continue }
            callSites.append(file)
        }
    }

    // Window > Browser menu item + its menu-bar mirror (NativeAgentApp.swift x2),
    // the browser_show tool (AppModel+GraphCapabilityActions.swift), and the
    // /browser/show IPC route (BrowserWindow.swift). A new file appearing here
    // means an agent-lane caller learned to front the window.
    #expect(
        Set(callSites) == [
            "NativeAgentApp.swift",
            "AppModel+GraphCapabilityActions.swift",
            "BrowserWindow.swift",
        ],
        "unexpected showWindow() caller: \(callSites.sorted())"
    )
    #expect(callSites.filter { $0 == "NativeAgentApp.swift" }.count == 2)
}

// MARK: - the unauthenticated route surface

@Test("exactly one IPC path is exempt from the bearer check")
func browserIPC_onlyStatusSkipsAuth() throws {
    let source = try browserSource()
    let route = try AppSourceScraping.functionBody(named: "routeIPC", in: source)

    // The exemption is written as a single `path != "…"` guard. A second
    // exempted path — however it is spelled — changes this shape.
    #expect(route.contains("if path != \"/browser/status\" {"))
    #expect(AppSourceScraping.occurrences(of: "if path != ", in: route) == 1)
    #expect(!route.contains("||"), "a compound exemption predicate widened the unauthenticated surface")

    // And the check itself stays an exact compare against the whole header.
    #expect(route.contains("guard auth == \"Bearer \\(ipcToken)\""))
    #expect(!route.contains("hasPrefix(\"Bearer"))
    #expect(!route.contains("auth.contains("))
    #expect(route.contains("writeIPCJSON(conn, status: 401"))
}

@Test("the loopback refusal runs before a connection is ever retained")
func browserIPC_loopbackGuardPrecedesRegistration() throws {
    let source = try browserSource()
    let accept = try AppSourceScraping.functionBody(named: "acceptIPC", in: source)

    let guardRange = try #require(accept.range(of: "endpointIsLoopback(conn.endpoint)"))
    let retainRange = try #require(accept.range(of: "connections[key] = conn"))
    // A non-loopback peer must never enter the connections dictionary — if the
    // guard moves below the retain, a refused peer still leaks an entry.
    #expect(guardRange.lowerBound < retainRange.lowerBound)
    #expect(accept.contains("conn.cancel()"))
}

// MARK: - connection reaper (state-lifecycle leak)

@Test("every connection eviction tears down both dictionaries and its timeout Task")
func browserIPC_dropEvictsBothMapsAndCancelsTheTimer() throws {
    let source = try browserSource()
    let drop = try AppSourceScraping.functionBody(named: "dropIPCConnection", in: source)

    #expect(drop.contains("connections.removeValue(forKey: key)"))
    // The `?.cancel()` on the removed Task is the whole leak fix: removing the
    // entry without cancelling leaves an orphaned sleeper holding a weak conn.
    #expect(drop.contains("connectionTimeouts.removeValue(forKey: key)?.cancel()"))

    // Both terminal NWConnection states must route here. Dropping either arm
    // strands the pair forever in a process that runs for weeks.
    let accept = try AppSourceScraping.functionBody(named: "acceptIPC", in: source)
    #expect(accept.contains("if case .cancelled = state"))
    #expect(accept.contains("if case .failed = state"))
    #expect(AppSourceScraping.occurrences(of: "dropIPCConnection(key)", in: accept) == 2)

    // And the route-time re-arm must cancel the previous Task before replacing
    // it, or the 15s idle sleeper survives alongside the 120s one.
    let route = try AppSourceScraping.functionBody(named: "routeIPC", in: source)
    let cancelRange = try #require(route.range(of: "connectionTimeouts[timeoutKey]?.cancel()"))
    let rearmRange = try #require(route.range(of: "connectionTimeouts[timeoutKey] = Task"))
    #expect(cancelRange.lowerBound < rearmRange.lowerBound)
}

// MARK: - HTTP status truthfulness

@Test("a navigation's http status is reset per navigation and captured main-frame only")
func browserNavDelegate_neverFabricatesAStatus() throws {
    let source = try browserSource()

    // The reset. Without it a prior page's 200 leaks into a file:/about: load
    // that produced no HTTP response at all.
    #expect(source.contains("didStartProvisionalNavigation"))
    let start = source.range(of: "didStartProvisionalNavigation")
    let startBody = try #require(start.flatMap { r -> String? in
        guard let open = source[r.upperBound...].firstIndex(of: "{"),
              let close = AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}")
        else { return nil }
        return String(source[open...close])
    })
    #expect(startBody.contains("lastHTTPStatus = nil"))

    // Main-frame filter — a sub-frame's 204 must not overwrite the page status.
    #expect(source.contains("if navigationResponse.isForMainFrame {"))
    #expect(source.contains("lastHTTPStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode"))

    // didFinish forwards the captured optional; it must never substitute a
    // literal success code (404/500 pages "finish" successfully).
    let finishRange = try #require(source.range(of: "func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)"))
    let open = try #require(source[finishRange.upperBound...].firstIndex(of: "{"))
    let close = try #require(AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}"))
    let finishBody = String(source[open...close])
    #expect(finishBody.contains("httpStatus: lastHTTPStatus"))
    #expect(!finishBody.contains("httpStatus: 200"))
    #expect(!finishBody.contains("?? 200"))

    // NavResult carries it as an OPTIONAL — a non-optional field would force a
    // fabricated value at every construction site.
    #expect(source.contains("let httpStatus: Int?"))
}

// MARK: - single-flight latch lifecycle

@Test("navigate's single-flight latch is cleared on every terminal path")
func browserNavigate_latchNeverWedgesPermanently() throws {
    let source = try browserSource()
    let navigate = try AppSourceScraping.functionBody(named: "navigate", in: source)

    // `onFinish != nil` IS the busy latch; if any terminal path forgets to
    // clear it, EVERY later navigate throws .busy forever.
    #expect(navigate.contains("if navDelegate.onFinish != nil"))
    #expect(navigate.contains("BrowserError.busy"))

    // The timeout arm must both stop the load and clear the latch before
    // resuming, and it must cancel itself on the success path.
    #expect(navigate.contains("stopLoading()"))
    #expect(navigate.contains("timeoutTask.cancel()"))
    #expect(navigate.contains("activeNavigationID = nil"))

    // Cancellation is wired, so an abandoned turn does not strand the latch.
    #expect(navigate.contains("withTaskCancellationHandler"))

    let cancel = try AppSourceScraping.functionBody(named: "cancelNavigation", in: source)
    #expect(cancel.contains("onFinish"))

    // Every delegate terminal callback clears onFinish: didFinish, didFail,
    // didFailProvisionalNavigation.
    #expect(AppSourceScraping.occurrences(of: "onFinish = nil", in: source) >= 3)
}
