import AppKit
import SwiftUI

/// The Mac's own disclosure triangle (NSButton, disclosure bezel) for rows
/// that fold in place but keep their own layout, where a DisclosureGroup
/// would move the triangle off the title (User 09-27: all controls native).
struct NativeDisclosureTriangle: NSViewRepresentable {
    var isOpen: Bool
    var accessibilityLabel: String
    var onToggle: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .disclosure
        button.setButtonType(.onOff)
        button.state = isOpen ? .on : .off
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        button.setAccessibilityLabel(accessibilityLabel)
        let state: NSControl.StateValue = isOpen ? .on : .off
        if button.state != state { button.state = state }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    final class Coordinator: NSObject {
        var onToggle: () -> Void
        init(onToggle: @escaping () -> Void) { self.onToggle = onToggle }
        @objc func clicked() { onToggle() }
    }
}
