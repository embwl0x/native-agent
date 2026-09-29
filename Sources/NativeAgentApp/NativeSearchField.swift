import AppKit
import SwiftUI

/// The Mac's own search field (NSSearchField): magnifier, placeholder, clear
/// button, Escape-to-clear and the system look in every appearance (User
/// 09-27: all controls Mac native).
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var identifier: String
    var accessibilityLabel: String
    /// Return, Escape, and a token that pulls the cursor in when it changes
    /// (nil: the field never takes focus on its own).
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
            // After the view is in its window (first pass has none yet).
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
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

/// NSSearchField keeps Escape for itself (clearing); with an onEscape the
/// caller gets it first.
final class EscapableSearchField: NSSearchField {
    var onEscape: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true { super.cancelOperation(sender) }
    }
}
