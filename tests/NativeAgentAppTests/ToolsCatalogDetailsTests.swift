import AppKit
import SwiftUI
import Testing
@testable import NativeAgentApp

@Suite("Tool catalog detail disclosure")
struct ToolsCatalogDetailsTests {
    @MainActor
    @Test("tool details have a named semantic control without stealing selectable row text clicks")
    func detailsAreAnExplicitReadOnlyAction() throws {
        let collapsed = ChatToolDetailsButton(toolName: "doctor_status", isExpanded: .constant(false))
        let expanded = ChatToolDetailsButton(toolName: "doctor_status", isExpanded: .constant(true))
        #expect(NSHostingView(rootView: collapsed).fittingSize.height > 0)
        #expect(NSHostingView(rootView: expanded).fittingSize.height > 0)
        let source = try AppSourceScraping.appSource("ToolsView.swift")
        let row = try #require(source.components(separatedBy: "private func toolRow(_ tool: ChatCatalogTool)").last)
            .components(separatedBy: "private func statusBadge").first ?? ""
        #expect(row.contains("ChatToolDetailsButton(toolName: tool.name"))
        #expect(row.contains("if value { expanded.insert(tool.id) } else { expanded.remove(tool.id) }"))
        #expect(row.contains(".textSelection(.enabled)"))
        #expect(!row.contains(".onTapGesture"))
        #expect(source.contains(#".accessibilityLabel("\(isExpanded ? "Hide" : "Show") details for \(toolName)")"#))
        #expect(source.contains(".accessibilityValue(isExpanded ? \"Expanded\" : \"Collapsed\")"))
        #expect(source.contains("This does not run the tool."))
    }
}
