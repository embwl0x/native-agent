import AppKit
import SwiftUI
import Testing
@testable import NativeAgentApp

/// In-process fixture only: no AppModel, real approval inbox, or provider.
@Suite(.serialized) @MainActor struct ChatControlAccessibilityTests {
    @Test(arguments: [false, true])
    func approvalButtonsPerformAccessibilityPress(resolving: Bool) async throws {
        let model = MacChatTurnCardModel(
            identity: .init(sessionId: "fixture", turnId: "fixture"), phase: .working,
            title: "Approve fixture action?", detail: "Local test only", delegateName: nil,
            tone: .attention, symbolName: "lock.shield", isTerminal: false,
            showsLiveIndicator: false, elapsed: 0, secondsSinceMovement: nil,
            cancellationPending: false,
            approval: .init(approvalId: "fixture", toolName: "fixture action", reason: nil, outcome: .pending))
        var decisions: [String] = []
        let fixture = host(MacChatTurnCard(model: model, onDecideApproval: { decisions.append($0) },
                                         isResolvingApproval: resolving, snapshotWithoutLiveGlass: true)
            .environment(\.dynamicTypeSize, .accessibility3)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        defer { fixture.window.orderOut(nil); fixture.window.contentView = nil
            NSApplication.shared.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        try await Task.sleep(for: .milliseconds(100))
        for (identifier, decision) in [("chat.turn.approve", "approved"), ("chat.turn.deny", "denied")] {
            let button = try #require(walk(fixture.view).first { read($0, "accessibilityIdentifier") as? String == identifier })
            #expect(action(button, "isAccessibilityEnabled") == !resolving)
            let rectangle = frame(button)
            #expect(rectangle.width > 0 && rectangle.height > 0)
            let container = fixture.window.convertToScreen(fixture.view.bounds)
            #expect(container.insetBy(dx: -1, dy: -1).contains(rectangle))
            _ = action(button, "accessibilityPerformPress")
            #expect(decisions == (resolving ? [] : (decision == "approved" ? ["approved"] : ["approved", "denied"])))
        }
    }

    @Test(arguments: [false, true])
    func narrowToolReceiptExpandsWithoutCoveringItsHeader(disableAnimations: Bool) async throws {
        var metadata = ChatMessageMetadata()
        metadata.toolName = "read_file"
        metadata.inputJSON = "{\"path\":\"/fixture/a-long-file-name.txt\"}"
        metadata.resultSummary = String(repeating: "Fixture result text. ", count: 12)
        metadata.ok = true
        let fixture = host(ToolPillView(message: ChatMessage(role: "tool", metadata: metadata))
            .environment(\.dynamicTypeSize, .accessibility3)
            // Reduce Motion is read-only in SDK 27. This covers an explicitly
            // animation-disabled transaction, not the system preference; that
            // setting remains part of isolated VM acceptance.
            .transaction {
                if disableAnimations { $0.disablesAnimations = true; $0.animation = nil }
            })
        defer { fixture.window.orderOut(nil); fixture.window.contentView = nil
            NSApplication.shared.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        try await Task.sleep(for: .milliseconds(100))
        let button = try #require(walk(fixture.view).first { read($0, "accessibilityIdentifier") as? String == "chat.tool.details" })
        #expect(read(button, "accessibilityRole") as? String == "AXButton")
        try #require(action(button, "accessibilityPerformPress"))
        for delay in [20, 60, 160] {
            try await Task.sleep(for: .milliseconds(delay))
            fixture.view.layoutSubtreeIfNeeded()
            let tree = walk(fixture.view)
            let header = try #require(tree.first { read($0, "accessibilityIdentifier") as? String == "chat.tool.details" })
            let detail = try #require(tree.first { element in
                ["accessibilityValue", "accessibilityLabel"].contains { read(element, $0) as? String == "Tool: read_file" }
            })
            // Accessibility frames use screen coordinates with y increasing up.
            #expect(frame(detail).maxY <= frame(header).minY + 1)
            #expect(read(header, "accessibilityValue") as? String == "Expanded")
        }
        let header = try #require(walk(fixture.view).first { read($0, "accessibilityIdentifier") as? String == "chat.tool.details" })
        try #require(action(header, "accessibilityPerformPress"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!walk(fixture.view).contains { read($0, "accessibilityValue") as? String == "Tool: read_file" })
    }

    private func host<V: View>(_ content: V) -> (window: NSWindow, view: NSHostingView<AnyView>) {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let view = NSHostingView(rootView: AnyView(VStack { content; Spacer() }.frame(width: 380)))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 380, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        // Materialize the test's AX tree without activating or keying a window.
        window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }
    private func read(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }
    private func walk(_ element: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 30 else { return [] }
        return [element] + ((read(element, "accessibilityChildren") as? [NSObject]) ?? [])
            .flatMap { walk($0, depth: depth + 1) }
    }
    private func action(_ element: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector), let method = element.method(for: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Method.self)(element, selector)
    }
    private func frame(_ element: NSObject) -> CGRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard element.responds(to: selector), let method = element.method(for: selector) else { return .zero }
        typealias Method = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(method, to: Method.self)(element, selector)
    }
}
