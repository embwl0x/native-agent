import AppKit
import SwiftUI

// Blueprint: | `NativeDisclosureTriangle.swift` | `NativeDisclosureTriangle`: AppKit disclosure button bridge sharing the row's expansion binding |

/// Native disclosure button folds rows in place while retaining their layout.
struct NativeDisclosureTriangle: NSViewRepresentable {
    var isOpen: Bool
    var accessibilityLabel: String
    var onToggle: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(DisclosureToggle.clicked))
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

    func makeCoordinator() -> DisclosureToggle { DisclosureToggle(onToggle: onToggle) }

    final class DisclosureToggle: NSObject {
        var onToggle: () -> Void
        init(onToggle: @escaping () -> Void) { self.onToggle = onToggle }
        @objc func clicked() { onToggle() }
    }
}
