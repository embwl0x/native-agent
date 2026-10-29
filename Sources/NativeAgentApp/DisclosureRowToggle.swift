import SwiftUI

// Blueprint: | `DisclosureRowToggle.swift` | `DisclosureRowToggle`: whole-label disclosure hit target sharing the DisclosureGroup's existing binding |

// The whole disclosure label toggles the same binding as its DisclosureGroup.
struct DisclosureRowToggle: ViewModifier {
    @Binding var isExpanded: Bool

    func body(content: Content) -> some View {
        Button {
            withAnimation(NativeAgentMotion.arrive) { isExpanded.toggle() }
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

extension View {
    /// Whole-row click-to-toggle for a DisclosureGroup label.
    func togglesDisclosure(_ isExpanded: Binding<Bool>) -> some View {
        modifier(DisclosureRowToggle(isExpanded: isExpanded))
    }
}
