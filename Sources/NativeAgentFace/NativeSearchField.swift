import AppKit
import SwiftUI

// Blueprint: | `NativeSearchField.swift` | `NativeSearchField`: NSSearchField bridge that publishes text edits |

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var identifier: String
    var accessibilityLabel: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
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
    }

    func makeCoordinator() -> SearchEdits { SearchEdits(text: $text) }

    final class SearchEdits: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
