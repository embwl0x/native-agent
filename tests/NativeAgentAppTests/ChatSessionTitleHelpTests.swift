import Testing
@testable import NativeAgentApp

@Test("truncated session labels keep their full titles reachable without changing sessions")
func fullSessionTitlesAreAvailableInHoverHelp() throws {
    let sidebar = try AppSourceScraping.appSource("ChatView.swift")
    let tabs = try AppSourceScraping.appSource("ContextReceiptView.swift")
    #expect(sidebar.contains(#".help("\(session.displayTitle)\n\nHover for rename"#))
    #expect(tabs.contains(".help(session.displayTitle)"))
    // Existing specialized close/rename actions still describe their action,
    // not merely the title of the session they belong to.
    #expect(tabs.contains(".help(\"Unpin tab\")"))
    // The action now uses the same Chats vocabulary as the list.
    #expect(sidebar.contains("Rename Chat"))
}
