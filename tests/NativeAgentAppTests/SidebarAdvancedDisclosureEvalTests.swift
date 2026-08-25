import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.nav.advancedDisclosure

@MainActor
@Suite("Sidebar Advanced disclosure", .serialized)
struct SidebarAdvancedDisclosureEvalTests {
    @Test("Advanced toggle persists and projects its real sidebar rows")
    func advancedDisclosureChangesRowsInBothDirections() throws {
        let suiteName = "SidebarAdvancedDisclosureEvalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expectedRows = SidebarItem.visibleAdvancedItems(developerSurfacesEnabled: true)

        SidebarAdvancedDisclosurePresentation.setExpanded(false, in: defaults)
        #expect(SidebarAdvancedDisclosurePresentation.isExpanded(in: defaults) == false)
        #expect(SidebarAdvancedDisclosurePresentation.accessibilityValue(isExpanded: false) == "Collapsed")
        #expect(SidebarAdvancedDisclosurePresentation.visibleRows(
            isExpanded: false,
            developerSurfacesEnabled: true
        ).isEmpty)

        #expect(SidebarAdvancedDisclosurePresentation.toggle(in: defaults) == true)
        #expect(SidebarAdvancedDisclosurePresentation.isExpanded(in: defaults) == true)
        #expect(SidebarAdvancedDisclosurePresentation.accessibilityValue(isExpanded: true) == "Expanded")
        #expect(SidebarAdvancedDisclosurePresentation.visibleRows(
            isExpanded: true,
            developerSurfacesEnabled: true
        ) == expectedRows)

        #expect(SidebarAdvancedDisclosurePresentation.toggle(in: defaults) == false)
        #expect(SidebarAdvancedDisclosurePresentation.isExpanded(in: defaults) == false)
        #expect(SidebarAdvancedDisclosurePresentation.visibleRows(
            isExpanded: false,
            developerSurfacesEnabled: true
        ).isEmpty)
    }
}
