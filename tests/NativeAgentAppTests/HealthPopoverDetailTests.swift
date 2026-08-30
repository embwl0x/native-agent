import Testing
@testable import NativeAgentApp

@Test("compact health details retain their full explanation for reading and copying")
func healthPopoverDetailsRemainReadable() throws {
    let source = try AppSourceScraping.appSource("ChatRuntimeStatusChrome.swift")
    let detail = try #require(source.components(separatedBy: "Text(sub.detail)").dropFirst().first)
        .components(separatedBy: "Spacer()").first ?? ""
    #expect(detail.contains(".lineLimit(2)"))
    #expect(detail.contains(".textSelection(.enabled)"))
    #expect(detail.contains(".help(sub.detail)"))
}
