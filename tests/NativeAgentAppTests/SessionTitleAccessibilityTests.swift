import Testing
@testable import NativeAgentApp

@Test("session title accessibility shares pointer selection without swallowing rename or drag")
func sessionTitleExposesTheExistingSelectionAction() throws {
    let chat = try AppSourceScraping.appSource("ChatView.swift")
    let row = try #require(AppSourceScraping.looseFunctionBody(named: "sidebarSessionRow", in: chat))
    #expect(row.contains("let selectSession: () -> Void"))
    #expect(row.contains("guard !renaming else { return }"))
    #expect(row.contains("onSelect: selectSession"))
    #expect(row.contains(".onTapGesture(perform: selectSession)"))
    #expect(AppSourceScraping.occurrences(of: "appModel.selectChatSession(session)", in: row) == 1)
    #expect(row.contains("SessionDragSource(sessionId: session.id"))
    #expect(row.contains(".contextMenu"))

    let source = try AppSourceScraping.appSource("ContextReceiptView.swift")
    let title = try #require(source.components(separatedBy: "private var titleView: some View").dropFirst().first)
        .components(separatedBy: "private func endRename").first ?? ""
    let display = try #require(title.components(separatedBy: "Text(session.displayTitle)").dropFirst().first)
    #expect(display.contains(".accessibilityLabel(session.displayTitle)"))
    #expect(display.contains(".accessibilityAddTraits(.isButton)"))
    #expect(display.contains(".accessibilityValue(selected ? \"Selected\" : \"Not selected\")"))
    #expect(display.contains(".accessibilityAction { onSelect() }"))
    let editor = title.components(separatedBy: "} else {").first ?? ""
    #expect(editor.contains("TextField(\"Session\""))
    #expect(!editor.contains(".accessibilityAction"))
}
