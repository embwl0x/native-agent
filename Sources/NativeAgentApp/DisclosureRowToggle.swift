import SwiftUI

// User (2026-08-11): "I have to click on the tiny > to get it to open... I
// should be able to click on the whole thing." macOS DisclosureGroup only
// toggles on the chevron; this makes the ENTIRE label row a hit target.
// Apply to a DisclosureGroup's label view, passing the same binding the
// group uses.
struct DisclosureRowToggle: ViewModifier {
    @Binding var isExpanded: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            }
    }
}

extension View {
    /// Whole-row click-to-toggle for a DisclosureGroup label.
    func togglesDisclosure(_ isExpanded: Binding<Bool>) -> some View {
        modifier(DisclosureRowToggle(isExpanded: isExpanded))
    }
}
