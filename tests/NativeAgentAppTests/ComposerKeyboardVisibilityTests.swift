import AppKit
import Observation
import SwiftUI
import Testing
@testable import NativeAgentApp

@MainActor @Observable
private final class ComposerKeyboardFixtureState {
    var enabled = false
}

private struct ComposerKeyboardFixture: View {
    var state: ComposerKeyboardFixtureState

    var body: some View {
        TextField("Draft", text: .constant(""))
            // Simulate a retained composer whose focus binding has not reset.
            .shellComposerKeyboardTarget(isFocused: true, focus: {})
            .disabled(!state.enabled)
    }
}

@MainActor @Suite(.serialized)
struct ComposerKeyboardVisibilityTests {
    @Test("A retained disabled composer cannot keep its native key interceptor active")
    func disabledComposerWithStaleFocus() async throws {
        guard ProcessInfo.processInfo.environment["NATIVEAGENT_UI_MOTION_CHECK"] == "1" else { return }
        _ = NSApplication.shared
        let state = ComposerKeyboardFixtureState()
        let host = NSHostingView(rootView: ComposerKeyboardFixture(state: state))
        let window = NSWindow(
            contentRect: NSRect(x: 1200, y: 100, width: 400, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        for _ in 0..<40 where monitor(in: host) == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        let interceptor = try #require(monitor(in: host))
        #expect(!interceptor.active)

        state.enabled = true
        for _ in 0..<40 where !interceptor.active {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(interceptor.active, "Returning to Chat must restore its keyboard behavior")

        state.enabled = false
        for _ in 0..<40 where interceptor.active {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(monitor(in: host) === interceptor, "The composer remains mounted")
        #expect(!interceptor.active, "Stale focus cannot override the hidden page's disabled state")
    }

    private func monitor(in view: NSView) -> ComposerTabKeyHandler.TabView? {
        if let monitor = view as? ComposerTabKeyHandler.TabView { return monitor }
        for child in view.subviews {
            if let monitor = monitor(in: child) { return monitor }
        }
        return nil
    }
}
