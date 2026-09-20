import AppKit
import SwiftUI
import Testing
import ChatOrchestration
import PersistenceCore
import ApprovalInbox
@testable import NativeAgentApp

@Suite(.serialized) @MainActor struct AgentsTabAccessibilityTests {
    @Test(arguments: ["AXPress", "click"], ["Connect Codex", "Disconnect Fixture", "Send a test message to Fixture"])
    func tabExposesAndPressesConnectionButtons(activation: String, target: String) async throws {
        let application = NSApplication.shared
        application.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        defer { application.accessibilitySetValue(false, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agents-tab-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        var peer = AgentPeerContact(name: "ACP fixture", endpoint: URL(string: "acp://gemini-cli")!, transport: .acp)
        peer.approvedExecutablePath = "/fixture/gemini"
        peer.acpWorkingDirectory = "/fixture/work"
        let contact = AgentPeerContact(name: "Fixture", endpoint: URL(string: "https://agent.invalid/a2a")!, transport: .a2a)
        _ = try AgentPeerStore(dataRoot: root).upsert(contact)
        let rows = AgentContactRow.rows(peers: [peer, contact], installed: AgentHostDirectory.rows.filter { $0.id == "codex" })
        let host = NSHostingView(rootView: ShellTabbedPage(title: "Connectors", tabs: ConnectorsRailPage.tabs,
                                                         selection: .constant("agents")) { _ in
            AgentContactsSection(fixtureRows: rows).environment(model)
        })
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.title = "Agent contacts accessibility fixture"
        window.makeKeyAndOrderFront(nil)
        #expect(window.isVisible)
        #expect(application.windows.contains(window))
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // SwiftUI's virtual nodes expose the Objective-C accessibility API;
        // they do not all declare NSAccessibilityProtocol conformance.
        func read(_ element: NSObject, _ selector: String) -> Any? {
            let selector = NSSelectorFromString(selector)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        func booleanAction(_ element: NSObject, _ name: String) -> Bool {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector), let implementation = element.method(for: selector) else { return false }
            // These public NSAccessibility methods return BOOL, not an object.
            typealias Method = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Method.self)(element, selector)
        }
        func walk(_ value: Any, depth: Int = 0) -> [NSObject] {
            guard depth < 30, let element = value as? NSObject else { return [] }
            return [element] + ((read(element, "accessibilityChildren") as? [Any]) ?? [])
                .flatMap { walk($0, depth: depth + 1) }
        }
        let tree = walk(host)
        let spoken = tree.flatMap { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { read(element, $0) as? String }
        }.joined(separator: "\n")
        for detail in ["Route: ACP", "Starts in folder: /fixture/work", "Program: /fixture/gemini", "Cannot start a turn now"] {
            #expect(spoken.contains(detail), "Missing accessible ACP detail: \(detail)")
        }
        let buttons = tree.filter { (read($0, "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue }
        for label in ["Agents", "Connect Codex", "Disconnect Fixture",
                      "Send a test message to Fixture"] {
            let button = try #require(buttons.first {
                (read($0, "accessibilityLabel") as? String) == label
                    || (read($0, "accessibilityTitle") as? String) == label
            }, "Missing accessible button: \(label)")
            if label == target {
                try #require(booleanAction(button, "isAccessibilityEnabled"))
                if activation == "AXPress" {
                    // AXPress maps to this public NSAccessibility selector.
                    // SwiftUI implements the modern protocol, not NSObject's
                    // deprecated accessibilityActionNames/PerformAction pair.
                    let press = NSSelectorFromString("accessibilityPerformPress")
                    let allowed = NSSelectorFromString("isAccessibilitySelectorAllowed:")
                    try #require(button.responds(to: press))
                    try #require(button.responds(to: allowed))
                    typealias AllowedMethod = @convention(c) (AnyObject, Selector, Selector) -> Bool
                    let implementation = try #require(button.method(for: allowed))
                    try #require(unsafeBitCast(implementation, to: AllowedMethod.self)(button, allowed, press),
                        "\(target) must allow AXPress")
                    #expect(booleanAction(button, "accessibilityPerformPress"))
                } else {
                    let selector = NSSelectorFromString("accessibilityFrame")
                    typealias FrameMethod = @convention(c) (AnyObject, Selector) -> CGRect
                    let implementation = try #require(button.method(for: selector))
                    let frame = unsafeBitCast(implementation, to: FrameMethod.self)(button, selector)
                    let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                        window.sendEvent(event)
                    }
                }
            }
        }
        for _ in 0..<100 {
            if !model.activeChatSessionId.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.activeChatSessionId.isEmpty)
        let records = try await SwiftNativeApprovalInbox(root: root).list(filter: .pending)
        #expect(records.isEmpty, "The page must hand off to chat without filing its own approval.")
    }

    @Test func discoveryKeepsBuiltInAndOrdinaryCodexAndRoutesA2AConnect() throws {
        let local = AgentDiscoveryCandidate(name: "Codex", detail: "Coding agent", hostID: "codex",
            settingsPath: "/fixture/.codex/config.toml", cardURL: nil, endpoint: nil)
        let address = URL(string: "http://127.0.0.1:9999/.well-known/agent-card.json")!
        let nearby = AgentDiscoveryCandidate(name: "Fixture", detail: "Local helper", hostID: nil,
            settingsPath: nil, cardURL: address, endpoint: URL(string: "http://127.0.0.1:9999/a2a")!)
        let rows = AgentContactRow.rows(peers: [], candidates: [local, nearby], usable: ["codex"])
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(rows.contains { $0.displayName == "Codex (built-in connection)" })
        #expect(rows.contains { $0.displayName == "Codex (agent contact)" })
        #expect(AgentContactRow.rows(peers: [], candidates: [local], usable: []).first?.displayName == "Codex")
        let found = try #require(rows.first { $0.candidate != nil })
        #expect(found.prompt(.connect) == "Connect to Fixture.")
        #expect(found.route.contains("A2A address"))
        #expect(AgentContactRow.rows(peers: [AgentPeerContact(name: "Saved", endpoint: address, transport: .a2a)],
            candidates: [nearby], usable: []).count == 1)
    }

    @Test func sidebarActionsStayInsidePagesAndCardsUsePlainWords() throws {
        for file in ["ConnectorsView.swift", "MCPHubView.swift", "MemoryView.swift", "MacIntegrationView.swift",
                     "ToolsView.swift", "RunsView.swift", "DeskView.swift", "WorkshopHubView.swift"] {
            #expect(!(try AppSourceScraping.appSource(file)).contains(".toolbar {"))
        }
        let page = try AppSourceScraping.appSource("ShellRailPages.swift")
        #expect(page.contains("ShellTab(key: \"agents\", title: \"Agents\")"))
        #expect(page.contains("case \"agents\": AgentContactsSection()"))
        #expect(ConnectorsView.plainStatus("needs_auth") == "Needs sign-in")
        #expect(ConnectorsView.accessLabel("network_read") == "Reads the web")
        #expect(ConnectorsView.accessLabel("network_write") == "Can change things online")
        #expect(ConnectorsView.accessLabel("file_access") == "Reads your files")
        for tag in ["macos", "dev", "system_surface"] { #expect(ConnectorsView.accessLabel(tag) == nil) }
    }
}
