import AppKit
import SwiftUI

// Blueprint: | `NativeSearchField.swift` | `NativeSearchField`: NSSearchField bridge with native clear/escape/return behavior and explicit focus tokens |

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var identifier: String
    var accessibilityLabel: String
    /// A nil token prevents the field from taking focus on its own.
    var onSubmit: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var focusRequest: UInt? = nil

    func makeNSView(context: Context) -> NSSearchField {
        let field = EscapableSearchField()
        field.onEscape = { [weak coordinator = context.coordinator] in
            guard let run = coordinator?.onEscape else { return false }
            run()
            return true
        }
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(accessibilityLabel)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape
        if let focusRequest, focusRequest != context.coordinator.focusedFor {
            context.coordinator.focusedFor = focusRequest
            // The first pass has no window, so defer focus until mounting finishes.
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> SearchEdits { SearchEdits(text: $text) }

    final class SearchEdits: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        var onEscape: (() -> Void)?
        var focusedFor: UInt?
        init(text: Binding<String>) { self.text = text }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)), let onSubmit { onSubmit(); return true }
            return false
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Give the caller Escape before NSSearchField consumes it to clear the field.
final class EscapableSearchField: NSSearchField {
    var onEscape: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true { super.cancelOperation(sender) }
    }
}
