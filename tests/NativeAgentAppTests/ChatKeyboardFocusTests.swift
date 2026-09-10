import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Chat keyboard focus")
struct ChatKeyboardFocusTests {
    /// No window is created: pin the mounted focus declarations as well as the
    /// actual destination callbacks. This does not emulate AppKit's live loop.
    @Test @MainActor
    func composerTabReachesVisibleDetailsAndRailBacktabReturnsToComposer() throws {
        let shell = try AppSourceScraping.appSource("ShellWindowChrome.swift")
        let composer = try AppSourceScraping.appSource("ChatComposerChrome.swift")
        let chat = try AppSourceScraping.appSource("ChatView.swift")
        let rail = try AppSourceScraping.appSource("ShellSidebarRail.swift")
        let receipt = try AppSourceScraping.appSource("ChatToolPillView.swift")
        let transcript = try AppSourceScraping.appSource("ChatShellViews.swift")
        #expect(shell.contains(".environment(\\.shellKeyboardOrder, keyboardOrder)"))
        #expect(shell.components(separatedBy: "sidebar().focusSection()").count == 3)
        #expect(shell.components(separatedBy: "detail().focusSection()").count == 3)
        #expect(shell.contains("content.focused($focused)"))
        #expect(shell.contains(".onScrollVisibilityChange(threshold: 0.01)"))
        #expect(shell.contains("region != .receipt || visible"))
        #expect(chat.contains(".shellComposerKeyboardTarget(isFocused: inputFocused) { inputFocused = true }"))
        #expect(composer.contains("event.keyCode == 48"))
        #expect(composer.contains("event.window === window"))
        #expect(composer.contains("editor.insertText(\"\\t\", replacementRange: editor.selectedRange())"))
        #expect(composer.components(separatedBy: ".shellKeyboardTarget(.send)").count == 3)
        #expect(rail.contains(".shellKeyboardTarget(.rail)"))
        #expect(rail.contains(".focusable(false)"))
        #expect(receipt.contains(".shellKeyboardTarget(.receipt)"))
        #expect(transcript.contains(".shellKeyboardTarget(.receipt)"))
        #expect(receipt.contains(".onKeyPress(.return) { toggleDetails(); return .handled }"))
        #expect(receipt.contains(".onKeyPress(.space) { toggleDetails(); return .handled }"))

        let order = ShellKeyboardOrder()
        let firstRail = UUID(), draft = UUID(), newest = UUID(), older = UUID(), send = UUID()
        var focused: UUID?
        for (id, region, y): (UUID, ShellKeyboardOrder.Region, CGFloat) in [
            (firstRail, .rail, 20), (older, .receipt, 100),
            (newest, .receipt, 200), (draft, .composer, 300), (send, .send, 350)
        ] {
            order.destinations[id] = .init(id: id, region: region, y: y) { focused = id }
        }
        #expect(order.ordered.map(\.id) == [firstRail, newest, older, draft, send])
        #expect(order.move(from: firstRail, backwards: false))
        #expect(focused == newest)
        #expect(order.move(from: newest, backwards: false))
        #expect(focused == older)
        #expect(order.move(from: older, backwards: false))
        #expect(focused == draft)
        #expect(order.move(from: draft, backwards: false))
        #expect(focused == newest)
        #expect(order.move(from: newest, backwards: false))
        #expect(focused == older)
        #expect(order.move(from: older, backwards: false))
        #expect(focused == send)
        #expect(order.move(from: send, backwards: false))
        #expect(focused == firstRail)
        #expect(order.move(from: firstRail, backwards: true))
        #expect(focused == draft)
        order.destinations.removeValue(forKey: newest)
        order.destinations.removeValue(forKey: older)
        #expect(order.move(from: draft, backwards: false))
        #expect(focused == send)
        order.destinations.removeValue(forKey: send)
        #expect(order.move(from: draft, backwards: false))
        #expect(focused == firstRail)
        order.destinations.removeValue(forKey: draft)
        #expect(!order.move(from: firstRail, backwards: false))
    }
}
